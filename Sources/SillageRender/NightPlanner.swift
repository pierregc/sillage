import Foundation

/// One scene as a night plans it: a draw not explored yet, sized by `ExploreProbe`, or a
/// scene explored, sized from its own files.
public struct NightScene: Sendable, Equatable {
    public var name: String?
    public var score: Double?
    /// Particle steps of its exploration, settle included.
    public var exploreUnits: Double
    /// Visible particle steps of its hires at the night's size, settle included.
    public var hiresUnits: Double
    /// Frames its hires captures, which each export draws.
    public var frames: Int

    public init(
        name: String?, score: Double?, exploreUnits: Double, hiresUnits: Double, frames: Int
    ) {
        self.name = name
        self.score = score
        self.exploreUnits = exploreUnits
        self.hiresUnits = hiresUnits
        self.frames = frames
    }
}

/// What a night's folder holds already: a night planned again as it goes, or resumed, counts
/// what is done as done.
public struct NightProgress: Sendable, Equatable {
    /// The count a galaxy a batch started with keeps, from its `batch.conf`.
    public var perGalaxy: Int?
    /// Scenes explored, each with its score and its hires at the night's size.
    public var explored: [NightScene] = []
    public var exploreDone = false
    /// Once the pick is made, best first.
    public var picks: [String]?
    public var hiresDone: Set<String> = []
    public var styled: Set<String> = []
    /// `<scene>/<format>`.
    public var exported: Set<String> = []
    /// Scenes skipped by hand or for want of time: nothing more is done to them tonight.
    public var skipped: Set<String> = []

    public init() {}
}

/// Every step of a night with its duration, start and end, and when the whole night is done.
public struct NightPlan: Codable, Sendable, Equatable {
    public enum Phase: String, Codable, Sendable, CaseIterable { case explore, pick, hires, style, export }

    public struct Step: Codable, Sendable, Equatable {
        public var phase: Phase
        /// The scene, or `pick 1`, `pick 2` before the pick is made.
        public var scene: String?
        /// Explore: the scenes. Pick: how many.
        public var count: Int?
        /// Explore: a galaxy. Hires: in all.
        public var particles: Int?
        /// Export: the preset, `webp` or `gif`.
        public var format: String?
        public var seconds: Double
        public var start: Date
        public var end: Date
        /// Nothing left to compute.
        public var done: Bool
        /// Whether it will start: a hires whose scene cannot be finished by the delivery time
        /// does not, nor its style and exports, nor a style or export past the grace.
        public var fits: Bool
    }

    public struct Warning: Codable, Sendable, Equatable {
        /// `disk`, `late` or `explore`.
        public var kind: String
        public var message: String
    }

    /// One line a phase, as the new night sheet shows it.
    public struct Summary: Codable, Sendable, Equatable {
        public var phase: Phase
        public var count: Int
        public var seconds: Double
        public var start: Date
        public var end: Date
    }

    public var start: Date
    public var deliverBy: Date
    /// When the last step that starts ends.
    public var end: Date
    public var scenes: Int
    public var particlesPerGalaxy: Int
    /// How long exploring may go on before it eats into the time the picks need.
    public var exploreBudget: Double
    public var picks: Int
    public var hiresParticles: Int
    public var exports: [String]
    public var steps: [Step]
    /// What the steps left will write, previews, takes and videos.
    public var diskBytes: Double
    public var freeBytes: Double?
    public var warnings: [Warning]

    public var summaries: [Summary] {
        Phase.allCases.compactMap { phase in
            let mine = steps.filter { $0.phase == phase && $0.fits }
            guard let first = mine.first, let last = mine.last else { return nil }
            let count =
                switch phase {
                case .explore: first.count ?? 0
                case .pick: first.count ?? 0
                default: mine.count
                }
            return Summary(
                phase: phase, count: count, seconds: mine.reduce(0) { $0 + $1.seconds },
                start: first.start, end: last.end)
        }
    }

    public func encoded() throws -> Data { try RunStatus.encoder().encode(self) }
}

