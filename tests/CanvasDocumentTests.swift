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
        let defaults = CanvasBrushDynamics()
        precondition(defaults.size.value(at: 0) == 0.25 && defaults.size.value(at: 1) == 1)
        precondition(defaults.opacity.value(at: 0) == 1)
        let response = CanvasPressureCurve(minimum: 0.1, maximum: 0.9, exponent: 2)
        precondition(abs(response.value(at: 0.5) - 0.3) < 0.000001)
        precondition(response.value(at: -1) == 0.1 && response.value(at: 2) == 0.9)
        precondition(!CanvasPressureCurve(minimum: 0.8, maximum: 0.2).isValid)
        precondition(!CanvasPressureCurve(minimum: 0, maximum: 1, exponent: .nan).isValid)
        var dynamicStroke = document.strokes[0]
        dynamicStroke.id = UUID().uuidString
        dynamicStroke.dynamics = CanvasBrushDynamics(size: response, opacity: CanvasPressureCurve(minimum: 0, maximum: 0.8))
        dynamicStroke.maxOpacity = true
        let dynamicDecoded = try JSONDecoder().decode(CanvasStroke.self, from: JSONEncoder().encode(dynamicStroke))
        precondition(dynamicDecoded == dynamicStroke)
        let legacy = try JSONDecoder().decode(CanvasStroke.self, from: JSONEncoder().encode(document.strokes[0]))
        precondition(legacy.dynamics == nil && legacy.maxOpacity == nil)
        var invalid = dynamicStroke
        invalid.dynamics?.size.exponent = 0
        let unchanged = document.strokes
        precondition(!document.apply(CanvasOperation(kind: "beginStroke", authorID: invalid.authorID, stroke: invalid)))
        precondition(document.strokes == unchanged)
        let paper = CanvasInk(red: 0.2, green: 0.3, blue: 0.4)
        precondition(!document.apply(CanvasOperation(kind: "background", authorID: "bob", color: paper)))
        precondition(document.apply(CanvasOperation(kind: "background", authorID: "alice", color: paper)))
        precondition(document.paperColor == paper)
        let recolored = try JSONDecoder().decode(CanvasDocument.self, from: JSONEncoder().encode(document))
        precondition(recolored.paperColor == paper)
        precondition(!document.apply(CanvasOperation(kind: "background", authorID: "alice", color: CanvasInk(red: .nan))))
        precondition(!document.apply(CanvasOperation(kind: "background", authorID: "alice", color: CanvasInk(alpha: 0.5))))
        precondition(CanvasDocument().paperColor == .paper)
        let origin = CanvasPoint(x: 100, y: 100, pressure: 0.3)
        for end in [CanvasPoint(x: 300, y: 105), CanvasPoint(x: -100, y: 95)] {
            let snap = CanvasStraightLine.endpoint(from: origin, to: end)
            precondition(snap.y == origin.y && snap.x == end.x && snap.id == end.id && snap.pressure == end.pressure)
        }
        for end in [CanvasPoint(x: 105, y: 300), CanvasPoint(x: 95, y: -100)] {
            let snap = CanvasStraightLine.endpoint(from: origin, to: end)
            precondition(snap.x == origin.x && snap.y == end.y)
        }
        for degrees in [1.99, 2.01] {
            let end = CanvasPoint(x: origin.x + 200, y: origin.y + 200 * tan(degrees * .pi / 180))
            let result = CanvasStraightLine.endpoint(from: origin, to: end)
            precondition(degrees < 2 ? result.y == origin.y : result == end)
            let vertical = CanvasPoint(x: end.y, y: end.x)
            let snapped = CanvasStraightLine.endpoint(from: origin, to: vertical)
            precondition(degrees < 2 ? snapped.x == origin.x : snapped == vertical)
        }
        var eraser = dynamicStroke; eraser.id = UUID().uuidString; eraser.tool = .eraser
        let eraserDecoded = try JSONDecoder().decode(CanvasStroke.self, from: JSONEncoder().encode(eraser))
        precondition(eraserDecoded == eraser && eraserDecoded.isEraser && !legacy.isEraser)
        let settings = CanvasToolSettings(width: 80, opacity: 0.4, dynamics: defaults, maxOpacity: false)
        let reloadedSettings = try JSONDecoder().decode(CanvasToolSettings.self, from: JSONEncoder().encode(settings))
        precondition(settings == reloadedSettings && settings.isValid)
        precondition(!CanvasToolSettings(width: 0).isValid)
        let beforeEraser = document.strokes
        var foreign = eraser; foreign.authorID = "bob"
        precondition(!document.apply(CanvasOperation(kind: "beginStroke", authorID: "bob", stroke: foreign)))
        precondition(document.strokes == beforeEraser)
        let diagonal = CanvasPoint(x: 250, y: 230, pressure: 0.7)
        precondition(CanvasStraightLine.endpoint(from: origin, to: diagonal) == diagonal)
        precondition(CanvasStraightLine.endpoint(from: origin, to: origin) == origin)
        var branchA = dynamicStroke
        var branchB = dynamicStroke
        branchA.ended = false; branchB.ended = false
        let sampleA = CanvasPoint(x: 400, y: 400), sampleB = CanvasPoint(x: 500, y: 500)
        precondition(branchA.applySamples([sampleA]))
        precondition(branchB.applySamples([sampleB]))
        var correctedA = sampleA; correctedA.pressure = 0.25
        precondition(branchA.applySamples([correctedA]))
        precondition(branchA.points.last == correctedA && branchB.points.last == sampleB)
        let rawStroke = try JSONSerialization.jsonObject(with: JSONEncoder().encode(branchA)) as! [String: Any]
        precondition(rawStroke["renderVersion"] == nil && rawStroke["geometryEpoch"] == nil && rawStroke["lookup"] == nil)
        print("PASS: three owners, isolated undo/redo, corrections, resize preservation, save round trip, anchored zoom, pressure curves, paper colors, line snapping and legacy strokes")
    }
}
