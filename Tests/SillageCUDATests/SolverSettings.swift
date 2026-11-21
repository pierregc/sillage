import Testing

/// The solver's settings (`BarnesHutHost`) are global: a suite that moves them, or runs a solver
/// that reads them, holds them for each of its tests, so that a test of another suite cannot move
/// them under a run (#441).
struct SolverSettings: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? nil : self
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        if Self.holding { return try await function() }
        await Self.holder.acquire()
        do {
            try await Self.$holding.withValue(true) { try await function() }
        } catch {
            await Self.holder.release()
            throw error
        }
        await Self.holder.release()
    }

    @TaskLocal private static var holding = false
    private static let holder = Holder()

    private actor Holder {
        private var held = false
        private var waiting: [CheckedContinuation<Void, Never>] = []

        func acquire() async {
            if !held {
                held = true
                return
            }
            await withCheckedContinuation { waiting.append($0) }
        }

        func release() {
            if waiting.isEmpty { held = false } else { waiting.removeFirst().resume() }
        }
    }
}

extension Trait where Self == SolverSettings {
    static var solverSettings: Self { SolverSettings() }
}
