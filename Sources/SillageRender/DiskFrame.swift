import SillageCore
import simd

/// A galaxy's disk plane and spiral pattern, evaluated at render time.
///
/// Arms baked into the initial conditions wind up within about one orbit, because the disk
/// rotates differentially. Real spiral arms are a density wave: the pattern turns at its own
/// slower speed while stars pass through it, which is why a galaxy keeps two clean arms for
/// far longer than a material pattern could. Modulating brightness, colour and extinction by
/// the pattern at the particle's current position reproduces that.
public struct DiskFrame {
    public var center: SIMD4<Float>
    public var axisU: SIMD4<Float>
    public var axisV: SIMD4<Float>
    public var pattern: SIMD4<Float>
    public var tint: SIMD4<Float>

    /// Carries a galaxy's natal in-plane axes onto the plane its disk actually turns in now,
    /// by the shortest rotation that takes one normal onto the other.
    ///
    /// The obvious alternative — build any orthonormal pair perpendicular to the live axis —
    /// is what makes a pattern visibly swim. Such a basis has no way to know where the arms
    /// were, so it rolls about the axis as the axis tilts, and it jumps wherever the
    /// reference direction it was built from happens to line up with the axis. Transporting
    /// the natal pair has neither fault: it adds no rotation about the axis at all, and it
    /// collapses to the natal pair exactly when the disk has not moved.
    static func planeAxes(natal: simd_float3x3, normal: SIMD3<Float>, axis: SIMD3<Float>)
        -> (u: SIMD3<Float>, v: SIMD3<Float>)
    {
        let u = natal.columns.0
        let v = natal.columns.1
        let turn = simd_cross(normal, axis)
        let sine = simd_length(turn)
        let cosine = simd_dot(normal, axis)
        guard sine > 1e-6 else {
            // No rotation at all, or the disk has turned exactly upside down. A half turn has
            // no unique axis; taking it about the natal U keeps that axis and reverses the
            // other, which is what an inverted disk does to the sense its arms wind in.
            return cosine >= 0 ? (u, v) : (u, -v)
        }
        let k = turn / sine
        func rotate(_ w: SIMD3<Float>) -> SIMD3<Float> {
            w * cosine + simd_cross(k, w) * sine + k * (simd_dot(k, w) * (1 - cosine))
        }
        return (rotate(u), rotate(v))
    }

    /// Builds one frame per galaxy from the scene, the current centres and the elapsed time.
    ///
    /// `disks` is what the solver has measured of each disk: the plane it turns in now, and
    /// how much of it is still a disk. Passing none paints the natal plane, which is right
    /// for the setup preview and for a run that has not started.
    public static func make(
        scene: SceneConfig, centers: [SIMD3<Float>], time: Float, strength: Float,
        disks: [DiskState] = []
    ) -> [DiskFrame] {
        scene.galaxies.enumerated().map { index, galaxy in
            let orientation = galaxy.orientation
            let center = index < centers.count ? centers[index] : galaxy.position
            // The plane the pattern is painted into. A merger leaves no disk to paint, so
            // the wave has to go out with it rather than hang in a plane that has stopped
            // existing — which is exactly what the natal orientation did.
            // Signed by the spin, so it matches the angular momentum the solver measures:
            // a retrograde disk turns the other way in the same plane.
            let natal = orientation.columns.2 * galaxy.spin.sign
            let live = index < disks.count ? disks[index] : DiskState.natal(galaxy)
            let axis =
                simd_length_squared(live.axis) > 1e-12 ? simd_normalize(live.axis) : natal
            let (u, v) = planeAxes(natal: orientation, normal: natal, axis: axis)
            let intact = 1 - min(max(live.disruption, 0), 1)
            // The wave is painted whichever solver is running, and that is the physical answer
            // rather than a shortcut.
            //
            // Arms made of material wind up: a disk turns differentially, so a pattern carried
            // by the stars themselves is gone within an orbit. That is true of real galaxies
            // too, which is why their arms are a density wave the stars pass through instead.
            // A self-gravitating disk can raise a wave of its own, but only if the disk holds
            // enough of the galaxy's mass to amplify one. Measured on this one at the default
            // fifth: the m = 2 amplitude falls from 0.21 to 0.07 within 100 Myr and to 0.03 by
            // 600, and nothing regrows it. Painting the wave is what keeps a spiral a spiral.
            let armed =
                galaxy.kind == .spiral
                ? min(max(galaxy.armStrength * strength, 0), 1) * intact : 0

            // A pattern speed of roughly half the material rotation at two scale lengths is
            // typical, and is what keeps the arms from either freezing or winding up.
            let reference = max(galaxy.diskScaleLength * 2, 0.5)
            let patternSpeed =
                galaxy.potential.circularSpeed(atRadius: reference) / reference * 0.5
                * galaxy.spin.sign

            return DiskFrame(
                center: SIMD4<Float>(center.x, center.y, center.z, galaxy.diskScaleLength),
                axisU: SIMD4<Float>(u.x, u.y, u.z, Float(max(galaxy.armCount, 1))),
                axisV: SIMD4<Float>(v.x, v.y, v.z, armed),
                pattern: SIMD4<Float>(
                    galaxy.armWindRate, patternSpeed * time,
                    galaxy.armIrregularity, Float(index) * 37.4 + 5.1),
                tint: SIMD4<Float>(galaxy.color.x, galaxy.color.y, galaxy.color.z, 0))
        }
    }
}
