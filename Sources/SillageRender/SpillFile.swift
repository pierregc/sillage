import Foundation

/// Scratch storage a capture overflows into, so a long run keeps every frame it took.
///
/// A take used to answer a full memory budget by throwing away every other frame and
/// capturing half as often from then on. That keeps the *duration* and loses the *run*: ten
/// thousand megayears would come back at a cadence coarse enough that nothing between two
/// snapshots ever happened. Physics that cost hours to compute is not a thing to resample.
/// So the budget now bounds what the take holds in memory, not what it holds, and everything
/// past it goes here.
///
/// Opened and immediately unlinked. The descriptor goes on working, nothing else can find the
/// file or trip over it, and the volume takes the space back when the process ends however it
/// ends — including the crash of 18 September, which is exactly the moment an orphaned eighty
/// gigabyte scratch file would be least welcome.
///
/// Positional reads and writes throughout, never the file offset, so the capture can be
/// appending on the simulation queue while playback reads an older frame on another.
final class SpillFile {
    private let descriptor: Int32
    /// Bytes written. Only ever grows, and only under the take's own lock.
    private(set) var byteCount = 0

    enum Failure: Error, CustomStringConvertible {
        case create(String)
        case write(String)
        case read(String)

        var description: String {
            switch self {
            case .create(let why): "Impossible d'ouvrir le fichier de débord : \(why)"
            case .write(let why): "Écriture du fichier de débord : \(why)"
            case .read(let why): "Lecture du fichier de débord : \(why)"
            }
        }
    }

    init(directory: URL? = nil) throws {
        let base = directory ?? FileManager.default.temporaryDirectory
        let template = base.appendingPathComponent("sillage-debord.XXXXXX").path
        var bytes = Array(template.utf8CString)
        let handle = bytes.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }
        guard handle >= 0 else { throw Failure.create(String(cString: strerror(errno))) }
        // Nameless from here on: nothing to clean up, and nothing left behind by a crash.
        bytes.withUnsafeBufferPointer { _ = unlink($0.baseAddress!) }
        descriptor = handle
    }

    deinit { close(descriptor) }

    /// Appends a whole block, however large, retrying what a single write would not take.
    func append(_ buffer: UnsafeRawBufferPointer) throws {
        guard let base = buffer.baseAddress, !buffer.isEmpty else { return }
        var written = 0
        while written < buffer.count {
            let n = pwrite(
                descriptor, base + written, buffer.count - written, off_t(byteCount + written))
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.write(String(cString: strerror(errno)))
            }
            // A zero-length write with no error has nothing left to say, and looping on it
            // would spin for ever.
            guard n > 0 else { throw Failure.write("écriture vide") }
            written += n
        }
        byteCount += written
    }

    /// Fills `destination` from `offset`, and says so if the file is shorter than that.
    func read(into destination: UnsafeMutableRawPointer, count: Int, at offset: Int) throws {
        guard count > 0 else { return }
        guard offset >= 0, offset + count <= byteCount else {
            throw Failure.read("\(offset)..<\(offset + count) hors des \(byteCount) octets écrits")
        }
        var got = 0
        while got < count {
            let n = pread(descriptor, destination + got, count - got, off_t(offset + got))
            if n < 0 {
                if errno == EINTR { continue }
                throw Failure.read(String(cString: strerror(errno)))
            }
            guard n > 0 else { throw Failure.read("fin de fichier prématurée") }
            got += n
        }
    }
}
