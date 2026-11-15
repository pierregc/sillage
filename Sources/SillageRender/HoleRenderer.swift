import Foundation
import Metal
import SillageCore
import simd

/// What `holeSplatVertex` reads; mirrors `HoleSplatUniforms` in `HoleShaders`.
struct HoleSplatUniforms {
    var viewProjection: simd_float4x4
    var camera: SIMD4<Float>
    var projectionScale: Float
    var particleSize: Float
    var minimumSize: Float
    var maximumSize: Float
    var brightness: Float
    var hottest: Float
    var image: UInt32
    var lensed: UInt32
    var radiusCount: UInt32
    var angleCount: UInt32
    var lensInner: Float
    var lensSpan: Float
    var beaming: Float
    var shadowAngle: Float
    var temperature: UInt32
    var crossingScale: Float
    var lightScale: Float
    var ambient: Float
    var innerEdge: Float
    var edgePeak: Float
    var supersample: Float
    var stars: UInt32 = 0
}

/// How a tidal disruption's frame is drawn (#314).
public struct HoleLook: Sendable {
    public enum Temperature: String, Sendable, CaseIterable {
        /// A thin disk's: T falls as r^-3/4 past the last stable orbit, whatever the gas does.
        case radius
        /// The run's: the heat the stream's crossings and the viscosity give each tracer.
        case crossing
    }

    /// Bent by the hole, or drawn straight with the shadow hiding what is behind it.
    public var lensed = true
    /// Images drawn: 1 the direct one, 2 with the one that passes behind the hole, 3 with the
    /// next, in the photon ring.
    public var images = 2
    public var temperature = Temperature.crossing
    /// Kelvin at the hottest: the thin disk's peak, or the run's brightest few per thousand.
    public var hottest: Float = 6500
    /// 1 for the Doppler shift and the redshift as they are, 0 for none.
    public var beaming: Float = 1
    public var exposure: Float = 1
    /// Light every tracer gives whatever its heat, against the mean of the heated ones, so
    /// that a cold stream still shows, dim and red.
    public var ambient: Float = 0.02
    /// A tracer's kernel, in Schwarzschild radii, between two sizes in output pixels.
    public var particleSize: Float = 0.05
    public var minimumSize: Float = 1.3
    public var maximumSize: Float = 24
    /// Field stars far behind the hole, which the lens bends as it bends the disk.
    public var stars = 8000
    public var starBrightness: Float = 1

    public init() {}

    /// The post stages' settings: Sillage's, softer, with no field stars and no spikes.
    public static func settings(width: Int, height: Int, supersample: Int = 2) -> RenderSettings {
        var settings = RenderSettings(
            width: width, height: height, supersample: supersample, starCount: 0,
            bloomThreshold: 0.6, bloomSoftKnee: 0.6, bloomIntensity: 0.35, bloomLevels: 6,
            stretch: 6, saturation: 1.6, whitePoint: 6, spikeArms: 0, spikeLength: 0,
            spikeIntensity: 0, skyLevel: 0.0006, noiseLevel: 0.0008, galaxyTint: 0)
        settings.columnSmoothing = 0
        return settings
    }
}

/// Draws a `TidalFrame` (#314): each tracer a splat at its temperature's black body, once per
/// image where `HoleLens` puts it, into the light target of a `Renderer` whose post stages make
/// the picture. The lens table is the camera distance's, rebuilt when that changes.
public final class HoleRenderer {
    public let settings: RenderSettings
    let renderer: Renderer
    private let pipeline: MTLRenderPipelineState
    private let device: MTLDevice
    private var lens: HoleLens?
    private var lensBuffer: MTLBuffer?
    private var positions: MTLBuffer?
    private var velocities: MTLBuffer?
    private var uploaded = 0
    /// Tracers not yet swallowed, and the mean light of each law over them, for the exposure.
    private var alive: Float = 1
    private var meanLight: [HoleLook.Temperature: Float] = [:]
    private var crossingScale: Float = 1
    /// Holds the exposure of the frame it was first set on, for a video that should not
    /// breathe with the light a frame happens to hold.
    public var fixedExposure = false
    private var exposureSet = false
    /// Share of the last frame's normalisation a new frame keeps, so that a run's video eases
    /// between the light of one moment and the next instead of jumping; 0 for none.
    public var exposureEasing: Float = 0
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

    /// The lens table for a camera at `distance` from the hole, built once per distance.
    public func lens(at distance: Float) -> HoleLens {
        if let lens, abs(lens.cameraDistance - distance) < 1e-4 * distance { return lens }
        let built = HoleLens(cameraDistance: distance)
        lens = built
        lensBuffer = built.entries.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
        return built
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
        guard !(fixedExposure && exposureSet) else { return }
        exposureSet = true
        var heats: [Float] = []
        var fluxes: [Float] = []
        var disk: Float = 0
        let stride = max(frame.count / 200_000, 1)
        for index in Swift.stride(from: 0, to: frame.count, by: stride) where frame.velocities[index].w >= 0 {
            let p = frame.positions[index]
            let heat = max(p.w, 0)
            heats.append(heat)
            fluxes.append(heat * frame.velocities[index].w)
            let shape = Self.diskShape(radius: simd_length(SIMD3<Float>(p.x, p.y, p.z)))
            disk += shape * shape * shape * shape
        }
        let count = Float(max(heats.count, 1))
        alive = count * Float(stride)
        fluxes.sort()
        let top = fluxes.isEmpty ? 1 : fluxes[min(Int(Float(fluxes.count) * 0.997), fluxes.count - 1)]
        let measured: [HoleLook.Temperature: Float] = [
            .crossing: max(heats.reduce(0, +) / count, 1e-30), .radius: max(disk / count, 1e-30),
        ]
        let scale = top > 0 ? 1 / top : 1
        let keep = meanLight.isEmpty ? 0 : exposureEasing
        func eased(_ old: Float, _ new: Float) -> Float { exp(log(old) * keep + log(new) * (1 - keep)) }
        for (law, value) in measured { meanLight[law] = eased(meanLight[law] ?? value, value) }
        crossingScale = eased(crossingScale, scale)
    }

