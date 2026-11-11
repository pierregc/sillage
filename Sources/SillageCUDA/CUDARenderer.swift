internal import CSillageCUDA
import Foundation
import SillageCore
import SillageRender

/// The renderer's particle passes on CUDA (#276): what `Renderer` draws with Metal's rasteriser
/// into its supersampled light and dust, before any post-processing. It executes the same frame
/// plan (`FramePlan`), from the same attributes (`ParticleAttributes`), through kernels that
/// call the shared functions of `Shaders`; the light and the dust accumulate as 64-bit fixed
/// point, so a frame drawn twice is the same to the bit. #277 turns the targets into a picture.
public final class CUDARenderer: FramePreparing {
    /// Light tracers drawn beside the massive particles (#238), from the solver's own buffers:
    /// a float4 a state, four words a motion of which the last is the tracer's, and the spacing
    /// records of the massive tree with the frame they are read in. Without the records every
    /// tracer is drawn with one spacing, as before there is a tree.
    public struct Tracers {
        public var states: CUDABuffer
        public var motions: CUDABuffer
        public var count: Int
        public var cells: CUDABuffer?
        public var treeFrame: CUDABuffer?
        public var depth: Int

        public init(
            states: CUDABuffer, motions: CUDABuffer, count: Int, cells: CUDABuffer? = nil,
            treeFrame: CUDABuffer? = nil, depth: Int = 0
        ) {
            self.states = states
            self.motions = motions
            self.count = count
            self.cells = cells
            self.treeFrame = treeFrame
            self.depth = depth
        }
    }

    public enum Target: Sendable {
        /// Four floats a pixel, rows from the top: the light and its coverage.
        case light
        /// Four floats a pixel: the dust of the four depth slabs.
        case dust
        /// A float a cell: the emitting particles counted there.
        case column
        /// Four floats a coarse pixel: the dust handed to the web, and the galaxies' tags.
        case carrier, tags
    }

    public let context: CUDAContext
    public private(set) var settings: RenderSettings
    /// Strength multiplier on the density wave, 0 to disable it.
    public var armPersistence: Float = 1
    /// Simulated time of the frame being drawn, in code units.
    public var time: Float = 0
    /// One over the mean light per unit mass across the scene: `Renderer.luminosityNormalisation`.
    public var luminosityNormalisation: Float
    public let drawnCount: Int
    /// The buffer holding the massive particles' positions, 16 bytes each from `positionOffset`.
    public let positions: CUDABuffer
    public let positionOffset: Int
    /// Pixels of a splat's square past which it is set aside and drawn a block of threads, the
    /// second way for large splats; 0 draws every splat from its particle's thread.
    public var largeSplatPixels = 0 {
        didSet { largeSplatPixels = largeCapacity > 0 ? max(largeSplatPixels, 0) : 0 }
    }
    /// Accumulates as Metal's half float targets do in place of fixed point, to measure what
    /// they lose of the faint light (#283): the result depends on the order the threads run
    /// in, and `fixedTarget` then holds a half's bits a value.
    public var halfFloats = false
    /// Splats the last pass set aside.
    public var largeSplatCount: Int { Int(sc_render_large_count(handle)) }

    private let handle: OpaquePointer
    private let largeCapacity: Int
    private let count: Int
    private let population: CUDABuffer
    private let formation: CUDABuffer
    private let luminosity: CUDABuffer
    private let component: CUDABuffer
    private let galaxy: CUDABuffer
    private let traits: CUDABuffer
    private let rampKeys: CUDABuffer
    private var smoothing: CUDABuffer
    private var tracers: Tracers?
    private let tracerScales: [Float]
    private let galaxySlots: Int
    private var diskFrames: [DiskFrame] = []
    private var ramps: [GalaxyRamp]
    private var galaxyColours: [GalaxyColours] = []
    private var mapped = false
    /// One over the lace's mean, once it is baked.
    private var laceScale: Float?
    private var tracerCount: Int { tracers?.count ?? 0 }

