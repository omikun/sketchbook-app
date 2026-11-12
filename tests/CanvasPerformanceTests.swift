import Foundation
import MetalKit

/// Desktop diagnostic workload, not a physical-iPad FPS claim.
@main struct CanvasPerformanceTests {
    @MainActor static func main() throws {
        let device = MTLCreateSystemDefaultDevice()!, queue = device.makeCommandQueue()!
        let library = try device.makeLibrary(URL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let renderer = try CanvasRenderer(device: device, format: .bgra8Unorm, library: library)
        var doc = CanvasDocument(); doc.width = 1024; doc.height = 1024
        let layer = CanvasLayer(ownerID: "benchmark", ownerName: "Benchmark", name: "Artwork")
        doc.layers = [layer]
        let dynamics = CanvasBrushDynamics(size: CanvasPressureCurve(minimum: 1, maximum: 1), opacity: CanvasPressureCurve(minimum: 1, maximum: 1))
        for i in 0..<500 {
            let y = Double(30 + (i % 100) * 9)
            let points = (0..<100).map { j in CanvasPoint(x: Double(20 + j * 9), y: y + sin(Double(j) * 0.2) * 10) }
            doc.strokes.append(CanvasStroke(layerID: layer.id, authorID: "benchmark", color: CanvasInk(alpha: 0.4), width: 16, dynamics: dynamics, maxOpacity: true, points: points, ended: true))
        }
        var live = CanvasStroke(layerID: layer.id, authorID: "benchmark", color: CanvasInk(), width: 16, dynamics: dynamics, maxOpacity: true, points: [CanvasPoint(x: 20, y: 512)])
        doc.strokes.append(live)
        let textureDescription = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 512, height: 512, mipmapped: false)
        textureDescription.storageMode = .shared; textureDescription.usage = [.renderTarget, .shaderRead]
        let texture = device.makeTexture(descriptor: textureDescription)!
        var cpu: [Double] = [], gpu: [Double] = []
        for frame in 0..<21 {
            let points = (0..<8).map { j in CanvasPoint(x: Double(20 + frame * 8 + j), y: 512 + sin(Double(frame * 8 + j) * 0.1) * 30) }
            let op = CanvasOperation(kind: "samples", authorID: "benchmark", strokeID: live.id, points: points)
            doc.apply(op); renderer.document = doc
            let command = queue.makeCommandBuffer()!, start = ProcessInfo.processInfo.systemUptime
            precondition(renderer.render(to: texture, viewSize: CGSize(width: 512, height: 512), command: command))
            let encoded = ProcessInfo.processInfo.systemUptime
            command.commit(); command.waitUntilCompleted()
            precondition(command.status == .completed)
            if frame > 0 { cpu.append((encoded - start) * 1000); gpu.append((command.gpuEndTime - command.gpuStartTime) * 1000) }
        }
        let store = CanvasStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString), participantKey: String(repeating: "benchmark", count: 8))
        live = CanvasStroke(layerID: store.ownLayers[0].id, authorID: store.authorID, color: CanvasInk(), width: 16, points: [CanvasPoint(x: 0, y: 0)])
        store.submit(CanvasOperation(kind: "beginStroke", authorID: store.authorID, stroke: live))
        var input: [Double] = []
        for batch in 0..<1250 {
            let points = (0..<8).map { j in CanvasPoint(x: Double(batch * 8 + j), y: 100) }
            let op = CanvasOperation(kind: "samples", authorID: store.authorID, strokeID: live.id, points: points)
            let start = ProcessInfo.processInfo.systemUptime
            store.submit(op); input.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
        }
        store.save()
        func p95(_ values: [Double]) -> Double { values.sorted()[min(values.count - 1, Int(Double(values.count) * 0.95))] }
        let result: [String: Any] = ["completedStrokes": 500, "samplesPerCompletedStroke": 100, "targetPixels": "512x512", "measuredFrames": cpu.count,
            "cpuEncodeMeanMs": cpu.reduce(0,+) / Double(cpu.count), "gpuMeanMs": gpu.reduce(0,+) / Double(gpu.count), "inputBatchP95Ms": p95(input), "finalInputPoints": store.document.strokes.last!.points.count]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
    }
}
