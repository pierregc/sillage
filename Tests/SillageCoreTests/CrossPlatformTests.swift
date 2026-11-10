import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

/// What the Mac and Linux each make of the same sample, written out as SHA-256 digests so the
/// two runs can be compared line by line (#272). The digests are printed and not asserted:
/// docs/notes/linux-build.md says whether the platforms agree and where they part.
@Suite("Across platforms")
struct CrossPlatformTests {
    private static func digest(_ values: [Float]) -> String {
        var hash = PortableSHA256()
        for value in values { hash.update(littleEndian: value.bitPattern) }
        return hash.hex()
    }

    private static func digest(_ values: [SIMD3<Float>]) -> String {
        var hash = PortableSHA256()
        for value in values {
            hash.update(littleEndian: value.x.bitPattern)
            hash.update(littleEndian: value.y.bitPattern)
            hash.update(littleEndian: value.z.bitPattern)
        }
        return hash.hex()
    }

    private static func digest(_ values: [UInt32]) -> String {
        var hash = PortableSHA256()
        for value in values { hash.update(littleEndian: value) }
        return hash.hex()
    }

    private static func digest(_ values: [Double]) -> String {
        var hash = PortableSHA256()
        for value in values { hash.update(littleEndian: value.bitPattern) }
        return hash.hex()
    }

    /// A merger preset, 100 k drawn from 25 k massive, so with light tracers: the sample's
    /// positions, velocities and masses, then everything else it holds.
    @Test func aSampleHasOneDigestPerPlatform() {
        let drawn = SceneConfig.merger(particleCount: 100_000)
        let massive = SceneConfig.merger(particleCount: 25_000)
        let (system, tracers) = ParticleSystem.lightTracers(drawn: drawn, massive: massive)
        #expect(tracers > 0 && system.count > tracers)

        let rest = [
            Self.digest(system.formation), Self.digest(system.luminosity),
            Self.digest(system.birthRadius), Self.digest(system.population),
            Self.digest(system.kernelScale), Self.digest(system.galaxyIndex),
            Self.digest(system.component),
        ].joined()
        var everything = PortableSHA256()
        everything.update(data: Data(Self.digest(system.positions).utf8))
        everything.update(data: Data(Self.digest(system.velocities).utf8))
        everything.update(data: Data(Self.digest(system.mass).utf8))
        everything.update(data: Data(rest.utf8))

        print("CROSSPLATFORM sample particles \(system.count) tracers \(tracers)")
        print("CROSSPLATFORM sample positions \(Self.digest(system.positions))")
        print("CROSSPLATFORM sample velocities \(Self.digest(system.velocities))")
        print("CROSSPLATFORM sample masses \(Self.digest(system.mass))")
        print("CROSSPLATFORM sample formation \(Self.digest(system.formation))")
        print("CROSSPLATFORM sample luminosity \(Self.digest(system.luminosity))")
        print("CROSSPLATFORM sample birthRadius \(Self.digest(system.birthRadius))")
        print("CROSSPLATFORM sample population \(Self.digest(system.population))")
        print("CROSSPLATFORM sample kernelScale \(Self.digest(system.kernelScale))")
        print("CROSSPLATFORM sample galaxyIndex \(Self.digest(system.galaxyIndex))")
        print("CROSSPLATFORM sample component \(Self.digest(system.component))")
        print("CROSSPLATFORM sample all \(everything.hex())")
    }

