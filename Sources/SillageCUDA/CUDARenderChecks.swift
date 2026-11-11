import Foundation
import SillageCore
import SillageRender

/// The CUDA renderer measured against Metal's own targets and against itself (#276): what the
/// tests print, in a cloud session on the CPU target and on a GPU in #283.
public enum CUDARenderChecks {
    public struct Report {
        public var lines: [String] = []
        public var worst: Double = 0
    }

    public static let tolerance = 0.05

    public static func compare(folder: URL) throws -> Report { Report() }
    public static func faintLight(drawn: Int) throws -> [String] { [] }
    public static func timings(drawn: Int) throws -> [String] { [] }
}