/// Turns a recipe, the cost model of #122 and what the folder holds into a plan. Pure: the
/// draws are handed in, and the clock.
public struct NightPlanner: Sendable {
    /// How far past the delivery time a style or an export may still end, and the night may
    /// run at all.
    public static let grace: TimeInterval = 15 * 60
    /// The fewest a pick takes.
    public static let minimumScenes = 2
    /// How many draws a plan sizes an exploration from, as `explore-batch.sh --hours` does.
    public static let sample = 16
    /// A raw preview at 960x540, as `explore-batch.sh` counts it.
    public static let previewBytes = 40e6
    /// 2.76 GB for 2 M particles over 900 frames at the take interval of 4 (`hires.json` of
    /// 2026-10-25).
    public static let takeBytesPerParticleFrame = 1.533
    /// Promoting a look; drawing palettes from the scene's seed and scoring them.
    public static let styleSeconds = 2.0
    public static let paletteSeconds = 20.0
    /// An animated WebP or GIF of eight seconds.
    public static let previewSeconds = 30.0

    public var recipe: NightRecipe
    public var model: CostModel
    public var maximumParticles: Int
    /// The first draws of the batch at a count a galaxy, sized for this night's hires.
    public var draws: @Sendable (_ perGalaxy: Int) -> [NightScene]
    public var progress: NightProgress
    public var freeBytes: Double?

    public init(
        recipe: NightRecipe, model: CostModel, maximumParticles: Int = SceneFolder.maximumParticles(),
        progress: NightProgress = NightProgress(), freeBytes: Double? = nil,
        draws: @escaping @Sendable (_ perGalaxy: Int) -> [NightScene]
    ) {
        self.recipe = recipe
        self.model = model
        self.maximumParticles = maximumParticles
        self.progress = progress
        self.freeBytes = freeBytes
        self.draws = draws
    }

    public var hiresParticles: Int { recipe.hiresParticles(maximum: maximumParticles) }

    // MARK: Costs

    /// One explored scene's share of a batch's wall clock, scenes running side by side.
    public func exploreSeconds(_ scene: NightScene) -> Double {
        model.explore.seconds(scene.exploreUnits)
    }

    public func hiresSeconds(_ scene: NightScene) -> Double { model.hires.seconds(scene.hiresUnits) }

    public var styleSeconds: Double {
        recipe.style.palette.value != nil || recipe.style.world.value != nil
            ? Self.paletteSeconds : Self.styleSeconds
    }

    public func exportSeconds(_ format: String, frames: Int) -> Double {
        guard let preset = VideoPreset.named(format) else { return Self.previewSeconds }
        return model.exportSeconds(preset: preset, codec: preset.defaultCodec, frames: frames)
    }

    /// Everything after the pick for one scene.
    public func finishSeconds(_ scene: NightScene) -> Double {
        hiresSeconds(scene) + styleSeconds
            + recipe.exports.reduce(0) { $0 + exportSeconds($1, frames: scene.frames) }
    }

    public static func videoBytes(_ format: String, frames: Int, fps: Int = 30) -> Double {
        guard let preset = VideoPreset.named(format) else { return 10e6 }
        let codec = preset.codec ?? preset.defaultCodec
        let rate =
            preset.bitsPerSecond ?? codec.defaultBitRate(width: preset.width, height: preset.height)
            ?? preset.width * preset.height * 36
        let bytes = Double(rate) * Double(frames) / Double(fps) / 8
        return preset.maxBytes.map { min(bytes, Double($0)) } ?? bytes
    }

    /// The draws' mean, or a nominal scene when the filters keep none in the sample.
    func typical(perGalaxy: Int) -> NightScene {
        let found = draws(perGalaxy)
        guard !found.isEmpty else {
            let particles = 2.5 * Double(perGalaxy)
            let hires = Double(hiresParticles)
            return NightScene(
                name: nil, score: nil, exploreUnits: particles * 6_000,
                hiresUnits: hires * 12_000 * (hires / 2e6).squareRoot(), frames: 1_125)
        }
        let count = Double(found.count)
        return NightScene(
            name: nil, score: nil,
            exploreUnits: found.reduce(0) { $0 + $1.exploreUnits } / count,
            hiresUnits: found.reduce(0) { $0 + $1.hiresUnits } / count,
            frames: Int((Double(found.reduce(0) { $0 + $1.frames }) / count).rounded()))
    }

    /// What is kept back from a night for estimates gone wrong: a twentieth, five to twenty
    /// minutes.
    public static func margin(_ seconds: TimeInterval) -> TimeInterval {
        min(max(seconds * 0.05, 300), 1_200)
    }

    // MARK: Picks

    /// The scenes a pick takes from, best first: Pierre's own yes first, then the score's;
    /// a scene he said no to is never taken.
    public static func ranked(_ scenes: [NightScene]) -> [NightScene] {
        scenes.sorted {
            let (a, b) = ($0.score ?? -.infinity, $1.score ?? -.infinity)
            return a != b ? a > b : ($0.name ?? "") < ($1.name ?? "")
        }
    }

