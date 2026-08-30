import Testing
import simd

@testable import SillageRender

@Suite("Cinematography")
struct CinematographerTests {
    private let subject = Subject(
        centres: [SIMD3(-30, 0, 0), SIMD3(30, 6, -4)], radius: 46)

    /// Runs an hour of choreography at display rate and hands back every frame's camera.
    private func hour(seed: UInt64 = 5, minutes: Double = 60) -> [Camera] {
        let director = Cinematographer(seed: seed)
        director.beginScene(seed: seed)
        var cameras: [Camera] = []
        for _ in 0..<Int(minutes * 60 * 60) {
            director.advance(seconds: 1.0 / 60, of: subject)
            cameras.append(director.camera)
        }
        return cameras
    }

    /// The one property the whole mode rests on. A jump between two frames is a visible cut
    /// however smoothly everything else is drawn, so the eye must never move far in a
    /// sixtieth of a second — including across the joins between shots, which is exactly
    /// where an eased parameter that was not actually continuous would show.
    @Test func theCameraNeverJumps() {
        let cameras = hour()
        var worst: Float = 0
        var worstAim: Float = 0
        for index in 1..<cameras.count {
            worst = max(worst, simd_length(cameras[index].eye - cameras[index - 1].eye))
            let a = simd_normalize(cameras[index].target - cameras[index].eye)
            let b = simd_normalize(cameras[index - 1].target - cameras[index - 1].eye)
            worstAim = max(worstAim, simd_length(a - b))
        }
        // A twentieth of the scene radius in one frame would be three radii a second.
        #expect(worst < subject.radius / 20)
        #expect(worstAim < 0.02)
    }

    /// Slow is the brief. Nothing may cross the scene at speed.
    @Test func nothingMovesQuickly() {
        let cameras = hour()
        var total: Float = 0
        for index in 1..<cameras.count {
            total += simd_length(cameras[index].eye - cameras[index - 1].eye)
        }
        let perSecond = total / Float(cameras.count) * 60
        #expect(perSecond < subject.radius * 0.35)
    }

    @Test func everyKindOfShotIsUsed() {
        let director = Cinematographer(seed: 11)
        director.beginScene(seed: 11)
        var seen: Set<Cinematographer.Move> = []
        for _ in 0..<(90 * 60 * 60) {
            director.advance(seconds: 1.0 / 60, of: subject)
            seen.insert(director.move)
        }
        #expect(seen.count == Cinematographer.Move.allCases.count)
    }

    /// Two shots of the same kind running together is the thing that made an early cut read
    /// as four minutes of the same slow push.
    @Test func noKindFollowsItself() {
        let director = Cinematographer(seed: 23)
        director.beginScene(seed: 23)
        var order: [Cinematographer.Move] = []
        for _ in 0..<(120 * 60 * 60) {
            director.advance(seconds: 1.0 / 60, of: subject)
            if order.last != director.move { order.append(director.move) }
        }
        #expect(order.count > 8)
        for index in 1..<order.count { #expect(order[index] != order[index - 1]) }
    }

    /// Close is welcome; inside the bulge with the frame full of white is not.
    @Test func theCameraKeepsItsDistance() {
        let cameras = hour()
        var closest = Float.greatestFiniteMagnitude
        for camera in cameras {
            for centre in subject.centres {
                closest = min(closest, simd_length(camera.eye - centre))
            }
        }
        #expect(closest > subject.radius * 0.15)
    }

    /// Something has to be in the frame. A pan that swings onto a galaxy may leave the edge
    /// briefly — that reads as a deliberate move onto the subject — but a shot that sits on
    /// empty sky does not, and an early cut spent a minute doing exactly that.
    @Test func theSubjectIsNeverOffScreenForLong() {
        let director = Cinematographer(seed: 41)
        director.beginScene(seed: 41)
        var empty = 0
        var run = 0
        var longestRun = 0
        let frames = 60 * 60 * 60
        for _ in 0..<frames {
            director.advance(seconds: 1.0 / 60, of: subject)
            let camera = director.camera
            let aim = simd_normalize(camera.target - camera.eye)
            var best = Float.greatestFiniteMagnitude
            for centre in subject.centres {
                let toward = centre - camera.eye
                guard simd_length(toward) > 1e-4 else { continue }
                best = min(best, acos(min(max(simd_dot(aim, simd_normalize(toward)), -1), 1)))
            }
            if best > camera.fieldOfView / 2 {
                empty += 1
                run += 1
                longestRun = max(longestRun, run)
            } else {
                run = 0
            }
        }
        // Under a fiftieth of the time, and never more than a few seconds at a stretch.
        #expect(Double(empty) / Double(frames) < 0.02, "\(empty) frames of \(frames)")
        #expect(longestRun < 8 * 60, "\(longestRun) frames in a row")
    }

    /// The oscillators multiply the look, so a sign error anywhere would put out a negative
    /// exposure and a black frame rather than something obviously wrong.
    @Test func theLookStaysWithinItsSenses() {
        let director = Cinematographer(seed: 31)
        director.beginScene(seed: 31)
        for _ in 0..<(60 * 60 * 60) {
            director.advance(seconds: 1.0 / 60, of: subject)
            let look = director.look
            #expect(look.brightness > 0)
            #expect(look.smoothingScale > 0)
            #expect(look.stretch >= 0)
            #expect(look.saturation > 0)
            #expect(look.skyLevel >= 0)
            #expect(look.fieldOfView > 0.2 && look.fieldOfView < 1.2)
        }
    }

    /// Same seed, same film.
    @Test func aSeedFullyDeterminesTheFilm() {
        let a = hour(seed: 77, minutes: 20)
        let b = hour(seed: 77, minutes: 20)
        for index in stride(from: 0, to: a.count, by: 997) {
            #expect(simd_length(a[index].eye - b[index].eye) < 1e-4)
        }
    }
}