    /// `externalPositions` and `externalFormation` are a solver's own buffers, read where they
    /// are. `laceTexels` is the side of the baked lace, `DustWeb.laceTexels` for a picture.
    public init(
        context: CUDAContext, particles: ParticleSystem, settings: RenderSettings,
        externalPositions: CUDABuffer? = nil, externalFormation: CUDABuffer? = nil,
        externalPositionOffset: Int = 0, largeSplatCapacity: Int = 0,
        laceTexels: Int = DustWeb.laceTexels
    ) throws {
        self.context = context
        self.settings = settings
        let attributes = ParticleAttributes(particles)
        count = attributes.count
        drawnCount = attributes.drawnCount
        luminosityNormalisation = attributes.luminosityNormalisation
        tracerScales = attributes.tracerScales
        galaxySlots = attributes.galaxySlots
        ramps = GalaxyRamp.ramps(for: [], slots: attributes.galaxySlots)
        largeCapacity = max(largeSplatCapacity, 0)
        positionOffset = externalPositions == nil ? 0 : externalPositionOffset

        let frame = FramePlan.accumulationSize(settings)
        let column = FramePlan.columnSize(settings)
        let carrier = FramePlan.carrierSize(settings)
        var config = sc_render_config(
            width: UInt32(frame.width), height: UInt32(frame.height),
            column_width: UInt32(max(column.width, 1)), column_height: UInt32(max(column.height, 1)),
            carrier_width: settings.plain ? 0 : UInt32(carrier.width),
            carrier_height: settings.plain ? 0 : UInt32(carrier.height),
            lace_texels: settings.plain ? 0 : UInt32(max(laceTexels, 0)),
            large_capacity: UInt32(largeCapacity))
        var made: OpaquePointer?
        try check(
            sc_renderer_create(context.handle, &config, &made),
            "a renderer of \(frame.width) by \(frame.height)")
        guard let made else { throw CUDAError(.unknown, "no renderer") }
        handle = made

        do {
            positions =
                try externalPositions
                ?? context.makeBuffer(length: count * MemoryLayout<SIMD3<Float>>.stride)
            population = try context.makeBuffer(attributes.population)
            formation = try externalFormation ?? context.makeBuffer(attributes.formation)
            luminosity = try context.makeBuffer(attributes.luminosity)
            component = try context.makeBuffer(attributes.component)
            galaxy = try context.makeBuffer(attributes.galaxy)
            traits = try context.makeBuffer(attributes.traits)
            rampKeys = try context.makeBuffer(attributes.rampKeys)
            // Without lengths every particle is drawn with one spacing, as Metal's
            // `SmoothingField` starts.
            smoothing = try context.makeBuffer([Float](repeating: 0.05, count: count))
            let table = StellarPopulation.table
            try table.withUnsafeBytes { bytes in
                try check(
                    sc_render_set_stellar(
                        made, bytes.baseAddress?.assumingMemoryBound(to: Float.self),
                        UInt32(StellarPopulation.samples)),
                    "the stellar population's table")
            }
            let stars = BackgroundStar.field(count: settings.starCount)
            try stars.withUnsafeBytes { bytes in
                try check(
                    sc_render_set_starfield(made, bytes.baseAddress, UInt32(stars.count)),
                    "the field stars")
            }
            if externalPositions == nil { try upload(positions: particles.positions) }
        } catch {
            sc_renderer_destroy(made)
            throw error
        }
    }

    deinit { sc_renderer_destroy(handle) }

    public func upload(positions values: [SIMD3<Float>]) throws {
        guard !values.isEmpty else { return }
        try positions.upload(values, at: positionOffset)
    }

    /// The per-particle smoothing lengths, a float each: nil goes back to one spacing for all.
    public func setSmoothing(_ buffer: CUDABuffer?) throws {
        smoothing = try buffer ?? context.makeBuffer([Float](repeating: 0.05, count: count))
    }

