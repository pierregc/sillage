import simd

/// What a galaxy's disk is doing now, rather than what it was configured as.
///
/// The spiral pattern is painted into the disk plane, and that plane came from the scene
/// configuration and was never looked at again. After a merger the disk is gone and the
/// arms stay, lying in a plane nothing occupies any more. This is the measurement that
/// answers both halves of that: which way the disk material actually turns, and whether it
/// is still turning together at all.
public struct DiskState: Sendable {
    /// Unit normal of the plane the disk material turns in.
    public var axis: SIMD3<Float>
    /// The latest ordered fraction, |sum m r x v| / sum m|r||v| over the disk material. One
    /// would be a razor-thin disk on exactly circular orbits; a real one as the sampler lays
    /// it down starts near 0.9, and a spheroid of random orbits sits near zero.
    public var coherence: Float
    /// That same ratio the first time it was measured. A thicker disk starts lower, so
    /// disruption is judged against how this galaxy began rather than against an absolute
    /// nobody could pick for every scene.
    public var reference: Float
    /// How thick the disk material is, as the root of the mean square height above the plane
    /// over the mean square distance across it. A disk sits near 0.15; an isotropic spheroid
    /// has half its spread along the axis and two thirds across, so it sits near 0.71.
    public var thickness: Float
    /// And that the first time it was measured, for the same reason as `reference`.
    public var thicknessReference: Float
    /// Zero while the disk is a disk, one once it is not, and it never comes back down.
    public var disruption: Float

    /// Below this share of its initial order, a disk is no longer painted at all.
    static let disruptedBelow: Float = 0.30
    /// Above this share, it is painted in full. In between it fades.
    static let orderedAbove: Float = 0.70
    /// How many times thicker than it started the material may get before the arms begin to
    /// fade, and how many before they are gone. Measured on the presets: an isolated disk
    /// left to heat for 900 Myr reaches 1.2, a disk that survives a 2 kpc passage as a thick
    /// disk reaches 3.9, and the two halves of a merger reach 6.8 and 16.9.
    static let thickenedBy: Float = 3
    static let spheroidBy: Float = 6

    public init(
        axis: SIMD3<Float>, coherence: Float = 0, reference: Float = 0, thickness: Float = 0,
        thicknessReference: Float = 0, disruption: Float = 0
    ) {
        self.axis = axis
        self.coherence = coherence
        self.reference = reference
        self.thickness = thickness
        self.thicknessReference = thicknessReference
        self.disruption = disruption
    }

    /// The state a galaxy is configured to begin in: its natal plane, nothing lost yet.
    ///
    /// Signed by the spin, because this is an angular momentum and not just a plane. A
    /// retrograde disk is laid down in the same plane with its velocities reversed, so what
    /// gets measured of it points the other way; taking the unsigned normal as the starting
    /// point would read every retrograde galaxy as having flipped over on the first step.
    public static func natal(_ galaxy: GalaxyConfig) -> DiskState {
        DiskState(axis: galaxy.orientation.columns.2 * galaxy.spin.sign)
    }

    public static func natal(_ scene: SceneConfig) -> [DiskState] {
        scene.galaxies.map(natal)
    }

    /// Folds one measurement of the disk material into the running state.
    ///
    /// `momentum` is the mass-weighted sum of r x v about the galaxy's own centre and in its
    /// own frame, and `scalar` the sum of m|r||v| — what that first sum would reach if every
    /// orbit lay in one plane and ran the same way round. Their ratio is therefore how
    /// ordered the rotation is, needs no unit and no length scale, and does not care how many
    /// particles the scene was sampled with.
    ///
    /// Disruption is a ratchet on purpose. Material scattered out of the plane does not come
    /// back into it, and through a close passage the measured order dips and partly recovers
    /// as debris sloshes through; letting the arms come back for a few seconds and then go
    /// again reads far worse than letting them go once.
    public mutating func fold(
        momentum: SIMD3<Double>, scalar: Double, height: Double, across: Double
    ) {
        guard scalar > 0, momentum.x.isFinite, momentum.y.isFinite, momentum.z.isFinite else {
            return
        }
        let length = simd_length(momentum)
        // A disk with no net rotation left has no plane to report, so the last one it had is
        // a better answer than a normalised zero.
        if length > 1e-12 { axis = simd_normalize(SIMD3<Float>(momentum / length)) }
        coherence = Float(min(length / scalar, 1))
        if reference <= 0 { reference = max(coherence, 1e-3) }
        if across > 0 { thickness = Float((height / across).squareRoot()) }
        if thicknessReference <= 0 { thicknessReference = max(thickness, 1e-3) }

        // Two independent ways of stopping being a disk, and a merger needs both to be seen.
        // Ordered rotation alone says a merged pair is still turning, and it is: what it is
        // not any more is flat. Flatness alone would let a disk stirred into counter-rotating
        // halves keep its arms. Whichever has gone further decides.
        //
        // Order is judged against how this galaxy began and thickness against how many times
        // thicker it has got, and that difference is not arbitrary. A galaxy configured as a
        // spheroid starts thick and must not read as destroyed for it, so an absolute
        // thickness is no use; but judging it by a ratio to a very thin start would make any
        // disk that merely thickened into a thick disk read as destroyed, which is what the
        // measurements showed.
        let ordered = coherence / reference
        let swollen = thickness / max(thicknessReference, 1e-3)
        let kept = min(
            DiskState.smoothstep(DiskState.disruptedBelow, DiskState.orderedAbove, ordered),
            1 - DiskState.smoothstep(DiskState.thickenedBy, DiskState.spheroidBy, swollen))
        disruption = max(disruption, min(max(1 - kept, 0), 1))
    }

    static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float {
        let t = min(max((x - edge0) / max(edge1 - edge0, 1e-6), 0), 1)
        return t * t * (3 - 2 * t)
    }
}
