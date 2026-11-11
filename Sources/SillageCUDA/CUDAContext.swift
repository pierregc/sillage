internal import CSillageCUDA

/// A call of the CUDA engine's C API that failed, with the message it left (#273).
public struct CUDAError: Error, CustomStringConvertible, Sendable {
    public enum Code: Sendable, Equatable {
        case invalidArgument, outOfMemory, noDevice, cuda
        /// The CPU target cannot run it: block barriers or warp functions (#283 runs it).
        case gpuOnly
        case unknown
    }

    public let code: Code
    public let message: String

    public var description: String { message }

    init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }
}

func check(_ status: sc_status, _ what: @autoclosure () -> String) throws {
    guard status != SC_OK else { return }
    let code: CUDAError.Code =
        switch status {
        case SC_INVALID_ARGUMENT: .invalidArgument
        case SC_OUT_OF_MEMORY: .outOfMemory
        case SC_NO_DEVICE: .noDevice
        case SC_CUDA_ERROR: .cuda
        case SC_GPU_ONLY: .gpuOnly
        default: .unknown
        }
    throw CUDAError(code, "\(what()): \(String(cString: sc_last_error()))")
}

/// One NVIDIA GPU, or the CPU target standing in for one (#273). The buffers and builders made
/// on it keep it alive.
public final class CUDAContext {
    public enum Target: Sendable {
        /// libsillagecuda.a, built by nvcc.
        case gpu
        /// libsillagecuda_cpu.a, the same files built through cuda_cpu.h: correct on small
        /// inputs, never fast, and without the kernels that need block barriers or warp functions.
        case cpu
    }

    /// The library this build linked.
    public static var target: Target { sc_build_target() == SC_TARGET_CPU ? .cpu : .gpu }

    /// The devices the CUDA runtime finds: one on the CPU target, none without an NVIDIA GPU.
    public static var deviceCount: Int {
        var count: Int32 = 0
        return sc_device_count(&count) == SC_OK ? Int(count) : 0
    }

    /// Whether every kernel can run here: the GPU library and a GPU to run it on.
    public static var runsEveryKernel: Bool { target == .gpu && deviceCount > 0 }

    public let device: Int
    public let name: String
    /// Bytes of device memory, 0 on the CPU target.
    public let memory: Int
    public let computeCapability: (major: Int, minor: Int)
    public let multiprocessors: Int
    public let warpSize: Int
    let handle: OpaquePointer

    public init(device: Int = 0) throws {
        var made: OpaquePointer?
        try check(sc_context_create(Int32(device), &made), "the context of device \(device)")
        guard let made else { throw CUDAError(.unknown, "no context for device \(device)") }
        var info = sc_device_info()
        let status = sc_context_info(made, &info)
        guard status == SC_OK else {
            sc_context_destroy(made)
            try check(status, "the properties of device \(device)")
            throw CUDAError(.unknown, "no properties for device \(device)")
        }
        handle = made
        self.device = device
        name = withUnsafeBytes(of: info.name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        memory = Int(info.memory)
        computeCapability = (Int(info.major), Int(info.minor))
        multiprocessors = Int(info.multiprocessors)
        warpSize = Int(info.warp_size)
    }

    deinit { sc_context_destroy(handle) }

    /// Waits for the work queued so far, and reports an error a kernel left behind.
    public func synchronize() throws {
        try check(sc_context_synchronize(handle), "synchronizing device \(device)")
    }

    public func makeBuffer(length: Int) throws -> CUDABuffer {
        try CUDABuffer(context: self, length: length)
    }

    public func makeBuffer<T>(_ values: [T]) throws -> CUDABuffer {
        let buffer = try CUDABuffer(context: self, length: values.count * MemoryLayout<T>.stride)
        try buffer.upload(values)
        return buffer
    }
}