    /// Auto: between two and four scenes, as many of the best as can be finished from `start`
    /// before the delivery time, and never fewer than two when two were explored.
    public func autoPicks(_ ranked: [NightScene], from start: Date, deliverBy: Date) -> Int {
        let available = deliverBy.timeIntervalSince(start)
        for count in NightRecipe.pickRange.reversed() where count <= ranked.count {
            if ranked.prefix(count).reduce(0, { $0 + finishSeconds($1) }) <= available {
                return count
            }
        }
        return min(NightRecipe.pickRange.lowerBound, ranked.count)
    }

    // MARK: Sizing

    struct Sizing {
        var scenes: Int
        var perGalaxy: Int
        var picks: Int
        var budget: Double
    }

    /// The exploration's size and the picks it leaves room for. Auto keeps time for four
    /// picks, then three, then two, and within that explores fifty scenes at the largest
    /// count a galaxy that fits; failing that, fewer scenes at the smallest count.
    func sizing(now: Date, deliverBy: Date) -> Sizing {
        let explored = progress.explored.count
        let fixedCount = progress.perGalaxy ?? recipe.explore.particlesPerGalaxy.value
        let fixedScenes = recipe.explore.scenes.value
        let total = deliverBy.timeIntervalSince(now)
        let available = total - Self.margin(total)
        let ladder = NightRecipe.perGalaxyLadder
        let finish = finishSeconds(typical(perGalaxy: fixedCount ?? ladder[0]))
        let counts: [Int] =
            switch recipe.pick {
            case .none: [0]
            case .count(let count): [count]
            case .auto: NightRecipe.pickRange.reversed()
            }
        var slots: [Int: Double] = [:]
        func slot(_ perGalaxy: Int) -> Double {
            if let known = slots[perGalaxy] { return known }
            let seconds = exploreSeconds(typical(perGalaxy: perGalaxy))
            slots[perGalaxy] = seconds
            return seconds
        }
        if progress.exploreDone {
            return Sizing(
                scenes: explored, perGalaxy: fixedCount ?? ladder[0], picks: counts[0], budget: 0)
        }
        // Fifty scenes, or the number asked, with room for as many picks as can be had.
        for picks in counts {
            let budget = available - Double(picks) * finish
            func fits(_ scenes: Int, _ perGalaxy: Int) -> Bool {
                Double(max(scenes - explored, 0)) * slot(perGalaxy) <= budget
            }
            let scenes = fixedScenes ?? NightRecipe.defaultScenes
            if let perGalaxy = fixedCount.map({ [$0] }) ?? .some(ladder),
                let best = perGalaxy.last(where: { fits(scenes, $0) })
            {
                return Sizing(scenes: scenes, perGalaxy: best, picks: picks, budget: budget)
            }
        }
        // Then fewer scenes at the smallest count, keeping room for the fewest picks.
        let picks = counts.last ?? 0
        let budget = available - Double(picks) * finish
        let perGalaxy = fixedCount ?? ladder[0]
        if fixedScenes == nil {
            let scenes = explored + Int(max(budget, 0) / slot(perGalaxy))
            if scenes >= Self.minimumScenes {
                return Sizing(scenes: scenes, perGalaxy: perGalaxy, picks: picks, budget: budget)
            }
        }
        // Nothing fits: the smallest night that was asked for, which the plan says is late.
        return Sizing(
            scenes: max(fixedScenes ?? Self.minimumScenes, explored), perGalaxy: perGalaxy,
            picks: picks, budget: budget)
    }

    // MARK: Plan

