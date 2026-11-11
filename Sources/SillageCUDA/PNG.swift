import Foundation

#if canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#elseif canImport(Darwin)
    import Darwin
#endif

/// 8-bit PNGs, read and written without a library to link: the deflate stream goes through the
/// system's zlib, found when it is first needed, and a file written without it holds stored
/// blocks, bigger and the same picture (#277).
public enum PNG {
    public struct Image: Sendable, Equatable {
        public var width: Int
        public var height: Int
        /// 1 (grey), 3 (RGB) or 4 (RGBA) bytes a pixel.
        public var channels: Int
        /// Rows from the top, no padding.
        public var bytes: [UInt8]

        public init(width: Int, height: Int, channels: Int, bytes: [UInt8]) {
            self.width = width
            self.height = height
            self.channels = channels
            self.bytes = bytes
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case notAPNG
        case unsupported(String)
        case damaged(String)

        public var description: String {
            switch self {
            case .notAPNG: "not a PNG"
            case .unsupported(let what): "a PNG this reader does not take: \(what)"
            case .damaged(let what): "a damaged PNG: \(what)"
            }
        }
    }

    private typealias Compress =
        @convention(c) (
            UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt>, UnsafePointer<UInt8>, UInt, Int32
        ) -> Int32
    private typealias Uncompress =
        @convention(c) (
            UnsafeMutablePointer<UInt8>, UnsafeMutablePointer<UInt>, UnsafePointer<UInt8>, UInt
        ) -> Int32

    private static let zlib: (compress: Compress, uncompress: Uncompress)? = {
        for name in ["libz.so.1", "libz.1.dylib", "libz.so"] {
            guard let library = dlopen(name, RTLD_NOW),
                let compress = dlsym(library, "compress2"),
                let uncompress = dlsym(library, "uncompress")
            else { continue }
            return (
                unsafeBitCast(compress, to: Compress.self),
                unsafeBitCast(uncompress, to: Uncompress.self)
            )
        }
        return nil
    }()

    /// Whether the system's zlib was found, and files are compressed.
    public static var compresses: Bool { zlib != nil }

    // MARK: Writing

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 { value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1 }
        return value
    }

    private static func crc(_ bytes: [UInt8]) -> UInt32 {
        var value: UInt32 = 0xFFFF_FFFF
        for byte in bytes { value = crcTable[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8) }
        return ~value
    }

    private static func adler(_ bytes: [UInt8]) -> UInt32 {
        var low: UInt32 = 1
        var high: UInt32 = 0
        for byte in bytes {
            low = (low + UInt32(byte)) % 65521
            high = (high + low) % 65521
        }
        return high << 16 | low
    }

