import Foundation
import SillageCore

/// The scenes a batch will draw, sized from the generator alone, without a particle: what
/// `explore-batch.sh` probes before each scene, here in a few milliseconds a scene. A night is
/// planned from them before anything is explored.
public struct ExploreProbe: Sendable {
    /// What the batch passes to `explore`, as `explore-batch.sh` does by default.
    public var seed: UInt64
    public var archetypeShare = Double(BatchDraw.defaultArchetypeShare)
    public var dtScale = 3.5
    public var spanMyr = 700.0
    public var frames = 900
    public var settle = 400
    /// Draws outside these are skipped, as `--galaxies` and `--only-archetypes` skip them.
    public var galaxies: ClosedRange<Int>?
    public var archetypes: [String]?

    private let cache = Cache()

    public init(seed: UInt64) { self.seed = seed }

    /// Each place drawn once, the slow part, and sized again at any count from its scene file.
    private final class Cache: @unchecked Sendable {
        let lock = NSLock()
        var files: [String: (generator: String, file: SceneFile)] = [:]
    }

    /// The scene at a place, with the solver and step scale `explore` gives it.
    func file(_ index: Int) -> (generator: String, file: SceneFile) {
        let key = "\(seed)/\(archetypeShare)/\(index)"
        cache.lock.lock()
        let known = cache.files[key]
        cache.lock.unlock()
        if let known { return known }
        let preset = BatchDraw(batchSeed: seed, archetypeShare: Float(archetypeShare))
            .scene(at: index, particleCount: 100_000)
        var file = SceneFile(preset)
        file.solver = .barnesHut
        file.timeStepScale = Float(dtScale)
        let drawn = (preset.draw?.generator ?? "free", file)
        cache.lock.lock()
        cache.files[key] = drawn
        cache.lock.unlock()
        return drawn
    }

    /// One scene, or nil when the filters skip it.
    public struct Draw: Sendable, Equatable {
        public var index: Int
        public var generator: String
        public var galaxies: Int
        public var particles: Int
        /// The planned steps after the settle, a whole number per frame.
        public var steps: Int
        /// Simulation units, at `particles`.
        public var timeStep: Double
    }

    public func draw(_ index: Int, perGalaxy: Int) -> Draw? {
        let (generator, file) = file(index)
        // A black hole has no stars to share, so the host keeps a galaxy's worth.
        let count = file.galaxies.filter { $0.kind != .blackHole }.count
        if let galaxies, !galaxies.contains(count) { return nil }
        if let archetypes, generator != "free", !archetypes.contains(generator) { return nil }
        let particles = count * perGalaxy
        let step = Double(file.scene(particleCount: particles).timeStep)
        let stepMyr = step * Physics.megayearsPerTimeUnit
        var perFrame = Int(spanMyr / stepMyr / Double(frames))
        if Double(perFrame * frames) * stepMyr < spanMyr { perFrame += 1 }
        return Draw(
            index: index, generator: generator, galaxies: count, particles: particles,
            steps: max(perFrame, 1) * frames, timeStep: step)
    }

    /// The first `count` scenes the filters keep, from index 1 as a batch numbers them.
    public func draws(perGalaxy: Int, count: Int) -> [Draw] {
        var found: [Draw] = []
        var index = 1
        while found.count < count, index <= count * 50 {
            if let draw = draw(index, perGalaxy: perGalaxy) { found.append(draw) }
            index += 1
        }
        return found
    }

    /// The draw as a night plans it: its exploration with the story's usual extra, and its
    /// hires at `hiresParticles` over the same span, `frames` of it when given.
    public func scene(_ draw: Draw, hiresParticles: Int, frames hiresFrames: Int? = nil)
        -> NightScene
    {
        let target = Double(file(draw.index).file.scene(particleCount: hiresParticles).timeStep)
        var clip = SceneFolder.Clip()
        clip.frames = frames
        clip.steps = draw.steps
        clip.settle = settle
        let storyFrames = Int((Double(frames) * (1 + Story.extraShare)).rounded())
        let span = clip.spanning(
            previewStep: draw.timeStep, maximumStep: target, frames: hiresFrames ?? storyFrames)
        return NightScene(
            name: nil, score: nil,
            exploreUnits: Double(draw.particles)
                * (Double(settle) + Double(draw.steps) * (1 + Story.extraShare)),
            hiresUnits: Double(hiresParticles) * Double(span.settle + span.steps),
            frames: hiresFrames ?? storyFrames)
    }
}
