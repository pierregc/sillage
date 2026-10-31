import Foundation
import SillageCore
import simd

/// Measures one disk, alone, frame by frame and in its own frame: how it settles, how much
/// structure its particles hold at each azimuthal order, how lumpy it is below the scale of an
/// arm, and whether its pattern keeps its shape as it turns. Every figure is corrected for the
/// shot noise of the sample, so a run at fifty thousand particles and one at a million read on
/// the same scale, and every length is taken in scale lengths, so two galaxies compare.
///
/// The measurements are pure functions of the particle buffers; `DiskProbeRun` drives the
/// solver and writes the files. See `docs/notes/calm-disk-probe.md` for how to read them.
public enum DiskProbe {
    /// Radial zones, in scale lengths. The inner zone stops short of the bulge, the outer one
    /// reaches the usual truncation; past it there is only the dust disk and the outskirts.
    public struct Zone: Sendable {
        public let name: String
        public let from: Float
        public let to: Float
        /// The radius the circular speed and the epicyclic frequency are read at.
        public var centre: Float { (from + to) / 2 }
    }

    public static let zones = [
        Zone(name: "inner", from: 0.5, to: 1.5),
        Zone(name: "mid", from: 1.5, to: 3),
        Zone(name: "outer", from: 3, to: 4.5),
    ]
    /// Azimuthal orders written out, m = 1 to this.
    public static let modes = 8
    /// Orders kept for the young population, which only needs the low ones.
    public static let youngModes = 4
    /// Rings of the polar map, spaced in the logarithm of the radius from the inner zone's
    /// edge to the outer's, so a wound spiral loses the same little of its amplitude to the
    /// binning at every radius; and sectors of under four degrees.
    public static let rings = 40
    public static let sectors = 96
    /// Azimuthal structure shorter than this, in scale lengths, counts as lumps rather than
    /// arms in the polar map: the order it starts at follows the ring's circumference.
    public static let lumpScale: Float = 0.5
    /// The face-on map behind the cell lumpiness: cells of 0.07 scale lengths over the whole
    /// disk, and the box everything wider than a knot is smoothed out with, 0.2 scale lengths
    /// across. A bar or a sharpened arm is 0.3 to 0.5 scale lengths across and mostly goes
    /// with the box; a clump of the sampler's is 0.1 and stays.
    public static let cells = 128
    public static let reach: Float = 4.5
    public static let blurRadius = 1
    /// Where the cell lumpiness is read, whatever the particle count: outside the bulge,
    /// inside the truncation.
    public static let lumpinessRange: ClosedRange<Float> = 0.5...4.0
    /// Bins of the radial profile the deciles and the lumpiness expectation are read from.
    public static let profileBins = 2400
    public static let profileReach: Float = 6

    static let ringRatio: Float = zones[2].to / zones[0].from
    static let ringCentres: [Float] = (0..<rings).map {
        zones[0].from * pow(ringRatio, (Float($0) + 0.5) / Float(rings))
    }
    static let ringZones: [Int] = ringCentres.map(zoneIndex)

    static func ringIndex(_ scaled: Float) -> Int {
        let along = log(scaled / zones[0].from) / log(ringRatio)
        guard along >= 0, along < 1 else { return -1 }
        return min(Int(along * Float(rings)), rings - 1)
    }

    /// What a sector of the polar map leaves of a pure mode of this order, by Parseval's
    /// bookkeeping of a box average: sin(x) / x for half the sector's phase span.
    static func binning(_ order: Int) -> Double {
        let x = Double(order) * .pi / Double(sectors)
        return x == 0 ? 1 : sin(x) / x
    }

    /// What the measurements read: the solver's buffers in place, or arrays in a test.
    public struct Particles {
        public let positions: UnsafeBufferPointer<SIMD3<Float>>
        public let velocities: UnsafeBufferPointer<SIMD3<Float>>
        public let component: UnsafeBufferPointer<UInt32>
        public var count: Int { min(positions.count, min(velocities.count, component.count)) }

        public init(
            positions: UnsafeBufferPointer<SIMD3<Float>>,
            velocities: UnsafeBufferPointer<SIMD3<Float>>,
            component: UnsafeBufferPointer<UInt32>
        ) {
            self.positions = positions
            self.velocities = velocities
            self.component = component
        }
    }

    public static func withParticles<T>(
        positions: [SIMD3<Float>], velocities: [SIMD3<Float>], component: [UInt32],
        _ body: (Particles) throws -> T
    ) rethrows -> T {
        try positions.withUnsafeBufferPointer { p in
            try velocities.withUnsafeBufferPointer { v in
                try component.withUnsafeBufferPointer { c in
                    try body(Particles(positions: p, velocities: v, component: c))
                }
            }
        }
    }

    /// The disk's own frame: its nucleus, the bulk motion of the material around it, the axis
    /// its material turns about, and in-plane axes carried over from the natal ones so the
    /// frame never rolls about the axis on its own (`DiskFrame.planeAxes`). `v` is `axis x u`,
    /// right-handed about the angular momentum, so the azimuth grows with the rotation for a
    /// retrograde disk as for a prograde one.
    public struct Frame: Sendable {
        public var centre: SIMD3<Float>
        public var velocity: SIMD3<Float>
        public var axis: SIMD3<Float>
        public var u: SIMD3<Float>
        public var v: SIMD3<Float>

