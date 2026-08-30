import Foundation
import Metal

/// Compiled Metal libraries, kept for as long as the process runs.
///
/// Every library here is built from a source string that never changes, and `makeLibrary` is
/// a full compile of it. That is fine once; it is not fine on every rebuild of the renderer,
/// which is what a change of scene does — measured against a sixty hertz schedule, a scene
/// change cost a frame a full second late, and in a mode that changes scene every minute
/// that is the whole of the stutter.
///
/// Keyed by device and by the source itself, so two devices or two different shaders never
/// share an entry.
enum ShaderCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var libraries: [Key: MTLLibrary] = [:]

    private struct Key: Hashable {
        let device: ObjectIdentifier
        let source: Int
    }

    static func library(_ source: String, on device: MTLDevice) throws -> MTLLibrary {
        let key = Key(device: ObjectIdentifier(device), source: source.hashValue)
        lock.lock()
        if let held = libraries[key] {
            lock.unlock()
            return held
        }
        lock.unlock()
        // Compiled outside the lock: two threads racing here waste one compile between them,
        // which is cheaper than making every other caller wait behind a slow one.
        let built = try device.makeLibrary(source: source, options: nil)
        lock.lock()
        libraries[key] = built
        lock.unlock()
        return built
    }
}
