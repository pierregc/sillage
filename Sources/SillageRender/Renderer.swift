import Metal
import QuartzCore
import SillageCore
import simd

struct SplatUniforms {
    var viewProjection: simd_float4x4
    var pointSize: Float
    var brightness: Float
    var dustStrength: Float
    var starSize: Float
}

struct BackgroundStar {
    var direction: SIMD4<Float>
    var color: SIMD4<Float>
}

struct BloomParams {
    var threshold: Float
    var softKnee: Float
    var pad0: Float = 0
    var pad1: Float = 0
}

struct CompositeParams {
    var exposure: Float
    var bloomIntensity: Float
    var stretch: Float
    var saturation: Float
}

public struct RenderSettings: Sendable {
    public var width: Int
    public var height: Int
    /// Renders at this multiple of the output resolution, then box-filters down.
    public var supersample: Int
    public var pointSize: Float
    public var exposure: Float
    /// Emission per particle, expressed per million particles. Normalising by count keeps a
    /// scene looking the same whether it runs at 500 000 particles or at 20 million.
    public var brightness: Float
    /// Optical depth per dust particle, expressed per million particles so a scene keeps the
    /// same column density whichever count it runs at.
    public var dustStrength: Float
    /// Number of foreground field stars.
    public var starCount: Int
    /// Point size of the field stars before their magnitude scaling.
    public var starSize: Float
    public var bloomThreshold: Float
    public var bloomSoftKnee: Float
    public var bloomIntensity: Float
    public var bloomLevels: Int
    /// Strength of the logarithmic stretch applied before tone mapping. 0 disables it.
    public var stretch: Float
    /// 1 leaves colour untouched, above 1 pushes the two disks further apart in hue.
    public var saturation: Float

    public init(
        width: Int = 1920,
        height: Int = 1080,
        supersample: Int = 2,
        pointSize: Float = 1.7,
        exposure: Float = 1.0,
        brightness: Float = 0.055,
        dustStrength: Float = 0.055,
        starCount: Int = 11000,
        starSize: Float = 1.15,
        bloomThreshold: Float = 0.55,
        bloomSoftKnee: Float = 0.6,
        bloomIntensity: Float = 0.45,
        bloomLevels: Int = 6,
        stretch: Float = 18,
        saturation: Float = 1.8
    ) {
        self.width = width
        self.height = height
        self.supersample = max(1, min(supersample, 4))
        self.pointSize = pointSize
        self.exposure = exposure
        self.brightness = brightness
        self.dustStrength = dustStrength
        self.starCount = starCount
        self.starSize = starSize
        self.bloomThreshold = bloomThreshold
        self.bloomSoftKnee = bloomSoftKnee
        self.bloomIntensity = bloomIntensity
        self.bloomLevels = bloomLevels
        self.stretch = stretch
        self.saturation = saturation
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipelineCreation(String)
    case textureAllocation

    public var description: String {
        switch self {
        case .noDevice: "No Metal device available"
        case .shaderCompilation(let message): "Shader compilation failed: \(message)"
        case .pipelineCreation(let message): "Pipeline creation failed: \(message)"
        case .textureAllocation: "Could not allocate a render texture"
        }
    }
}

/// Accumulates particles additively into a supersampled HDR target, builds a Kawase
/// dual-filter bloom pyramid from it, then tone maps the sum to 8-bit sRGB.
public final class Renderer {
    public let device: MTLDevice
    public private(set) var settings: RenderSettings
    public private(set) var lastGPUTime: Double = 0

    private let queue: MTLCommandQueue
    private let splatPipeline: MTLRenderPipelineState
    private let starfieldPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let brightPassPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState

    private let accumulation: MTLTexture
    private let dustAccumulation: MTLTexture
    private let resolved: MTLTexture
    private let bloomDown: [MTLTexture]
    private let bloomUp: [MTLTexture]
    public let output: MTLTexture

    private let positionBuffer: MTLBuffer
    private let populationBuffer: MTLBuffer
    private let luminosityBuffer: MTLBuffer
    private let componentBuffer: MTLBuffer
    private let starBuffer: MTLBuffer?
    private let particleCount: Int

    /// Framing at which the brightness and dust settings are calibrated, in kpc per pixel.
    static let referenceKpcPerPixel: Float = 0.0436

