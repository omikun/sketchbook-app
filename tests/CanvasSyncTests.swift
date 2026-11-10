import Foundation

@main struct CanvasSyncTests {
    @MainActor static func wait(_ description: String, until predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        fatalError("Timed out: \(description)")
    }
    @MainActor static func main() async throws {
        let url = URL(string: CommandLine.arguments[1])!
        let token = CommandLine.arguments[2]
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let stores = (1...3).map { index in
            CanvasStore(directory: root.appendingPathComponent("\(index)"), participantKey: String(repeating: "\(index)", count: 64))
        }
        for (index, store) in stores.enumerated() {
            store.connect(url: url, room: "native", token: token, name: "Native \(index)")
        }
        try await wait("three native clients join") { stores.allSatisfy { $0.document.layers.count == 3 && $0.session.pending.isEmpty } }
        let author = stores[0]
        let stroke = CanvasStroke(layerID: author.ownLayers[0].id, authorID: author.authorID,
                                  color: CanvasInk(), width: 10, points: [CanvasPoint(x: 100, y: 100)])
        author.submit(CanvasOperation(kind: "beginStroke", authorID: author.authorID, stroke: stroke))
        author.activity(layerID: stroke.layerID, drawing: true)
        author.submit(CanvasOperation(kind: "samples", authorID: author.authorID, strokeID: stroke.id, points: [CanvasPoint(x: 200, y: 200)]))
        author.submit(CanvasOperation(kind: "endStroke", authorID: author.authorID, strokeID: stroke.id))
        try await wait("stroke and presence converge") {
            stores.allSatisfy { $0.document.strokes.first?.points.count == 2 && $0.session.pending.isEmpty && !$0.activeArtists(on: stroke.layerID).isEmpty }
        }
        author.undo()
        try await wait("native undo converges") { stores.allSatisfy { $0.document.strokes.first?.visible == false && $0.session.pending.isEmpty } }
        author.redo()
        let host = stores.first { $0.canResize }!
        host.submit(CanvasOperation(kind: "resize", authorID: host.authorID, width: 512, height: 768))
        try await wait("resize and redo converge") { stores.allSatisfy { $0.document.width == 512 && $0.document.strokes.first?.visible == true && $0.session.pending.isEmpty } }
        author.activity(layerID: stroke.layerID, drawing: false)
        try await wait("activity stops") { stores.allSatisfy { $0.activeArtists(on: stroke.layerID).isEmpty } }
        author.save()
        // Close all sockets while preserving the room files. Rejoin using the same identity.
        for store in stores { store.disconnect() }
        author.connect(url: url, room: "native", token: token, name: "Native 0")
        try await wait("native saved room rejoins") { author.status.contains("Connected") && author.document.width == 512 }
        precondition(author.document.strokes.count == 1)
        author.useLocalCanvas()
        precondition(author.document.strokes.isEmpty)
        precondition(author.document.layers.count == 1)
        print("PASS: three native Swift clients, layer activity, drawing, undo/redo, shared resize, save/rejoin, separate local canvas")
    }
}