    public func setTracers(_ source: Tracers?) { tracers = source }

    public func setDiskFrames(_ frames: [DiskFrame]) {
        guard !frames.isEmpty else { return }
        diskFrames = frames
    }

    /// Each galaxy's colours from a look file's palette, as `Renderer.setGalaxyColours`.
    public func setGalaxyColours(_ palette: [GalaxyColours]) {
        guard palette != galaxyColours else { return }
        galaxyColours = palette
        ramps = GalaxyRamp.ramps(for: palette, slots: galaxySlots)
        mapped = GalaxyRamp.mapped(ramps)
    }

    public func apply(_ look: RenderLook) {
        settings.apply(look)
        armPersistence = look.armPersistence
    }

    public func apply(_ file: LookFile) {
        apply(file.look)
        setGalaxyColours(file.palette)
    }

    /// Everything but the positions and the smoothing, for drawing `file` on a moment of a take.
    public func prepare(
        _ file: LookFile, shot: ShotReplay.Shot, take: RecordingFile.Loaded,
        at blend: Recording.Blend
    ) {
        let moment = TakeFraming.moment(file, shot: shot, take: take, at: blend)
        apply(moment.look)
        setGalaxyColours(moment.palette)
        time = moment.time
        setDiskFrames(moment.diskFrames)
    }

    /// The plan `draw` executes for this camera, with the lace baked if the frame wants the web.
    public func plan(
        camera: Camera, stages: ClosedRange<UInt32> = 0...1, first: Bool = true
    ) throws -> FramePlan {
        if FramePlan.drawsWeb(settings, stages: stages), laceScale == nil {
            var mean: Float = 0
            try check(sc_render_bake_lace(handle, &mean), "baking the lace")
            laceScale = 1 / max(mean, 1e-6)
        }
        return FramePlan(
            settings: settings, camera: camera, time: time, drawnCount: drawnCount,
            tracerCount: tracerCount, luminosityNormalisation: luminosityNormalisation,
            mapped: mapped,
            laceScale: FramePlan.drawsWeb(settings, stages: stages) ? laceScale : nil,
            stages: stages, first: first)
    }

    /// The particle passes of a frame into the light and the dust. `particles`, counted over
    /// the massive ones drawn then the tracers, and `stages` draw part of the frame into what
    /// earlier parts left, as `Renderer.render(camera:slice:)` does. `threads` draws each pass
    /// from that many host threads at once, which only the CPU target gains from.
    public func draw(
        camera: Camera, particles: Range<Int>? = nil, stages: ClosedRange<UInt32> = 0...1,
        first: Bool = true, threads: Int = 1
    ) throws {
        try draw(
            plan(camera: camera, stages: stages, first: first), particles: particles,
            threads: threads)
    }

    /// The same from a plan made elsewhere: another renderer's, or one read back from a file.
    public func draw(_ plan: FramePlan, particles: Range<Int>? = nil, threads: Int = 1) throws {
        try bind()
        if plan.clears { try check(sc_render_clear(handle), "emptying the light and the dust") }
        let everything = split(0..<(drawnCount + tracerCount))
        let parts = split(particles ?? 0..<(drawnCount + tracerCount))
        for pass in plan.passes {
            switch pass {
            case .column:
                try draw(SC_RENDER_COLUMN, pass, plan, everything, threads)
            case .webCarrier:
                try draw(SC_RENDER_WEB_CARRIER, pass, plan, parts, threads)
            case .starfield:
                try draw(SC_RENDER_STARFIELD, pass, plan, (0..<0, 0..<0), 1)
            case .dust:
                try draw(SC_RENDER_DUST, pass, plan, parts, threads)
            case .paintedDust:
                try draw(SC_RENDER_PAINTED_DUST, pass, plan, parts, threads)
            case .webResolve:
                try draw(SC_RENDER_WEB_RESOLVE, pass, plan, (0..<0, 0..<0), 1)
            case .stars:
                try draw(SC_RENDER_STARS, pass, plan, parts, threads)
            case .plain:
                try draw(SC_RENDER_PLAIN, pass, plan, everything, threads)
            }
        }
    }

