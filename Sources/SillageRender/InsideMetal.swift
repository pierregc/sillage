import Foundation
import Metal

/// What Metal draws a frame from inside a galaxy with (#297): a library of its own, the text
/// every frame compiles with the inside of a galaxy in it, so that a frame without it draws
/// from the library it always had; the pipelines of the passes that text changes; and the list
/// of the near particles, whose point stars one instanced draw lays.
struct InsidePass {
    static let source =
        "#define SILLAGE_POPULATION_WIDTHS 1\n#define SILLAGE_INSIDE 1\n" + Shaders.source
    /// Particles a thread of the listing kernels goes through.
    static let block = 1024
    /// Stars a list entry stands for, `insideGroup` in the shader, and the most entries a list
    /// holds: a hundred and twenty-eight million stars, more than a frame can afford to draw.
    static let group = 8
    static let mostEntries = 16_000_000
    /// The most entries a particle takes: `nearStars` at its most (#357).
    static let particleEntries = 2048

    let library: MTLLibrary
    let dust: MTLRenderPipelineState
    let splat: MTLRenderPipelineState
    let stars: MTLRenderPipelineState
    let resolve: MTLComputePipelineState
    private let count: MTLComputePipelineState
    private let offsets: MTLComputePipelineState
    private let fill: MTLComputePipelineState
    private let counts: MTLBuffer
    /// The stars to draw, eight to an entry: a particle's index and which eight of its stars.
    let list: MTLBuffer
    let entries: Int
    /// The stars' draw, as `MTLDrawPrimitivesIndirectArguments`.
    let draw: MTLBuffer
    let particles: Int
    /// Built the first time a frame with the web is drawn; nil when it could not be.
    var web: DustWeb.Pass?
    var webUnavailable = false
    /// The light tracers' two, built the first time a frame draws some.
    var tracers: (dust: MTLRenderPipelineState, splat: MTLRenderPipelineState)?

    init(device: MTLDevice, particles: Int) throws {
        guard device.readWriteTextureSupport == .tier2 else {
            throw RenderError.unsupported("textures read and written in one kernel")
        }
        do {
            library = try ShaderCache.library(Self.source, on: device)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        let library = library
        func additive(_ vertex: String, _ fragment: String, writing target: Int) throws
            -> MTLRenderPipelineState
        {
            try Renderer.additive(
                vertex, fragment, writing: target, attachments: 2, format: .rgba16Float,
                library: library, device: device)
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
        dust = try additive("splatVertex", "dustFragment", writing: 1)
        splat = try additive("splatVertex", "splatFragment", writing: 0)
        stars = try additive("pointStarVertex", "pointStarFragment", writing: 0)
        resolve = try compute("insideResolve")
        count = try compute("insideCount")
        offsets = try compute("insideOffsets")
        fill = try compute("insideFill")
        self.particles = max(particles, 1)
        let blocks = (self.particles + Self.block - 1) / Self.block
        entries = min(self.particles * Self.particleEntries, Self.mostEntries)
        guard let counts = device.makeBuffer(length: blocks * 4, options: .storageModePrivate),
            let list = device.makeBuffer(length: entries * 8, options: .storageModePrivate),
            let draw = device.makeBuffer(length: 16, options: .storageModeShared)
        else { throw RenderError.textureAllocation }
        self.counts = counts
        self.list = list
        self.draw = draw
    }

    /// Lists the stars that may reach the frame and writes their draw. `bind` gives the kernels
    /// the particles, the frame's uniforms and its column density where the vertex stage reads
    /// them.
    func encodeList(into buffer: MTLCommandBuffer, bind: (MTLComputeCommandEncoder) -> Void) {
        guard let encoder = buffer.makeComputeCommandEncoder() else { return }
        var span = SIMD4<UInt32>(UInt32(particles), UInt32(Self.block), UInt32(entries), 0)
        let blocks = (particles + Self.block - 1) / Self.block
        bind(encoder)
        encoder.setBuffer(counts, offset: 0, index: 20)
        encoder.setBytes(&span, length: 16, index: 21)
        encoder.setBuffer(draw, offset: 0, index: 22)
        encoder.setBuffer(list, offset: 0, index: 23)
        for (pipeline, threads) in [(count, blocks), (offsets, 1), (fill, blocks)] {
            encoder.setComputePipelineState(pipeline)
            encoder.dispatchThreads(
                MTLSize(width: threads, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(pipeline.maxTotalThreadsPerThreadgroup, 64), height: 1, depth: 1))
        }
        encoder.endEncoding()
    }

    /// The stars the last frame drew, to the eight, once its commands have run.
    var listed: Int { Int(draw.contents().load(as: UInt32.self)) * Self.group }

    mutating func webPass(device: MTLDevice, width: Int, height: Int) -> DustWeb.Pass? {
        if web == nil, !webUnavailable {
            do {
                web = try DustWeb.Pass(library: library, device: device, width: width, height: height)
            } catch {
                webUnavailable = true
            }
        }
        return web
    }

    /// The web's coarse targets for a frame that carries each galaxy's dust apart (#399).
    mutating func webTargets(_ count: Int, device: MTLDevice) -> [(carrier: MTLTexture, tags: MTLTexture)]? {
        guard var held = web else { return nil }
        let targets = held.targets(count, device: device)
        web = held
        return targets
    }

    mutating func tracerPipelines(device: MTLDevice) -> (
        dust: MTLRenderPipelineState, splat: MTLRenderPipelineState
    )? {
        if tracers == nil {
            func additive(_ fragment: String, writing target: Int) -> MTLRenderPipelineState? {
                try? Renderer.additive(
                    "splatTracerVertex", fragment, writing: target, attachments: 2,
                    format: .rgba16Float, library: library, device: device)
            }
            if let dust = additive("dustFragment", writing: 1),
                let splat = additive("splatFragment", writing: 0)
            {
                tracers = (dust, splat)
            }
        }
        return tracers
    }
}
