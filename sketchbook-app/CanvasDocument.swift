import Foundation

struct CanvasPoint: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var x: Double
    var y: Double
    var pressure: Double = 1
}

struct CanvasInk: Codable, Equatable, Sendable {
    var red: Double = 0.12
    var green: Double = 0.18
    var blue: Double = 0.26
    var alpha: Double = 1
    static let paper = CanvasInk(red: 1, green: 1, blue: 1)
    var isValid: Bool { [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) } }
}

enum CanvasStraightLine {
    /// Snap within two degrees of either axis, including leftward/upward lines.
    static func endpoint(from start: CanvasPoint, to end: CanvasPoint) -> CanvasPoint {
        var result = end
        let dx = abs(end.x - start.x), dy = abs(end.y - start.y)
        let tolerance = tan(2 * Double.pi / 180)
        if dy <= dx * tolerance { result.y = start.y }
        else if dx <= dy * tolerance { result.x = start.x }
        return result
    }
}

struct CanvasLayer: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var ownerID: String
    var ownerName: String
    var name: String
    var visible = true
}

struct CanvasPressureCurve: Codable, Equatable, Sendable {
    var minimum: Double
    var maximum: Double
    var exponent: Double = 1

    var isValid: Bool {
        minimum.isFinite && maximum.isFinite && exponent.isFinite &&
        (0...1).contains(minimum) && (minimum...1).contains(maximum) && (0.2...4).contains(exponent)
    }
    func value(at pressure: Double) -> Double {
        let p = pressure.isFinite ? min(1, max(0, pressure)) : 0
        return minimum + (maximum - minimum) * pow(p, exponent)
    }
}

struct CanvasBrushDynamics: Codable, Equatable, Sendable {
    // These defaults reproduce strokes saved before pressure controls were available.
    var size = CanvasPressureCurve(minimum: 0.25, maximum: 1)
    var opacity = CanvasPressureCurve(minimum: 1, maximum: 1)
    var isValid: Bool { size.isValid && opacity.isValid }
}

enum CanvasDrawingTool: String, Codable, Sendable { case brush, eraser }

struct CanvasToolSettings: Codable, Equatable, Sendable {
    var width: Double = 16
    var opacity: Double = 1
    var dynamics = CanvasBrushDynamics()
    var maxOpacity = true
    var isValid: Bool { width.isFinite && (1...512).contains(width) && opacity.isFinite && (0...1).contains(opacity) && dynamics.isValid }
}

private final class CanvasPointLookup: @unchecked Sendable {
    let lock = NSLock()
    var indices: [String: Int] = [:]
    var count = -1
    var lastID: String?
}

struct CanvasStroke: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var layerID: String
    var authorID: String
    var color: CanvasInk
    var width: Double
    var dynamics: CanvasBrushDynamics? = nil
    var maxOpacity: Bool? = nil
    var tool: CanvasDrawingTool? = nil
    var isEraser: Bool { tool == .eraser }
    var points: [CanvasPoint] = []
    var ended = false
    var visible = true
    var redoEligible = false
    var hiddenAt = 0
    // Disposable rendering/index metadata; never enters files or the wire protocol.
    var renderVersion = UUID()
    var geometryEpoch = UUID()
    private var lookup = CanvasPointLookup()
    init(id: String = UUID().uuidString, layerID: String, authorID: String, color: CanvasInk, width: Double,
         dynamics: CanvasBrushDynamics? = nil, maxOpacity: Bool? = nil, tool: CanvasDrawingTool? = nil, points: [CanvasPoint] = [],
         ended: Bool = false, visible: Bool = true, redoEligible: Bool = false, hiddenAt: Int = 0) {
        self.id = id; self.layerID = layerID; self.authorID = authorID; self.color = color; self.width = width
        self.dynamics = dynamics; self.maxOpacity = maxOpacity; self.tool = tool; self.points = points; self.ended = ended
        self.visible = visible; self.redoEligible = redoEligible; self.hiddenAt = hiddenAt
    }
    enum CodingKeys: String, CodingKey {
        case id, layerID, authorID, color, width, dynamics, maxOpacity, tool, points, ended, visible, redoEligible, hiddenAt
    }
    static func == (a: Self, b: Self) -> Bool {
        a.id == b.id && a.layerID == b.layerID && a.authorID == b.authorID && a.color == b.color && a.width == b.width &&
        a.dynamics == b.dynamics && a.maxOpacity == b.maxOpacity && a.tool == b.tool && a.points == b.points && a.ended == b.ended &&
        a.visible == b.visible && a.redoEligible == b.redoEligible && a.hiddenAt == b.hiddenAt
    }
    mutating func invalidateGeometry() { renderVersion = UUID(); geometryEpoch = UUID() }
    @discardableResult mutating func applySamples(_ samples: [CanvasPoint]) -> Bool {
        lookup.lock.lock(); defer { lookup.lock.unlock() }
        if lookup.count != points.count || lookup.lastID != points.last?.id {
            lookup.indices = Dictionary(points.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { _, newest in newest })
            lookup.count = points.count; lookup.lastID = points.last?.id
        }
        if ended && samples.contains(where: { lookup.indices[$0.id] == nil }) { return false }
        var corrected = false
        for sample in samples {
            if let index = lookup.indices[sample.id], index < points.count, points[index].id == sample.id {
                if points[index] != sample { points[index] = sample; corrected = true }
            } else {
                lookup.indices[sample.id] = points.count; points.append(sample)
            }
        }
        lookup.count = points.count; lookup.lastID = points.last?.id
        renderVersion = UUID()
        if corrected { geometryEpoch = UUID() }
        return true
    }
}

/// Versioned wire operations use document coordinates, independent of any iPad's viewport.
struct CanvasOperation: Codable, Equatable, Sendable {
    var id = UUID().uuidString
    var kind: String
    var authorID: String
    var layer: CanvasLayer?
    var stroke: CanvasStroke?
    var strokeID: String?
    var layerID: String?
    var points: [CanvasPoint]?
    var visible: Bool?
    var color: CanvasInk?
    var width: Double?
    var height: Double?
}

struct CanvasDocument: Codable {
    var width: Double = 2048
    var height: Double = 2736
    var background: CanvasInk? = nil
    var paperColor: CanvasInk { background ?? .paper }
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
                  stroke.dynamics?.isValid != false,
                  layers.contains(where: { $0.id == stroke.layerID && $0.ownerID == op.authorID }),
                  !strokes.contains(where: { $0.id == stroke.id }) else { return false }
            for i in strokes.indices where strokes[i].authorID == op.authorID && !strokes[i].visible {
                strokes[i].redoEligible = false
            }
            strokes.append(stroke)
        case "samples":
            guard let i = strokes.firstIndex(where: { $0.id == op.strokeID && $0.authorID == op.authorID }),
                  let points = op.points, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.pressure.isFinite }) else { return false }
            guard strokes[i].applySamples(points) else { return false }
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
        case "background":
            guard hostID == nil || hostID == op.authorID,
                  let color = op.color, color.isValid, color.alpha == 1 else { return false }
            background = color
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

struct CanvasPresence: Codable, Sendable {
    var authorID: String
    var name: String
    var layerID: String?
    var drawing: Bool
}

struct CanvasSession: Codable, Sendable {
    var confirmed = CanvasDocument()
    var pending: [CanvasOperation] = []
}

/// Only the viewport is local; zoom/pan never alter the document or other participants.
struct CanvasViewport: Equatable, Sendable {
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