    private static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    private static func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
        let named = Array(type.utf8) + body
        return be32(UInt32(body.count)) + named + be32(crc(named))
    }

    /// The deflate stream of `bytes` in zlib's wrapper: compressed when zlib is there, as stored
    /// blocks when it is not.
    private static func deflate(_ bytes: [UInt8]) -> [UInt8] {
        if let zlib {
            var length = UInt(bytes.count + bytes.count / 1000 + 64)
            var packed = [UInt8](repeating: 0, count: Int(length))
            let status = packed.withUnsafeMutableBufferPointer { target in
                bytes.withUnsafeBufferPointer { source in
                    zlib.compress(
                        target.baseAddress!, &length, source.baseAddress!, UInt(bytes.count), 6)
                }
            }
            if status == 0 { return Array(packed.prefix(Int(length))) }
        }
        var stream: [UInt8] = [0x78, 0x01]
        var start = 0
        repeat {
            let size = min(65535, bytes.count - start)
            let last: UInt8 = start + size >= bytes.count ? 1 : 0
            stream += [
                last, UInt8(size & 0xFF), UInt8(size >> 8), UInt8(~size & 0xFF), UInt8((~size >> 8) & 0xFF),
            ]
            stream += bytes[start..<(start + size)]
            start += size
        } while start < bytes.count
        return stream + be32(adler(bytes))
    }

    /// The rows with the filter that leaves the least to compress, tried a row at a time as
    /// libpng does: the one whose bytes, read as signed, add up the smallest.
    private static func filtered(_ image: Image) -> [UInt8] {
        let row = image.width * image.channels
        let step = image.channels
        var out = [UInt8]()
        out.reserveCapacity((row + 1) * image.height)
        let none = [UInt8](repeating: 0, count: row)
        for y in 0..<image.height {
            let current = Array(image.bytes[(y * row)..<((y + 1) * row)])
            let above = y > 0 ? Array(image.bytes[((y - 1) * row)..<(y * row)]) : none
            var best: (cost: Int, type: UInt8, bytes: [UInt8]) = (.max, 0, [])
            for type in 0..<5 {
                var line = [UInt8](repeating: 0, count: row)
                var cost = 0
                for x in 0..<row {
                    let left = x >= step ? Int(current[x - step]) : 0
                    let up = Int(above[x])
                    let corner = x >= step ? Int(above[x - step]) : 0
                    let predicted: Int
                    switch type {
                    case 0: predicted = 0
                    case 1: predicted = left
                    case 2: predicted = up
                    case 3: predicted = (left + up) / 2
                    default:
                        let guess = left + up - corner
                        let (a, b, c) = (abs(guess - left), abs(guess - up), abs(guess - corner))
                        predicted = a <= b && a <= c ? left : (b <= c ? up : corner)
                    }
                    let value = UInt8(truncatingIfNeeded: Int(current[x]) - predicted)
                    line[x] = value
                    cost += abs(Int(Int8(bitPattern: value)))
                }
                if cost < best.cost { best = (cost, UInt8(type), line) }
            }
            out.append(best.type)
            out += best.bytes
        }
        return out
    }

    public static func encode(_ image: Image) -> Data {
        precondition(
            [1, 3, 4].contains(image.channels)
                && image.bytes.count == image.width * image.height * image.channels,
            "a PNG of 8-bit grey, RGB or RGBA pixels")
        let colour: UInt8 = image.channels == 1 ? 0 : (image.channels == 3 ? 2 : 6)
        let header = be32(UInt32(image.width)) + be32(UInt32(image.height)) + [8, colour, 0, 0, 0]
        var file: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        file += chunk("IHDR", header)
        file += chunk("IDAT", deflate(filtered(image)))
        file += chunk("IEND", [])
        return Data(file)
    }

    public static func write(_ image: Image, to url: URL) throws {
        try encode(image).write(to: url, options: .atomic)
    }

    // MARK: Reading

    public static func decode(_ data: Data) throws -> Image {
        let file = [UInt8](data)
        guard file.count > 8, Array(file[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        else { throw Failure.notAPNG }
        func word(_ at: Int) -> Int {
            Int(file[at]) << 24 | Int(file[at + 1]) << 16 | Int(file[at + 2]) << 8 | Int(file[at + 3])
        }
        var (width, height, channels) = (0, 0, 0)
        var compressed = [UInt8]()
        var at = 8
        while at + 12 <= file.count {
            let size = word(at)
            let type = String(decoding: file[(at + 4)..<(at + 8)], as: UTF8.self)
            guard at + 12 + size <= file.count else { throw Failure.damaged("a chunk past the end") }
            let body = file[(at + 8)..<(at + 8 + size)]
            switch type {
            case "IHDR":
                guard size == 13 else { throw Failure.damaged("the header") }
                let fields = Array(body)
                width = Int(fields[0]) << 24 | Int(fields[1]) << 16 | Int(fields[2]) << 8 | Int(fields[3])
                height = Int(fields[4]) << 24 | Int(fields[5]) << 16 | Int(fields[6]) << 8 | Int(fields[7])
                guard fields[8] == 8 else { throw Failure.unsupported("\(fields[8]) bits a channel") }
                guard fields[12] == 0 else { throw Failure.unsupported("an interlaced image") }
                switch fields[9] {
                case 0: channels = 1
                case 2: channels = 3
                case 6: channels = 4
                default: throw Failure.unsupported("colour type \(fields[9])")
                }
            case "IDAT":
                compressed += body
            default:
                break
            }
            at += 12 + size
        }
        guard width > 0, height > 0, channels > 0, !compressed.isEmpty else {
            throw Failure.damaged("no header or no pixels")
        }
        guard let zlib else { throw Failure.unsupported("no zlib on this machine to inflate it") }
        let row = width * channels
        var length = UInt((row + 1) * height)
        var raw = [UInt8](repeating: 0, count: Int(length))
        let status = raw.withUnsafeMutableBufferPointer { target in
            compressed.withUnsafeBufferPointer { source in
                zlib.uncompress(target.baseAddress!, &length, source.baseAddress!, UInt(compressed.count))
            }
        }
        guard status == 0, Int(length) == (row + 1) * height else {
            throw Failure.damaged("the pixels do not inflate")
        }
        var bytes = [UInt8](repeating: 0, count: row * height)
        for y in 0..<height {
            let type = raw[y * (row + 1)]
            for x in 0..<row {
                let value = Int(raw[y * (row + 1) + 1 + x])
                let left = x >= channels ? Int(bytes[y * row + x - channels]) : 0
                let up = y > 0 ? Int(bytes[(y - 1) * row + x]) : 0
                let corner = x >= channels && y > 0 ? Int(bytes[(y - 1) * row + x - channels]) : 0
                let predicted: Int
                switch type {
                case 0: predicted = 0
                case 1: predicted = left
                case 2: predicted = up
                case 3: predicted = (left + up) / 2
                case 4:
                    let guess = left + up - corner
                    let (a, b, c) = (abs(guess - left), abs(guess - up), abs(guess - corner))
                    predicted = a <= b && a <= c ? left : (b <= c ? up : corner)
                default: throw Failure.damaged("filter \(type)")
                }
                bytes[y * row + x] = UInt8(truncatingIfNeeded: value + predicted)
            }
        }
        return Image(width: width, height: height, channels: channels, bytes: bytes)
    }

    public static func read(_ url: URL) throws -> Image { try decode(Data(contentsOf: url)) }
}