    public func plan(now: Date, deliverBy: Date) -> NightPlan {
        let sized = sizing(now: now, deliverBy: deliverBy)
        let hires = hiresParticles
        let exports = recipe.exports
        var warnings: [NightPlan.Warning] = []
        var steps: [NightPlan.Step] = []
        var disk = 0.0
        var clock = now

        // Exploration, cut at its budget when it would run past it.
        let explored = progress.explored.count
        var scenes = sized.scenes
        var exploreSeconds = 0.0
        if !progress.exploreDone {
            let slot = self.exploreSeconds(typical(perGalaxy: sized.perGalaxy))
            exploreSeconds = Double(max(scenes - explored, 0)) * slot
            if exploreSeconds > sized.budget, slot > 0 {
                let fit = explored + Int(max(sized.budget, 0) / slot)
                warnings.append(
                    .init(
                        kind: "explore",
                        message: "\(scenes) scenes do not fit before the picks: about \(fit) will"))
                scenes = max(fit, min(scenes, max(Self.minimumScenes, explored)))
                exploreSeconds = Double(max(scenes - explored, 0)) * slot
            }
            disk += Double(max(scenes - explored, 0)) * Self.previewBytes
        }
        steps.append(
            NightPlan.Step(
                phase: .explore, count: scenes, particles: sized.perGalaxy, seconds: exploreSeconds,
                start: clock, end: clock.addingTimeInterval(exploreSeconds),
                done: progress.exploreDone, fits: true))
        clock = clock.addingTimeInterval(exploreSeconds)

        // The pick, and the scenes it takes, known or typical.
        var finishing: [NightScene]
        if let picks = progress.picks {
            finishing = picks.compactMap { name in progress.explored.first { $0.name == name } }
        } else if case .none = recipe.pick {
            finishing = []
        } else if progress.exploreDone {
            let ranked = Self.ranked(progress.explored)
            let count: Int
            if case .count(let asked) = recipe.pick {
                count = asked
            } else {
                count = autoPicks(ranked, from: clock, deliverBy: deliverBy)
            }
            finishing = Array(ranked.prefix(count))
        } else {
            let typical = typical(perGalaxy: sized.perGalaxy)
            finishing = (0..<min(sized.picks, max(scenes, 0))).map { index in
                var scene = typical
                scene.name = nil
                scene.score = Double(-index)
                return scene
            }
        }
        steps.append(
            NightPlan.Step(
                phase: .pick, count: finishing.count, seconds: 0, start: clock, end: clock,
                done: progress.picks != nil, fits: true))

        let hard = deliverBy.addingTimeInterval(Self.grace)
        for (index, scene) in finishing.enumerated() {
            let name = scene.name ?? "pick \(index + 1)"
            let skipped = progress.skipped.contains(name)
            let hiresDone = progress.hiresDone.contains(name)
            let styled = progress.styled.contains(name)
            let hiresTime = hiresDone ? 0 : hiresSeconds(scene)
            let styleTime = styled ? 0 : styleSeconds
            let exportTimes = exports.map {
                progress.exported.contains("\(name)/\($0)") ? 0 : exportSeconds($0, frames: scene.frames)
            }
            let finishEnd = clock.addingTimeInterval(
                hiresTime + styleTime + exportTimes.reduce(0, +))
            var starts = !skipped && (hiresDone || finishEnd <= deliverBy)
            if !starts && !skipped {
                warnings.append(
                    .init(
                        kind: "late",
                        message: "\(name) cannot be finished before the delivery time: left out"))
            }
            func add(_ phase: NightPlan.Phase, _ seconds: Double, done: Bool, format: String? = nil) {
                if starts, !done, phase != .hires, clock.addingTimeInterval(seconds) > hard {
                    starts = false
                }
                steps.append(
                    NightPlan.Step(
                        phase: phase, scene: name, particles: phase == .hires ? hires : nil,
                        format: format, seconds: seconds, start: clock,
                        end: clock.addingTimeInterval(seconds), done: done, fits: starts))
                if starts { clock = clock.addingTimeInterval(seconds) }
            }
            add(.hires, hiresTime, done: hiresDone)
            if starts, !hiresDone {
                disk += Double(hires) * Double(scene.frames) * Self.takeBytesPerParticleFrame
            }
            add(.style, styleTime, done: styled)
            for (format, seconds) in zip(exports, exportTimes) {
                let done = progress.exported.contains("\(name)/\(format)")
                add(.export, seconds, done: done, format: format)
                if starts, !done { disk += Self.videoBytes(format, frames: scene.frames) }
            }
        }

        if let freeBytes, disk > freeBytes {
            warnings.append(
                .init(
                    kind: "disk",
                    message: String(
                        format: "%.1f GB needed, %.1f GB free", disk / 1e9, freeBytes / 1e9)))
        }
        return NightPlan(
            start: now, deliverBy: deliverBy, end: clock, scenes: scenes,
            particlesPerGalaxy: sized.perGalaxy, exploreBudget: max(sized.budget, 0),
            picks: finishing.count, hiresParticles: hires, exports: exports, steps: steps,
            diskBytes: disk, freeBytes: freeBytes, warnings: warnings)
    }
}
