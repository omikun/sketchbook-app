import MetalKit

private struct CanvasStamp {
    var position: SIMD2<Float>
    var size: SIMD2<Float>
    var color: SIMD4<Float>
}

final class CanvasRenderer: NSObject, MTKViewDelegate {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let inkPipeline: MTLRenderPipelineState
    private let eraserPipeline: MTLRenderPipelineState
    private let eraserCompositePipeline: MTLRenderPipelineState
    private var layerSurface: MTLTexture?
    private let paperPipeline: MTLRenderPipelineState
    private let maskPipeline: MTLRenderPipelineState
    private let compositePipeline: MTLRenderPipelineState
    private var strokeMask: MTLTexture?
    private struct Style: Equatable {
        var color: CanvasInk; var width: Double; var dynamics: CanvasBrushDynamics?
        init(_ stroke: CanvasStroke) { color = stroke.color; width = stroke.width; dynamics = stroke.dynamics }
    }
    private struct StampChunk { var buffer: MTLBuffer; var count: Int; var level: Int }
    private struct CachedStroke { var epoch: UUID; var sampleCount: Int; var style: Style; var chunks: [StampChunk] }
    private struct RasterKey: Equatable {
        var id: String; var version: UUID; var style: Style; var maxOpacity: Bool?; var tool: CanvasDrawingTool?
        init(_ stroke: CanvasStroke) { id = stroke.id; version = stroke.renderVersion; style = Style(stroke); maxOpacity = stroke.maxOpacity; tool = stroke.tool }
    }
    private struct ViewKey: Equatable {
        var pixels: CGSize; var points: CGSize; var viewport: CanvasViewport; var width: Double; var height: Double
    }
    private struct LayerCache { var texture: MTLTexture; var keys: [RasterKey] }
    private var cache: [String: CachedStroke] = [:]
    private var history: [String: LayerCache] = [:]
    private var historyView: ViewKey?
    private let historyPipeline: MTLRenderPipelineState
    private let format: MTLPixelFormat
    var useHistoryCache = true
    struct Statistics {
        var stampsBuilt = 0
        var stampsDrawn = 0
        var historyHits = 0
        var historyUpdates = 0
    }
    private(set) var statistics = Statistics()
    var document = CanvasDocument()
    var viewport = CanvasViewport()

