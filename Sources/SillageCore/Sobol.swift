import Foundation

/// A Sobol sequence, digitally shifted by a seed. Successive points fill the unit cube evenly
/// in every dimension at once, where independent random draws leave clumps and holes: the
/// first 2^k points put exactly one in each of 2^k slices of any axis.
///
/// Direction numbers after Joe and Kuo, chosen so the points also spread well over pairs of
/// dimensions: every polynomial is primitive, and the first 1024 points form a (t, 10, 2)-net
/// with t at most 5 on every pair of the 24 dimensions. The shift is an XOR per dimension,
/// which keeps that structure and makes one batch differ from the next.
public struct Sobol: Sendable {
    public static let maximumDimensions = primitives.count + 1

    public let dimensions: Int
    private let directions: [[UInt32]]
    private let shift: [UInt32]

    public init(dimensions: Int, seed: UInt64) {
        precondition(dimensions >= 1 && dimensions <= Self.maximumDimensions)
        self.dimensions = dimensions
        directions = (0..<dimensions).map(Self.directions)
        var generator = SeededGenerator(seed: seed ^ 0x534F_424F_4C53_4549)
        shift = (0..<dimensions).map { _ in UInt32(truncatingIfNeeded: generator.next() >> 32) }
    }

    /// Point `index` in [0, 1) per dimension.
    public func point(_ index: Int) -> [Float] {
        (0..<dimensions).map { dimension in
            var bits = UInt32(truncatingIfNeeded: index)
            var value = shift[dimension]
            var k = 0
            while bits != 0 {
                if bits & 1 == 1 { value ^= directions[dimension][k] }
                bits >>= 1
                k += 1
            }
            return Float(Double(value) * 0x1p-32)
        }
    }

    /// Degree, interior coefficients and initial direction numbers of each dimension after
    /// the first.
    private static let primitives: [(degree: Int, coefficients: UInt32, initial: [UInt32])] = [
        (1, 0, [1]), (2, 1, [1, 3]), (3, 1, [1, 3, 1]), (3, 2, [1, 1, 1]),
        (4, 1, [1, 1, 3, 3]), (4, 4, [1, 3, 5, 13]), (5, 2, [1, 1, 5, 5, 17]),
        (5, 4, [1, 1, 5, 5, 5]), (5, 7, [1, 1, 7, 11, 19]), (5, 11, [1, 1, 5, 1, 1]),
        (5, 13, [1, 1, 1, 3, 11]), (5, 14, [1, 3, 5, 5, 31]), (6, 1, [1, 3, 3, 9, 7, 49]),
        (6, 13, [1, 1, 1, 15, 21, 21]), (6, 16, [1, 3, 1, 13, 27, 49]),
        (6, 19, [1, 1, 1, 15, 7, 5]), (6, 22, [1, 3, 1, 15, 13, 25]),
        (6, 25, [1, 1, 5, 5, 19, 61]), (7, 1, [1, 3, 7, 11, 23, 15, 103]),
        (7, 4, [1, 3, 7, 13, 13, 15, 69]), (7, 7, [1, 1, 3, 13, 7, 35, 63]),
        (7, 8, [1, 3, 5, 9, 1, 25, 53]), (7, 14, [1, 3, 1, 13, 9, 35, 107]),
    ]

    private static func directions(_ dimension: Int) -> [UInt32] {
        guard dimension > 0 else { return (0..<32).map { UInt32(1) << (31 - $0) } }
        let (s, a, m) = primitives[dimension - 1]
        var v = [UInt32](repeating: 0, count: 33)
        for i in 1...s { v[i] = m[i - 1] << (32 - i) }
        if s < 32 {
            for i in (s + 1)...32 {
                v[i] = v[i - s] ^ (v[i - s] >> s)
                for k in 1..<s where (a >> (s - 1 - k)) & 1 == 1 { v[i] ^= v[i - k] }
            }
        }
        return Array(v[1...])
    }
}