    /// Darwin's and glibc's libm are not all correctly rounded, so a sampler's rejection test
    /// fed by one of their functions can take another branch. Each function over the same
    /// inputs, as Float and as Double, one digest apiece: the ones that differ are the ones to
    /// look at.
    @Test func eachMathFunctionHasOneDigestPerPlatform() {
        let doubles = (0..<4_001).map { Double($0) * 0.0037 - 7.4 }
        let positives = doubles.map { abs($0) + 0.05 }
        let floats = doubles.map { Float($0) }
        let positiveFloats = positives.map { Float($0) }

        func report(_ name: String, _ double: [Double], _ float: [Float]) {
            print("CROSSPLATFORM math \(name).double \(Self.digest(double))")
            print("CROSSPLATFORM math \(name).float \(Self.digest(float))")
        }
        report("exp", doubles.map { exp($0) }, floats.map { exp($0) })
        report("exp2", doubles.map { exp2($0) }, floats.map { exp2($0) })
        report("log", positives.map { log($0) }, positiveFloats.map { log($0) })
        report("log10", positives.map { log10($0) }, positiveFloats.map { log10($0) })
        report("pow", positives.map { pow($0, 1.7) }, positiveFloats.map { pow($0, 1.7) })
        report("sin", doubles.map { sin($0) }, floats.map { sin($0) })
        report("cos", doubles.map { cos($0) }, floats.map { cos($0) })
        report("tan", doubles.map { tan($0 / 5) }, floats.map { tan($0 / 5) })
        report("atan", doubles.map { atan($0) }, floats.map { atan($0) })
        report(
            "atan2", doubles.map { atan2($0, 1.3 + sin($0)) },
            floats.map { atan2($0, 1.3 + sin($0)) })
        report("asin", doubles.map { asin($0 / 8) }, floats.map { asin($0 / 8) })
        report("acos", doubles.map { acos($0 / 8) }, floats.map { acos($0 / 8) })
        report("sqrt", positives.map { sqrt($0) }, positiveFloats.map { sqrt($0) })
        report("cbrt", doubles.map { cbrt($0) }, floats.map { cbrt($0) })
        report("tanh", doubles.map { tanh($0) }, floats.map { tanh($0) })
        report("sinh", doubles.map { sinh($0) }, floats.map { sinh($0) })
        report("cosh", doubles.map { cosh($0) }, floats.map { cosh($0) })
        report("erf", doubles.map { erf($0) }, floats.map { erf($0) })
        report("tgamma", positives.map { tgamma($0) }, positiveFloats.map { tgamma($0) })
    }

    /// The vector functions of `SIMDLinux.swift` against Apple's, which this runs the same
    /// source text on both sides of: on Linux they are ours, on the Mac Apple's.
    @Test func theVectorFunctionsHaveOneDigestPerPlatform() {
        var generator = SeededGenerator(seed: 7)
        let vectors = (0..<2_000).map { _ in
            SIMD3<Float>(
                Float.random(in: -9..<9, using: &generator), Float.random(in: -9..<9, using: &generator),
                Float.random(in: -9..<9, using: &generator))
        }
        let others = vectors.reversed().map { $0 }
        func report(_ name: String, _ values: [Float]) {
            print("CROSSPLATFORM simd \(name) \(Self.digest(values))")
        }
        report("dot", zip(vectors, others).map { simd_dot($0, $1) })
        report("length", vectors.map { simd_length($0) })
        report("length_squared", vectors.map { simd_length_squared($0) })
        report("distance", zip(vectors, others).map { simd_distance($0, $1) })
        report(
            "normalize",
            vectors.flatMap { [simd_normalize($0).x, simd_normalize($0).y, simd_normalize($0).z] })
        report(
            "cross",
            zip(vectors, others).flatMap { a, b in
                let c = simd_cross(a, b)
                return [c.x, c.y, c.z]
            })
        let angle: Float = 0.7
        let turn = simd_float3x3(
            SIMD3<Float>(cos(angle), sin(angle), 0), SIMD3<Float>(-sin(angle), cos(angle), 0),
            SIMD3<Float>(0, 0, 1))
        let tilt = simd_float3x3(
            SIMD3<Float>(1, 0, 0), SIMD3<Float>(0, cos(0.4), sin(0.4)),
            SIMD3<Float>(0, -sin(0.4), cos(0.4)))
        report(
            "matrix_vector",
            vectors.flatMap { v in
                let w = (turn * tilt) * v
                return [w.x, w.y, w.z]
            })
    }
}