    /// Draws the frame and brings the targets up to date for reading.
    public func render(camera: Camera, threads: Int = 1) throws {
        try draw(camera: camera, threads: threads)
        try finish()
    }

    /// Brings the light and the dust up to date as floats, for `target` and for #277.
    public func finish() throws {
        try check(sc_render_finish(handle), "finishing the frame's targets")
    }

    /// A target of the last frame, after `finish`.
    public func target(_ which: Target) throws -> [Float] {
        let frame = FramePlan.accumulationSize(settings)
        let column = FramePlan.columnSize(settings)
        let carrier = FramePlan.carrierSize(settings)
        let (name, values): (sc_render_target, Int) =
            switch which {
            case .light: (SC_RENDER_LIGHT, frame.width * frame.height * 4)
            case .dust: (SC_RENDER_DUST_TARGET, frame.width * frame.height * 4)
            case .column: (SC_RENDER_COLUMN_TARGET, max(column.width, 1) * max(column.height, 1))
            case .carrier: (SC_RENDER_CARRIER, carrier.width * carrier.height * 4)
            case .tags: (SC_RENDER_TAGS, carrier.width * carrier.height * 4)
            }
        guard let buffer = sc_render_target_of(handle, name) else {
            throw CUDAError(.invalidArgument, "this renderer has no \(which) target")
        }
        return try CUDABuffer(borrowing: buffer, of: self, context: context)
            .download(Float.self, count: values)
    }

    /// The light or the dust as it accumulated: four 64-bit fixed point values a pixel, of
    /// which `fixedUnit` is one unit.
    public func fixedTarget(_ which: Target) throws -> [UInt64] {
        let frame = FramePlan.accumulationSize(settings)
        let name: sc_render_target
        switch which {
        case .light: name = SC_RENDER_LIGHT_FIXED
        case .dust: name = SC_RENDER_DUST_FIXED
        case .column, .carrier, .tags:
            throw CUDAError(.invalidArgument, "only the light and the dust are read as fixed point")
        }
        guard let buffer = sc_render_target_of(handle, name) else {
            throw CUDAError(.invalidArgument, "this renderer has no \(which) target")
        }
        return try CUDABuffer(borrowing: buffer, of: self, context: context)
            .download(UInt64.self, count: frame.width * frame.height * 4)
    }

    public static var fixedUnit: UInt64 { sc_render_fixed_unit() }

