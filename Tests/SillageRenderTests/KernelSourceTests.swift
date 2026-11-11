import Foundation
import Testing

@testable import SillageCore
@testable import SillageRender

/// The structs a shared kernel reads from a buffer are written twice: in the MSL, which the CUDA
/// engine compiles too, and in Swift, which fills the buffers. `cuda/src/kernels.cu` holds the
/// MSL's to a size with `SILLAGE_STRUCT`; this holds the Swift mirrors to the same lines (#281).
@Suite("Kernel source")
struct KernelSourceTests {
    static let asserts = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("cuda/src/kernels.cu")

    /// The stride of the Swift mirror of each struct `SILLAGE_STRUCT` names.
    static let mirrors: [String: Int] = [
        "BarnesHutShaders.BHNode": MemoryLayout<BHNode>.stride,
        "BarnesHutShaders.BHParams": MemoryLayout<BHParams>.stride,
        "BarnesHutShaders.HaloGPU": MemoryLayout<HaloGPU>.stride,
        "BarnesHutShaders.DiskCooling": MemoryLayout<DiskCoolingGPU>.stride,
        "BarnesHutShaders.SFParams": MemoryLayout<StarFormationGPU>.stride,
        "BarnesHutShaders.HoleGPU": MemoryLayout<HoleGPU>.stride,
        "GPUTreeShaders.BHNode": MemoryLayout<BHNode>.stride,
        "GPUTreeShaders.TreeParams": MemoryLayout<GPUTreeBuilder.Params>.stride,
    ]

    @Test func swiftMirrorsHaveTheSizesOfTheirMSLStructs() throws {
        let text = try String(contentsOf: Self.asserts, encoding: .utf8)
        var seen: Set<String> = []
        for line in text.split(separator: "\n") where line.hasPrefix("SILLAGE_STRUCT(") {
            let fields = line.dropFirst("SILLAGE_STRUCT(".count).prefix { $0 != ")" }
                .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            try #require(fields.count == 3, "cannot read \(line)")
            let name = "\(fields[0]).\(fields[1])"
            let bytes = try #require(Int(fields[2]), "cannot read \(line)")
            let mirror = try #require(
                Self.mirrors[name], "\(name) has no Swift mirror listed in KernelSourceTests")
            #expect(mirror == bytes, "\(name) is \(bytes) bytes in the MSL and \(mirror) in Swift")
            seen.insert(name)
        }
        #expect(seen == Set(Self.mirrors.keys), "a mirror is listed here without its SILLAGE_STRUCT")
    }
}
