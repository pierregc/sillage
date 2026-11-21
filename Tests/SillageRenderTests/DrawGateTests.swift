import Testing

@testable import SillageCore
@testable import SillageRender

@Suite("Draw gate")
struct DrawGateTests {
    private func key(eye: Float = 1, time: Float = 0, epoch: Int = 0, width: Int = 100)
        -> DrawGate.Key
    {
        DrawGate.Key(
            camera: Camera(eye: SIMD3<Float>(eye, 0, 0)), time: time, playhead: 0, width: width,
            height: 50, epoch: epoch)
    }

    @Test func theFirstTickDraws() {
        var gate = DrawGate()
        #expect(gate.decide(key(), moving: false, grain: false, now: 0) == .active)
    }

    @Test func aStillPictureWithoutGrainStopsDrawingAfterTheSettle() {
        var gate = DrawGate()
        _ = gate.decide(key(), moving: false, grain: false, now: 0)
        #expect(gate.decide(key(), moving: false, grain: false, now: 0.3) == .active)
        #expect(gate.decide(key(), moving: false, grain: false, now: 0.9) == .skip)
        for tick in 0..<600 {
            let now = 1 + Double(tick) / 60
            #expect(gate.decide(key(), moving: false, grain: false, now: now) == .skip)
        }
    }

    @Test func aStillPictureWithGrainDrawsAtTheIdleRate() {
        var gate = DrawGate(idleInterval: 0.1, settle: 0.5)
        _ = gate.decide(key(), moving: false, grain: true, now: 0)
        var drawn = 0
        for tick in 0..<600 {
            let now = 1 + Double(tick) / 60
            if gate.decide(key(), moving: false, grain: true, now: now) == .refresh { drawn += 1 }
        }
        // Ten seconds of ticks at ten a second, rounded up to the next of sixty ticks.
        #expect((80...100).contains(drawn), "\(drawn)")
    }

    @Test func anyChangeOfTheKeyDrawsAtOnce() {
        for changed in [key(eye: 2), key(time: 1), key(epoch: 1), key(width: 101)] {
            var gate = DrawGate()
            _ = gate.decide(key(), moving: false, grain: false, now: 0)
            #expect(gate.decide(key(), moving: false, grain: false, now: 5) == .skip)
            #expect(gate.decide(changed, moving: false, grain: false, now: 6) == .active)
            #expect(gate.decide(changed, moving: false, grain: false, now: 9) == .skip)
        }
    }

    @Test func movingDrawsEveryTick() {
        var gate = DrawGate()
        for tick in 0..<120 {
            let now = Double(tick) / 60
            #expect(gate.decide(key(), moving: true, grain: false, now: now) == .active)
        }
        #expect(gate.decide(key(), moving: false, grain: false, now: 3) == .skip)
    }

    @Test func forceDrawsOnceMoreAndSettles() {
        var gate = DrawGate()
        _ = gate.decide(key(), moving: false, grain: false, now: 0)
        #expect(gate.decide(key(), moving: false, grain: false, now: 3) == .skip)
        gate.force()
        #expect(gate.decide(key(), moving: false, grain: false, now: 3.1) == .active)
        #expect(gate.decide(key(), moving: false, grain: false, now: 4) == .skip)
    }

    @Test func aWakeShowsAFinishedJobOnceWithoutSettling() {
        var gate = DrawGate()
        _ = gate.decide(key(), moving: false, grain: false, now: 0)
        #expect(gate.decide(key(), moving: false, grain: false, now: 3) == .skip)
        gate.wake()
        #expect(gate.decide(key(), moving: false, grain: false, now: 3.01) == .refresh)
        #expect(gate.decide(key(), moving: false, grain: false, now: 3.02) == .skip)
    }

    @Test func frozenGrainNeverRefreshes() {
        var gate = DrawGate(idleInterval: 0)
        _ = gate.decide(key(), moving: false, grain: true, now: 0)
        #expect(gate.decide(key(), moving: false, grain: true, now: 10) == .skip)
    }
}
