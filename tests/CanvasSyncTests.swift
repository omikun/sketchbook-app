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
        let dynamics = CanvasBrushDynamics(size: CanvasPressureCurve(minimum: 0.1, maximum: 1, exponent: 2),
                                           opacity: CanvasPressureCurve(minimum: 0.2, maximum: 0.8, exponent: 0.5))
        let stroke = CanvasStroke(layerID: author.ownLayers[0].id, authorID: author.authorID,
                                  color: CanvasInk(alpha: 0.4), width: 10, dynamics: dynamics, maxOpacity: true, points: [CanvasPoint(x: 100, y: 100)])
        author.submit(CanvasOperation(kind: "beginStroke", authorID: author.authorID, stroke: stroke))
        author.activity(layerID: stroke.layerID, drawing: true)
        author.submit(CanvasOperation(kind: "samples", authorID: author.authorID, strokeID: stroke.id, points: [CanvasPoint(x: 200, y: 200)]))
        author.submit(CanvasOperation(kind: "endStroke", authorID: author.authorID, strokeID: stroke.id))
        try await wait("stroke and presence converge") {
            stores.allSatisfy { $0.document.strokes.first?.points.count == 2 && $0.session.pending.isEmpty && !$0.activeArtists(on: stroke.layerID).isEmpty }
        }
        precondition(stores.allSatisfy { $0.document.strokes.first?.maxOpacity == true && $0.document.strokes.first?.dynamics == dynamics && $0.document.strokes.first?.color.alpha == 0.4 })
        author.undo()
        try await wait("native undo converges") { stores.allSatisfy { $0.document.strokes.first?.visible == false && $0.session.pending.isEmpty } }
        author.redo()
        let host = stores.first { $0.canResize }!
        host.submit(CanvasOperation(kind: "resize", authorID: host.authorID, width: 512, height: 768))
        try await wait("resize and redo converge") { stores.allSatisfy { $0.document.width == 512 && $0.document.strokes.first?.visible == true && $0.session.pending.isEmpty } }
        let paper = CanvasInk(red: 0.2, green: 0.25, blue: 0.3)
        host.submit(CanvasOperation(kind: "background", authorID: host.authorID, color: paper))
        try await wait("paper color converges") { stores.allSatisfy { $0.document.paperColor == paper && $0.session.pending.isEmpty } }
        let eraser = CanvasStroke(layerID: stroke.layerID, authorID: author.authorID, color: CanvasInk(alpha: 0.5), width: 64,
                                  dynamics: dynamics, maxOpacity: true, tool: .eraser, points: [CanvasPoint(x: 150, y: 150)])
        author.submit(CanvasOperation(kind: "beginStroke", authorID: author.authorID, stroke: eraser))
        author.submit(CanvasOperation(kind: "endStroke", authorID: author.authorID, strokeID: eraser.id))
        try await wait("eraser converges") { stores.allSatisfy { $0.document.strokes.last?.isEraser == true && $0.document.strokes.last?.color.alpha == 0.5 && $0.session.pending.isEmpty } }
        author.undo()
        try await wait("eraser undo converges") { stores.allSatisfy { $0.document.strokes.last?.visible == false && $0.session.pending.isEmpty } }
        author.redo()
        try await wait("eraser redo converges") { stores.allSatisfy { $0.document.strokes.last?.visible == true && $0.session.pending.isEmpty } }
        author.activity(layerID: stroke.layerID, drawing: false)
        try await wait("activity stops") { stores.allSatisfy { $0.activeArtists(on: stroke.layerID).isEmpty } }
        author.save()
        // Close all sockets while preserving the room files. Rejoin using the same identity.
        for store in stores { store.disconnect() }
        author.connect(url: url, room: "native", token: token, name: "Native 0")
        try await wait("native saved room rejoins") { author.status.contains("Connected") && author.document.width == 512 }
        precondition(author.document.strokes.count == 2 && author.document.paperColor == paper)
        author.useLocalCanvas()
        precondition(author.document.strokes.isEmpty)
        precondition(author.document.layers.count == 1 && author.document.paperColor == .paper)
        print("PASS: three native Swift clients, layer activity, drawing, undo/redo, shared resize, eraser/undo/redo, pressure/opacity, paper color, save/rejoin, separate local canvas")
    }
}
