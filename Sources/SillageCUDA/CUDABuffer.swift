internal import CSillageCUDA

/// Device memory on one context (#273), zeroed when made, as Metal's buffers are. Offsets and
/// lengths are in bytes.
public final class CUDABuffer {
    public let context: CUDAContext
    public let length: Int
    let handle: OpaquePointer
    /// The builder whose buffer this is, which frees it; nil when this buffer owns its memory.
    private let owner: AnyObject?

    public init(context: CUDAContext, length: Int) throws {
        var made: OpaquePointer?
        try check(
            sc_buffer_create(context.handle, max(length, 0), &made), "a buffer of \(length) bytes")
        guard let made else { throw CUDAError(.unknown, "no buffer of \(length) bytes") }
        handle = made
        self.context = context
        self.length = max(length, 0)
        owner = nil
    }

    init(borrowing handle: OpaquePointer, of owner: AnyObject, context: CUDAContext) {
        self.handle = handle
        self.owner = owner
        self.context = context
        length = sc_buffer_length(handle)
    }

    deinit {
        if owner == nil { sc_buffer_destroy(handle) }
    }

    public func upload(_ bytes: UnsafeRawBufferPointer, at offset: Int = 0) throws {
        guard offset >= 0 else { throw CUDAError(.invalidArgument, "a negative offset") }
        try check(
            sc_buffer_upload(handle, offset, bytes.baseAddress, bytes.count),
            "uploading \(bytes.count) bytes at \(offset)")
    }

    public func upload<T>(_ values: [T], at offset: Int = 0) throws {
        try values.withUnsafeBytes { try upload($0, at: offset) }
    }

    public func download(into bytes: UnsafeMutableRawBufferPointer, from offset: Int = 0) throws {
        guard offset >= 0 else { throw CUDAError(.invalidArgument, "a negative offset") }
        try check(
            sc_buffer_download(handle, offset, bytes.baseAddress, bytes.count),
            "downloading \(bytes.count) bytes from \(offset)")
    }

    /// `count` values of a plain type from `offset`.
    public func download<T>(_ type: T.Type, count: Int, from offset: Int = 0) throws -> [T] {
        guard count > 0 else { return [] }
        return try [T](unsafeUninitializedCapacity: count) { values, initialized in
            initialized = 0
            try download(into: UnsafeMutableRawBufferPointer(values), from: offset)
            initialized = count
        }
    }

    public func fill(_ value: UInt8 = 0) throws {
        try check(sc_buffer_fill(handle, value), "filling \(length) bytes")
    }

    public func copy(
        _ length: Int, from source: CUDABuffer, at sourceOffset: Int = 0, to offset: Int = 0
    ) throws {
        guard length >= 0, sourceOffset >= 0, offset >= 0 else {
            throw CUDAError(.invalidArgument, "a negative length or offset")
        }
        try check(
            sc_buffer_copy(handle, offset, source.handle, sourceOffset, length),
            "copying \(length) bytes")
    }
}

/// Pinned host memory (#273): an upload from it or a download into it runs at the bus's speed.
public final class CUDAHostMemory {
    public let context: CUDAContext
    public let bytes: UnsafeMutableRawBufferPointer

    public init(context: CUDAContext, length: Int) throws {
        var memory: UnsafeMutableRawPointer?
        try check(
            sc_host_allocate(context.handle, max(length, 0), &memory),
            "\(length) bytes of pinned memory")
        guard let memory else { throw CUDAError(.unknown, "no pinned memory") }
        self.context = context
        bytes = UnsafeMutableRawBufferPointer(start: memory, count: max(length, 0))
    }

    deinit { sc_host_free(bytes.baseAddress) }
}
