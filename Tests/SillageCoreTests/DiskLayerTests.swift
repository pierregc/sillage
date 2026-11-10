import Testing

@testable import SillageCore
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

@Suite("Disk layer")
struct DiskLayerTests {
    /// A thin exponential disk in the xy plane: 4 kpc scale length, 0.2 kpc rms height.
    private func disk(count: Int = 20_000) -> [SIMD3<Float>] {
        var generator = SeededGenerator(seed: 210)
        return (0..<count).map { _ in
            let radius = -4 * log(max(generator.uniform() * generator.uniform(), 1e-6))
            let angle = 2 * Float.pi * generator.uniform()
            return SIMD3(radius * cos(angle), radius * sin(angle), 0.2 * generator.normal())
        }
    }

    /// Folds one reading of `points` into `state`, as the solver and a take's reader do.
    private func read(_ points: [SIMD3<Float>], into state: inout DiskState) {
        var layer = DiskLayer(axis: SIMD3(0, 0, 1), scaleLength: 4, edge: 16)
        for point in points { layer.add(point) }
        let fit = layer.fitted()
        let cut = state.layerHeight(spread: fit.spread)
        let held = points.filter { fit.height(of: $0).map { abs($0) < cut } ?? false }.count
        state.foldLayer(spread: fit.spread, held: Float(held) / Float(points.count))
    }

    /// A companion bends a large disk long before it tears it (#210). About one plane, as
    /// `disruption` takes it, the warped and tilted disk is several times thicker; about the
    /// plane of each ring it is the disk it was, and its arms stay.
    @Test func aBentDiskKeepsItsLayer() {
        let flat = disk()
        let tilt: Float = 0.3
        let bent = flat.map { point -> SIMD3<Float> in
            let radius = (point.x * point.x + point.y * point.y).squareRoot()
            let lift = max(radius - 8, 0) * 0.35 * sin(atan2(point.y, point.x))
            let z = point.z + lift
            return SIMD3(
                point.x, point.y * cos(tilt) - z * sin(tilt), point.y * sin(tilt) + z * cos(tilt))
        }
        func thickness(_ points: [SIMD3<Float>]) -> Float {
            let height = points.reduce(0) { $0 + $1.z * $1.z }
            return (height / points.reduce(0) { $0 + simd_length_squared($1) }).squareRoot()
        }
        #expect(thickness(bent) > 3 * thickness(flat))

        var state = DiskState(axis: SIMD3(0, 0, 1))
        read(flat, into: &state)
        read(bent, into: &state)
        #expect(state.layered > 0.9)
        #expect(state.torn == 0)
    }

    /// Material stirred into a spheroid has left its layer, and the arms go for good.
    @Test func aDiskStirredIntoASpheroidHasLeftIt() {
        let flat = disk()
        var generator = SeededGenerator(seed: 7)
        let stirred = flat.map { point -> SIMD3<Float> in
            let z = 2 * generator.uniform() - 1
            let angle = 2 * Float.pi * generator.uniform()
            let across = (1 - z * z).squareRoot()
            return simd_length(point) * SIMD3(across * cos(angle), across * sin(angle), z)
        }
        var state = DiskState(axis: SIMD3(0, 0, 1))
        read(flat, into: &state)
        #expect(state.torn == 0)
        read(stirred, into: &state)
        #expect(state.layered < 0.3)
        #expect(state.torn == 1)
        read(flat, into: &state)
        #expect(state.torn == 1)
    }

    /// In between, the arms fade with the share of the disk still in its layer.
    @Test func theArmsFadeAsTheLayerEmpties() {
        var state = DiskState(axis: SIMD3(0, 0, 1))
        state.foldLayer(spread: 0.2, held: 0.96)
        #expect(state.layerHeight(spread: 0.5) == 0.4)
        state.foldLayer(spread: 0.3, held: 0.96 * 0.8)
        #expect(state.torn == 0)
        state.foldLayer(spread: 0.4, held: 0.96 * 0.575)
        #expect(abs(state.torn - 0.5) < 0.01)
        state.foldLayer(spread: 0.4, held: 0.96 * 0.4)
        #expect(state.torn == 1)
    }
}
