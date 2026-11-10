// swift-format-ignore-file: AlwaysUseLowerCamelCase, TypeNamesShouldBeCapitalized

#if !canImport(simd)
    import Foundation

    // What the code takes from Apple's `simd` module, over the standard library's vectors, so
    // that the portable code builds on Linux. Sums of products written out, left to right:
    // docs/notes/linux-build.md says whether they give Apple's bits.

    @inlinable public func simd_dot<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD2<T>, _ b: SIMD2<T>
    ) -> T {
        a.x * b.x + a.y * b.y
    }

    @inlinable public func simd_dot<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>, _ b: SIMD3<T>
    ) -> T {
        a.x * b.x + a.y * b.y + a.z * b.z
    }

    @inlinable public func simd_dot<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD4<T>, _ b: SIMD4<T>
    ) -> T {
        a.x * b.x + a.y * b.y + a.z * b.z + a.w * b.w
    }

    @inlinable public func simd_length_squared<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD2<T>
    ) -> T {
        simd_dot(a, a)
    }

    @inlinable public func simd_length_squared<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>
    ) -> T {
        simd_dot(a, a)
    }

    @inlinable public func simd_length_squared<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD4<T>
    ) -> T {
        simd_dot(a, a)
    }

    @inlinable public func simd_length<T: BinaryFloatingPoint & SIMDScalar>(_ a: SIMD2<T>) -> T {
        simd_length_squared(a).squareRoot()
    }

    @inlinable public func simd_length<T: BinaryFloatingPoint & SIMDScalar>(_ a: SIMD3<T>) -> T {
        simd_length_squared(a).squareRoot()
    }

    @inlinable public func simd_length<T: BinaryFloatingPoint & SIMDScalar>(_ a: SIMD4<T>) -> T {
        simd_length_squared(a).squareRoot()
    }

    @inlinable public func simd_distance_squared<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>, _ b: SIMD3<T>
    ) -> T {
        simd_length_squared(a - b)
    }

    @inlinable public func simd_distance<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD2<T>, _ b: SIMD2<T>
    ) -> T {
        simd_length(a - b)
    }

    @inlinable public func simd_distance<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>, _ b: SIMD3<T>
    ) -> T {
        simd_length(a - b)
    }

    @inlinable public func simd_normalize<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD2<T>
    ) -> SIMD2<T> {
        a / simd_length(a)
    }

    @inlinable public func simd_normalize<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>
    ) -> SIMD3<T> {
        a / simd_length(a)
    }

    @inlinable public func simd_cross<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMD3<T>, _ b: SIMD3<T>
    ) -> SIMD3<T> {
        SIMD3(
            a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x)
    }

    @inlinable public func simd_min<V: SIMD>(_ a: V, _ b: V) -> V
    where V.Scalar: Comparable {
        a.replacing(with: b, where: b .< a)
    }

    @inlinable public func simd_max<V: SIMD>(_ a: V, _ b: V) -> V
    where V.Scalar: Comparable {
        a.replacing(with: b, where: b .> a)
    }

    @inlinable public func simd_clamp<V: SIMD>(_ a: V, _ low: V, _ high: V) -> V
    where V.Scalar: Comparable {
        simd_min(simd_max(a, low), high)
    }

    @inlinable public func simd_mix<V: SIMD>(_ a: V, _ b: V, _ t: V) -> V
    where V.Scalar: FloatingPoint {
        a + (b - a) * t
    }

    @inlinable public func simd_sum<V: SIMD>(_ a: V) -> V.Scalar where V.Scalar: FloatingPoint {
        a.sum()
    }

    @inlinable public func smoothstep<T: BinaryFloatingPoint>(_ edge0: T, _ edge1: T, _ x: T) -> T {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }

    @inlinable public func fract<T: BinaryFloatingPoint>(_ x: T) -> T {
        x - x.rounded(.down)
    }

    /// `simd_float3x3` and `simd_double3x3`: three columns, with the operations the code uses.
    public struct SIMDMatrix3<T: BinaryFloatingPoint & SIMDScalar>: Equatable {
        public var columns: (SIMD3<T>, SIMD3<T>, SIMD3<T>)

        @inlinable public init() {
            columns = (SIMD3(repeating: 0), SIMD3(repeating: 0), SIMD3(repeating: 0))
        }

        @inlinable public init(_ c0: SIMD3<T>, _ c1: SIMD3<T>, _ c2: SIMD3<T>) {
            columns = (c0, c1, c2)
        }

        @inlinable public init(columns: (SIMD3<T>, SIMD3<T>, SIMD3<T>)) {
            self.columns = columns
        }

        @inlinable public init(_ columns: [SIMD3<T>]) {
            precondition(columns.count == 3, "a 3x3 matrix takes three columns")
            self.columns = (columns[0], columns[1], columns[2])
        }

        @inlinable public init(rows: [SIMD3<T>]) {
            precondition(rows.count == 3, "a 3x3 matrix takes three rows")
            columns = (
                SIMD3(rows[0].x, rows[1].x, rows[2].x),
                SIMD3(rows[0].y, rows[1].y, rows[2].y),
                SIMD3(rows[0].z, rows[1].z, rows[2].z)
            )
        }

        @inlinable public init(diagonal: SIMD3<T>) {
            columns = (
                SIMD3(diagonal.x, 0, 0), SIMD3(0, diagonal.y, 0), SIMD3(0, 0, diagonal.z)
            )
        }

        @inlinable public subscript(column: Int) -> SIMD3<T> {
            get {
                switch column {
                case 0: return columns.0
                case 1: return columns.1
                case 2: return columns.2
                default: preconditionFailure("column \(column) out of range")
                }
            }
            set {
                switch column {
                case 0: columns.0 = newValue
                case 1: columns.1 = newValue
                case 2: columns.2 = newValue
                default: preconditionFailure("column \(column) out of range")
                }
            }
        }

        @inlinable public subscript(column: Int, row: Int) -> T {
            get { self[column][row] }
            set { self[column][row] = newValue }
        }

        @inlinable public static func == (a: Self, b: Self) -> Bool {
            a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
        }

        @inlinable public var transpose: Self {
            Self(
                rows: [columns.0, columns.1, columns.2])
        }

        @inlinable public var determinant: T {
            simd_dot(columns.0, simd_cross(columns.1, columns.2))
        }

        @inlinable public var inverse: Self {
            let c0 = simd_cross(columns.1, columns.2)
            let c1 = simd_cross(columns.2, columns.0)
            let c2 = simd_cross(columns.0, columns.1)
            let scale = 1 / simd_dot(columns.0, c0)
            return Self(rows: [c0 * scale, c1 * scale, c2 * scale])
        }

        @inlinable public static func + (a: Self, b: Self) -> Self {
            Self(a.columns.0 + b.columns.0, a.columns.1 + b.columns.1, a.columns.2 + b.columns.2)
        }

        @inlinable public static func - (a: Self, b: Self) -> Self {
            Self(a.columns.0 - b.columns.0, a.columns.1 - b.columns.1, a.columns.2 - b.columns.2)
        }

        @inlinable public static func += (a: inout Self, b: Self) { a = a + b }

        @inlinable public static func -= (a: inout Self, b: Self) { a = a - b }

        @inlinable public static func * (a: Self, s: T) -> Self {
            Self(a.columns.0 * s, a.columns.1 * s, a.columns.2 * s)
        }

        @inlinable public static func * (s: T, a: Self) -> Self { a * s }

        @inlinable public static func * (a: Self, v: SIMD3<T>) -> SIMD3<T> {
            a.columns.0 * v.x + a.columns.1 * v.y + a.columns.2 * v.z
        }

        @inlinable public static func * (a: Self, b: Self) -> Self {
            Self(a * b.columns.0, a * b.columns.1, a * b.columns.2)
        }
    }

    /// `simd_float4x4`: four columns, with the product the cameras use.
    public struct SIMDMatrix4<T: BinaryFloatingPoint & SIMDScalar>: Equatable {
        public var columns: (SIMD4<T>, SIMD4<T>, SIMD4<T>, SIMD4<T>)

        @inlinable public init(_ c0: SIMD4<T>, _ c1: SIMD4<T>, _ c2: SIMD4<T>, _ c3: SIMD4<T>) {
            columns = (c0, c1, c2, c3)
        }

        @inlinable public init(columns: (SIMD4<T>, SIMD4<T>, SIMD4<T>, SIMD4<T>)) {
            self.columns = columns
        }

        @inlinable public subscript(column: Int) -> SIMD4<T> {
            switch column {
            case 0: return columns.0
            case 1: return columns.1
            case 2: return columns.2
            case 3: return columns.3
            default: preconditionFailure("column \(column) out of range")
            }
        }

        @inlinable public static func == (a: Self, b: Self) -> Bool {
            a.columns.0 == b.columns.0 && a.columns.1 == b.columns.1 && a.columns.2 == b.columns.2
                && a.columns.3 == b.columns.3
        }

        @inlinable public static func * (a: Self, v: SIMD4<T>) -> SIMD4<T> {
            a.columns.0 * v.x + a.columns.1 * v.y + a.columns.2 * v.z + a.columns.3 * v.w
        }

        @inlinable public static func * (a: Self, b: Self) -> Self {
            Self(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
        }
    }

    public typealias simd_float4x4 = SIMDMatrix4<Float>

    @inlinable public func simd_determinant<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMDMatrix3<T>
    ) -> T {
        a.determinant
    }

    @inlinable public func simd_inverse<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMDMatrix3<T>
    ) -> SIMDMatrix3<T> {
        a.inverse
    }

    @inlinable public func simd_transpose<T: BinaryFloatingPoint & SIMDScalar>(
        _ a: SIMDMatrix3<T>
    ) -> SIMDMatrix3<T> {
        a.transpose
    }

    public typealias simd_float3x3 = SIMDMatrix3<Float>
    public typealias simd_double3x3 = SIMDMatrix3<Double>
#endif
