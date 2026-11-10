import Foundation

/// SHA-256 written out, for the places CryptoKit is not there (Linux) and for a digest that
/// has to come out the same on both platforms.
public struct PortableSHA256 {
    private static let constants: [UInt32] = [
        0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
        0xab1c_5ed5, 0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe,
        0x9bdc_06a7, 0xc19b_f174, 0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f,
        0x4a74_84aa, 0x5cb0_a9dc, 0x76f9_88da, 0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7,
        0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351, 0x1429_2967, 0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc,
        0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e, 0x9272_2c85, 0xa2bf_e8a1, 0xa81a_664b,
        0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585, 0x106a_a070, 0x19a4_c116,
        0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f, 0x682e_6ff3,
        0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
        0xc671_78f2,
    ]

    private var state: [UInt32] = [
        0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a, 0x510e_527f, 0x9b05_688c, 0x1f83_d9ab,
        0x5be0_cd19,
    ]
    private var pending: [UInt8] = []
    private var length: UInt64 = 0

    public init() { pending.reserveCapacity(64) }

    public mutating func update(data: Data) {
        data.withUnsafeBytes { update(bytes: $0) }
    }

    public mutating func update(bytes: UnsafeRawBufferPointer) {
        length &+= UInt64(bytes.count)
        var offset = 0
        if !pending.isEmpty {
            let take = min(64 - pending.count, bytes.count)
            pending.append(contentsOf: bytes[0..<take])
            offset = take
            if pending.count == 64 {
                pending.withUnsafeBytes { compress($0.baseAddress!) }
                pending.removeAll(keepingCapacity: true)
            }
        }
        while bytes.count - offset >= 64 {
            compress(bytes.baseAddress! + offset)
            offset += 64
        }
        if offset < bytes.count { pending.append(contentsOf: bytes[offset...]) }
    }

    public mutating func update<T: FixedWidthInteger>(littleEndian value: T) {
        var bytes = value.littleEndian
        withUnsafeBytes(of: &bytes) { update(bytes: $0) }
    }

    /// The 32 bytes of the digest.
    public mutating func finalize() -> [UInt8] {
        let bits = length &* 8
        var tail: [UInt8] = [0x80]
        let filled = (pending.count + 1) % 64
        tail += [UInt8](repeating: 0, count: filled <= 56 ? 56 - filled : 120 - filled)
        for shift in stride(from: 56, through: 0, by: -8) {
            tail.append(UInt8(truncatingIfNeeded: bits >> UInt64(shift)))
        }
        tail.withUnsafeBytes { update(bytes: $0) }
        return state.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> UInt32(24 - 8 * $0)) }
        }
    }

    /// The digest of `finalize` as lower-case hexadecimal.
    public mutating func hex() -> String {
        finalize().map { String(format: "%02x", $0) }.joined()
    }

    private mutating func compress(_ block: UnsafeRawPointer) {
        var words = [UInt32](repeating: 0, count: 64)
        for index in 0..<16 {
            var word: UInt32 = 0
            for byte in 0..<4 {
                word = word << 8 | UInt32(block.load(fromByteOffset: index * 4 + byte, as: UInt8.self))
            }
            words[index] = word
        }
        for index in 16..<64 {
            let a = words[index - 15]
            let b = words[index - 2]
            let low = Self.rotate(a, 7) ^ Self.rotate(a, 18) ^ (a >> 3)
            let high = Self.rotate(b, 17) ^ Self.rotate(b, 19) ^ (b >> 10)
            words[index] = words[index - 16] &+ low &+ words[index - 7] &+ high
        }
        var (a, b, c, d) = (state[0], state[1], state[2], state[3])
        var (e, f, g, h) = (state[4], state[5], state[6], state[7])
        for index in 0..<64 {
            let sum1 = Self.rotate(e, 6) ^ Self.rotate(e, 11) ^ Self.rotate(e, 25)
            let choose = (e & f) ^ (~e & g)
            let first = h &+ sum1 &+ choose &+ Self.constants[index] &+ words[index]
            let sum0 = Self.rotate(a, 2) ^ Self.rotate(a, 13) ^ Self.rotate(a, 22)
            let majority = (a & b) ^ (a & c) ^ (b & c)
            let second = sum0 &+ majority
            (h, g, f, e, d, c, b, a) = (g, f, e, d &+ first, c, b, a, first &+ second)
        }
        for (index, value) in [a, b, c, d, e, f, g, h].enumerated() { state[index] = state[index] &+ value }
    }

    private static func rotate(_ value: UInt32, _ by: UInt32) -> UInt32 {
        (value >> by) | (value << (32 - by))
    }
}