        public init(
            centre: SIMD3<Float>, velocity: SIMD3<Float>, axis: SIMD3<Float>, u: SIMD3<Float>
        ) {
            self.centre = centre
            self.velocity = velocity
            self.axis = axis
            self.u = u
            self.v = simd_cross(axis, u)
        }

        /// Where a galaxy is configured to begin.
        public static func natal(_ galaxy: GalaxyConfig) -> Frame {
            let orientation = galaxy.orientation
            return Frame(
                centre: galaxy.position, velocity: galaxy.velocity,
                axis: orientation.columns.2 * galaxy.spin.sign, u: orientation.columns.0)
        }
    }

    static func isDiskMaterial(_ component: UInt32) -> Bool {
        component < ParticleComponent.halo.rawValue
    }

    /// The nucleus and the axis, from the disk material (stars, young stars and gas) near the
    /// previous centre: the centre of mass inside three scale lengths of where it was, taken
    /// again about itself until it stops moving, then inside one and a half scale lengths, so
    /// the outer disk and anything thrown off it cannot drag the frame about. The axis is the
    /// angular momentum of the material inside three scale lengths about that nucleus.
    public static func frame(of particles: Particles, galaxy: GalaxyConfig, previous: Frame) -> Frame {
        let h = max(galaxy.diskScaleLength, 1e-3)
        let count = particles.count
        var centre = previous.centre
        var velocity = previous.velocity
        // Wide passes until the centre settles, then the narrow ones; the last also sums the
        // angular momentum about the centre the wide passes found.
        let radii: [Float] = [3 * h, 3 * h, 3 * h, 3 * h, 1.5 * h, 1.5 * h]
        var momentum = SIMD3<Double>.zero
        var wide = (position: SIMD3<Double>.zero, velocity: SIMD3<Double>.zero, count: 0.0)
        var pass = 0
        while pass < radii.count {
            let radius = radii[pass]
            let last = pass == radii.count - 1
            let limit = radius * radius
            let outer = (3 * h) * (3 * h)
            var sum = SIMD3<Double>.zero
            var drift = SIMD3<Double>.zero
            var counted = 0.0
            for index in 0..<count where isDiskMaterial(particles.component[index]) {
                let offset = particles.positions[index] - centre
                let distance = simd_length_squared(offset)
                if distance < limit {
                    sum += SIMD3<Double>(particles.positions[index])
                    drift += SIMD3<Double>(particles.velocities[index])
                    counted += 1
                }
                if last, distance < outer {
                    let r = SIMD3<Double>(particles.positions[index])
                    let w = SIMD3<Double>(particles.velocities[index])
                    momentum += simd_cross(r, w)
                    wide.position += r
                    wide.velocity += w
                    wide.count += 1
                }
            }
            guard counted > 0 else { break }
            let found = SIMD3<Float>(sum / counted)
            let moved = simd_length(found - centre)
            centre = found
            velocity = SIMD3<Float>(drift / counted)
            // A wide pass that barely moved the centre has found it; skip to the narrow ones.
            if radius > 2 * h, moved < 0.01 * h, let narrow = radii.firstIndex(where: { $0 < 2 * h }) {
                pass = max(narrow, pass + 1)
            } else {
                pass += 1
            }
        }
        var frame = previous
        frame.centre = centre
        frame.velocity = velocity
        if wide.count > 0 {
            // About the nucleus and relative to its motion, from sums taken about the origin.
            let c = SIMD3<Double>(centre)
            let w = SIMD3<Double>(velocity)
            let about =
                momentum - simd_cross(c, wide.velocity) - simd_cross(wide.position, w)
                + simd_cross(c, w) * wide.count
            if simd_length(about) > 1e-9 {
                let axis = simd_normalize(SIMD3<Float>(about / simd_length(about)))
                let natal = galaxy.orientation.columns.2 * galaxy.spin.sign
                let (u, _) = DiskFrame.planeAxes(natal: galaxy.orientation, normal: natal, axis: axis)
                frame = Frame(centre: centre, velocity: velocity, axis: axis, u: simd_normalize(u))
            }
        }
        return frame
    }

    /// The stars counted on rings and sectors of the disk's plane, in two interleaved halves
    /// of the sample, with what each ring says on its own, kept from frame to frame for the
    /// pattern speed and the coherence.
    public struct PolarMap: Sendable {
        public var a: [Float]
        public var b: [Float]
        /// Mean v_phi / R of the stars in each ring, in radians per megayear.
        public var rotation: [Double]
        /// Stars in each ring, the phase of the pattern mode there as a pattern angle, and
        /// that mode's power with the shot noise taken out.
        public var count: [Double]
        public var phase: [Double]
        public var power: [Double]
        public var timeMyr: Double

        /// Mean count per sector in each ring of one half: the expectation its contrast is
        /// taken against.
        static func ringMeans(_ counts: [Float]) -> [Double] {
            (0..<DiskProbe.rings).map { ring in
                var total = 0.0
                for sector in 0..<DiskProbe.sectors {
                    total += Double(counts[ring * DiskProbe.sectors + sector])
                }
                return total / Double(DiskProbe.sectors)
            }
        }
    }