    /// A value's bytes over its whole stride, as a Metal buffer holds it: its size alone
    /// leaves out the padding that ends a struct the MSL counts.
    private static func withStride<T, R>(of value: T, _ body: (UnsafeRawBufferPointer) -> R) -> R {
        withUnsafeTemporaryAllocation(
            byteCount: MemoryLayout<T>.stride, alignment: MemoryLayout<T>.alignment
        ) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            withUnsafeBytes(of: value) { bytes.copyMemory(from: $0) }
            return body(UnsafeRawBufferPointer(bytes))
        }
    }

    /// `particles`, counted over `[massive drawn | tracers]`, split into the two draws' ranges.
    private func split(_ particles: Range<Int>) -> (massive: Range<Int>, tracers: Range<Int>) {
        let massive = particles.clamped(to: 0..<drawnCount)
        let light = particles.clamped(to: drawnCount..<(drawnCount + tracerCount))
        return (massive, (light.lowerBound - drawnCount)..<(light.upperBound - drawnCount))
    }

    /// Hands the frame's buffers and tables to the renderer.
    private func bind() throws {
        var massive = sc_render_massive(
            positions: positions.handle, positions_offset: positionOffset,
            population: population.handle, formation: formation.handle,
            luminosity: luminosity.handle, component: component.handle, galaxy: galaxy.handle,
            smoothing: smoothing.handle, traits: traits.handle, ramp_keys: rampKeys.handle,
            count: UInt32(drawnCount))
        if let tracers {
            var traced = sc_render_tracers()
            traced.states = tracers.states.handle
            traced.words = tracers.motions.handle
            traced.cells = tracers.cells?.handle
            traced.tree_frame = tracers.treeFrame?.handle
            traced.depth = UInt32(max(tracers.depth, 0))
            traced.count = UInt32(max(tracers.count, 0))
            withUnsafeMutableBytes(of: &traced.scales) { scales in
                for (index, scale) in tracerScales.prefix(16).enumerated() {
                    scales.storeBytes(of: scale, toByteOffset: index * 4, as: Float.self)
                }
            }
            try check(sc_render_set_particles(handle, &massive, &traced), "the particles' buffers")
        } else {
            try check(sc_render_set_particles(handle, &massive, nil), "the particles' buffers")
        }
        let status = diskFrames.withUnsafeBytes { frames in
            ramps.withUnsafeBytes { ramps in
                sc_render_set_frame(
                    handle, frames.baseAddress, UInt32(diskFrames.count), ramps.baseAddress,
                    UInt32(self.ramps.count))
            }
        }
        try check(status, "the disk frames and the ramps")
        try check(sc_render_set_large(handle, UInt32(largeSplatPixels)), "the large splats' size")
        try check(sc_render_set_half_floats(handle, halfFloats ? 1 : 0), "the accumulation")
    }

    private func draw(
        _ name: sc_render_pass, _ pass: FramePlan.Pass, _ plan: FramePlan,
        _ parts: (massive: Range<Int>, tracers: Range<Int>), _ threads: Int
    ) throws {
        try check(sc_render_begin(handle, name), "starting the \(pass) pass")
        let uniforms = plan.uniforms(for: pass)
        let web = plan.web
        let handle = SendableHandle(handle)
        func part(_ massive: Range<Int>, _ tracers: Range<Int>) -> sc_status {
            Self.withStride(of: uniforms) { uniforms in
                func call(_ web: UnsafeRawBufferPointer?) -> sc_status {
                    sc_render_draw(
                        handle.pointer, name, uniforms.baseAddress, uniforms.count, web?.baseAddress,
                        web?.count ?? 0, UInt32(massive.lowerBound), UInt32(massive.count),
                        UInt32(tracers.lowerBound), UInt32(tracers.count))
                }
                guard let web else { return call(nil) }
                return Self.withStride(of: web) { call($0) }
            }
        }
        // The second way keeps one list of splats set aside: its passes are drawn in one go.
        let ways = largeSplatPixels > 0 ? 1 : max(threads, 1)
        guard ways > 1, parts.massive.count + parts.tracers.count > ways else {
            return try check(part(parts.massive, parts.tracers), "the \(pass) pass")
        }
        let failures = Failures()
        concurrentPerform(iterations: ways) { way in
            func share(_ range: Range<Int>) -> Range<Int> {
                let low = range.lowerBound + range.count * way / ways
                let high = range.lowerBound + range.count * (way + 1) / ways
                return low..<high
            }
            let status = part(share(parts.massive), share(parts.tracers))
            if status != SC_OK { failures.note(String(cString: sc_last_error())) }
        }
        if let message = failures.first {
            throw CUDAError(.unknown, "the \(pass) pass: \(message)")
        }
    }
}

private struct SendableHandle: @unchecked Sendable {
    let pointer: OpaquePointer
    init(_ pointer: OpaquePointer) { self.pointer = pointer }
}

/// The first message of the parts of a pass that failed.
private final class Failures: @unchecked Sendable {
    private let lock = NSLock()
    private var message: String?

    var first: String? {
        lock.lock()
        defer { lock.unlock() }
        return message
    }

    func note(_ text: String) {
        lock.lock()
        if message == nil { message = text }
        lock.unlock()
    }
}
