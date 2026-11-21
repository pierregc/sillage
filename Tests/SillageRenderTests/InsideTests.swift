import Foundation
import SillageCore
import Testing

@testable import SillageRender

#if canImport(simd)
    import simd
#endif

@Suite("Inside a galaxy")
struct InsideTests {
    @Test func aFlightFileTakesItsInsideSettingsOrTheChosenOnes() throws {
        let plain = try FlightFile.decoded(
            from: Data(
                #"{"version": 1, "keys": [{"at": 0, "myr": 1, "look": true}, {"at": 1, "myr": 2, "look": true}]}"#
                    .utf8))
        #expect(plain.inside == nil && plain.near == nil)
        let text = #"""
            {"version": 1, "inside": {"stars": 64, "exposure": 0, "subframes": 1, "field": [2, 5]},
             "keys": [{"at": 0, "myr": 1, "look": true}, {"at": 1, "myr": 2, "look": true}]}
            """#
        let file = try FlightFile.decoded(from: Data(text.utf8))
        var wanted = InsideSettings()
        wanted.stars = 64
        wanted.exposure = 0
        wanted.subframes = 1
        wanted.field = [2, 5]
        #expect(file.inside == wanted)
        #expect(try FlightFile.decoded(from: file.encoded()) == file)
        // Strict, as the rest of the file is.
        let stray = text.replacingOccurrences(of: "\"stars\"", with: "\"star\"")
        #expect(throws: (any Error).self) { try FlightFile.decoded(from: Data(stray.utf8)) }
        let wrong = text.replacingOccurrences(of: "[2, 5]", with: "[5, 2]")
        #expect(throws: FlightFile.ReadError.self) { try FlightFile.decoded(from: Data(wrong.utf8)) }
        #expect(InsideSettings().fault == nil)
        var faulty = InsideSettings()
        faulty.slabs = [0.3, 0.2, 7]
        #expect(faulty.fault?.contains("slabs") == true)
    }

    private func frame(_ nearness: Float) -> InsideFrame {
        InsideFrame(settings: InsideSettings(), nearness: nearness)
    }

    private func uniforms(_ nearness: Float, camera: Camera) -> (splat: SplatUniforms, inside: InsideUniforms)
    {
        let settings = RenderSettings(width: 1920, height: 1080, supersample: 2, maximumKernel: 92)
        let plan = FramePlan(
            settings: settings, camera: camera, time: 0, drawnCount: 1000, tracerCount: 0,
            luminosityNormalisation: 1, mapped: false, laceScale: nil)
        return (
            plan.splat, InsideUniforms(frame(nearness), camera: camera, settings: settings, splat: plan.splat)
        )
    }

    /// Far from any matter the slabs are the stack every export has, hard; inside they start
    /// from the eye at the settings' distances, soft; and they slide between the two.
    @Test func theSlabsSlideFromTheAimPointsStackToTheEyes() {
        let camera = Camera(eye: SIMD3(0, -100, 0), target: .zero, near: 0.001)
        let far = uniforms(50, camera: camera)
        let thickness = 1 / far.splat.slabScale
        for index in 0..<4 {
            let wanted = far.splat.slabNear + Float(index) * thickness / 4
            #expect(abs(far.inside.slabKnots[index] - wanted) < 1e-3 * wanted)
        }
        #expect(abs(far.inside.slabEnd - (far.splat.slabNear + thickness)) < 1e-3 * far.inside.slabEnd)
        #expect(far.inside.slabSoft == 0)

        let near = uniforms(0.2, camera: camera)
        #expect(abs(near.inside.slabKnots[1] - 0.3) < 1e-4)
        #expect(abs(near.inside.slabKnots[2] - 1.5) < 1e-4)
        #expect(abs(near.inside.slabKnots[3] - 7.5) < 1e-3)
        #expect(near.inside.slabKnots[0] < 0.3 && near.inside.slabEnd > 7.5 && near.inside.slabSoft == 1)

        let between = uniforms(3, camera: camera)
        #expect(between.inside.slabSoft > 0 && between.inside.slabSoft < 1)
        for index in 1..<4 {
            #expect(between.inside.slabKnots[index] > near.inside.slabKnots[index])
            #expect(between.inside.slabKnots[index] < far.inside.slabKnots[index])
            #expect(between.inside.slabKnots[index] > between.inside.slabKnots[index - 1])
        }
    }

    /// A flight lays its slabs on the matter in the frame past the near field, soft, at every
    /// distance and wherever it aims, but on the look's own camera (#355).
    @Test func aFlightsSlabsStayOnTheMatterInTheFrame() {
        var generator = SeededGenerator(seed: 5)
        var points = (0..<200_000).map { _ in
            SIMD3<Float>(
                generator.uniform() * 8 - 4, generator.uniform() * 20 - 10, generator.uniform() * 8 - 4)
        }
        // Off the frame, where nothing counts.
        points += (0..<50_000).map { _ in SIMD3<Float>(400, generator.uniform() * 100, 0) }
        func knots(_ camera: Camera) -> [Float] {
            points.withUnsafeBytes {
                MatterDepth.knots(
                    camera: camera, aspectRatio: 16 / 9, points: $0.baseAddress!, count: points.count)!
            }
        }
        let near = knots(Camera(eye: SIMD3(0, -100, 0), target: .zero, fieldOfView: 0.6, near: 0.001))
        // From the second to the ninety-eighth percentile of 90 to 110 kpc, 19.2 kpc deep.
        let slab = 0.75 * Float(19.2)
        for index in 0..<5 {
            #expect(abs(near[index] - (100 + slab * Float(index - 2))) < 0.1, "\(near)")
        }
        // Twice as far and aimed aside, the slabs keep their place in the matter.
        let far = knots(Camera(eye: SIMD3(0, -200, 0), target: SIMD3(8, 0, 3), fieldOfView: 0.6, near: 0.001))
        for index in 0..<5 { #expect(abs(far[index] - near[index] - 100) < 0.4, "\(far)") }

        let settings = RenderSettings(width: 1920, height: 1080, supersample: 2, maximumKernel: 92)
        let camera = Camera(eye: SIMD3(0, -100, 0), target: .zero, near: 0.001)
        let plan = FramePlan(
            settings: settings, camera: camera, time: 0, drawnCount: 1000, tracerCount: 0,
            luminosityNormalisation: 1, mapped: false, laceScale: nil)
        func inside(look: Float) -> InsideUniforms {
            InsideUniforms(
                InsideFrame(settings: InsideSettings(), nearness: 50, matter: near, look: look),
                camera: camera, settings: settings, splat: plan.splat)
        }
        let flying = inside(look: 0)
        #expect(
            flying.slabSoft == 1 && abs(flying.slabKnots[1] - near[1]) < 1e-3
                && abs(flying.slabEnd - near[4]) < 1e-3)
        let onLook = inside(look: 1)
        let aim = uniforms(50, camera: camera).inside
        #expect(onLook.slabSoft == 0 && onLook.slabKnots == aim.slabKnots && onLook.slabEnd == aim.slabEnd)
        let leaving = inside(look: 0.5)
        #expect(leaving.slabSoft == 0.5)
        // Inside, the eye's slabs whatever the matter.
        let within = InsideUniforms(
            InsideFrame(settings: InsideSettings(), nearness: 0.2, matter: near),
            camera: camera, settings: settings, splat: plan.splat)
        #expect(abs(within.slabKnots[2] - 1.5) < 1e-4 && within.slabSoft == 1)

        // Near enough that the matter reaches the eye, the stack still follows it: its first
        // knot behind the eye rather than stopped at the near plane (#396).
        let close = knots(Camera(eye: SIMD3(0, -12, 0), target: .zero, fieldOfView: 0.6, near: 0.001))
        #expect(close[0] < 0 && close[2] > 10 && close[2] < 22, "\(close)")
        for index in 1..<5 {
            #expect(abs((close[index] - close[index - 1]) - (close[1] - close[0])) < 1e-3, "\(close)")
        }
    }

    /// Between the matter's slabs and the eye's, a render is drawn with either stack as asked,
    /// for the renderer to dissolve them, and never slides one into the other (#396).
    @Test func aFrameBetweenTheStacksIsDrawnWithEither() {
        let settings = RenderSettings(width: 1920, height: 1080, supersample: 2, maximumKernel: 92)
        let camera = Camera(eye: SIMD3(0, -12, 0), target: .zero, near: 0.001)
        let plan = FramePlan(
            settings: settings, camera: camera, time: 0, drawnCount: 1000, tracerCount: 0,
            luminosityNormalisation: 1, mapped: false, laceScale: nil)
        let matter: [Float] = [-16.8, -2.4, 12, 26.4, 40.8]
        func inside(_ eyeSlabs: Float?) -> InsideUniforms {
            InsideUniforms(
                InsideFrame(settings: InsideSettings(), nearness: 3, matter: matter, eyeSlabs: eyeSlabs),
                camera: camera, settings: settings, splat: plan.splat)
        }
        let theMatters = inside(0)
        #expect(theMatters.slabKnots == SIMD4(matter[0], matter[1], matter[2], matter[3]))
        #expect(theMatters.slabEnd == matter[4] && theMatters.slabSoft == 1)
        let theEyes = inside(1)
        #expect(theEyes.slabKnots[1] == 0.3 && theEyes.slabKnots[2] == 1.5 && theEyes.slabKnots[3] == 7.5)
        #expect(theEyes.slabSoft == 1)
        let depth = InsideUniforms.depth(InsideFrame(settings: InsideSettings(), nearness: 3))
        #expect(depth > 0 && depth < 1)
        // Asked for neither, a knot behind the eye still blends to finite, rising knots.
        let sliding = inside(nil)
        let all = [
            sliding.slabKnots[0], sliding.slabKnots[1], sliding.slabKnots[2], sliding.slabKnots[3],
            sliding.slabEnd,
        ]
        #expect(all.allSatisfy(\.isFinite) && zip(all, all.dropFirst()).allSatisfy { $0 < $1 }, "\(all)")
    }

    @Test func theUniformsCarryTheSettingsInAccumulationPixels() {
        let camera = Camera(eye: SIMD3(0, -10, 0), target: .zero, fieldOfView: 0.6, near: 0.001)
        let inside = uniforms(1, camera: camera).inside
        #expect(inside.nearPlane == 0.001 && inside.starCount == 128)
        #expect(abs(inside.starStart - 0.05 * 92 * 2) < 1e-4 && abs(inside.starEnd - 0.2 * 92 * 2) < 1e-4)
        // A star is 1.5 pixels of a frame 2160 high: 1.5 of the 2160 lines this one accumulates.
        #expect(inside.starPointSize == 1.5)
        #expect(inside.nearStars == 4096 && abs(inside.nearFrom - 0.3 * 2160) < 1e-3)
        // Its light is held to what takes one output pixel to twice its white: a stretch of 10
        // and a white point of 2.2 put white at an energy of 19.4.
        var look = RenderSettings(width: 1920, height: 1080, supersample: 2, maximumKernel: 92)
        look.stretch = 10
        look.whitePoint = 2.2
        let cap = InsideUniforms.cap(peak: 2, size: 1.5, scale: 2, settings: look)
        #expect(abs(cap * 0.1736 * 1.5 * 1.5 / 4 - 2 * 19.445) < 0.05, "\(cap)")
        #expect(abs(inside.projectionY - 1 / tan(0.3)) < 1e-5)
        #expect(abs(inside.projectionX - inside.projectionY * 1080 / 1920) < 1e-5)
        // The shares add up to the particle's light.
        for exponent in [Float(0), 1, 2] {
            let norm = InsideUniforms.shareNorm(stars: 128, exponent: exponent)
            let total = (1...128).reduce(Float(0)) {
                $0 + (exponent > 0 ? pow(Float($1), -exponent) : 1) * norm
            }
            #expect(abs(total - 1) < 0.01, "exponent \(exponent): \(total)")
        }
    }

    /// The dust's trim (#356) comes in with the eye near matter and is nowhere else; the fine
    /// dust's settings go through as they are.
    @Test func theDustIsTrimmedOnlyOnceTheEyeIsInside() {
        let camera = Camera(eye: SIMD3(0, -10, 0), target: .zero, fieldOfView: 0.6, near: 0.001)
        #expect(uniforms(50, camera: camera).inside.dustThin == 0)
        #expect(uniforms(2, camera: camera).inside.dustThin == 0)
        #expect(abs(uniforms(0.3, camera: camera).inside.dustThin - 0.7) < 1e-6)
        let halfway = uniforms(1.25, camera: camera).inside.dustThin
        #expect(halfway > 0 && halfway < 0.7, "\(halfway)")
        let inside = uniforms(0.3, camera: camera).inside
        #expect(inside.dustFine == 1.75 && inside.dustCell == 0.12)
        #expect(InsideUniforms(outside: uniforms(0.3, camera: camera).splat).dustThin == 0)
        #expect(InsideUniforms(outside: uniforms(0.3, camera: camera).splat).dustFine == 0)
        var faulty = InsideSettings()
        faulty.dustWithin = [2, 0.5]
        #expect(faulty.fault?.contains("dustWithin") == true)
        faulty = InsideSettings()
        faulty.dustFine = 3
        #expect(faulty.fault?.contains("dustFine") == true)
    }

    /// The clusters young stars gather in (#405) go to the kernels in kiloparsecs, on by
    /// default, and a flight file can turn them off or reshape them.
    @Test func theClustersGoThroughInKiloparsecs() throws {
        let camera = Camera(eye: SIMD3(0, -10, 0), target: .zero, fieldOfView: 0.6, near: 0.001)
        let inside = uniforms(0.3, camera: camera).inside
        #expect(inside.clusterCentres == 4 && inside.clusterShare == 0.8)
        #expect(abs(inside.clusterBirth - 0.003) < 1e-9 && abs(inside.clusterGrowth - 0.001) < 1e-9)
        #expect(InsideUniforms(outside: uniforms(0.3, camera: camera).splat).clusterCentres == 0)
        let read = try JSONDecoder().decode(
            InsideSettings.self, from: Data(#"{"clusters": 0, "clusterBirth": 5, "clusterShare": 1}"#.utf8))
        #expect(
            read.clusters == 0 && read.clusterBirth == 5 && read.clusterGrowth == 1 && read.clusterShare == 1)
        var faulty = InsideSettings()
        faulty.clusters = 9
        #expect(faulty.fault?.contains("clusters") == true)
        faulty = InsideSettings()
        faulty.clusterShare = 1.5
        #expect(faulty.fault?.contains("clusterShare") == true)
        faulty = InsideSettings()
        faulty.clusterBirth = 0
        #expect(faulty.fault?.contains("clusterBirth") == true)
    }

    @Test func nearnessIsTheDistanceTheRankedParticleStandsAt() {
        var generator = SeededGenerator(seed: 11)
        let points = (0..<300_000).map { _ in
            SIMD3<Float>(
                generator.uniform() * 40 - 20, generator.uniform() * 40 - 20, generator.uniform() * 4 - 2)
        }
        let eye = SIMD3<Float>(3, -7, 0.5)
        let sorted = points.map { simd_length($0 - eye) }.sorted()
        points.withUnsafeBytes { bytes in
            let base = bytes.baseAddress!
            for rank in [1, 30, 2_999, 300_000] {
                let found = Nearness.distance(from: eye, to: base, count: points.count, rank: rank)
                #expect(abs(found - sorted[rank - 1]) <= 1e-5 * sorted[rank - 1], "rank \(rank)")
            }
            #expect(Nearness.distance(from: eye, to: base, count: points.count) == sorted[29])
            // Moving the eye moves it by no more than the eye moved.
            let moved = Nearness.distance(from: eye + SIMD3(0.5, 0, 0), to: base, count: points.count)
            #expect(abs(moved - sorted[29]) <= 0.5 + 1e-4)
        }
        #expect(Nearness.rank(of: 8_000_000) == 800 && Nearness.rank(of: 50) == 1)
    }

    @Test func aFrameIsAveragedFromMoreRendersTheFasterItPassesNearMatter() {
        func camera(_ x: Float, aim: SIMD3<Float> = SIMD3(0, 100, 0)) -> Camera {
            Camera(eye: SIMD3(x, 0, 0), target: SIMD3(x, 0, 0) + aim, near: 0.001)
        }
        let near = frame(0.2)
        // At rest, none: the frame is drawn once through its own camera.
        #expect(InsideBlur.subframes(from: camera(0), to: camera(0), frame: near, height: 1080) == 0)
        // A tenth of a parsec during the shutter, 200 pc from matter: 1 745 px a radian, under
        // a pixel, one render with its streaks. A parsec, 9 pixels: three.
        let slow = InsideBlur.subframes(from: camera(0), to: camera(0.0001), frame: near, height: 1080)
        let fast = InsideBlur.subframes(from: camera(0), to: camera(0.001), frame: near, height: 1080)
        #expect(slow == 1 && fast == 3)
        // The same move far from everything is the frame itself, and so is a turn out there.
        let far = frame(60)
        #expect(InsideBlur.subframes(from: camera(0), to: camera(0.001), frame: far, height: 1080) == 0)
        let turned = camera(0, aim: SIMD3(2, 100, 0))
        #expect(InsideBlur.subframes(from: camera(0), to: turned, frame: far, height: 1080) == 0)
        #expect(InsideBlur.subframes(from: camera(0), to: turned, frame: near, height: 1080) == 8)
        var settings = InsideSettings()
        settings.subframes = 1
        let single = InsideFrame(settings: settings, nearness: 0.2)
        #expect(InsideBlur.subframes(from: camera(0), to: camera(1), frame: single, height: 1080) == 0)
    }

    /// A frame under the target keeps its exposure; one over it is brought down to it in a few
    /// draws, the tone curve making the mean fall by less than a stop per stop.
    @Test func theExposureOnlyDarkensAndLandsOnItsTarget() {
        var draws = 0
        func mean(_ brightness: Double) -> (Double) -> Double {
            { stops in
                draws += 1
                return min(brightness * pow(2, -0.7 * stops), 1)
            }
        }
        #expect(InsideExposure.solve(target: 0.16, draw: mean(0.05)) == 0)
        #expect(draws == 1)
        for brightness in [0.2, 0.5, 0.9, 6.0] {
            draws = 0
            let stops = InsideExposure.solve(target: 0.16, draw: mean(brightness))
            let landed = brightness * pow(2, -0.7 * stops)
            #expect(abs(landed / 0.16 - 1) <= InsideExposure.tolerance + 1e-9, "\(brightness): \(landed)")
            #expect(draws <= 6, "\(brightness): \(draws) draws")
        }
        // From the trim of the moment before, a draw is enough.
        draws = 0
        let wanted = log2(0.5 / 0.16) / 0.7
        #expect(abs(InsideExposure.solve(target: 0.16, guess: wanted, draw: mean(0.5)) - wanted) < 1e-9)
        #expect(draws == 1)
        // Too bright for the deepest trim: it stops there.
        #expect(InsideExposure.solve(target: 0.16) { _ in 1 } == InsideExposure.deepest)
        #expect(InsideExposure.solve(target: 0, draw: mean(0.9)) == 0)

        var look = RenderLook()
        look.brightness = 0.8
        look.stretch = 10
        let trimmed = InsideExposure.trimmed(look, stops: 2)
        #expect(abs(trimmed.brightness - 0.2) < 1e-6)
        #expect(abs(trimmed.stretch - 10 * pow(2, -2 * 1.9 / 1.3)) < 1e-5)
        #expect(InsideExposure.trimmed(look, stops: 0) == look)
        #expect(abs(InsideExposure.meanLuminance(rgba: [255, 255, 255, 255, 0, 0, 0, 255]) - 0.5) < 1e-9)
    }

    @Test func theTrimIsEasedAndLeavesTheLooksOwnFramesAlone() {
        let step = 0.25
        // Nothing for two seconds, then three stops.
        let stops = InsideExposure.Track.moments(seconds: 6, step: step).map { $0 < 2 ? 0.0 : 3.0 }
        let eased = InsideExposure.Track(step: step, stops: stops, ease: 1)
        #expect(eased.stops(atSeconds: 0.5) == 0)
        #expect(abs(eased.stops(atSeconds: 4) - 3) < 1e-9)
        var previous = 0.0
        for index in 0...600 {
            let now = eased.stops(atSeconds: Double(index) / 100)
            #expect(now >= previous - 1e-9 && now - previous < 0.05)
            previous = now
        }
        #expect(eased.deepest == 3)
        // On the look's own camera, none; and it comes on from there without a step.
        let held = InsideExposure.Track(step: step, stops: stops.map { _ in 3 }, ease: 1, still: [0...2.5])
        #expect(held.stops(atSeconds: 0) == 0 && held.stops(atSeconds: 2.5) == 0)
        #expect(held.stops(atSeconds: 2.51) < 0.01)
        #expect(abs(held.stops(atSeconds: 3.5) - 3) < 1e-9)
        let sharp = InsideExposure.Track(step: step, stops: stops, ease: 0)
        #expect(sharp.stops(atSeconds: 1.75) == 0 && sharp.stops(atSeconds: 2) == 3)
    }

    private func take() -> FlightTake {
        FlightTake(
            megayears: (0...100).map { 200 + Double($0) }, capturedRate: 10, galaxies: 1,
            centres: { _ in [.zero] },
            disks: { _ in [[SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]] })
    }

    @Test func aFlightsCameraComesWithinAParsecAndBlursOffItsLookKeys() throws {
        let look = Camera(eye: SIMD3(0, -100, 30), target: .zero)
        let file = FlightFile(keys: [
            .init(at: 0, myr: 200, look: true),
            .init(at: 2, myr: 220, look: true),
            .init(at: 4, eye: .world(SIMD3(0, -1, 0.05)), aim: .world(.zero)),
            .init(at: 6, myr: 220, eye: .world(SIMD3(1, 0, 0.05))),
        ])
        let flight = try Flight(file, take: take(), look: { _ in look })
        #expect(flight.near == 0.001 && flight.inside == InsideSettings())
        #expect(flight.camera(atSeconds: 1).camera.near == 0.001)
        #expect(flight.lookSpans == [0...2])
        #expect(flight.look(atSeconds: 1) == 1 && flight.look(atSeconds: 2) == 1)
        #expect(flight.look(atSeconds: 2.5) == 0.5 && flight.look(atSeconds: 3) == 0)
        let near = InsideFrame(settings: flight.inside, nearness: 0.1)
        // On the look's camera, one render whatever moves.
        #expect(flight.cameras(atSeconds: 1, interval: 1.0 / 30, frame: near, height: 1080).count == 1)
        // Flying past matter, the ends of eight shares of the shutter, about the frame's moment.
        let views = flight.cameras(atSeconds: 5, interval: 1.0 / 30, frame: near, height: 1080)
        #expect(views.count == 9)
        let middle = flight.camera(atSeconds: 5).camera.eye
        #expect(simd_length(views[4].eye - middle) < 1e-6)
        let open = flight.camera(atSeconds: 5 - 1.0 / 120).camera.eye
        #expect(simd_length(views[0].eye - open) < 1e-6 && simd_length(views[0].eye - views[8].eye) > 0)
        var kept = file
        kept.near = 0.5
        #expect(try Flight(kept, take: take(), look: { _ in look }).near == 0.5)
    }
}
