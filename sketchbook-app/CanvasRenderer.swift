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
    private let paperPipeline: MTLRenderPipelineState
    private struct CachedStroke { var stroke: CanvasStroke; var buffer: MTLBuffer; var count: Int }
    private var cache: [String: CachedStroke] = [:]
    var document = CanvasDocument()
    var viewport = CanvasViewport()

    init(device: MTLDevice, format: MTLPixelFormat) throws {
        self.device = device
        guard let queue = device.makeCommandQueue(), let library = device.makeDefaultLibrary() else {
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
        super.init()
    }

    private func makeBuffer(for stroke: CanvasStroke) -> CachedStroke? {
        if let cached = cache[stroke.id], cached.stroke == stroke { return cached }
        var stamps: [CanvasStamp] = []
        let color = SIMD4<Float>(Float(stroke.color.red), Float(stroke.color.green), Float(stroke.color.blue), Float(stroke.color.alpha))
        func append(x: Double, y: Double, pressure: Double) {
            let diameter = Float(stroke.width * (0.25 + 0.75 * min(1, max(0, pressure))))
            stamps.append(CanvasStamp(position: SIMD2(Float(x), Float(y)), size: SIMD2(repeating: diameter), color: color))
        }
        for (index, point) in stroke.points.enumerated() {
            guard index > 0 else { append(x: point.x, y: point.y, pressure: point.pressure); continue }
            let previous = stroke.points[index - 1]
            let distance = hypot(point.x - previous.x, point.y - previous.y)
            let steps = max(1, Int(ceil(distance / max(0.5, stroke.width / 8))))
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                append(x: previous.x + (point.x - previous.x) * t,
                       y: previous.y + (point.y - previous.y) * t,
                       pressure: previous.pressure + (point.pressure - previous.pressure) * t)
            }
        }
        guard !stamps.isEmpty, let buffer = device.makeBuffer(bytes: stamps, length: stamps.count * MemoryLayout<CanvasStamp>.stride) else { return nil }
        // Immutable buffers remain alive through their command buffer; the CPU never overwrites GPU reads.
        let result = CachedStroke(stroke: stroke, buffer: buffer, count: stamps.count)
        cache[stroke.id] = result
        return result
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { view.setNeedsDisplay() }

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let drawable = view.currentDrawable, let descriptor = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer() else { return }
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].clearColor = MTLClearColorMake(0.12, 0.14, 0.17, 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        let scale = viewport.scale(viewWidth: view.bounds.width, viewHeight: view.bounds.height, document: document)
        var uniforms = [SIMD4<Float>(Float(view.bounds.width), Float(view.bounds.height), Float(scale), 0),
                        SIMD4<Float>(Float(document.width), Float(document.height), Float(viewport.panX), Float(viewport.panY))]
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
        // Fragment clipping is in document coordinates, so resize never destroys hidden samples.
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride * 2, index: 1)
        var paper = CanvasStamp(position: SIMD2(Float(document.width / 2), Float(document.height / 2)),
                                size: SIMD2(Float(document.width), Float(document.height)), color: SIMD4(repeating: 1))
        encoder.setRenderPipelineState(paperPipeline)
        encoder.setVertexBytes(&paper, length: MemoryLayout<CanvasStamp>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.setRenderPipelineState(inkPipeline)
        let strokeIDs = Set(document.strokes.map(\.id))
        cache = cache.filter { strokeIDs.contains($0.key) }
        for layer in document.layers where layer.visible {
            for stroke in document.strokes where stroke.layerID == layer.id && stroke.visible {
                guard let cached = makeBuffer(for: stroke) else { continue }
                encoder.setVertexBuffer(cached.buffer, offset: 0, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: cached.count)
            }
        }
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }
}