    /// The buffer holding particle positions, so a GPU solver can write into it directly.
    public var positions: MTLBuffer { positionBuffer }

    /// `externalPositions` lets a GPU solver own the position buffer, so particle state
    /// never crosses the bus between the integrator and the rasteriser.
    public init(
        device: MTLDevice? = nil,
        particles: ParticleSystem,
        settings: RenderSettings,
        externalPositions: MTLBuffer? = nil
    ) throws {
        guard let device = device ?? MTLCreateSystemDefaultDevice() else {
            throw RenderError.noDevice
        }
        self.device = device
        self.settings = settings
        self.particleCount = particles.count

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }

        func compute(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else {
                throw RenderError.pipelineCreation("missing kernel \(name)")
            }
            do {
                return try device.makeComputePipelineState(function: function)
            } catch {
                throw RenderError.pipelineCreation("\(name): \(error)")
            }
        }

        func additive(_ vertexFunction: String) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: vertexFunction)
            descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
            for (index, format) in [MTLPixelFormat.rgba16Float, .r16Float].enumerated() {
                guard let attachment = descriptor.colorAttachments[index] else { continue }
                attachment.pixelFormat = format
                attachment.isBlendingEnabled = true
                attachment.rgbBlendOperation = .add
                attachment.alphaBlendOperation = .add
                attachment.sourceRGBBlendFactor = .one
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationRGBBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .one
            }
            do {
                return try device.makeRenderPipelineState(descriptor: descriptor)
            } catch {
                throw RenderError.pipelineCreation("\(vertexFunction): \(error)")
            }
        }
        splatPipeline = try additive("splatVertex")
        starfieldPipeline = try additive("starfieldVertex")

        resolvePipeline = try compute("resolve")
        brightPassPipeline = try compute("brightPass")
        downsamplePipeline = try compute("downsample")
        upsamplePipeline = try compute("upsampleAdd")
        compositePipeline = try compute("composite")

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        func texture(
            _ width: Int, _ height: Int, _ format: MTLPixelFormat, _ usage: MTLTextureUsage,
            shared: Bool = false
        ) throws -> MTLTexture {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: max(width, 1), height: max(height, 1), mipmapped: false)
            descriptor.usage = usage
            descriptor.storageMode = shared ? .shared : .private
            guard let texture = device.makeTexture(descriptor: descriptor) else {
                throw RenderError.textureAllocation
            }
            return texture
        }

        let scale = settings.supersample
        accumulation = try texture(
            settings.width * scale, settings.height * scale, .rgba16Float,
            [.renderTarget, .shaderRead])
        dustAccumulation = try texture(
            settings.width * scale, settings.height * scale, .r16Float,
            [.renderTarget, .shaderRead])
        resolved = try texture(
            settings.width, settings.height, .rgba16Float, [.shaderRead, .shaderWrite])

        var down: [MTLTexture] = []
        var up: [MTLTexture] = []
        var levelWidth = settings.width / 2
        var levelHeight = settings.height / 2
        while down.count < settings.bloomLevels && levelWidth >= 8 && levelHeight >= 8 {
            down.append(
                try texture(levelWidth, levelHeight, .rgba16Float, [.shaderRead, .shaderWrite]))
            up.append(
                try texture(levelWidth, levelHeight, .rgba16Float, [.shaderRead, .shaderWrite]))
            levelWidth /= 2
            levelHeight /= 2
        }
        bloomDown = down
        bloomUp = up

        output = try texture(
            settings.width, settings.height, .rgba8Unorm, [.shaderRead, .shaderWrite], shared: true)

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let count = max(particles.count, 1)
        guard
            let positionBuffer = externalPositions
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let populationBuffer = device.makeBuffer(
                bytes: particles.population.isEmpty ? [Float(0.5)] : particles.population,
                length: count * 4, options: .storageModeShared),
            let luminosityBuffer = device.makeBuffer(
                bytes: particles.luminosity.isEmpty ? [Float(1)] : particles.luminosity,
                length: count * 4, options: .storageModeShared),
            let componentBuffer = device.makeBuffer(
                bytes: particles.component.isEmpty ? [UInt32(0)] : particles.component,
                length: count * 4, options: .storageModeShared)
        else {
            throw RenderError.textureAllocation
        }
        self.positionBuffer = positionBuffer
        self.populationBuffer = populationBuffer
        self.luminosityBuffer = luminosityBuffer
        self.componentBuffer = componentBuffer
        self.starBuffer = Renderer.makeStarfield(device: device, count: settings.starCount)
        if externalPositions == nil {
            upload(positions: particles.positions)
        }
    }

    /// Field stars, placed far enough out that orbiting the galaxy does not parallax them.
    /// Magnitudes follow a steep power law so a handful are bright and the rest are faint,
    /// and colours run from common cool dwarfs to rare hot blue stars.
    private static func makeStarfield(device: MTLDevice, count: Int) -> MTLBuffer? {
        guard count > 0 else { return nil }
        var generator = SeededGenerator(seed: 0x5111_1A6E)
        var stars: [BackgroundStar] = []
        stars.reserveCapacity(count)
        let shell: Float = 6_000

        for _ in 0..<count {
            let direction = DiskSampler.randomDirection(&generator)
            let magnitude = pow(generator.uniform(), 3.2)
            let warmth = generator.uniform()
            let color =
                warmth < 0.62
                ? SIMD3<Float>(1.0, 0.72 + 0.18 * warmth, 0.50 + 0.22 * warmth)
                : (warmth < 0.9
                    ? SIMD3<Float>(1.0, 0.96, 0.90)
                    : SIMD3<Float>(0.72, 0.82, 1.0))
            let spike = DiskSampler.smoothstep(0.45, 0.9, magnitude)
            stars.append(
                BackgroundStar(
                    direction: SIMD4<Float>(
                        direction.x * shell, direction.y * shell, direction.z * shell, magnitude),
                    color: SIMD4<Float>(color.x, color.y, color.z, spike)))
        }
        return device.makeBuffer(
            bytes: stars, length: stars.count * MemoryLayout<BackgroundStar>.stride,
            options: .storageModeShared)
    }

    /// Unified memory means this is a plain memcpy into a buffer the GPU already sees.
    public func upload(positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        positions.withUnsafeBytes { source in
            positionBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    public func setExposure(_ exposure: Float) { settings.exposure = exposure }
    public func setBrightness(_ brightness: Float) { settings.brightness = brightness }
    public func setBloomIntensity(_ intensity: Float) { settings.bloomIntensity = intensity }
    public func setPointSize(_ size: Float) { settings.pointSize = size }
    public func setDustStrength(_ strength: Float) { settings.dustStrength = strength }
    public func setStretch(_ stretch: Float) { settings.stretch = stretch }
    public func setSaturation(_ saturation: Float) { settings.saturation = saturation }

    /// Encodes the whole frame. Pass a drawable texture to present, or nil to render offscreen.
    public func encode(camera: Camera, into buffer: MTLCommandBuffer, present: MTLTexture? = nil) {
        let scale = settings.supersample
        let aspect = Float(settings.width) / Float(settings.height)

        // Emission and optical depth are quantities per unit sky area, but a splat deposits
        // them per pixel. Without this, zooming out packs more particles into each pixel and
        // the image saturates, which is why the exposure had to be retuned for every framing.
        let distance = simd_length(camera.eye - camera.target)
        let kpcPerPixel =
            2 * tan(camera.fieldOfView / 2) * distance / Float(max(settings.height, 1))
        let areaScale = pow(Renderer.referenceKpcPerPixel / max(kpcPerPixel, 1e-6), 2)
        let perParticle = 1_000_000 / Float(max(particleCount, 1))

        var splat = SplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            pointSize: settings.pointSize * Float(scale),
            brightness: settings.brightness * perParticle * areaScale,
            dustStrength: settings.dustStrength * perParticle * areaScale,
            starSize: settings.starSize * Float(scale))

        let pass = MTLRenderPassDescriptor()
        for (index, target) in [accumulation, dustAccumulation].enumerated() {
            pass.colorAttachments[index].texture = target
            pass.colorAttachments[index].loadAction = .clear
            pass.colorAttachments[index].clearColor = MTLClearColor(
                red: 0, green: 0, blue: 0, alpha: 0)
            pass.colorAttachments[index].storeAction = .store
        }

        if let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) {
            encoder.setVertexBytes(&splat, length: MemoryLayout<SplatUniforms>.stride, index: 4)

            if let starBuffer {
                encoder.setRenderPipelineState(starfieldPipeline)
                encoder.setVertexBuffer(starBuffer, offset: 0, index: 0)
                encoder.drawPrimitives(
                    type: .point, vertexStart: 0, vertexCount: settings.starCount)
            }

            encoder.setRenderPipelineState(splatPipeline)
            encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
            encoder.setVertexBuffer(populationBuffer, offset: 0, index: 1)
            encoder.setVertexBuffer(luminosityBuffer, offset: 0, index: 2)
            encoder.setVertexBuffer(componentBuffer, offset: 0, index: 3)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
            encoder.endEncoding()
        }

        guard let compute = buffer.makeComputeCommandEncoder() else { return }

        var factor = UInt32(scale)
        dispatch(compute, resolvePipeline, into: resolved) { encoder in
            encoder.setTexture(accumulation, index: 0)
            encoder.setTexture(dustAccumulation, index: 1)
            encoder.setTexture(resolved, index: 2)
            encoder.setBytes(&factor, length: 4, index: 0)
        }

        var bloom = BloomParams(
            threshold: settings.bloomThreshold, softKnee: settings.bloomSoftKnee)
        if let first = bloomDown.first {
            dispatch(compute, brightPassPipeline, into: first) { encoder in
                encoder.setTexture(resolved, index: 0)
                encoder.setTexture(first, index: 1)
                encoder.setBytes(&bloom, length: MemoryLayout<BloomParams>.stride, index: 0)
            }
            for level in 1..<bloomDown.count {
                dispatch(compute, downsamplePipeline, into: bloomDown[level]) { encoder in
                    encoder.setTexture(bloomDown[level - 1], index: 0)
                    encoder.setTexture(bloomDown[level], index: 1)
                }
            }
        }

        var bloomResult = bloomDown.last
        if bloomDown.count > 1 {
            for level in stride(from: bloomDown.count - 1, to: 0, by: -1) {
                let destination = bloomUp[level - 1]
                let source = bloomResult!
                dispatch(compute, upsamplePipeline, into: destination) { encoder in
                    encoder.setTexture(source, index: 0)
                    encoder.setTexture(bloomDown[level - 1], index: 1)
                    encoder.setTexture(destination, index: 2)
                }
                bloomResult = destination
            }
        }

        var composite = CompositeParams(
            exposure: settings.exposure,
            bloomIntensity: bloomResult == nil ? 0 : settings.bloomIntensity,
            stretch: settings.stretch,
            saturation: settings.saturation)
        let target = present ?? output
        dispatch(compute, compositePipeline, into: target) { encoder in
            encoder.setTexture(resolved, index: 0)
            encoder.setTexture(bloomResult ?? resolved, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setBytes(&composite, length: MemoryLayout<CompositeParams>.stride, index: 0)
        }
        compute.endEncoding()
    }

    private func dispatch(
        _ encoder: MTLComputeCommandEncoder,
        _ pipeline: MTLComputePipelineState,
        into texture: MTLTexture,
        configure: (MTLComputeCommandEncoder) -> Void
    ) {
        encoder.setComputePipelineState(pipeline)
        configure(encoder)
        let side = 16
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (texture.width + side - 1) / side,
                height: (texture.height + side - 1) / side,
                depth: 1),
            threadsPerThreadgroup: MTLSize(width: side, height: side, depth: 1))
    }

    /// Renders straight into a view's drawable.
    public func present(camera: Camera, drawable: CAMetalDrawable) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(camera: camera, into: buffer, present: drawable.texture)
        buffer.present(drawable)
        buffer.commit()
    }

    /// Renders offscreen and reads the result back as 8-bit RGBA.
    public func render(camera: Camera) -> [UInt8] {
        guard let buffer = queue.makeCommandBuffer() else { return [] }
        encode(camera: camera, into: buffer)
        buffer.commit()
        buffer.waitUntilCompleted()
        lastGPUTime = buffer.gpuEndTime - buffer.gpuStartTime

        var pixels = [UInt8](repeating: 0, count: settings.width * settings.height * 4)
        pixels.withUnsafeMutableBytes { destination in
            output.getBytes(
                destination.baseAddress!,
                bytesPerRow: settings.width * 4,
                from: MTLRegionMake2D(0, 0, settings.width, settings.height),
                mipmapLevel: 0)
        }
        return pixels
    }

    public var gpuName: String { device.name }
}