    /// One frame's readings. Lengths in kpc unless named otherwise, speeds in km/s, angular
    /// rates in radians per megayear.
    public struct Measurement: Sendable {
        public var frame = 0
        public var timeMyr = 0.0
        /// Radii holding 10 % to 90 % of the thin-disk stars, by tenths.
        public var deciles = [Double](repeating: 0, count: 9)
        public var zRms = 0.0
        /// Root mean square height over root mean square radius of the stars inside three
        /// scale lengths.
        public var thicknessRatio = 0.0
        /// Stars by zone: Fourier amplitudes of order 1 to `modes`, the shot noise taken out,
        /// as the count-weighted root mean square over the zone's rings.
        public var amplitudes: [[Double]] = Array(
            repeating: [Double](repeating: 0, count: DiskProbe.modes), count: DiskProbe.zones.count)
        public var youngAmplitudes = [Double](repeating: 0, count: DiskProbe.youngModes)
        public var counts = [Int](repeating: 0, count: DiskProbe.zones.count)
        public var youngCount = 0
        /// Knots the star formation rule lit since the last frame.
        public var formed = 0
        /// Phase of the pattern mode in the middle zone, as a pattern angle in radians,
        /// weighted over its rings by their pattern power.
        public var patternAngle = 0.0
        public var sigmaR = [Double](repeating: 0, count: DiskProbe.zones.count)
        public var sigmaPhi = 0.0
        public var sigmaZ = 0.0
        public var streaming = 0.0
        public var circular = [Double](repeating: 0, count: DiskProbe.zones.count)
        public var toomreQ = 0.0
        /// Measured mean angular rate of the middle zone, and the equilibrium one at two
        /// scale lengths.
        public var materialRate = 0.0
        public var referenceRate = 0.0
        public var patternSpeed = Double.nan
        /// Spread of the rings' own pattern rates about the zone's, over the last frame: near
        /// zero for one rigid pattern, up to the shear for structure carried by the material.
        public var patternSpread = Double.nan
        public var corotation = Double.nan
        public var coherencePattern = Double.nan
        public var coherenceMaterial = Double.nan
        public var coherenceStatic = Double.nan
        public var mapSignalToNoise = Double.nan
        /// Root mean square contrast below a fifth of a scale length on the face-on map.
        public var lumpiness = 0.0
        public var youngLumpiness = 0.0
        /// The same kind of figure from the polar map: the root mean square contrast carried
        /// by the orders shorter than `lumpScale` on each ring, over the rings that resolve it.
        public var polarLumpiness = 0.0
        /// Centroid of the outer zone's stars, as a distance from the nucleus in scale lengths.
        public var outerOffset = 0.0
        public var axisTilt = 0.0
        public var centreOffset = 0.0
        public var centre = SIMD3<Float>.zero
        public var solverCentre = SIMD3<Float>.zero
        public var stepMilliseconds = 0.0
        public var measureMilliseconds = 0.0

        public init() {}

        public var amplitude2Mid: Double { amplitudes[1][1] }
        public var amplitude1Mid: Double { amplitudes[1][0] }
        public var median: Double { deciles[4] }
        public var sigmaRatioMid: Double { circular[1] > 0 ? sigmaR[1] / circular[1] : 0 }

        public static let csvHeader: String = {
            var columns = ["frame", "time_myr", "step_ms", "measure_ms"]
            columns += (1...9).map { "r\($0 * 10)_kpc" }
            columns += ["z_rms_kpc", "thickness_ratio"]
            columns += [
                "sigma_r_kms_mid", "sigma_phi_kms_mid", "sigma_z_kms_mid", "v_phi_kms_mid",
                "v_c_kms_mid", "q_mid",
            ]
            columns += DiskProbe.zones.map { "sigma_r_vc_\($0.name)" }
            columns += DiskProbe.zones.map { "n_\($0.name)" }
            for zone in DiskProbe.zones {
                columns += (1...DiskProbe.modes).map { "a\($0)_\(zone.name)" }
            }
            columns += [
                "pattern_angle_rad", "omega_p_rad_myr", "omega_p_spread_rad_myr", "omega_2h_rad_myr",
                "omega_mat_mid_rad_myr", "corotation_h", "coh_pattern", "coh_material", "coh_static",
                "map_snr", "lump_stars", "lump_young", "lump_polar",
            ]
            columns += (1...DiskProbe.youngModes).map { "young_a\($0)_mid" }
            columns += ["n_young_mid", "formed", "outer_offset_h", "axis_tilt_deg", "centre_offset_kpc"]
            columns += ["cx", "cy", "cz", "sx", "sy", "sz"]
            return columns.joined(separator: ",")
        }()

