import Foundation
import CryptoKit

/// All document mutations and connection callbacks are serialized on the editor's main actor.
@MainActor final class CanvasStore {
    let authorID: String
    private let clientKey: String
    var authorName = "Me"
    private(set) var document = CanvasDocument()
    private(set) var session = CanvasSession()
    private(set) var status = "Saved on this iPad"
    private(set) var presences: [String: (CanvasPresence, Date)] = [:]
    var changed: (() -> Void)?
    var message: ((String) -> Void)?
    private var storageKey = "local"
    private var endpoint: URL?
    private var room = ""
    private var token = ""
    private var socket: URLSessionWebSocketTask?
    private var generation = UUID()
    private var connected = false
    private var outbound: [Data] = []
    private var sending = false
    private var receiveTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var retry = 0
    private var localPresence: CanvasPresence?
    private var activeStrokeID: String?
    private let directory: URL

    init(directory: URL? = nil, participantKey: String? = nil) {
        let defaults = UserDefaults.standard
        let key = participantKey ?? defaults.string(forKey: "canvasClientKey") ?? UUID().uuidString + UUID().uuidString
        if participantKey == nil { defaults.set(key, forKey: "canvasClientKey") }
        clientKey = key
        authorID = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CanvasSessions", isDirectory: true)
        loadSession()
        ensureLayer()
    }

    var canResize: Bool { document.hostID == nil || document.hostID == authorID }
    var isRoom: Bool { endpoint != nil }
    var ownLayers: [CanvasLayer] { document.layers.filter { $0.ownerID == authorID } }

