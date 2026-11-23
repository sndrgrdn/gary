import GaryCore
import MetalKit
import SwiftUI

nonisolated struct ShaderError: LocalizedError {
    let errorDescription: String?
}

final nonisolated class ShaderProgram {
    static let device = MTLCreateSystemDefaultDevice()
    static let queue = device?.makeCommandQueue()
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private struct Frame {
        var size: SIMD2<Float>
        var time: Float
        var scale: Float
        var count: UInt32
    }

    private let pipeline: MTLRenderPipelineState

    init(source: String, function: String) throws {
        guard let device = Self.device else { throw ShaderError(errorDescription: "this Mac has no Metal device") }
        let library = try device.makeLibrary(source: Self.wrap(source, function), options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "gary_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "gary_fragment")
        descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    private static func wrap(_ source: String, _ function: String) -> String {
        """
        #include <metal_stdlib>
        using namespace metal;
        #line 1
        \(source)
        struct GaryVertex { float4 position [[position]]; };
        struct GaryFrame { float2 size; float time; float scale; uint count; };
        vertex GaryVertex gary_vertex(uint id [[vertex_id]]) {
            float2 corner = float2((id << 1) & 2, id & 2);
            return { float4(corner.x * 2 - 1, 1 - corner.y * 2, 0, 1) };
        }
        fragment half4 gary_fragment(GaryVertex in [[stage_in]], constant GaryFrame &frame [[buffer(0)]], constant float *args [[buffer(1)]]) {
            half4 color = \(function)(in.position.xy / frame.scale, frame.size, frame.time, args, frame.count);
            return half4(color.rgb * color.a, color.a);
        }
        """
    }

    func encode(_ encoder: MTLRenderCommandEncoder, size: CGSize, scale: Double, time: Double, args: [Double]) {
        var frame = Frame(size: SIMD2(Float(size.width), Float(size.height)), time: Float(time), scale: Float(scale), count: UInt32(args.count))
        var floats = args.isEmpty ? [0] : args.map(Float.init)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<Frame>.stride, index: 0)
        encoder.setFragmentBytes(&floats, length: MemoryLayout<Float>.stride * floats.count, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    }
}

final nonisolated class ShaderCache: @unchecked Sendable {
    static let shared = ShaderCache()

    private struct Entry {
        let plugin: PluginID?
        let modified: Double
        let result: Result<ShaderProgram, ShaderError>
    }

    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private let compiler = DispatchQueue(label: "gary.shaders", qos: .userInitiated)

    func program(_ shader: Node.Shader, plugin: PluginID?) async -> ShaderProgram? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: shader.path)[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let key = "\(shader.path)|\(shader.function)"
        if let entry = cached(key, modified) {
            return try? entry.result.get()
        }
        return await withCheckedContinuation { continuation in
            compiler.async {
                let entry = self.cached(key, modified) ?? Entry(
                    plugin: plugin,
                    modified: modified,
                    result: Self.compile(shader, plugin: plugin),
                )
                self.lock.withLock { self.entries[key] = entry }
                continuation.resume(returning: try? entry.result.get())
            }
        }
    }

    func drop(_ plugin: PluginID) {
        lock.withLock { entries = entries.filter { $0.value.plugin != plugin } }
    }

    private func cached(_ key: String, _ modified: Double) -> Entry? {
        lock.withLock { entries[key].flatMap { $0.modified == modified ? $0 : nil } }
    }

    private static func compile(_ shader: Node.Shader, plugin: PluginID?) -> Result<ShaderProgram, ShaderError> {
        do {
            let source = try String(contentsOfFile: shader.path, encoding: .utf8)
            return try .success(ShaderProgram(source: source, function: shader.function))
        } catch {
            log("plugin \(plugin?.description ?? "?"): shader \(shader.path): \(error.localizedDescription)")
            return .failure(ShaderError(errorDescription: error.localizedDescription))
        }
    }
}

private struct PluginIDKey: EnvironmentKey {
    static let defaultValue: PluginID? = nil
}

extension EnvironmentValues {
    var pluginID: PluginID? {
        get { self[PluginIDKey.self] }
        set { self[PluginIDKey.self] = newValue }
    }
}

struct ShaderNode: View {
    let shader: Node.Shader
    @Environment(\.pluginID) private var plugin
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let program = State<ShaderProgram?>(initialValue: nil)

    var body: some View {
        MetalCanvas(program: program.wrappedValue, args: shader.args, animated: shader.animated && !reduceMotion)
            .task(id: shader) {
                let compiled = await ShaderCache.shared.program(shader, plugin: plugin)
                guard !Task.isCancelled else { return }
                program.wrappedValue = compiled
            }
    }
}

private final class PassThroughMetalView: MTKView {
    var animated = false {
        didSet { updatePaused() }
    }

    override func hitTest(_: NSPoint) -> NSView? {
        nil
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        layer?.contentsScale = window?.backingScaleFactor ?? 1
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        if let window {
            center.addObserver(self, selector: #selector(updatePaused), name: NSWindow.didChangeOcclusionStateNotification, object: window)
        }
        updatePaused()
    }

    @objc private func updatePaused() {
        isPaused = !animated || !(window?.occlusionState.contains(.visible) ?? false)
    }
}

private struct MetalCanvas: NSViewRepresentable {
    let program: ShaderProgram?
    let args: [Double]
    let animated: Bool

    final class Coordinator: NSObject, MTKViewDelegate {
        var program: ShaderProgram?
        var args: [Double] = []
        var animated = false
        let start = CACurrentMediaTime()

        func mtkView(_ view: MTKView, drawableSizeWillChange _: CGSize) {
            view.needsDisplay = true
        }

        func draw(in view: MTKView) {
            guard let program, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let buffer = ShaderProgram.queue?.makeCommandBuffer(), let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
            else { return }
            let scale = view.bounds.width > 0 ? view.drawableSize.width / view.bounds.width : 1
            program.encode(encoder, size: view.bounds.size, scale: scale, time: animated ? CACurrentMediaTime() - start : 0, args: args)
            encoder.endEncoding()
            buffer.present(drawable)
            buffer.commit()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> PassThroughMetalView {
        let view = PassThroughMetalView(frame: .zero, device: ShaderProgram.device)
        view.colorPixelFormat = ShaderProgram.pixelFormat
        view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        view.layer?.isOpaque = false
        view.delegate = context.coordinator
        return view
    }

    func updateNSView(_ view: PassThroughMetalView, context: Context) {
        let coordinator = context.coordinator
        (coordinator.program, coordinator.args, coordinator.animated) = (program, args, animated)
        view.preferredFramesPerSecond = view.window?.screen?.maximumFramesPerSecond ?? 60
        view.enableSetNeedsDisplay = !animated
        view.animated = animated
        view.needsDisplay = true
    }
}
