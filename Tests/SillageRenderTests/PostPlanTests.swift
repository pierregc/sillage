import Testing

@testable import SillageCore
@testable import SillageRender

/// The passes that turn the light into a picture, worked out once for both renderers (#277).
@Suite("Post-processing plan")
struct PostPlanTests {
    /// The names of a plan's passes, in order, with the levels they run at.
    static func names(_ plan: PostPlan) -> [String] {
        plan.passes.map { pass in
            switch pass {
            case .resolve(let factor): "resolve \(factor)"
            case .plainComposite(let factor, _): "plainComposite \(factor)"
            case .bright: "bright"
            case .downsample(let level): "down \(level)"
            case .upsample(let level, let source): "up \(level) from \(source)"
            case .compact(_, let broad): "compact \(broad)"
            case .spikes(_, let source, let into): "spikes \(source) into \(into)"
            case .composite(_, let bloom, let spikes): "composite \(bloom) \(spikes)"
            }
        }
    }

    static func settings(
        _ width: Int = 480, _ height: Int = 270, bloom: Float = 0.3, spikes: Int = 0,
        intensity: Float = 0.3, sharpness: Float = 0, levels: Int = 6
    ) -> RenderSettings {
        var settings = RenderSettings(width: width, height: height, supersample: 2)
        settings.bloomIntensity = bloom
        settings.bloomLevels = levels
        settings.spikeArms = spikes
        settings.spikeIntensity = intensity
        settings.spikeSharpness = sharpness
        return settings
    }

    @Test func theRawLookIsOneCompositeOfItsLightAndLeavesTheGrainAlone() {
        var settings = Self.settings()
        settings.plain = true
        settings.supersample = 1
        var grain = FrameGrain()
        let plan = PostPlan(settings: settings, fade: 0.5, grain: &grain)
        #expect(Self.names(plan) == ["plainComposite 1"])
        if case .plainComposite(_, let fade) = plan.passes[0] { #expect(fade == 0.5) }
        #expect(grain.seed == 1)
    }

    @Test func aFadeIsKeptBetweenZeroAndOne() {
        var grain = FrameGrain()
        for (asked, kept) in [(-3, 0), (0.25, 0.25), (7, 1)] as [(Float, Float)] {
            let plan = PostPlan(settings: Self.settings(), fade: asked, grain: &grain)
            guard case .composite(let composite, _, _) = plan.passes.last else {
                Issue.record("no composite")
                return
            }
            #expect(composite.fade == kept)
        }
    }

    @Test func bloomAloneGoesDownTheLevelsAndBackUp() {
        var grain = FrameGrain()
        let plan = PostPlan(settings: Self.settings(), fade: 1, grain: &grain)
        // 480 by 270 halves to 15 by 8 in five levels, where six were asked.
        #expect(plan.sizes.levels.count == 5)
        #expect(
            Self.names(plan) == [
                "resolve 2", "bright", "down 1", "down 2", "down 3", "down 4",
                "up 4 from down(4)", "up 3 from up(3)", "up 2 from up(2)", "up 1 from up(1)",
                "composite up(0) resolved",
            ])
    }

    @Test func noBloomAndNoSpikesIsTheLightAndTheComposite() {
        var grain = FrameGrain()
        let plan = PostPlan(
            settings: Self.settings(bloom: 0, spikes: 0), fade: 1, grain: &grain)
        #expect(Self.names(plan) == ["resolve 2", "composite resolved resolved"])
        guard case .composite(let composite, _, _) = plan.passes.last else { return }
        #expect(composite.bloomIntensity == 0 && composite.spikeIntensity == 0)
    }