    private var file: URL { directory.appendingPathComponent(storageKey + ".json") }
    private func loadSession() {
        do {
            if FileManager.default.fileExists(atPath: file.path) {
                session = try JSONDecoder().decode(CanvasSession.self, from: Data(contentsOf: file))
            } else { session = CanvasSession() }
        } catch { status = "Could not open saved canvas"; session = CanvasSession() }
        rebuild()
    }
    func save() {
        saveTask?.cancel()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(session).write(to: file, options: .atomic)
        } catch { status = "Could not save: \(error.localizedDescription)"; changed?() }
    }
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            self?.save()
        }
    }
    private func rebuild() {
        document = session.confirmed
        for op in session.pending { document.apply(op) }
    }
    func submit(_ operation: CanvasOperation) {
        guard document.apply(operation) else { return }
        if operation.kind == "beginStroke" { activeStrokeID = operation.stroke?.id }
        if operation.kind == "endStroke", operation.strokeID == activeStrokeID { activeStrokeID = nil }
        if isRoom {
            session.pending.append(operation)
            if connected { enqueue(operationEnvelope(operation)) }
        } else { session.confirmed = document }
        scheduleSave()
        changed?()
    }
    func ensureLayer() {
        guard ownLayers.isEmpty else { return }
        addLayer()
    }
    func addLayer() {
        let layer = CanvasLayer(ownerID: authorID, ownerName: authorName, name: "\(authorName == "Me" ? "My" : authorName + "’s") layer \(ownLayers.count + 1)")
        submit(CanvasOperation(kind: "addLayer", authorID: authorID, layer: layer))
    }
    func undo() {
        guard let stroke = document.undoTarget(for: authorID) else { return }
        submit(CanvasOperation(kind: "strokeVisibility", authorID: authorID, strokeID: stroke.id, visible: false))
    }
    func redo() {
        guard let stroke = document.redoTarget(for: authorID) else { return }
        submit(CanvasOperation(kind: "strokeVisibility", authorID: authorID, strokeID: stroke.id, visible: true))
    }
    func activity(layerID: String?, drawing: Bool) {
        let presence = CanvasPresence(authorID: authorID, name: authorName, layerID: layerID, drawing: drawing)
        localPresence = presence
        presences[authorID] = (presence, Date())
        if connected { enqueuePresence(presence) }
        changed?()
    }
    func heartbeat() {
        let now = Date()
        presences = presences.filter { now.timeIntervalSince($0.value.1) < 4 }
        if let presence = localPresence {
            presences[authorID] = (presence, now)
            if connected { enqueuePresence(presence) }
        }
        changed?()
    }
    func activeArtists(on layerID: String) -> [CanvasPresence] {
        presences.values.filter { $0.0.layerID == layerID && $0.0.drawing && Date().timeIntervalSince($0.1) < 4 }
            .map { $0.0 }.sorted { $0.authorID < $1.authorID }
    }

    func connect(url: URL, room: String, token: String, name: String) {
        disconnect()
        endpoint = url; self.room = room; self.token = token
        authorName = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        if authorName.isEmpty { authorName = "Artist" }
        storageKey = SHA256.hash(data: Data((url.absoluteString + "/" + room).utf8)).map { String(format: "%02x", $0) }.joined()
        loadSession()
        status = "Connecting…"
        changed?()
        openSocket()
    }
    func disconnect() {
        save()
        generation = UUID()
        receiveTask?.cancel(); reconnectTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil; connected = false; outbound.removeAll(); sending = false
        endpoint = nil; activeStrokeID = nil; localPresence = nil; presences.removeAll()
    }
    func useLocalCanvas() {
        disconnect()
        storageKey = "local"; authorName = "Me"
        loadSession(); ensureLayer()
        status = "Saved on this iPad"; changed?()
    }
    private func openSocket() {
        guard let endpoint else { return }
        let current = UUID(); generation = current
        let task = URLSession.shared.webSocketTask(with: endpoint)
        task.maximumMessageSize = 32 * 1024 * 1024
        socket = task; task.resume()
        enqueue(["type": "join", "room": room, "token": token, "clientKey": clientKey,
                 "name": authorName, "pendingIDs": session.pending.map(\.id)])
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard let self, self.generation == current else { return }
                    let data: Data
                    switch message {
                    case .data(let value): data = value
                    case .string(let value): data = Data(value.utf8)
                    @unknown default: continue
                    }
                    try self.receive(data)
                }
            } catch {
                guard let self, self.generation == current else { return }
                self.lostConnection()
            }
        }
    }
    private func lostConnection() {
        guard isRoom else { return }
        generation = UUID(); connected = false
        socket?.cancel(with: .goingAway, reason: nil)
        outbound.removeAll(); sending = false
        status = "Reconnecting · saved on this iPad"
        presences.removeAll(); changed?()
        retry = min(retry + 1, 5)
        let delay = UInt64(min(30, pow(2, Double(retry)))) * 1_000_000_000
        reconnectTask?.cancel()
        reconnectTask = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: delay) } catch { return }
            self?.openSocket()
        }
    }
    private func operationEnvelope(_ op: CanvasOperation) -> [String: Any] {
        let object = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(op))) ?? [:]
        return ["type": "operation", "operation": object]
    }
    private func enqueuePresence(_ presence: CanvasPresence) {
        guard let object = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(presence)) else { return }
        enqueue(["type": "presence", "presence": object])
    }
    private func enqueue(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        // Durable edits remain in session.pending and are retried after a fresh snapshot.
        guard outbound.count < 512 else { lostConnection(); return }
        outbound.append(data)
        guard !sending, let socket else { return }
        sending = true
        let current = generation
        Task { [weak self] in
            do {
                while let self, self.generation == current, !self.outbound.isEmpty {
                    let next = self.outbound.removeFirst()
                    try await socket.send(.data(next))
                }
                if let self, self.generation == current { self.sending = false }
            } catch {
                if let self, self.generation == current { self.lostConnection() }
            }
        }
    }
    private func receive(_ data: Data) throws {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = object["type"] as? String else { return }
        func decode<T: Decodable>(_ value: Any, as: T.Type) throws -> T {
            try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: value))
        }
        switch type {
        case "snapshot":
            session.confirmed = try decode(object["document"] ?? [:], as: CanvasDocument.self)
            let accepted = Set(object["acceptedPendingIDs"] as? [String] ?? [])
            session.pending.removeAll { accepted.contains($0.id) }
            connected = true; retry = 0
            rebuild()
            for op in session.pending { enqueue(operationEnvelope(op)) }
            ensureLayer()
            // After an app restart, recover unfinished saved strokes into undoable strokes.
            // An ongoing touch in this process remains open through a transient reconnect.
            for stroke in document.strokes where stroke.authorID == authorID && !stroke.ended && stroke.id != activeStrokeID {
                submit(CanvasOperation(kind: "endStroke", authorID: authorID, strokeID: stroke.id))
            }
            if let presence = localPresence { enqueuePresence(presence) }
        case "operation":
            let op = try decode(object["operation"] ?? [:], as: CanvasOperation.self)
            let revision = object["revision"] as? Int ?? 0
            guard revision == session.confirmed.revision + 1 else { lostConnection(); return }
            guard session.confirmed.apply(op) else { lostConnection(); return }
            session.pending.removeAll { $0.id == op.id }
            rebuild()
        case "ack":
            // A retried operation already appears in the snapshot. No second application.
            session.pending.removeAll { $0.id == object["id"] as? String }; rebuild()
        case "presence":
            let presence = try decode(object["presence"] ?? [:], as: CanvasPresence.self)
            presences[presence.authorID] = (presence, Date())
        case "error":
            let detail = object["message"] as? String ?? "The server rejected an edit."
            if let id = object["id"] as? String {
                session.pending.removeAll { $0.id == id }; rebuild()
            } else {
                // Authentication/configuration errors require user action, not endless retries.
                generation = UUID(); connected = false
                socket?.cancel(with: .policyViolation, reason: nil)
                status = detail; message?(detail); changed?(); return
            }
            message?(detail)
        default: return
        }
        if connected { status = session.pending.isEmpty ? "Connected · all edits synced" : "Connected · syncing \(session.pending.count) edits" }
        scheduleSave(); changed?()
    }
}
