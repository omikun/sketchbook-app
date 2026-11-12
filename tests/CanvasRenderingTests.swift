import Foundation
import MetalKit

/// Real GPU pixel checks; run with a macOS metallib built from the app's Shaders.metal.
@main struct CanvasRenderingTests {
    static func main() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { fatalError("Metal unavailable") }
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let renderer = try CanvasRenderer(device: device, format: .bgra8Unorm, library: library)
        let reference = try CanvasRenderer(device: device, format: .bgra8Unorm, library: library)
        reference.useHistoryCache = false
        let layer = CanvasLayer(ownerID: "test", ownerName: "Test", name: "Ink")
        let constant = CanvasBrushDynamics(size: CanvasPressureCurve(minimum: 1, maximum: 1), opacity: CanvasPressureCurve(minimum: 1, maximum: 1))
        func stroke(_ maxOpacity: Bool?, pressures: [Double] = [1], alpha: Double = 0.25) -> CanvasStroke {
            CanvasStroke(layerID: layer.id, authorID: "test", color: CanvasInk(red: 0, green: 0, blue: 0, alpha: alpha),
                         width: 32, dynamics: constant, maxOpacity: maxOpacity,
                         points: pressures.map { CanvasPoint(x: 64, y: 64, pressure: $0) })
        }
        func pixels(_ strokes: [CanvasStroke], zoom: Double = 1, hidpi: Bool = false, layers: [CanvasLayer]? = nil, caching: Bool = true, paper: CanvasInk? = nil) -> [UInt8] {
            let renderer = caching ? renderer : reference
            var document = CanvasDocument(); document.width = 128; document.height = 128
            document.layers = layers ?? [layer]; document.strokes = strokes; document.background = paper
            renderer.document = document; renderer.viewport = CanvasViewport(); renderer.viewport.zoom = zoom
            let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false)
            description.usage = [.renderTarget, .shaderRead]; description.storageMode = .shared
            let texture = device.makeTexture(descriptor: description)!, command = queue.makeCommandBuffer()!
            precondition(renderer.render(to: texture, viewSize: CGSize(width: hidpi ? 64 : 128, height: hidpi ? 64 : 128), command: command))
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed, "GPU failure: \(String(describing: command.error))")
            var result = [UInt8](repeating: 0, count: 128 * 128 * 4)
            result.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: 128 * 4, from: MTLRegionMake2D(0, 0, 128, 128), mipmapLevel: 0) }
            return result
        }
        func center(_ image: [UInt8]) -> Int { Int(image[(64 * 128 + 64) * 4]) }
        func near(_ actual: Int, _ expected: Int) { precondition(abs(actual - expected) <= 2, "Pixel \(actual), expected \(expected)") }
        let single = pixels([stroke(true)])
        let repeated = pixels([stroke(true, pressures: Array(repeating: 1, count: 12))])
        precondition(single == repeated, "Retracing changed coverage within a max-opacity stroke")
        near(center(repeated), 191)
        near(center(pixels([stroke(true), stroke(true)])), 143) // Separate strokes still composite.
        let legacy = pixels([stroke(nil, pressures: Array(repeating: 1, count: 12))])
        precondition(center(legacy) < 15, "Legacy accumulation was lost")
        precondition(legacy == pixels([stroke(false, pressures: Array(repeating: 1, count: 12))]))
        var varying = stroke(true, pressures: [0.2, 0.8, 0.3], alpha: 0.5)
        varying.dynamics?.opacity = CanvasPressureCurve(minimum: 0, maximum: 1)
        near(center(pixels([varying])), 153) // Highest stamp is 0.5 * 0.8, not last or accumulated.
        near(center(pixels([stroke(true), stroke(false), stroke(true)])), 108)
        precondition(pixels([stroke(true, alpha: 0)]) == pixels([]))
        precondition(pixels([stroke(true, pressures: [1, 1, 1])], zoom: 2, hidpi: true) == pixels([stroke(true)], zoom: 2, hidpi: true))
        var hidden = stroke(true); hidden.visible = false
        precondition(pixels([hidden]) == pixels([]))
        let upper = CanvasLayer(ownerID: "other", ownerName: "Other", name: "Upper")
        var finished = stroke(true); finished.ended = true
        finished.color = CanvasInk(red: 0.8, green: 0.2, blue: 0.1, alpha: 0.3)
        var live = stroke(true); live.color = CanvasInk(red: 0.1, green: 0.8, blue: 0.3, alpha: 0.4)
        var over = stroke(false); over.ended = true; over.layerID = upper.id
        over.color = CanvasInk(red: 0.2, green: 0.1, blue: 0.8, alpha: 0.35)
        func equivalent(_ strokes: [CanvasStroke], layers: [CanvasLayer] = [layer, upper], zoom: Double = 1, hidpi: Bool = false, paper: CanvasInk? = nil) {
            let replay = pixels(strokes, zoom: zoom, hidpi: hidpi, layers: layers, caching: false, paper: paper)
            let cached = pixels(strokes, zoom: zoom, hidpi: hidpi, layers: layers, paper: paper)
            precondition(zip(replay, cached).allSatisfy { abs(Int($0) - Int($1)) <= 2 }, "Layer cache differs from replay")
        }
        equivalent([finished, live, over])
        _ = pixels([finished, live, over], layers: [layer, upper])
        precondition(renderer.statistics.historyHits == 2 && renderer.statistics.stampsDrawn == 1 && renderer.statistics.stampsBuilt == 0)
        let additions = (1...8).map { CanvasPoint(x: 64 + Double($0), y: 64) }
        live.applySamples(additions)
        equivalent([finished, live, over])
        precondition(renderer.statistics.stampsBuilt == 8, "Append rebuilt old stamp geometry")
        var next = stroke(true); next.ended = true
        equivalent([finished, next, live, over])
        precondition(renderer.statistics.historyUpdates == 1 && renderer.statistics.historyHits == 1, "Commit invalidated unrelated artwork")
        live.ended = true
        equivalent([finished, next, live, over])
        _ = pixels([finished, next, live, over], layers: [layer, upper])
        precondition(renderer.statistics.stampsDrawn == 0, "Warm history rerasterized stamps")
        var correction = finished.points[0]; correction.x = 56; correction.pressure = 0.4
        finished.applySamples([correction])
        equivalent([finished, next, live, over])
        precondition(renderer.statistics.historyUpdates == 1 && renderer.statistics.historyHits == 1)
        equivalent([finished, next, live, over], paper: CanvasInk(red: 0.2, green: 0.3, blue: 0.4))
        precondition(renderer.statistics.stampsDrawn == 0, "Paper change replayed artwork")
        finished.visible = false
        equivalent([finished, next, live, over])
        var hiddenLayer = layer; hiddenLayer.visible = false
        equivalent([finished, next, live, over], layers: [hiddenLayer, upper])
        equivalent([finished, next, live, over], zoom: 2, hidpi: true)
        var blue = stroke(true, alpha: 1); blue.ended = true; blue.color = CanvasInk(red: 0, green: 0, blue: 1, alpha: 1)
        var red = stroke(true, alpha: 1); red.ended = true; red.layerID = upper.id; red.color = CanvasInk(red: 1, green: 0, blue: 0, alpha: 1)
        var eraser = stroke(true, pressures: Array(repeating: 1, count: 12), alpha: 0.5)
        eraser.layerID = upper.id; eraser.tool = .eraser
        let offset = (64 * 128 + 64) * 4
        func erased(_ strokes: [CanvasStroke]) -> [UInt8] {
            equivalent(strokes)
            return pixels(strokes, layers: [layer, upper])
        }
        let partial = erased([blue, red, eraser])
        near(Int(partial[offset]), 128); near(Int(partial[offset + 2]), 127); near(Int(partial[offset + 3]), 255)
        eraser.ended = true
        precondition(erased([blue, red, eraser]) == partial, "Committing the eraser changed its appearance")
        precondition(renderer.statistics.stampsDrawn == 0, "Committed erasing did not cache")
        var secondErase = eraser; secondErase.id = UUID().uuidString
        let twice = erased([blue, red, eraser, secondErase])
        near(Int(twice[offset]), 191); near(Int(twice[offset + 2]), 64)
        var building = eraser; building.maxOpacity = false
        let buildup = erased([blue, red, building])
        precondition(buildup[offset] > 250 && buildup[offset + 2] < 5)
        var full = eraser; full.id = UUID().uuidString; full.color.alpha = 1; full.width = 48
        precondition(erased([blue, red, full]) == pixels([blue], layers: [layer, upper]))
        var undoErase = eraser; undoErase.visible = false
        precondition(erased([blue, red, undoErase]) == pixels([blue, red], layers: [layer, upper]))
        var after = red; after.id = UUID().uuidString; after.color = CanvasInk(red: 0, green: 1, blue: 0, alpha: 1)
        let repainted = erased([blue, red, full, after])
        near(Int(repainted[offset + 1]), 255); near(Int(repainted[offset]), 0)
        let emptyErase = erased([eraser])
        precondition(emptyErase == pixels([], layers: [layer, upper]), "Eraser affected paper or empty layers")
        print("PASS: GPU max-opacity retracing, pressure maximum, separate strokes, legacy blending, mixed order, transparent/hidden strokes, zoom/high-DPI masks, cached layer order, incremental append/commit, corrections, undo, hidden layers, paper changes, eraser isolation, opacity, accumulation, undo and repainting")
    }
}
