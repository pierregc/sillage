import Foundation
import SillageCore
#if canImport(simd)
    import simd
#endif

extension DiskProbe {
    /// Bound knots (#218): clumps of disk material that hold together. Each frame, the density
    /// peaks that stand out of their ring are taken as candidates with what lies within the knot
    /// radius of them; a lag later a candidate is a knot if half of those members are still
    /// within that radius of their own centre. An arm crest or a clump the shear takes apart
    /// spreads over kiloparsecs in that time; a bound knot does not.
    public struct KnotTracker {
        /// Cells of the peak map, in scale lengths, over the probe's reach.
        public static let cell: Float = 0.05
        /// A candidate peak holds this many times what its ring holds on average per cell.
        public static let contrast: Float = 3
        public static let candidates = 96
        public static let minimumMembers = 24
        /// Share of a candidate's members still together a lag later for it to be a knot.
        public static let kept: Float = 0.5
        /// The knot radius, in kpc, never under 2.5 softening lengths.
        public static let radiusKpc: Float = 0.5
        /// Peaks are looked for outside the nucleus, as the lumpiness is read.
        public static let innerEdge: Float = 0.5
        /// The share of the disk material in knots that reads as knotted, and the explore clip
        /// it is judged over, in Myr.
        public static let visibleShare = 0.01
        public static let clipMyr = 800.0

        public let lagMyr: Double
        public let radius: Float
        private var history: [(timeMyr: Double, groups: [[Int32]])] = []

        public init(lagMyr: Double = 50, softening: Float) {
            self.lagMyr = lagMyr
            radius = max(Self.radiusKpc, 2.5 * softening)
        }

        /// The knots among the candidates taken a lag ago, and the share of the disk material
        /// they hold now; then this frame's candidates are kept for a lag later.
        public mutating func fold(
            _ particles: Particles, frame: Frame, galaxy: GalaxyConfig, timeMyr: Double
        ) -> (count: Int, share: Double) {
            var total = 0
            for index in 0..<particles.count where isDiskMaterial(particles.component[index]) {
                total += 1
            }
            var found = (count: 0, share: 0.0)
            if total > 0, let earlier = history.last(where: { $0.timeMyr <= timeMyr - lagMyr * 0.999 }) {
                var held = 0
                for group in earlier.groups {
                    let together = Self.together(group, positions: particles.positions, radius: radius)
                    if Float(together) >= Self.kept * Float(group.count) {
                        found.count += 1
                        held += together
                    }
                }
                found.share = Double(held) / Double(total)
            }
            // One entry at or before the lag stays, so the next frame finds a whole lag back.
            while history.count > 1, history[1].timeMyr <= timeMyr - lagMyr * 0.999 {
                history.removeFirst()
            }
            history.append(
                (timeMyr, Self.candidates(particles, frame: frame, galaxy: galaxy, radius: radius)))
            return found
        }

        /// How many of a group's members are within `radius` of their centre, the centre found
        /// by closing in from the centroid of them all.
        static func together(
            _ group: [Int32], positions: UnsafeBufferPointer<SIMD3<Float>>, radius: Float
        ) -> Int {
            guard !group.isEmpty else { return 0 }
            var centre = SIMD3<Double>.zero
            for member in group { centre += SIMD3<Double>(positions[Int(member)]) }
            centre /= Double(group.count)
            for reach in [8 * radius, 4 * radius, 2 * radius, radius, radius] {
                let limit = Double(reach * reach)
                var sum = SIMD3<Double>.zero
                var inside = 0.0
                for member in group {
                    let p = SIMD3<Double>(positions[Int(member)])
                    if simd_length_squared(p - centre) < limit {
                        sum += p
                        inside += 1
                    }
                }
                guard inside > 0 else { return 0 }
                centre = sum / inside
            }
            let limit = Double(radius * radius)
            return group.reduce(0) {
                $0 + (simd_length_squared(SIMD3<Double>(positions[Int($1)]) - centre) < limit ? 1 : 0)
            }
        }

