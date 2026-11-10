import Foundation

/// `DispatchQueue.concurrentPerform`, for work that shares buffers between its iterations on
/// purpose. libdispatch on Linux takes a `@Sendable` closure where Apple's takes a plain one,
/// which strict concurrency refuses these iterations' captures for.
@inline(__always)
public func concurrentPerform(iterations: Int, execute work: (Int) -> Void) {
    #if canImport(Darwin)
        DispatchQueue.concurrentPerform(iterations: iterations, execute: work)
    #else
        withoutActuallyEscaping(work) { work in
            nonisolated(unsafe) let shared = work
            DispatchQueue.concurrentPerform(iterations: iterations) { shared($0) }
        }
    #endif
}