        public var csvLine: String {
            func f(_ value: Double, _ digits: Int = 4) -> String {
                value.isNaN ? "nan" : String(format: "%.\(digits)f", value)
            }
            let kms = Physics.kilometersPerSecondPerVelocityUnit
            var fields = [
                String(frame), f(timeMyr, 2), f(stepMilliseconds, 3), f(measureMilliseconds, 2),
            ]
            fields += deciles.map { f($0) }
            fields += [f(zRms), f(thicknessRatio)]
            fields += [
                f(sigmaR[1] * kms, 2), f(sigmaPhi * kms, 2), f(sigmaZ * kms, 2), f(streaming * kms, 2),
                f(circular[1] * kms, 2), f(toomreQ, 3),
            ]
            fields += DiskProbe.zones.indices.map {
                f(circular[$0] > 0 ? sigmaR[$0] / circular[$0] : 0)
            }
            fields += counts.map(String.init)
            for zone in DiskProbe.zones.indices { fields += amplitudes[zone].map { f($0) } }
            fields += [
                f(patternAngle), f(patternSpeed, 6), f(patternSpread, 6), f(referenceRate, 6),
                f(materialRate, 6), f(corotation, 3), f(coherencePattern, 3), f(coherenceMaterial, 3),
                f(coherenceStatic, 3), f(mapSignalToNoise, 2), f(lumpiness), f(youngLumpiness),
                f(polarLumpiness),
            ]
            fields += youngAmplitudes.map { f($0) }
            fields += [String(youngCount), String(formed), f(outerOffset), f(axisTilt, 3), f(centreOffset)]
            fields += [centre.x, centre.y, centre.z, solverCentre.x, solverCentre.y, solverCentre.z]
                .map { f(Double($0)) }
            return fields.joined(separator: ",")
        }
    }

