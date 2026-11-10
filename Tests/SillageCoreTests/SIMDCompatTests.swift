import Foundation
import Testing

@testable import SillageCore

#if canImport(simd)
    import simd
#endif

/// What `SIMDLinux.swift` stands in for on Linux, checked on both platforms against the same
/// numbers.
@Suite("Vector functions")
struct SIMDCompatTests {
    @Test func lengthsDotsAndCrossesAreTheTextbookOnes() {
        let a = SIMD3<Float>(1, 2, 2)
        let b = SIMD3<Float>(-2, 0, 1)
        #expect(simd_length(a) == 3)
        #expect(simd_length_squared(a) == 9)
        #expect(simd_dot(a, b) == 0)
        #expect(simd_cross(a, b) == SIMD3<Float>(2, -5, 4))
        #expect(simd_distance(a, b) == Float(14).squareRoot())
        let unit = simd_normalize(a)
        #expect(abs(simd_length(unit) - 1) < 1e-6)
        #expect(simd_min(a, b) == SIMD3<Float>(-2, 0, 1))
        #expect(simd_max(a, b) == SIMD3<Float>(1, 2, 2))
    }

    @Test func aRotationKeepsLengthsAndItsInverseUndoesIt() {
        let angle = 0.7
        let turn = simd_double3x3(
            SIMD3<Double>(cos(angle), sin(angle), 0), SIMD3<Double>(-sin(angle), cos(angle), 0),
            SIMD3<Double>(0, 0, 1))
        let vector = SIMD3<Double>(1, -2, 3)
        #expect(abs(simd_length(turn * vector) - simd_length(vector)) < 1e-12)
        #expect(abs(turn.determinant - 1) < 1e-12)
        let back = turn.inverse * (turn * vector)
        #expect(simd_distance(back, vector) < 1e-12)
        let product = turn * turn.inverse
        #expect(simd_distance(product.columns.0, SIMD3<Double>(1, 0, 0)) < 1e-12)
        #expect(simd_distance(product.columns.1, SIMD3<Double>(0, 1, 0)) < 1e-12)
        #expect(simd_distance(product.columns.2, SIMD3<Double>(0, 0, 1)) < 1e-12)
    }

    @Test func aMatrixBuiltFromRowsReadsBackByColumns() {
        let m = simd_double3x3(rows: [
            SIMD3<Double>(1, 2, 3), SIMD3<Double>(4, 5, 6), SIMD3<Double>(7, 8, 10),
        ])
        #expect(m.columns.0 == SIMD3<Double>(1, 4, 7))
        #expect(m[1][2] == 8)
        #expect(abs(m.determinant - -3) < 1e-12)
        let sum = m + simd_double3x3(diagonal: SIMD3<Double>(1, 1, 1)) - m
        #expect(sum.columns.2 == SIMD3<Double>(0, 0, 1))
        #expect((m * 2).columns.1 == SIMD3<Double>(4, 10, 16))
    }
}
