import Metal
import QuartzCore
import SillageCore
import simd

struct SplatUniforms {
    var viewProjection: simd_float4x4
    var brightness: Float
    var dustStrength: Float
    var starSize: Float
    var projectionScale: Float
    var smoothingScale: Float
    var referenceArea: Float
    var minimumSize: Float
    var maximumSize: Float
    var galaxyTint: Float
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
    var bloomIntensity: Float
    var stretch: Float
    var saturation: Float
    var spikeIntensity: Float
    var skyLevel: Float
    var noiseLevel: Float
    var seed: Float
    var fade: Float = 1
}

struct SpikeParams {
    var arms: UInt32
    var baseAngle: Float
    var length: Float
    var falloff: Float
    var samples: UInt32
    var pad0: Float = 0
    var pad1: Float = 0
    var pad2: Float = 0
}

public struct RenderSettings: Sendable {
    public var width: Int
    public var height: Int
    /// Renders at this multiple of the output resolution, then box-filters down.
    public var supersample: Int
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
    /// How many local interparticle spacings a particle's kernel spans. This is the whole of
    /// the softness control: it scales the stored length in the shader, so it costs nothing to
    /// change and never rebuilds the tree.
    public var smoothingScale: Float
    /// Smallest and largest kernel a particle may cover, in output pixels.
    public var minimumKernel: Float
    public var maximumKernel: Float
    public var bloomThreshold: Float
    public var bloomSoftKnee: Float
    public var bloomIntensity: Float
    public var bloomLevels: Int
    /// Strength of the logarithmic stretch applied before tone mapping. 0 disables it.
    public var stretch: Float
    /// 1 leaves colour untouched, above 1 pushes the two disks further apart in hue.
    public var saturation: Float
    /// Diffraction arms: 6 for a segmented mirror, 4 for a Cassegrain spider, 0 for none.
    public var spikeArms: Int
    public var spikeLength: Float
    public var spikeIntensity: Float
    /// Sky background and detector noise, both in linear signal units before tone mapping.
    public var skyLevel: Float
    public var noiseLevel: Float
    /// How far the per-galaxy tint pulls the stars away from the colour their population
    /// implies. Zero is the physical answer; a little of it is what keeps stars torn out of
    /// one disk recognisable inside the other.
    public var galaxyTint: Float

