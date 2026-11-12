import SillageCore

/// The ramps of the palette a renderer draws with, which galaxies have a colour ramp, and
/// whether the palette is the one held already. Both engines keep their palette here, and only
/// copy the ramps where their kernels read them.
public struct GalaxyPalette: Sendable {
    public private(set) var colours: [GalaxyColours] = []
    public private(set) var ramps: [GalaxyRamp]
    public private(set) var mapped = false
    public let slots: Int

    public init(slots: Int) {
        self.slots = slots
        ramps = GalaxyRamp.ramps(for: [], slots: slots)
    }

    /// Takes a look file's palette. False when it is the one held, which leaves everything
    /// as it was.
    @discardableResult
    public mutating func set(_ palette: [GalaxyColours]) -> Bool {
        guard palette != colours else { return false }
        colours = palette
        ramps = GalaxyRamp.ramps(for: palette, slots: slots)
        mapped = GalaxyRamp.mapped(ramps)
        return true
    }

    /// Takes the ramps as they are, which a palette has not made.
    public mutating func set(ramps: [GalaxyRamp]) {
        colours = []
        self.ramps = ramps
        mapped = GalaxyRamp.mapped(ramps)
    }
}

/// What setting up a frame does that is not the engine's: the look and its settings, the
/// palette, the time and the painted arms of a moment of a take. The Metal renderer and the CUDA
/// one conform, give their own `restyle`, `setGalaxyColours` and `setDiskFrames` (the buffers
/// those fill are theirs), and share the rest (#277).
public protocol FrameStyling: FramePreparing {
    var settings: RenderSettings { get }
    /// Simulated time of the frame being drawn, in code units.
    var time: Float { get set }
    /// Takes new settings, and the look's strength multiplier on the density wave.
    func restyle(_ settings: RenderSettings, armPersistence: Float)
    func setGalaxyColours(_ palette: [GalaxyColours])
    func setDiskFrames(_ frames: [DiskFrame])
}

extension FrameStyling {
    /// Everything a frame may change on its own, in one go. Resolution, supersampling, bloom
    /// levels and the starfield are deliberately absent: those own textures and buffers, and
    /// changing them means a new renderer.
    public func apply(_ look: RenderLook) {
        var next = settings
        next.apply(look)
        restyle(next, armPersistence: look.armPersistence)
    }

    public func apply(_ file: LookFile) {
        apply(file.look)
        setGalaxyColours(file.palette)
    }

    /// Everything but the positions, for drawing `file` on a moment of a take.
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
}