    /// Everything one frame tells, from a single pass over the particles and the maps it
    /// fills. `patternMode` is the order whose phase the pattern speed follows.
    ///
    /// `solverCentre` is where the solver believes the galaxy is, the centre the camera and the
    /// cooling follow; it is the centre of mass of every visible particle, and the gap between
    /// it and the nucleus is one of the things this exists to show.
    public static func measure(
        _ particles: Particles, frame: Frame, galaxy: GalaxyConfig, equilibrium: DiskEquilibrium,
        solverCentre: SIMD3<Float>, timeMyr: Double, patternMode: Int = 2
    ) -> (Measurement, PolarMap) {
        let h = max(galaxy.diskScaleLength, 1e-3)
        let count = particles.count
        let zoneCount = zones.count
        let star = ParticleComponent.star.rawValue
        let hii = ParticleComponent.hiiRegion.rawValue
        let dust = ParticleComponent.dust.rawValue

        // Velocity moments of the stars by zone: v_R, v_R^2, v_phi, v_phi^2, v_z, v_z^2, v_phi/R.
        var moments = [Double](repeating: 0, count: zoneCount * 7)
        var zoneCounts = [Double](repeating: 0, count: zoneCount)
        var heightSquared = 0.0
        var radiusSquared = 0.0
        var outerSum = SIMD2<Double>.zero
        var profile = [Int32](repeating: 0, count: profileBins)
        var youngProfile = [Int32](repeating: 0, count: profileBins)
        var polarA = [Float](repeating: 0, count: rings * sectors)
        var polarB = [Float](repeating: 0, count: rings * sectors)
        var youngPolar = [Float](repeating: 0, count: rings * sectors)
        var ringRate = [Double](repeating: 0, count: rings)
        var ringCount = [Double](repeating: 0, count: rings)
        var map = [Int32](repeating: 0, count: cells * cells)
        var youngMap = [Int32](repeating: 0, count: cells * cells)

        let profileScale = Float(profileBins) / (profileReach * h)
        let cellScale = Float(cells) / (2 * reach * h)
        let sectorScale = Float(sectors) / (2 * .pi)
        var parity = false

        for index in 0..<count {
            let component = particles.component[index]
            guard component == star || component == hii || component == dust else { continue }
            let young = component != star
            let offset = particles.positions[index] - frame.centre
            let x = simd_dot(offset, frame.u)
            let y = simd_dot(offset, frame.v)
            let z = simd_dot(offset, frame.axis)
            let radius = (x * x + y * y).squareRoot()
            guard radius > 1e-4 else { continue }
            let scaled = radius / h

            let bin = min(Int(radius * profileScale), profileBins - 1)
            if young { youngProfile[bin] += 1 } else { profile[bin] += 1 }
            let cx = Int((x + reach * h) * cellScale)
            let cy = Int((y + reach * h) * cellScale)
            if cx >= 0, cx < cells, cy >= 0, cy < cells {
                if young { youngMap[cy * cells + cx] += 1 } else { map[cy * cells + cx] += 1 }
            }
            let ring = ringIndex(scaled)
            guard ring >= 0 else { continue }
            let angle = atan2(y, x)
            let sector = min(Int((angle + .pi) * sectorScale), sectors - 1)
            let cell = ring * sectors + sector
            if young {
                youngPolar[cell] += 1
                continue
            }
            // Alternate halves, so a lag's two maps never share a particle.
            if parity { polarB[cell] += 1 } else { polarA[cell] += 1 }
            parity.toggle()

            let zone = ringZones[ring]
            zoneCounts[zone] += 1
            let motion = particles.velocities[index] - frame.velocity
            let wu = simd_dot(motion, frame.u)
            let wv = simd_dot(motion, frame.v)
            let vr = Double((x * wu + y * wv) / radius)
            let vphi = Double((x * wv - y * wu) / radius)
            let vz = Double(simd_dot(motion, frame.axis))
            let m = zone * 7
            moments[m] += vr
            moments[m + 1] += vr * vr
            moments[m + 2] += vphi
            moments[m + 3] += vphi * vphi
            moments[m + 4] += vz
            moments[m + 5] += vz * vz
            moments[m + 6] += vphi / Double(radius)
            if zone < 2 {
                heightSquared += Double(z * z)
                radiusSquared += Double(radius * radius)
            }
            if zone == 2 { outerSum += SIMD2<Double>(Double(x), Double(y)) }
            ringRate[ring] += vphi / Double(radius)
            ringCount[ring] += 1
        }

        var result = Measurement()
        result.timeMyr = timeMyr
        result.centre = frame.centre
        result.solverCentre = solverCentre
        result.centreOffset = Double(simd_length(frame.centre - solverCentre))
        let natalAxis = galaxy.orientation.columns.2 * galaxy.spin.sign
        result.axisTilt =
            Double(acos(min(max(simd_dot(frame.axis, natalAxis), -1), 1))) * 180 / .pi

        // Deciles of the thin-disk stars, read off the profile.
        let total = profile.reduce(0) { $0 + Int($1) }
        if total > 0 {
            var cumulative = 0
            var decile = 1
            for bin in 0..<profileBins where decile <= 9 {
                let before = cumulative
                cumulative += Int(profile[bin])
                while decile <= 9, Double(cumulative) >= Double(total) * Double(decile) / 10 {
                    let wanted = Double(total) * Double(decile) / 10
                    let inside = Int(profile[bin]) > 0 ? (wanted - Double(before)) / Double(profile[bin]) : 0
                    result.deciles[decile - 1] = (Double(bin) + inside) / Double(profileScale)
                    decile += 1
                }
            }
        }
        let innerCount = zoneCounts[0] + zoneCounts[1]
        if innerCount > 0 {
            result.zRms = (heightSquared / innerCount).squareRoot()
            if radiusSquared > 0 { result.thicknessRatio = (heightSquared / radiusSquared).squareRoot() }
        }

        // Each ring's azimuthal spectrum, the noise floor taken out and the binning undone.
        let spectrum = ringSpectra(polarA, polarB)
        var ringPhase = [Double](repeating: 0, count: rings)
        var ringPower = [Double](repeating: 0, count: rings)
        var zoneWeight = [Double](repeating: 0, count: zoneCount)
        var zonePower = [Double](repeating: 0, count: zoneCount * modes)
        var lumpPower = 0.0
        var lumpWeight = 0.0
        var anglePhasor = (re: 0.0, im: 0.0)
        for ring in 0..<rings {
            let n = spectrum.count[ring]
            guard n > 0 else { continue }
            let zone = ringZones[ring]
            zoneWeight[zone] += n
            for order in 0..<modes {
                zonePower[zone * modes + order] += n * spectrum.power[ring][order]
            }
            // Orders above the ring's circumference over the lump scale; the outer rings have
            // nothing that fine to resolve and weigh nothing.
            let from = Int((2 * Float.pi * ringCentres[ring] / lumpScale).rounded(.up))
            if from <= spectrum.power[ring].count {
                var lumps = 0.0
                for order in max(from, 1)...spectrum.power[ring].count {
                    lumps += spectrum.power[ring][order - 1]
                }
                lumpPower += n * lumps
                lumpWeight += n
            }
            let mode = min(max(patternMode, 1), sectors / 2)
            ringPhase[ring] = spectrum.phase[ring][mode - 1] / Double(mode)
            ringPower[ring] = n * max(spectrum.power[ring][mode - 1], 0)
            if zone == 1 {
                // A pattern angle repeats every 1 / mode turn; the weighted mean is taken
                // as a phasor at the mode's own period so that wrapping does not bias it.
                anglePhasor.re += ringPower[ring] * cos(Double(mode) * ringPhase[ring])
                anglePhasor.im += ringPower[ring] * sin(Double(mode) * ringPhase[ring])
            }
        }
        for zone in 0..<zoneCount where zoneWeight[zone] > 0 {
            result.counts[zone] = Int(zoneWeight[zone])
            for order in 0..<modes {
                let power = zonePower[zone * modes + order] / zoneWeight[zone]
                result.amplitudes[zone][order] = max(power, 0).squareRoot()
            }
        }
        if lumpWeight > 0 { result.polarLumpiness = max(2 * lumpPower / lumpWeight, 0).squareRoot() }
        if anglePhasor.re != 0 || anglePhasor.im != 0 {
            result.patternAngle =
                atan2(anglePhasor.im, anglePhasor.re) / Double(min(max(patternMode, 1), sectors / 2))
        }

        let youngSpectrum = ringSpectra(youngPolar, [Float](repeating: 0, count: rings * sectors))
        var youngWeight = 0.0
        var youngPower = [Double](repeating: 0, count: youngModes)
        for ring in 0..<rings where ringZones[ring] == 1 && youngSpectrum.count[ring] > 0 {
            let n = youngSpectrum.count[ring]
            youngWeight += n
            for order in 0..<youngModes { youngPower[order] += n * youngSpectrum.power[ring][order] }
        }
        if youngWeight > 0 {
            result.youngCount = Int(youngWeight)
            for order in 0..<youngModes {
                result.youngAmplitudes[order] = max(youngPower[order] / youngWeight, 0).squareRoot()
            }
        }

        for zone in 0..<zoneCount {
            let reference = zones[zone].centre * h
            result.circular[zone] = Double(equilibrium.circularSpeed(atRadius: reference))
            let n = zoneCounts[zone]
            guard n > 1 else { continue }
            let m = zone * 7
            let meanR = moments[m] / n
            result.sigmaR[zone] = max(moments[m + 1] / n - meanR * meanR, 0).squareRoot()
            if zone == 1 {
                let meanPhi = moments[m + 2] / n
                let meanZ = moments[m + 4] / n
                result.sigmaPhi = max(moments[m + 3] / n - meanPhi * meanPhi, 0).squareRoot()
                result.sigmaZ = max(moments[m + 5] / n - meanZ * meanZ, 0).squareRoot()
                result.streaming = meanPhi
                result.materialRate = moments[m + 6] / n / Physics.megayearsPerTimeUnit
                result.toomreQ = Double(
                    equilibrium.toomreQ(atRadius: reference, radialDispersion: Float(result.sigmaR[zone])))
            }
        }
        if zoneCounts[2] > 0 {
            result.outerOffset = simd_length(outerSum / zoneCounts[2]) / Double(h)
        }
        let twoScale = 2 * h
        result.referenceRate =
            Double(equilibrium.circularSpeed(atRadius: twoScale) / twoScale)
            / Physics.megayearsPerTimeUnit

        result.lumpiness = lumpiness(map: map, profile: profile)
        result.youngLumpiness = lumpiness(map: youngMap, profile: youngProfile)

        var rotation = [Double](repeating: 0, count: rings)
        for ring in 0..<rings where ringCount[ring] > 0 {
            rotation[ring] = ringRate[ring] / ringCount[ring] / Physics.megayearsPerTimeUnit
        }
        let polar = PolarMap(
            a: polarA, b: polarB, rotation: rotation, count: spectrum.count, phase: ringPhase,
            power: ringPower, timeMyr: timeMyr)
        return (result, polar)
    }