        /// Peaks of the disk material on a face-on map that stand `contrast` times over their
        /// ring's mean, the strongest first, each with the members within `radius` of its
        /// centre; a peak within two radii of a stronger one is the same knot.
        static func candidates(
            _ particles: Particles, frame: Frame, galaxy: GalaxyConfig, radius: Float
        ) -> [[Int32]] {
            let h = max(galaxy.diskScaleLength, 1e-3)
            let size = cell * h
            let n = Int((2 * reach / cell).rounded())
            let half = Float(n) / 2 * size
            var plane: [SIMD3<Float>] = []
            var owners: [Int32] = []
            var cellOf: [Int32] = []
            var counts = [Int32](repeating: 0, count: n * n)
            let rings = Int((reach / cell).rounded()) + 1
            var ringCounts = [Double](repeating: 0, count: rings)
            for index in 0..<particles.count where isDiskMaterial(particles.component[index]) {
                let offset = particles.positions[index] - frame.centre
                let x = simd_dot(offset, frame.u)
                let y = simd_dot(offset, frame.v)
                let r = (x * x + y * y).squareRoot()
                guard r >= innerEdge * h, r < reach * h, x.isFinite, y.isFinite else { continue }
                let cx = Int((x + half) / size)
                let cy = Int((y + half) / size)
                guard cx >= 0, cx < n, cy >= 0, cy < n else { continue }
                plane.append(SIMD3<Float>(x, y, simd_dot(offset, frame.axis)))
                owners.append(Int32(index))
                cellOf.append(Int32(cy * n + cx))
                counts[cy * n + cx] += 1
                ringCounts[min(Int(r / size), rings - 1)] += 1
            }
            guard !plane.isEmpty else { return [] }
            // Members by cell, for the neighbourhood of a peak.
            var starts = [Int32](repeating: 0, count: n * n + 1)
            for c in 0..<(n * n) { starts[c + 1] = starts[c] + counts[c] }
            var filled = starts
            var sorted = [Int32](repeating: 0, count: plane.count)
            for (slot, c) in cellOf.enumerated() {
                sorted[Int(filled[Int(c)])] = Int32(slot)
                filled[Int(c)] += 1
            }
            func expected(_ cx: Int, _ cy: Int) -> Double {
                let x = (Float(cx) + 0.5) * size - half
                let y = (Float(cy) + 0.5) * size - half
                let ring = min(Int((x * x + y * y).squareRoot() / size), rings - 1)
                let inner = Double(ring) * Double(size)
                let area = Double.pi * ((inner + Double(size)) * (inner + Double(size)) - inner * inner)
                return ringCounts[ring] / area * Double(size * size)
            }
            var peaks: [(cell: Int, excess: Double)] = []
            for cy in 1..<(n - 1) {
                for cx in 1..<(n - 1) {
                    let c = cy * n + cx
                    let count = counts[c]
                    guard count >= Int32(minimumMembers / 2) else { continue }
                    let e = expected(cx, cy)
                    guard Double(count) >= Double(contrast) * e else { continue }
                    var highest = true
                    for dy in -1...1 {
                        for dx in -1...1 where dx != 0 || dy != 0 {
                            let other = counts[(cy + dy) * n + cx + dx]
                            // Ties go to the earlier cell, so a flat top yields one peak.
                            if other > count || (other == count && (dy < 0 || (dy == 0 && dx < 0))) {
                                highest = false
                            }
                        }
                    }
                    if highest { peaks.append((c, Double(count) - e)) }
                }
            }
            peaks.sort { $0.excess > $1.excess }
            let span = Int((radius / size).rounded(.up)) + 1
            var centres: [SIMD3<Float>] = []
            var groups: [[Int32]] = []
            for peak in peaks where groups.count < candidates {
                var centre = SIMD3<Float>(
                    (Float(peak.cell % n) + 0.5) * size - half, (Float(peak.cell / n) + 0.5) * size - half,
                    0)
                var members: [Int32] = []
                for pass in 0..<3 {
                    var sum = SIMD3<Float>.zero
                    members.removeAll(keepingCapacity: true)
                    let cx = min(max(Int((centre.x + half) / size), 0), n - 1)
                    let cy = min(max(Int((centre.y + half) / size), 0), n - 1)
                    for jy in max(cy - span, 0)...min(cy + span, n - 1) {
                        for jx in max(cx - span, 0)...min(cx + span, n - 1) {
                            let c = jy * n + jx
                            for k in Int(starts[c])..<Int(starts[c + 1]) {
                                let slot = Int(sorted[k])
                                var offset = plane[slot] - centre
                                // The height is unknown until the first pass has a centroid.
                                if pass == 0 { offset.z = 0 }
                                if simd_length_squared(offset) < radius * radius {
                                    sum += plane[slot]
                                    members.append(Int32(slot))
                                }
                            }
                        }
                    }
                    guard !members.isEmpty else { break }
                    centre = sum / Float(members.count)
                }
                guard members.count >= minimumMembers,
                    !centres.contains(where: { simd_length_squared($0 - centre) < 4 * radius * radius })
                else { continue }
                centres.append(centre)
                groups.append(members.map { owners[Int($0)] })
            }
            return groups
        }
    }
}