    public init(
        width: Int = 1920,
        height: Int = 1080,
        supersample: Int = 2,
        brightness: Float = 0.15,
        dustStrength: Float = 0.055,
        starCount: Int = 14000,
        starSize: Float = 1.15,
        smoothingScale: Float = 1.9,
        minimumKernel: Float = 1.1,
        maximumKernel: Float = 64,
        bloomThreshold: Float = 0.55,
        bloomSoftKnee: Float = 0.6,
        bloomIntensity: Float = 0.22,
        bloomLevels: Int = 6,
        stretch: Float = 18,
        saturation: Float = 1.8,
        spikeArms: Int = 6,
        spikeLength: Float = 72,
        spikeIntensity: Float = 0.38,
        skyLevel: Float = 0.0018,
        noiseLevel: Float = 0.0016,
        galaxyTint: Float = 0.35
    ) {
        self.width = width
        self.height = height
        self.supersample = max(1, min(supersample, 4))
        self.brightness = brightness
        self.dustStrength = dustStrength
        self.starCount = starCount
        self.starSize = starSize
        self.smoothingScale = smoothingScale
        self.minimumKernel = minimumKernel
        self.maximumKernel = maximumKernel
        self.bloomThreshold = bloomThreshold
        self.bloomSoftKnee = bloomSoftKnee
        self.bloomIntensity = bloomIntensity
        self.bloomLevels = bloomLevels
        self.stretch = stretch
        self.saturation = saturation
        self.spikeArms = spikeArms
        self.spikeLength = spikeLength
        self.spikeIntensity = spikeIntensity
        self.skyLevel = skyLevel
        self.noiseLevel = noiseLevel
        self.galaxyTint = galaxyTint
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
    private var frameSeed: Float = 1

    private let queue: MTLCommandQueue
    private let splatPipeline: MTLRenderPipelineState
    private let starfieldPipeline: MTLRenderPipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let brightPassPipeline: MTLComputePipelineState
    private let downsamplePipeline: MTLComputePipelineState
    private let upsamplePipeline: MTLComputePipelineState
    private let compositePipeline: MTLComputePipelineState
    private let spikePipeline: MTLComputePipelineState

    private let accumulation: MTLTexture
    private let dustAccumulation: MTLTexture
    private let resolved: MTLTexture
    private let bloomDown: [MTLTexture]
    private let bloomUp: [MTLTexture]
    private let spikeTexture: MTLTexture
    public let output: MTLTexture

    private let positionBuffer: MTLBuffer
    private let populationBuffer: MTLBuffer
    private let luminosityBuffer: MTLBuffer
    private let componentBuffer: MTLBuffer
    private let galaxyBuffer: MTLBuffer
    private var frameBuffer: MTLBuffer?
    private var smoothingBuffer: MTLBuffer?
    private var frameCount = 1
    private let starBuffer: MTLBuffer?
    private let particleCount: Int
    private let drawnCount: Int

    /// Framing at which the brightness and dust settings are calibrated, in kpc per pixel.
    static let referenceKpcPerPixel: Float = 0.0436

    /// The buffer holding particle positions, so a GPU solver can write into it directly.
    public var positions: MTLBuffer { positionBuffer }

    /// `externalPositions` lets a GPU solver own the position buffer, so particle state
    /// never crosses the bus between the integrator and the rasteriser.
    /// Strength multiplier on the density wave, 0 to disable it.
    public var armPersistence: Float = 1
    /// Master fade, 1 for the picture and 0 for black. Contemplation crossfades scenes
    /// through it; nothing else uses it.
    public var fade: Float = 1

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
        // Only what is drawn. Dark matter is discarded in the vertex shader anyway, so the
        // draw call stops before it: at three million stars with live halos that is four and a
        // half million vertices a frame that existed only to be thrown away.
        self.drawnCount = particles.visibleCount > 0 ? particles.visibleCount : particles.count
        // Exposure still counts every particle the scene simulates, which is not what it
        // should count: adding dark matter makes the stars dimmer by the halo ratio, and it
        // ought to change nothing. Left alone deliberately — correcting it brightens every
        // self-gravitating scene by two and a half and would mean retuning the defaults and
        // every rendered comparison at once.
        self.particleCount = particles.count

        let library: MTLLibrary
        do {
            library = try ShaderCache.library(Shaders.source, on: device)
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
        spikePipeline = try compute("diffractionSpikes")

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

        spikeTexture = try texture(
            max(settings.width / 2, 1), max(settings.height / 2, 1), .rgba16Float,
            [.shaderRead, .shaderWrite])
        output = try texture(
            settings.width, settings.height, .rgba8Unorm, [.shaderRead, .shaderWrite], shared: true)

        let stride = MemoryLayout<SIMD3<Float>>.stride
        let count = max(particles.count, 1)
        // makeBuffer(bytes:length:) copies `length` bytes from the pointer it is given, so a
        // one-element stand-in would have it read off the end of the array. Fill the whole
        // length instead.
        func attribute<T>(_ values: [T], _ fallback: T) -> [T] {
            values.count == count ? values : [T](repeating: fallback, count: count)
        }
        guard
            let positionBuffer = externalPositions
                ?? device.makeBuffer(length: count * stride, options: .storageModeShared),
            let populationBuffer = device.makeBuffer(
                bytes: attribute(particles.population, Float(0.5)),
                length: count * 4, options: .storageModeShared),
            let luminosityBuffer = device.makeBuffer(
                bytes: attribute(particles.luminosity, Float(1)),
                length: count * 4, options: .storageModeShared),
            let componentBuffer = device.makeBuffer(
                bytes: attribute(particles.component, UInt32(0)),
                length: count * 4, options: .storageModeShared),
            let galaxyBuffer = device.makeBuffer(
                bytes: attribute(particles.galaxyIndex, UInt32(0)),
                length: count * 4, options: .storageModeShared)
        else {
            throw RenderError.textureAllocation
        }
        self.galaxyBuffer = galaxyBuffer
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
            let magnitude = pow(generator.uniform(), 4.6)
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

    /// Binds the per-particle smoothing lengths. Without them every particle covers the same
    /// fixed number of pixels and the image resolves the sampling rather than the galaxy.
    public func setSmoothing(_ buffer: MTLBuffer?) { smoothingBuffer = buffer }

    /// Updates the spiral pattern for each galaxy. Called once per frame with the current
    /// galaxy centres and elapsed time, so the arms turn as a density wave.
    public func setDiskFrames(_ frames: [DiskFrame]) {
        guard !frames.isEmpty else { return }
        let length = frames.count * MemoryLayout<DiskFrame>.stride
        if frameBuffer == nil || frameCount != frames.count {
            frameBuffer = device.makeBuffer(length: length, options: .storageModeShared)
            frameCount = frames.count
        }
        frames.withUnsafeBytes { source in
            frameBuffer?.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    /// Unified memory means this is a plain memcpy into a buffer the GPU already sees.
    public func upload(positions: [SIMD3<Float>]) {
        guard !positions.isEmpty else { return }
        positions.withUnsafeBytes { source in
            positionBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    /// Everything a frame may change on its own, in one go. Resolution, supersampling, bloom
    /// levels and the starfield are deliberately absent: those own textures and buffers, and
    /// changing them means a new renderer.
    public func apply(_ look: RenderLook) {
        settings.brightness = look.brightness
        settings.dustStrength = look.dustStrength
        settings.smoothingScale = look.smoothingScale
        settings.minimumKernel = look.minimumKernel
        settings.maximumKernel = look.maximumKernel
        settings.bloomThreshold = look.bloomThreshold
        settings.bloomSoftKnee = look.bloomSoftKnee
        settings.bloomIntensity = look.bloomIntensity
        settings.stretch = look.stretch
        settings.saturation = look.saturation
        settings.spikeArms = look.spikeArms
        settings.spikeLength = look.spikeLength
        settings.spikeIntensity = look.spikeIntensity
        settings.skyLevel = look.skyLevel
        settings.noiseLevel = look.noiseLevel
        settings.galaxyTint = look.galaxyTint
        settings.starSize = look.starSize
        armPersistence = look.armPersistence
    }

    /// Encodes the whole frame. Pass a drawable texture to present, or nil to render offscreen.
    public func encode(camera: Camera, into buffer: MTLCommandBuffer, present: MTLTexture? = nil) {
        let scale = settings.supersample
        let aspect = Float(settings.width) / Float(settings.height)

        // Pixels per unit length at unit depth. The vertex shader divides a particle's
        // smoothing length by its view depth to get the kernel's size on screen.
        let projectionScale =
            Float(settings.height * scale) / (2 * tan(camera.fieldOfView / 2))
        // Conserving flux per particle already makes surface brightness independent of the
        // zoom, so no separate area correction is needed here.
        //
        // Over the particles that reach a pixel, not over every particle simulated. Dividing
        // by the whole count meant that turning live halos on dimmed a scene by the halo
        // ratio — two and a half at the default — because three particles in five are dark
        // matter that never lands on a pixel. Exposure per drawn particle is what keeps a
        // scene looking the same whether it runs at 500 000 stars or at twenty million,
        // which is the whole point of normalising by count at all.
        let perParticle = 1_000_000 / Float(max(drawnCount, 1))

        var splat = SplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            brightness: settings.brightness * perParticle,
            dustStrength: settings.dustStrength * perParticle,
            starSize: settings.starSize * Float(scale),
            projectionScale: projectionScale,
            smoothingScale: settings.smoothingScale,
            referenceArea: 0.01,
            minimumSize: settings.minimumKernel * Float(scale),
            maximumSize: settings.maximumKernel * Float(scale),
            galaxyTint: settings.galaxyTint)

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
            encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 5)
            encoder.setVertexBuffer(frameBuffer, offset: 0, index: 6)
            encoder.setVertexBuffer(smoothingBuffer, offset: 0, index: 7)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: drawnCount)
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

        // Spikes are gathered from the bright pass, so they pick up stars and galaxy cores
        // rather than the whole frame.
        var spike = SpikeParams(
            arms: UInt32(max(settings.spikeArms, 0)),
            baseAngle: 0.32,
            length: settings.spikeLength,
            falloff: 4.2,
            samples: 28)
        let spikeSource = bloomDown.first ?? resolved
        dispatch(compute, spikePipeline, into: spikeTexture) { encoder in
            encoder.setTexture(spikeSource, index: 0)
            encoder.setTexture(spikeTexture, index: 1)
            encoder.setBytes(&spike, length: MemoryLayout<SpikeParams>.stride, index: 0)
        }

        frameSeed = frameSeed.truncatingRemainder(dividingBy: 4096) + 7.13
        var composite = CompositeParams(
            bloomIntensity: bloomResult == nil ? 0 : settings.bloomIntensity,
            stretch: settings.stretch,
            saturation: settings.saturation,
            spikeIntensity: settings.spikeArms > 0 ? settings.spikeIntensity : 0,
            skyLevel: settings.skyLevel,
            noiseLevel: settings.noiseLevel,
            seed: frameSeed,
            fade: min(max(fade, 0), 1))
        let target = present ?? output
        dispatch(compute, compositePipeline, into: target) { encoder in
            encoder.setTexture(resolved, index: 0)
            encoder.setTexture(bloomResult ?? resolved, index: 1)
            encoder.setTexture(target, index: 2)
            encoder.setTexture(spikeTexture, index: 3)
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
    /// Wall time the GPU spent on the last presented frame. The CPU side of `present` is
    /// encoding only — it commits and returns — so timing around the call measures nothing
    /// that matters. This is the number that decides whether a frame makes its vsync.
    public private(set) var lastGPUMilliseconds = 0.0

    public func present(camera: Camera, drawable: CAMetalDrawable) {
        guard let buffer = queue.makeCommandBuffer() else { return }
        encode(camera: camera, into: buffer, present: drawable.texture)
        buffer.addCompletedHandler { [weak self] finished in
            let spent = (finished.gpuEndTime - finished.gpuStartTime) * 1000
            DispatchQueue.main.async { self?.lastGPUMilliseconds = spent }
        }
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