    static func zoneIndex(_ scaled: Float) -> Int {
        for (index, zone) in zones.enumerated() where scaled >= zone.from && scaled < zone.to {
            return index
        }
        return -1
    }

    static let sectorPhasors: [(cos: Double, sin: Double)] = (0..<sectors).map {
        let angle = (Double($0) + 0.5) / Double(sectors) * 2 * .pi
        return (cos(angle), sin(angle))
    }

    /// The azimuthal spectrum of every ring of the two halves taken together: for each order
    /// from one to half the sector count, the power |C_m|^2 of the normalised sum with the
    /// expectation of a random sample, 1 / N, taken out (so it may be negative) and the sector
    /// binning undone, and the phase of the mode.
    static func ringSpectra(_ a: [Float], _ b: [Float]) -> (
        count: [Double], power: [[Double]], phase: [[Double]]
    ) {
        let orders = sectors / 2
        var counts = [Double](repeating: 0, count: rings)
        var power = [[Double]](repeating: [Double](repeating: 0, count: orders), count: rings)
        var phase = [[Double]](repeating: [Double](repeating: 0, count: orders), count: rings)
        var cosines = [Double](repeating: 0, count: sectors)
        var sines = [Double](repeating: 0, count: sectors)
        for ring in 0..<rings {
            var n = 0.0
            for sector in 0..<sectors {
                n += Double(a[ring * sectors + sector] + b[ring * sectors + sector])
            }
            counts[ring] = n
            guard n > 0 else { continue }
            // Orders by angle addition from each sector's own phasor.
            for sector in 0..<sectors {
                cosines[sector] = 1
                sines[sector] = 0
            }
            for order in 0..<orders {
                var re = 0.0
                var im = 0.0
                for sector in 0..<sectors {
                    let phasor = sectorPhasors[sector]
                    let next = cosines[sector] * phasor.cos - sines[sector] * phasor.sin
                    sines[sector] = sines[sector] * phasor.cos + cosines[sector] * phasor.sin
                    cosines[sector] = next
                    let weight = Double(a[ring * sectors + sector] + b[ring * sectors + sector])
                    re += weight * cosines[sector]
                    im += weight * sines[sector]
                }
                // Signed: the floor is taken out before the binning is undone, and the sum
                // over rings or orders is clipped at zero only once, or every noisy term
                // clipped on its own would pile up a positive bias.
                let attenuation = binning(order + 1)
                power[ring][order] = ((re * re + im * im) / (n * n) - 1 / n) / (attenuation * attenuation)
                phase[ring][order] = atan2(im, re)
            }
        }
        return (counts, power, phase)
    }

