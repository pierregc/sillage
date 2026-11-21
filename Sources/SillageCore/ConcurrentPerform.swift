import Foundation

/// `DispatchQueue.concurrentPerform`, for work that shares buffers between its iterations on
/// purpose: each iteration writes its own part of a buffer, which strict concurrency cannot
/// see. Dispatch takes a `@Sendable` closure, on Linux and in Apple's recent SDKs alike.
@inline(__always)
public func concurrentPerform(iterations: Int, execute work: (Int) -> Void) {
    withoutActuallyEscaping(work) { work in
        nonisolated(unsafe) let shared = work
        DispatchQueue.concurrentPerform(iterations: iterations) { shared($0) }
    }
}
