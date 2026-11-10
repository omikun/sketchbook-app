import Foundation

@main struct CanvasDocumentTests {
    static func main() throws {
        var document = CanvasDocument()
        document.hostID = "alice"
        let alice = CanvasLayer(ownerID: "alice", ownerName: "Alice", name: "Alice")
        let bob = CanvasLayer(ownerID: "bob", ownerName: "Bob", name: "Bob")
        let carol = CanvasLayer(ownerID: "carol", ownerName: "Carol", name: "Carol")
        for layer in [alice, bob, carol] { precondition(document.apply(CanvasOperation(kind: "addLayer", authorID: layer.ownerID, layer: layer))) }
        for layer in [alice, bob, carol] {
            let stroke = CanvasStroke(layerID: layer.id, authorID: layer.ownerID, color: CanvasInk(), width: 10,
                                      points: [CanvasPoint(x: 100, y: 100)])
            precondition(document.apply(CanvasOperation(kind: "beginStroke", authorID: layer.ownerID, stroke: stroke)))
            precondition(document.apply(CanvasOperation(kind: "endStroke", authorID: layer.ownerID, strokeID: stroke.id)))
        }
        let own = document.undoTarget(for: "alice")!
        precondition(!document.apply(CanvasOperation(kind: "strokeVisibility", authorID: "bob", strokeID: own.id, visible: false)))
        precondition(document.apply(CanvasOperation(kind: "strokeVisibility", authorID: "alice", strokeID: own.id, visible: false)))
        precondition(document.undoTarget(for: "bob") != nil && document.redoTarget(for: "alice")?.id == own.id)
        precondition(document.apply(CanvasOperation(kind: "strokeVisibility", authorID: "alice", strokeID: own.id, visible: true)))
        let point = own.points[0]
        var corrected = point; corrected.pressure = 0.4
        precondition(document.apply(CanvasOperation(kind: "samples", authorID: "alice", strokeID: own.id, points: [corrected])))
        precondition(document.strokes[0].points.count == 1 && document.strokes[0].points[0].pressure == 0.4)
        let before = document.strokes
        precondition(!document.apply(CanvasOperation(kind: "resize", authorID: "bob", width: 64, height: 64)))
        precondition(document.apply(CanvasOperation(kind: "resize", authorID: "alice", width: 64, height: 64)))
        precondition(document.strokes == before)
        precondition(document.apply(CanvasOperation(kind: "resize", authorID: "alice", width: 4096, height: 4096)))
        precondition(document.strokes == before)
        precondition(!document.apply(CanvasOperation(kind: "resize", authorID: "alice", width: .nan, height: 100)))
        precondition(!document.apply(CanvasOperation(kind: "resize", authorID: "alice", width: 0, height: 100)))
        let decoded = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document))
        precondition(decoded.strokes == document.strokes && decoded.layers == document.layers)
        var viewport = CanvasViewport()
        let a = viewport.point(x: 100, y: 200, viewWidth: 800, viewHeight: 1000, document: document)
        viewport.zoom(by: 2, anchorX: 100, anchorY: 200, viewWidth: 800, viewHeight: 1000)
        let b = viewport.point(x: 100, y: 200, viewWidth: 800, viewHeight: 1000, document: document)
        precondition(abs(a.0 - b.0) < 0.00001 && abs(a.1 - b.1) < 0.00001)
        precondition(viewport.zoom == 2)
        print("PASS: three owners, isolated undo/redo, corrections, resize preservation, save round trip, anchored zoom")
    }
}