    init(device: MTLDevice, format: MTLPixelFormat, library suppliedLibrary: MTLLibrary? = nil) throws {
        self.device = device; self.format = format
        guard let queue = device.makeCommandQueue(), let library = suppliedLibrary ?? device.makeDefaultLibrary() else {
            throw NSError(domain: "CanvasRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Metal is unavailable."])
        }
        self.queue = queue
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "canvas_stamp_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_ink_fragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        inkPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_paper_fragment")
        paperPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_stroke_composite_fragment")
        compositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_cached_layer_fragment")
        historyPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        attachment.sourceRGBBlendFactor = .zero; attachment.sourceAlphaBlendFactor = .zero
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_ink_fragment")
        eraserPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_stroke_composite_fragment")
        eraserCompositePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.fragmentFunction = library.makeFunction(name: "canvas_stroke_mask_fragment")
        attachment.pixelFormat = .r8Unorm
        attachment.rgbBlendOperation = .max
        attachment.alphaBlendOperation = .max
        attachment.sourceRGBBlendFactor = .one; attachment.destinationRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one; attachment.destinationAlphaBlendFactor = .one
        maskPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
    }

    private func makeBuffer(for stroke: CanvasStroke) -> CachedStroke? {
        let style = Style(stroke)
        let old = cache[stroke.id]
        let appendOnly = old?.epoch == stroke.geometryEpoch && old?.style == style && (old?.sampleCount ?? 0) <= stroke.points.count
        if appendOnly, old?.sampleCount == stroke.points.count { return old }
        let start = appendOnly ? old!.sampleCount : 0
        var stamps: [CanvasStamp] = []
        let dynamics = stroke.dynamics ?? CanvasBrushDynamics()
        func append(x: Double, y: Double, pressure: Double) {
            let diameter = Float(stroke.width * dynamics.size.value(at: pressure))
            let color = SIMD4<Float>(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), Float(stroke.color.alpha * dynamics.opacity.value(at: pressure)))
            stamps.append(CanvasStamp(position: SIMD2(Float(x), Float(y)), size: SIMD2(repeating: diameter), color: color))
        }
        for index in start..<stroke.points.count {
            let point = stroke.points[index]
            guard index > 0 else { append(x: point.x, y: point.y, pressure: point.pressure); continue }
            let previous = stroke.points[index - 1]
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let smallest = min(dynamics.size.value(at: previous.pressure), dynamics.size.value(at: point.pressure))
            let spacing = stroke.width * (stroke.dynamics == nil ? 1 : smallest) / 8
            let steps = max(1, Int(ceil(distance / max(0.5, spacing))))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                append(x: previous.x + (point.x - previous.x) * t, y: previous.y + (point.y - previous.y) * t,
                       pressure: previous.pressure + (point.pressure - previous.pressure) * t)
            }
        }
        guard !stamps.isEmpty, let buffer = device.makeBuffer(bytes: stamps, length: stamps.count * MemoryLayout<CanvasStamp>.stride, options: .storageModeShared) else { return nil }
        statistics.stampsBuilt += stamps.count
        var chunks = appendOnly ? old!.chunks : []
        var chunk = StampChunk(buffer: buffer, count: stamps.count, level: 0)
        // Immutable binary chunks keep append cost small and draw-call count logarithmic.
        while let previous = chunks.last, previous.level == chunk.level {
            let bytes = (previous.count + chunk.count) * MemoryLayout<CanvasStamp>.stride
            guard let merged = device.makeBuffer(length: bytes, options: .storageModeShared) else { break }
            let offset = previous.count * MemoryLayout<CanvasStamp>.stride
            merged.contents().copyMemory(from: previous.buffer.contents(), byteCount: offset)
            merged.contents().advanced(by: offset).copyMemory(from: chunk.buffer.contents(), byteCount: chunk.count * MemoryLayout<CanvasStamp>.stride)
            chunks.removeLast(); chunk = StampChunk(buffer: merged, count: previous.count + chunk.count, level: chunk.level + 1)
        }
        chunks.append(chunk)
        let result = CachedStroke(epoch: stroke.geometryEpoch, sampleCount: stroke.points.count, style: style, chunks: chunks)
        cache[stroke.id] = result
        return result
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        #if os(macOS)
        view.needsDisplay = true
        #else
        view.setNeedsDisplay()
        #endif
    }

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable, let command = queue.makeCommandBuffer(),
              render(to: drawable.texture, viewSize: view.bounds.size, command: command) else { return }
        command.present(drawable); command.commit()
    }

    /// Viewport-sized layer prefixes are disposable; document samples remain authoritative.
    @discardableResult func render(to target: MTLTexture, viewSize: CGSize, command: MTLCommandBuffer) -> Bool {
        guard viewSize.width > 0, viewSize.height > 0 else { return false }
        statistics = Statistics()
        let viewKey = ViewKey(pixels: CGSize(width: target.width, height: target.height), points: viewSize, viewport: viewport, width: document.width, height: document.height)
        if historyView != viewKey { history.removeAll(); historyView = viewKey }
        let grouped = Dictionary(grouping: document.strokes.filter(\.visible), by: \.layerID)
        let plans = document.layers.filter(\.visible).map { layer -> (id: String, prefix: [CanvasStroke], tail: [CanvasStroke]) in
            let strokes = grouped[layer.id] ?? []
            let split = strokes.firstIndex(where: { !$0.ended }) ?? strokes.endIndex
            return (layer.id, Array(strokes[..<split]), Array(strokes[split...]))
        }
        // Bound rebuildable color caches to 64 MiB and four layers. Others retain the exact replay path.
        let bytesPerSurface = max(1, target.width * target.height * (format == .rgba16Float ? 8 : 4))
        let limit = useHistoryCache ? min(4, (64 * 1024 * 1024) / bytesPerSurface) : 0
        let selected = Set(plans.filter { !$0.prefix.isEmpty }.sorted { $0.prefix.count > $1.prefix.count }.prefix(limit).map(\.id))
        history = history.filter { selected.contains($0.key) }
        var uniforms = [SIMD4<Float>(Float(viewSize.width), Float(viewSize.height), Float(viewport.scale(viewWidth: viewSize.width, viewHeight: viewSize.height, document: document)), 0),
                        SIMD4<Float>(Float(document.width), Float(document.height), Float(viewport.panX), Float(viewport.panY))]
        var quad = CanvasStamp(position: SIMD2(Float(document.width / 2), Float(document.height / 2)),
                               size: SIMD2(Float(document.width), Float(document.height)), color: SIMD4(repeating: 1))
        func bind(_ encoder: MTLRenderCommandEncoder) {
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
        }
        func pass(_ texture: MTLTexture, load: MTLLoadAction, clear: MTLClearColor = MTLClearColorMake(0, 0, 0, 0)) -> MTLRenderPassDescriptor {
            let value = MTLRenderPassDescriptor()
            value.colorAttachments[0].texture = texture; value.colorAttachments[0].loadAction = load
            value.colorAttachments[0].storeAction = .store; value.colorAttachments[0].clearColor = clear
            return value
        }
        func drawChunks(_ geometry: CachedStroke, on encoder: MTLRenderCommandEncoder) {
            for chunk in geometry.chunks {
                encoder.setVertexBuffer(chunk.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: chunk.count)
                statistics.stampsDrawn += chunk.count
            }
        }
        func encode(_ strokes: [CanvasStroke], on encoder: inout MTLRenderCommandEncoder, descriptor: MTLRenderPassDescriptor) -> Bool {
            for stroke in strokes {
                guard let geometry = makeBuffer(for: stroke) else { continue }
                if stroke.maxOpacity == true {
                    if strokeMask?.width != target.width || strokeMask?.height != target.height {
                        let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: target.width, height: target.height, mipmapped: false)
                        description.usage = [.renderTarget, .shaderRead]; description.storageMode = .private
                        strokeMask = device.makeTexture(descriptor: description)
                    }
                    guard let mask = strokeMask else { encoder.endEncoding(); return false }
                    encoder.endEncoding()
                    guard let maskEncoder = command.makeRenderCommandEncoder(descriptor: pass(mask, load: .clear)) else { return false }
                    bind(maskEncoder); maskEncoder.setRenderPipelineState(maskPipeline); drawChunks(geometry, on: maskEncoder)
                    maskEncoder.endEncoding()
                    descriptor.colorAttachments[0].loadAction = .load
                    guard let resumed = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
                    encoder = resumed; bind(encoder); encoder.setRenderPipelineState(stroke.isEraser ? eraserCompositePipeline : compositePipeline)
                    quad.color = SIMD4(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), 1)
                    encoder.setVertexBytes(&quad, length: MemoryLayout<CanvasStamp>.stride, index: 0)
                    encoder.setFragmentTexture(mask, index: 0)
                    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                } else {
                    encoder.setRenderPipelineState(stroke.isEraser ? eraserPipeline : inkPipeline); drawChunks(geometry, on: encoder)
                }
            }
            return true
        }
        for plan in plans where selected.contains(plan.id) {
            let keys = plan.prefix.map(RasterKey.init)
            if history[plan.id]?.keys == keys { statistics.historyHits += 1; continue }
            let old = history[plan.id]
            let extends = old.map { keys.starts(with: $0.keys) } ?? false
            let texture: MTLTexture
            if let old { texture = old.texture }
            else {
                let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
                description.usage = [.renderTarget, .shaderRead]; description.storageMode = .private
                guard let allocated = device.makeTexture(descriptor: description) else { continue }
                texture = allocated
            }
            let descriptor = pass(texture, load: extends ? .load : .clear)
            guard var encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
            bind(encoder)
            let additions = extends ? Array(plan.prefix.dropFirst(old!.keys.count)) : plan.prefix
            guard encode(additions, on: &encoder, descriptor: descriptor) else { return false }
            encoder.endEncoding(); history[plan.id] = LayerCache(texture: texture, keys: keys)
            statistics.historyUpdates += 1
        }
        let descriptor = pass(target, load: .clear, clear: MTLClearColorMake(0.12, 0.14, 0.17, 1))
        guard var encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
        bind(encoder)
        let paper = document.paperColor
        quad.color = SIMD4(Float(paper.red), Float(paper.green), Float(paper.blue), 1)
        encoder.setRenderPipelineState(paperPipeline)
        encoder.setVertexBytes(&quad, length: MemoryLayout<CanvasStamp>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        func composite(_ texture: MTLTexture, on encoder: MTLRenderCommandEncoder) {
            encoder.setRenderPipelineState(historyPipeline)
            encoder.setVertexBytes(&quad, length: MemoryLayout<CanvasStamp>.stride, index: 0)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        }
        for plan in plans {
            let cached = history[plan.id]
            let isolated = plan.tail.contains(where: \.isEraser) || (cached == nil && plan.prefix.contains(where: \.isEraser))
            if isolated {
                // Destination-out must operate on this layer, never on already-composited lower layers or paper.
                if layerSurface?.width != target.width || layerSurface?.height != target.height {
                    let description = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: target.width, height: target.height, mipmapped: false)
                    description.usage = [.renderTarget, .shaderRead]; description.storageMode = .private
                    layerSurface = device.makeTexture(descriptor: description)
                }
                guard let surface = layerSurface else { encoder.endEncoding(); return false }
                encoder.endEncoding()
                let layerPass = pass(surface, load: .clear)
                guard var layerEncoder = command.makeRenderCommandEncoder(descriptor: layerPass) else { return false }
                bind(layerEncoder)
                if let cached { composite(cached.texture, on: layerEncoder) }
                guard encode(cached == nil ? plan.prefix + plan.tail : plan.tail, on: &layerEncoder, descriptor: layerPass) else { return false }
                layerEncoder.endEncoding()
                descriptor.colorAttachments[0].loadAction = .load
                guard let resumed = command.makeRenderCommandEncoder(descriptor: descriptor) else { return false }
                encoder = resumed; bind(encoder); composite(surface, on: encoder)
            } else if let cached {
                composite(cached.texture, on: encoder)
                guard encode(plan.tail, on: &encoder, descriptor: descriptor) else { return false }
            } else {
                guard encode(plan.prefix + plan.tail, on: &encoder, descriptor: descriptor) else { return false }
            }
        }
        encoder.endEncoding()
        let liveIDs = Set(document.strokes.map(\.id)); cache = cache.filter { liveIDs.contains($0.key) }
        return true
    }
}
