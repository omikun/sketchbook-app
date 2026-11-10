import Foundation

struct CanvasPoint: Codable, Equatable {
    var id = UUID().uuidString
    var x: Double
    var y: Double
    var pressure: Double = 1
}

struct CanvasInk: Codable, Equatable {
    var red: Double = 0.12
    var green: Double = 0.18
    var blue: Double = 0.26
    var alpha: Double = 1
}

struct CanvasLayer: Codable, Equatable {
    var id = UUID().uuidString
    var ownerID: String
    var ownerName: String
    var name: String
    var visible = true
}

struct CanvasStroke: Codable, Equatable {
    var id = UUID().uuidString
    var layerID: String
    var authorID: String
    var color: CanvasInk
    var width: Double
    var points: [CanvasPoint] = []
    var ended = false
    var visible = true
    var redoEligible = false
    var hiddenAt = 0
}

/// Versioned wire operations use document coordinates, independent of any iPad's viewport.
struct CanvasOperation: Codable {
    var id = UUID().uuidString
    var kind: String
    var authorID: String
    var layer: CanvasLayer?
    var stroke: CanvasStroke?
    var strokeID: String?
    var layerID: String?
    var points: [CanvasPoint]?
    var visible: Bool?
    var width: Double?
    var height: Double?
}

struct CanvasDocument: Codable {
    var width: Double = 2048
    var height: Double = 2736
    var layers: [CanvasLayer] = [] // bottom to top
    var strokes: [CanvasStroke] = []
    var revision = 0
    var hostID: String?

    func undoTarget(for author: String) -> CanvasStroke? {
        strokes.last { $0.authorID == author && $0.ended && $0.visible }
    }

    func redoTarget(for author: String) -> CanvasStroke? {
        strokes.filter { $0.authorID == author && !$0.visible && $0.redoEligible }
            .max { $0.hiddenAt < $1.hiddenAt }
    }

    /// The server validates ownership too. Keeping the same rules here makes offline edits safe.
    @discardableResult mutating func apply(_ op: CanvasOperation) -> Bool {
        switch op.kind {
        case "addLayer":
            guard let layer = op.layer, layer.ownerID == op.authorID,
                  !layers.contains(where: { $0.id == layer.id }) else { return false }
            layers.append(layer)
        case "beginStroke":
            guard let stroke = op.stroke, stroke.authorID == op.authorID,
                  stroke.width.isFinite, (0.5...512).contains(stroke.width),
                  layers.contains(where: { $0.id == stroke.layerID && $0.ownerID == op.authorID }),
                  !strokes.contains(where: { $0.id == stroke.id }) else { return false }
            for i in strokes.indices where strokes[i].authorID == op.authorID && !strokes[i].visible {
                strokes[i].redoEligible = false
            }
            strokes.append(stroke)
        case "samples":
            guard let i = strokes.firstIndex(where: { $0.id == op.strokeID && $0.authorID == op.authorID }),
                  let points = op.points, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite }) else { return false }
            // Corrections replace the sample with the same ID instead of painting it twice.
            var indexes: [String: Int] = [:]
            for (index, point) in strokes[i].points.enumerated() { indexes[point.id] = index }
            if strokes[i].ended && points.contains(where: { indexes[$0.id] == nil }) { return false }
            for point in points {
                if let index = indexes[point.id] { strokes[i].points[index] = point }
                else { indexes[point.id] = strokes[i].points.count; strokes[i].points.append(point) }
            }
        case "endStroke":
            guard let i = strokes.firstIndex(where: { $0.id == op.strokeID && $0.authorID == op.authorID && !$0.ended }) else { return false }
            strokes[i].ended = true
        case "strokeVisibility":
            guard let i = strokes.firstIndex(where: { $0.id == op.strokeID && $0.authorID == op.authorID && $0.ended }),
                  let visible = op.visible else { return false }
            if visible && !strokes[i].redoEligible { return false }
            strokes[i].visible = visible
            strokes[i].redoEligible = !visible
            strokes[i].hiddenAt = revision + 1
        case "layerVisibility":
            guard let i = layers.firstIndex(where: { $0.id == op.layerID && $0.ownerID == op.authorID }),
                  let visible = op.visible else { return false }
            layers[i].visible = visible
        case "resize":
            guard hostID == nil || hostID == op.authorID,
                  let w = op.width, let h = op.height, w.isFinite, h.isFinite,
                  (64...8192).contains(w), (64...8192).contains(h) else { return false }
            // Top-left anchored crop/expand. Samples outside the new bounds are preserved.
            width = w.rounded(); height = h.rounded()
        default: return false
        }
        revision += 1
        return true
    }
}

struct CanvasPresence: Codable {
    var authorID: String
    var name: String
    var layerID: String?
    var drawing: Bool
}

struct CanvasSession: Codable {
    var confirmed = CanvasDocument()
    var pending: [CanvasOperation] = []
}

/// Only the viewport is local; zoom/pan never alter the document or other participants.
struct CanvasViewport {
    var zoom: Double = 1
    var panX: Double = 0
    var panY: Double = 0

    func scale(viewWidth: Double, viewHeight: Double, document: CanvasDocument) -> Double {
        min(viewWidth / document.width, viewHeight / document.height) * 0.92 * zoom
    }

    func point(x: Double, y: Double, viewWidth: Double, viewHeight: Double, document: CanvasDocument) -> (Double, Double) {
        let s = scale(viewWidth: viewWidth, viewHeight: viewHeight, document: document)
        return ((x - viewWidth / 2 - panX) / s + document.width / 2,
                (y - viewHeight / 2 - panY) / s + document.height / 2)
    }

    mutating func zoom(by factor: Double, anchorX: Double, anchorY: Double, viewWidth: Double, viewHeight: Double) {
        let next = min(16, max(0.2, zoom * factor))
        let ratio = next / zoom
        panX = anchorX - viewWidth / 2 - (anchorX - viewWidth / 2 - panX) * ratio
        panY = anchorY - viewHeight / 2 - (anchorY - viewHeight / 2 - panY) * ratio
        zoom = next
    }
}