    /// Small-scale power of the face-on map once its azimuthal mean is taken out and the arms
    /// smoothed away: the root mean square contrast left below a fifth of a scale length,
    /// weighted by the stars expected in each cell, with the shot noise of the cells taken
    /// out. Read over the same annulus whatever the count, so the footprint does not grow
    /// with it.
    static func lumpiness(map: [Int32], profile: [Int32]) -> Double {
        let n = cells
        let cell = 2 * reach / Float(n)
        let area = Double(cell * cell)
        let binWidth = profileReach / Float(profileBins)
        var expected = [Double](repeating: 0, count: n * n)
        var contrast = [Double](repeating: 0, count: n * n)
        var valid = [Bool](repeating: false, count: n * n)
        var density = [Double](repeating: 0, count: profileBins)
        for bin in 0..<profileBins {
            let inner = Double(Float(bin) * binWidth)
            let outer = Double(Float(bin + 1) * binWidth)
            density[bin] = Double(profile[bin]) / (.pi * (outer * outer - inner * inner))
        }
        // The profile is read over twice a cell's width, or its own shot noise, which is a
        // function of radius far narrower than a cell, would pass the filter below as lumps.
        let halfWindow = Int((2 * cell / binWidth).rounded() / 2)
        var smoothDensity = density
        var running = 0.0
        for bin in 0..<min(halfWindow, profileBins) { running += density[bin] }
        for bin in 0..<profileBins {
            if bin + halfWindow < profileBins { running += density[bin + halfWindow] }
            if bin - halfWindow - 1 >= 0 { running -= density[bin - halfWindow - 1] }
            let low = max(bin - halfWindow, 0)
            let high = min(bin + halfWindow, profileBins - 1)
            smoothDensity[bin] = running / Double(high - low + 1)
        }
        for iy in 0..<n {
            for ix in 0..<n {
                let x = (Float(ix) + 0.5) * cell - reach
                let y = (Float(iy) + 0.5) * cell - reach
                let radius = (x * x + y * y).squareRoot()
                guard lumpinessRange.contains(radius) else { continue }
                let bin = min(Int(radius / binWidth), profileBins - 1)
                let e = smoothDensity[bin] * area
                guard e > 0.02 else { continue }
                let index = iy * n + ix
                expected[index] = e
                contrast[index] = Double(map[index]) / e - 1
                valid[index] = true
            }
        }
        let k = blurRadius
        var weighted = 0.0
        var weight = 0.0
        for iy in 0..<n {
            for ix in 0..<n where valid[iy * n + ix] {
                var sum = 0.0
                var inverse = 0.0
                var boxCount = 0.0
                for jy in max(iy - k, 0)...min(iy + k, n - 1) {
                    for jx in max(ix - k, 0)...min(ix + k, n - 1) where valid[jy * n + jx] {
                        sum += contrast[jy * n + jx]
                        inverse += 1 / expected[jy * n + jx]
                        boxCount += 1
                    }
                }
                let index = iy * n + ix
                let residual = contrast[index] - sum / boxCount
                // A Poisson cell's contrast has variance 1 / E, and the box mean it is
                // compared against carries the cells' own noise, this one's included.
                let noise = (1 / expected[index]) * (1 - 2 / boxCount) + inverse / (boxCount * boxCount)
                weighted += expected[index] * (residual * residual - noise)
                weight += expected[index]
            }
        }
        guard weight > 0 else { return 0 }
        return max(weighted / weight, 0).squareRoot()
    }

    /// The readings that need the frames before: the pattern speed, from how each ring's
    /// pattern phase moved since the last frame, weighted by the ring's pattern power and
    /// fitted over the last `lagMyr`; and the coherence, one half of the map against the
    /// other half a lag earlier, in the frame turning at that pattern speed, in the one
    /// turning with the material ring by ring, and in none.
    public struct Tracker {
        public let lagMyr: Double
        public let patternMode: Int
        private let equilibrium: DiskEquilibrium?
        private var history: [(timeMyr: Double, angle: Double, map: PolarMap, valid: Bool)] = []
        private var unwrapped = 0.0

        /// With an equilibrium, the corotation radius is read off its rotation curve.
        public init(lagMyr: Double = 50, patternMode: Int = 2, equilibrium: DiskEquilibrium? = nil) {
            self.lagMyr = lagMyr
            self.patternMode = max(patternMode, 1)
            self.equilibrium = equilibrium
        }

