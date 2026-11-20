import Foundation
import Metal
import SillageCore
import simd

/// Draws a `TidalFrame` (#314): each tracer a splat at its temperature's black body, once per
/// image where `HoleLens` puts it, into the light target of a `Renderer` whose post stages make
/// the picture. The lens table is the camera distance's, rebuilt when that changes.
public final class HoleRenderer {
    public let settings: RenderSettings
    let renderer: Renderer
    private let pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    /// The lens tables over camera distances, which renderers can share.
    public var lenses = HoleLensSet()
    private var lensBuffers: [Float: MTLBuffer] = [:]
    private var positions: MTLBuffer?
    private var velocities: MTLBuffer?
    private var uploaded = 0
    /// What the frames' light is normalised by.
    public var exposure = HoleExposure()
    /// `HoleExposure.fixed`.
    public var fixedExposure: Bool {
        get { exposure.fixed }
        set { exposure.fixed = newValue }
    }
    /// `HoleExposure.easing`.
    public var exposureEasing: Float {
        get { exposure.easing }
        set { exposure.easing = newValue }
    }
    private var starPositions: MTLBuffer?
    private var starColours: MTLBuffer?
    private var starCount = 0

    public init(settings: RenderSettings, device: MTLDevice? = nil) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = device
        self.settings = settings
        var placeholder = ParticleSystem()
        placeholder.append(position: .zero, velocity: .zero, galaxy: 0, radius: 0, component: .halo)
        renderer = try Renderer(device: device, particles: placeholder, settings: settings)
        let library = try HoleKernels.library(on: device)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "holeSplatVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "holeSplatFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one
        do {
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            throw RenderError.pipelineCreation("holeSplatVertex: \(error)")
        }
    }

    /// The two lens tables round a camera at `distance` from the hole, on the GPU, with the
    /// far one's share; each table is built the first time a camera comes near its distance.
    func lensPair(at distance: Float) -> (
        near: HoleLens, far: HoleLens, buffers: (MTLBuffer?, MTLBuffer?), blend: Float, distance: Float
    ) {
        let (near, far, blend, ro) = lenses.pair(at: distance)
        func buffer(_ lens: HoleLens) -> MTLBuffer? {
            if let buffer = lensBuffers[lens.cameraDistance] { return buffer }
            let buffer = lens.entries.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            lensBuffers[lens.cameraDistance] = buffer
            return buffer
        }
        let buffers = (buffer(near), buffer(far))
        let kept = Set(lenses.built)
        lensBuffers = lensBuffers.filter { kept.contains($0.key) }
        return (near, far, buffers, blend, ro)
    }

    /// Hands the frame's tracers to the GPU, with what their light is normalised by: each law's
    /// mean over the tracers left, and the run's flux at which the brightest few per thousand
    /// reach the hottest.
    public func upload(_ frame: TidalFrame) {
        let length = max(frame.count, 1) * MemoryLayout<SIMD4<Float>>.stride
        if positions == nil || uploaded != frame.count {
            positions = device.makeBuffer(length: length, options: .storageModeShared)
            velocities = device.makeBuffer(length: length, options: .storageModeShared)
            uploaded = frame.count
        }
        frame.positions.withUnsafeBytes {
            positions?.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        frame.velocities.withUnsafeBytes {
            velocities?.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count)
        }
        exposure.measure(frame)
    }

    /// The field stars of `HoleSplats.fieldStars`.
    func placeStars(_ count: Int) {
        guard count != starCount else { return }
        let (positions, colours) = HoleSplats.fieldStars(count)
        starCount = count
        guard count > 0 else { return }
        starPositions = device.makeBuffer(bytes: positions, length: count * 16, options: .storageModeShared)
        starColours = device.makeBuffer(bytes: colours, length: count * 16, options: .storageModeShared)
    }

    /// The frame `upload` last took, seen by `camera` as `look` asks. `present` takes the
    /// picture instead of the returned pixels, through `buffer` when given.
    public func render(
        _ frame: TidalFrame, camera: Camera, look: HoleLook, present: MTLTexture? = nil,
        into buffer: MTLCommandBuffer? = nil
    ) -> [UInt8] {
        let (lens, far, buffers, blend, distance) = lensPair(at: simd_length(camera.eye))
        placeStars(look.stars)
        let splats = HoleSplats(
            settings: settings, camera: camera, look: look, exposure: exposure, near: lens, far: far,
            blend: blend, distance: distance, starCount: starCount)
        return renderer.render(present: present, into: buffer) { target, buffer in
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[0].storeAction = .store
            guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(positions, offset: 0, index: 0)
            encoder.setVertexBuffer(velocities, offset: 0, index: 1)
            encoder.setVertexBuffer(buffers.0, offset: 0, index: 3)
            encoder.setVertexBuffer(buffers.1, offset: 0, index: 4)
            for image in 0..<splats.images {
                var uniforms = splats.tracers.drawing(image: image)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<HoleSplatUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: uploaded)
            }
            if let field = splats.stars {
                encoder.setVertexBuffer(starPositions, offset: 0, index: 0)
                encoder.setVertexBuffer(starColours, offset: 0, index: 1)
                for image in 0..<splats.images {
                    var uniforms = field.drawing(image: image)
                    encoder.setVertexBytes(
                        &uniforms, length: MemoryLayout<HoleSplatUniforms>.stride, index: 2)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
                }
            }
            encoder.endEncoding()
        }
    }

    public var lastGPUTime: Double { renderer.lastGPUTime }
}