    /// Field stars on a sphere `radius` from the hole: uniform over the sky, a few bright among
    /// many faint, from red dwarfs' colour to blue giants', the same every time.
    func placeStars(_ count: Int, radius: Float = 2000) {
        guard count != starCount else { return }
        var generator = SeededGenerator(seed: 314)
        var positions: [SIMD4<Float>] = []
        var colours: [SIMD4<Float>] = []
        for _ in 0..<count {
            let z = generator.uniform(in: -1...1)
            let angle = generator.uniform() * 2 * .pi
            let ring = (1 - z * z).squareRoot()
            let light = 0.0015 * pow(max(generator.uniform(), 1e-4), -1.5)
            let kelvin = 3000 + 9000 * pow(generator.uniform(), 2)
            positions.append(
                SIMD4<Float>(
                    ring * cos(angle) * radius, ring * sin(angle) * radius, z * radius, min(light, 1.5)))
            colours.append(SIMD4<Float>(0, 0, 0, kelvin))
        }
        starCount = count
        guard count > 0 else { return }
        starPositions = device.makeBuffer(bytes: positions, length: count * 16, options: .storageModeShared)
        starColours = device.makeBuffer(bytes: colours, length: count * 16, options: .storageModeShared)
    }

    static let innerEdge = TidalDisruption.innermostStableOrbit
    /// The largest value of x^3/4 (1 - √x)^1/4, at x = 36/49.
    static let edgePeak: Float = {
        let x: Float = 36 / 49
        return pow(x, 0.75) * pow(1 - x.squareRoot(), 0.25)
    }()

    static func diskShape(radius: Float) -> Float {
        let x = innerEdge / max(radius, 1e-3)
        return x >= 1 ? 0 : pow(x, 0.75) * pow(1 - x.squareRoot(), 0.25) / edgePeak
    }

    /// The frame `upload` last took, seen by `camera` as `look` asks. `present` takes the
    /// picture instead of the returned pixels, through `buffer` when given.
    public func render(
        _ frame: TidalFrame, camera: Camera, look: HoleLook, present: MTLTexture? = nil,
        into buffer: MTLCommandBuffer? = nil
    ) -> [UInt8] {
        let distance = simd_length(camera.eye)
        let lens = self.lens(at: distance)
        let scale = Float(settings.supersample)
        let aspect = Float(settings.width) / Float(settings.height)
        var uniforms = HoleSplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            camera: SIMD4<Float>(camera.eye, distance),
            projectionScale: Float(settings.height) * scale / 2 / tan(camera.fieldOfView / 2),
            particleSize: look.particleSize, minimumSize: look.minimumSize * scale,
            maximumSize: look.maximumSize * scale,
            brightness: look.exposure * 1e5 / (alive * (1 + look.ambient)), hottest: look.hottest, image: 0,
            lensed: look.lensed ? 1 : 0, radiusCount: UInt32(lens.radiusCount),
            angleCount: UInt32(lens.angleCount), lensInner: lens.minimumRadius,
            lensSpan: log(lens.maximumRadius / lens.minimumRadius), beaming: look.beaming,
            shadowAngle: lens.shadowAngle, temperature: look.temperature == .radius ? 0 : 1,
            crossingScale: crossingScale, lightScale: 1 / (meanLight[look.temperature] ?? 1),
            ambient: look.ambient, innerEdge: Self.innerEdge,
            edgePeak: Self.edgePeak, supersample: scale)
        let images = look.lensed ? min(max(look.images, 1), lens.images) : 1
        placeStars(look.stars)
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
            encoder.setVertexBuffer(lensBuffer, offset: 0, index: 3)
            for image in 0..<images {
                uniforms.image = UInt32(image)
                encoder.setVertexBytes(&uniforms, length: MemoryLayout<HoleSplatUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: uploaded)
            }
            if starCount > 0, look.starBrightness > 0 {
                var field = uniforms
                field.stars = 1
                field.beaming = 0
                field.particleSize = 0
                field.brightness = look.starBrightness * look.exposure
                encoder.setVertexBuffer(starPositions, offset: 0, index: 0)
                encoder.setVertexBuffer(starColours, offset: 0, index: 1)
                for image in 0..<images {
                    field.image = UInt32(image)
                    encoder.setVertexBytes(&field, length: MemoryLayout<HoleSplatUniforms>.stride, index: 2)
                    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: starCount)
                }
            }
            encoder.endEncoding()
        }
    }

    public var lastGPUTime: Double { renderer.lastGPUTime }
}
