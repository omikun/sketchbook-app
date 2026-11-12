import Foundation

@main struct CanvasStoreTests {
    @MainActor static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let key = String(repeating: "save-check", count: 8)
        let store = CanvasStore(directory: directory, participantKey: key)
        let beforePresence = store.contentVersion
        store.activity(layerID: store.ownLayers[0].id, drawing: true); store.heartbeat()
        precondition(store.contentVersion == beforePresence, "Presence dirtied artwork")
        let stroke = CanvasStroke(layerID: store.ownLayers[0].id, authorID: store.authorID, color: CanvasInk(alpha: 0.4), width: 16,
                                  maxOpacity: true, points: [CanvasPoint(x: 0, y: 0)])
        store.submit(CanvasOperation(kind: "beginStroke", authorID: store.authorID, stroke: stroke))
        for index in 1...50 {
            store.submit(CanvasOperation(kind: "samples", authorID: store.authorID, strokeID: stroke.id, points: [CanvasPoint(x: Double(index), y: 20)]))
            if index.isMultiple(of: 10) { store.saveEventually() }
        }
        store.submit(CanvasOperation(kind: "endStroke", authorID: store.authorID, strokeID: stroke.id))
        store.saveEventually()
        // Synchronous save is an ordered flush for background/room switching.
        store.save()
        let saved = try JSONDecoder().decode(CanvasSession.self, from: Data(contentsOf: directory.appendingPathComponent("local.json")))
        precondition(saved.confirmed.strokes == store.document.strokes)
        precondition(saved.confirmed.strokes[0].points.count == 51 && saved.confirmed.strokes[0].ended)
        precondition(store.session.confirmed.strokes == store.document.strokes)
        let reloaded = CanvasStore(directory: directory, participantKey: key)
        precondition(reloaded.document.strokes == store.document.strokes)
        let idle = reloaded.contentVersion
        reloaded.heartbeat(); reloaded.activity(layerID: reloaded.ownLayers[0].id, drawing: false)
        precondition(reloaded.contentVersion == idle)
        reloaded.save()
        print("PASS: presence leaves artwork clean, queued saves preserve latest samples, flush/reload, local session snapshot")
    }
}