        public mutating func fold(_ reading: inout Measurement, map: PolarMap) {
            var valid = true
            if let last = history.last, reading.timeMyr > last.timeMyr {
                let elapsed = reading.timeMyr - last.timeMyr
                // Each ring of the middle zone says how far its pattern turned; the mode's
                // own period is the ambiguity of the reading, so each step is taken closest
                // to zero, which holds for any cadence under a quarter of a pattern turn.
                let period = .pi / Double(patternMode)
                var rate = 0.0
                var square = 0.0
                var weight = 0.0
                for ring in 0..<DiskProbe.rings where DiskProbe.ringZones[ring] == 1 {
                    let w = min(map.power[ring], last.map.power[ring])
                    guard w > 0 else { continue }
                    var step = map.phase[ring] - last.map.phase[ring]
                    while step > period / 2 { step -= period }
                    while step <= -period / 2 { step += period }
                    let own = step / elapsed
                    rate += w * own
                    square += w * own * own
                    weight += w
                }
                if weight > 0 {
                    rate /= weight
                    unwrapped += rate * elapsed
                    reading.patternSpread = max(square / weight - rate * rate, 0).squareRoot()
                }
                valid = weight > 0
            }
            history.append((reading.timeMyr, unwrapped, map, valid))
            let oldest = reading.timeMyr - lagMyr
            // Keep one entry at or before the lag, so the earlier map is a whole lag back.
            while history.count > 2, history[1].timeMyr <= oldest { history.removeFirst() }

            // No speed from a window in which the pattern was ever lost in the noise.
            if history.count >= 3, reading.timeMyr - history[0].timeMyr >= lagMyr * 0.5,
                history.dropFirst().allSatisfy(\.valid)
            {
                let times = history.map(\.timeMyr)
                let angles = history.map(\.angle)
                let meanT = times.reduce(0, +) / Double(times.count)
                let meanA = angles.reduce(0, +) / Double(angles.count)
                var covariance = 0.0
                var variance = 0.0
                for (t, a) in zip(times, angles) {
                    covariance += (t - meanT) * (a - meanA)
                    variance += (t - meanT) * (t - meanT)
                }
                if variance > 0 { reading.patternSpeed = covariance / variance }
                if let equilibrium {
                    reading.corotation = DiskProbe.corotation(
                        patternSpeed: reading.patternSpeed, equilibrium: equilibrium)
                }
            }
            guard let earlier = history.first, reading.timeMyr - earlier.timeMyr >= lagMyr * 0.999
            else { return }
            let elapsed = reading.timeMyr - earlier.timeMyr
            let pattern = reading.patternSpeed.isNaN ? 0 : reading.patternSpeed
            let readings = DiskProbe.coherence(
                earlier: earlier.map, later: map,
                shifts: [
                    [Double](repeating: pattern * elapsed, count: DiskProbe.rings),
                    earlier.map.rotation.map { $0 * elapsed },
                    [Double](repeating: 0, count: DiskProbe.rings),
                ])
            reading.coherencePattern = readings.correlations[0]
            reading.coherenceMaterial = readings.correlations[1]
            reading.coherenceStatic = readings.correlations[2]
            reading.mapSignalToNoise = readings.signalToNoise
        }
    }

    /// The radius where the material turns at the pattern's own rate, in scale lengths, read
    /// off the equilibrium rotation curve; nan when the pattern turns faster than any ring
    /// inside a tenth of a scale length or slower than the one at twelve.
    static func corotation(patternSpeed: Double, equilibrium: DiskEquilibrium) -> Double {
        guard patternSpeed.isFinite, patternSpeed > 0 else { return .nan }
        let h = max(equilibrium.config.diskScaleLength, 1e-3)
        func rate(_ scaled: Double) -> Double {
            let radius = Float(scaled) * h
            return Double(equilibrium.circularSpeed(atRadius: radius) / radius)
                / Physics.megayearsPerTimeUnit
        }
        var low = 0.1
        var high = 12.0
        guard rate(low) > patternSpeed, rate(high) < patternSpeed else { return .nan }
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if rate(middle) > patternSpeed { low = middle } else { high = middle }
        }
        return (low + high) / 2
    }

    /// Weighted correlation of one half of the earlier map with the other half of the later,
    /// the later turned back by `shifts` (radians, one per ring), each ring weighted by the
    /// stars it holds. Halves, so no particle meets its own earlier position, which would read
    /// Poisson noise riding with the stars as carried clumps. The variances are corrected for
    /// shot noise, which would otherwise pull a perfectly coherent pattern below one at low
    /// counts; the shift is a whole number of sectors so no interpolation smooths the noise
    /// unevenly.
    static func coherence(earlier: PolarMap, later: PolarMap, shifts: [[Double]]) -> (
        correlations: [Double], signalToNoise: Double
    ) {
        let n = sectors
        let meansA = PolarMap.ringMeans(earlier.a)
        let meansB = PolarMap.ringMeans(later.b)
        func contrast(_ counts: [Float], _ means: [Double], _ ring: Int, _ sector: Int) -> Double {
            let mean = means[ring]
            return mean > 0 ? Double(counts[ring * n + sector]) / mean - 1 : 0
        }
        var results: [Double] = []
        var snr = Double.nan
        for shift in shifts {
            var cov = 0.0
            var varA = 0.0
            var varB = 0.0
            var noiseA = 0.0
            var noiseB = 0.0
            var weight = 0.0
            for ring in 0..<rings where meansA[ring] >= 1 && meansB[ring] >= 1 {
                let w = meansA[ring] + meansB[ring]
                let turned = Int((shift[ring] / (2 * .pi) * Double(n)).rounded())
                for sector in 0..<n {
                    let a = contrast(earlier.a, meansA, ring, sector)
                    let b = contrast(later.b, meansB, ring, ((sector + turned) % n + n) % n)
                    cov += w * a * b
                    varA += w * a * a
                    varB += w * b * b
                }
                noiseA += w * Double(n) / meansA[ring]
                noiseB += w * Double(n) / meansB[ring]
                weight += w * Double(n)
            }
            guard weight > 0 else {
                results.append(.nan)
                continue
            }
            let signalA = (varA - noiseA) / weight
            let signalB = (varB - noiseB) / weight
            if snr.isNaN { snr = (max(signalA, 0) / max(noiseA / weight, 1e-12)).squareRoot() }
            // A map that is all noise correlates with nothing: with the variances floored at
            // their own noise, its covariance is divided by that noise and reads near zero,
            // where a smaller floor would turn the same covariance into a random coherence of
            // either sign. Structure weaker than the noise reads low rather than wrong.
            let denominator = (max(signalA, noiseA / weight) * max(signalB, noiseB / weight)).squareRoot()
            results.append(min(max(cov / weight / denominator, -1), 1))
        }
        return (results, snr)
    }
}