    @Test func spikesWithoutBloomNeedTheFirstLevelAlone() {
        var grain = FrameGrain()
        let plan = PostPlan(
            settings: Self.settings(bloom: 0, spikes: 4), fade: 1, grain: &grain)
        #expect(
            Self.names(plan) == [
                "resolve 2", "bright", "spikes down(0) into spikes", "composite resolved spikes",
            ])
    }

    @Test func spikesSharpenedFromTheFourthLevelDown() {
        var grain = FrameGrain()
        let plan = PostPlan(
            settings: Self.settings(bloom: 0, spikes: 6, sharpness: 0.7), fade: 1, grain: &grain)
        #expect(
            Self.names(plan) == [
                "resolve 2", "bright", "down 1", "down 2", "down 3", "compact 3",
                "spikes sharpSource into sharpSpikes", "composite resolved sharpSpikes",
            ])
        guard case .compact(let amount, _) = plan.passes[5],
            case .spikes(let spike, _, _) = plan.passes[6]
        else {
            Issue.record("no compact or spikes")
            return
        }
        #expect(amount == 0.7)
        // The taps are at half the length, over as many samples as that asks for.
        #expect(spike.length == 36 && spike.samples == 28)
    }

    @Test func webbSpikesHaveTheirShortArms() {
        var settings = Self.settings(bloom: 0, spikes: 6)
        settings.spikePattern = .webb
        var grain = FrameGrain()
        let plan = PostPlan(settings: settings, fade: 1, grain: &grain)
        guard case .spikes(let spike, _, _) = plan.passes[2] else {
            Issue.record("no spikes")
            return
        }
        #expect(spike.shortArms == 2 && spike.shortScale == PostPlan.webbShortArm)
        #expect(spike.baseAngle == Float.pi / 2)
        #expect(spike.arms == 6 && spike.samples == 28)
    }

    @Test func spikesTooFaintToSeeAreNotDrawn() {
        var grain = FrameGrain()
        let plan = PostPlan(
            settings: Self.settings(bloom: 0, spikes: 6, intensity: PostPlan.spikeVisible / 2),
            fade: 1, grain: &grain)
        #expect(Self.names(plan) == ["resolve 2", "composite resolved resolved"])
    }

    @Test func theLevelsHalveDownToEightPixelsOrTheCountAsked() {
        let sizes = PostPlan.sizes(for: Self.settings(480, 270, levels: 12))
        #expect(sizes.levels.map(\.width) == [240, 120, 60, 30, 15])
        #expect(sizes.levels.map(\.height) == [135, 67, 33, 16, 8])
        #expect(sizes.light == PostPlan.Size(width: 960, height: 540))
        #expect(sizes.spikes == PostPlan.Size(width: 240, height: 135))
        #expect(sizes.sharp == PostPlan.Size(width: 120, height: 67))
        #expect(PostPlan.sizes(for: Self.settings(480, 270, levels: 2)).levels.count == 2)
        #expect(PostPlan.sizes(for: Self.settings(12, 12)).levels.isEmpty)
        #expect(sizes.size(of: .down(2)) == PostPlan.Size(width: 60, height: 33))
        #expect(sizes.size(of: .output) == PostPlan.Size(width: 480, height: 270))
    }

    @Test func aFrameSmallerThanItsLevelsStillComposes() {
        var grain = FrameGrain()
        let plan = PostPlan(settings: Self.settings(12, 12, spikes: 4), fade: 1, grain: &grain)
        #expect(
            Self.names(plan) == [
                "resolve 2", "spikes resolved into spikes", "composite resolved spikes",
            ])
    }

    @Test func eachFrameMovesTheGrainOn() {
        var grain = FrameGrain()
        var seeds: [Float] = []
        for _ in 0..<3 {
            let plan = PostPlan(settings: Self.settings(), fade: 1, grain: &grain)
            if case .composite(let composite, _, _) = plan.passes.last { seeds.append(composite.seed) }
        }
        #expect(seeds.count == 3 && Set(seeds).count == 3)
        #expect(seeds[0] == Float(1).truncatingRemainder(dividingBy: 4096) + 7.13)
        #expect(seeds[1] == seeds[0].truncatingRemainder(dividingBy: 4096) + 7.13)
        #expect(grain.seed == seeds[2])
    }

    @Test func skippingFramesIsDrawingThem() {
        var drawn = FrameGrain()
        for _ in 0..<7 { drawn.advance() }
        var skipped = FrameGrain()
        skipped.skip(7)
        #expect(skipped.seed == drawn.seed)
        skipped.skip(-3)
        #expect(skipped.seed == drawn.seed)
    }

    @Test func theGrainWrapsBeforeFourThousandAndNinetySix() {
        var grain = FrameGrain()
        grain.skip(1000)
        #expect(grain.seed < 4096 + 8)
        #expect(grain.seed > 0)
    }

    @Test func aPaletteWithoutARampLeavesTheLookAsItWas() {
        var palette = GalaxyPalette(slots: 4)
        #expect(!palette.mapped)
        #expect(palette.ramps.count == 4)
        let changed = palette.set([])
        #expect(!changed, "the palette held is the empty one")
    }
}
