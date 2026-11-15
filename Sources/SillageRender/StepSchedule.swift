import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// A coarser step where nothing fast happens (#307, #312; docs/notes/variable-time.md): from each
/// entry's moment on, the step is `scale` times the run's own. The scale is a power of two that
/// divides a frame's steps, and a switch waits for the next frame boundary, so the captured
/// frames keep their cadence in megayears. A hires plans one from its preview's curves
/// (`planned`) and judges its own as it goes (`margin`, `StepJudge`); an explicit one is
/// followed as written.
public struct StepSchedule: Codable, Sendable, Equatable, CustomStringConvertible {
    public struct Entry: Codable, Sendable, Equatable {
        public var fromMyr: Double
        public var scale: Int

        public init(fromMyr: Double, scale: Int) {
            self.fromMyr = fromMyr
            self.scale = scale
        }
    }

    /// Where a run changed its step, in steps of its own from its first, settle included.
    public struct Switch: Codable, Sendable, Equatable {
        public var step: Int
        public var myr: Double
        public var scale: Int
        /// The captured frame it came before; absent while settling.
        public var frame: Int?

        public init(step: Int, myr: Double, scale: Int, frame: Int?) {
            self.step = step
            self.myr = myr
            self.scale = scale
            self.frame = frame
        }
    }

    public enum Problem: Error, CustomStringConvertible {
        case badEntry(String)
        case badScale(Int, perFrame: Int)
        case badPlan(String)

        public var description: String {
            switch self {
            case .badEntry(let entry):
                "--dt-schedule: \"\(entry)\" is not <Myr>:<scale>, e.g. 0:2,162:1"
            case .badScale(let scale, let perFrame):
                "--dt-schedule: a scale of \(scale) is not a power of two dividing a frame's"
                    + " \(perFrame) steps"
            case .badPlan(let text):
                "--dt-schedule: \"\(text)\" is not off, story[:<before>[:<after>[:<margin Myr>]]]"
                    + " or <Myr>:<scale>,..."
            }
        }
    }

    /// In order of time; the run's own step before the first.
    public private(set) var entries: [Entry]
    /// Set when the run judges its own centres (#312): a coarser step waits until no pair has
    /// been engaged for this many Myr (`StepJudge`). Absent for a schedule followed as written.
    public var margin: Double?

    public init(entries: [Entry], margin: Double? = nil) {
        self.entries = entries.sorted { $0.fromMyr < $1.fromMyr }
        self.margin = margin
    }

    /// `0:2,162:1`: twice the step from the start, the run's own from 162 Myr.
    public init(parsing text: String) throws {
        let entries = try text.split(separator: ",").map { part -> Entry in
            let fields = part.split(separator: ":")
            guard fields.count == 2, let myr = Double(fields[0]), myr >= 0, let scale = Int(fields[1]),
                scale >= 1
            else { throw Problem.badEntry(String(part)) }
            return Entry(fromMyr: myr, scale: scale)
        }
        guard !entries.isEmpty else { throw Problem.badEntry(text) }
        self.init(entries: entries)
    }

    public func check(stepsPerFrame: Int) throws {
        for entry in entries
        where entry.scale & (entry.scale - 1) != 0 || stepsPerFrame % entry.scale != 0 {
            throw Problem.badScale(entry.scale, perFrame: stepsPerFrame)
        }
    }

    /// The scale for a stretch starting at `myr`.
    public func scale(atMyr myr: Double) -> Int {
        entries.last { $0.fromMyr <= myr + 1e-6 }?.scale ?? 1
    }

    /// The scale a stretch of `count` steps starting at `myr` runs at: the run's own when the
    /// stretch does not hold a whole number of coarse steps.
    public func scale(atMyr myr: Double, count: Int) -> Int {
        let scale = scale(atMyr: myr)
        return count % scale == 0 ? scale : 1
    }

    public var description: String {
        entries.map { String(format: "%g:%d", $0.fromMyr, $0.scale) }.joined(separator: ",")
    }

    /// How a run with a schedule cuts its settle: a first stretch up to a whole number of frames
    /// before the first captured frame, then a frame at a time, so every switch, settle included,
    /// falls on a frame boundary counted from the captured frames.
    public static func settleChunks(settle: Int, perFrame: Int) -> [Int] {
        guard settle > 0 else { return [] }
        let each = max(perFrame, 1)
        let first = (settle - 1) % each + 1
        return [first] + [Int](repeating: each, count: (settle - first) / each)
    }

    /// The steps a run of `settle` steps and `frames` frames of `perFrame` steps takes following
    /// the schedule as planned, the step being `stepMyr`, from its own step `from` on. What a
    /// run that judges its own may take more of.
    public func steps(settle: Int, frames: Int, perFrame: Int, stepMyr: Double, from: Int = 0) -> Int {
        var own = 0
        var run = 0
        let each = max(perFrame, 1)
        for count in Self.settleChunks(settle: settle, perFrame: each) + [Int](repeating: each, count: frames)
        {
            if own >= from { run += count / scale(atMyr: Double(own) * stepMyr, count: count) }
            own += count
        }
        return run
    }
}

// MARK: - Planned from the preview

extension StepSchedule {
    /// What a hires plans when asked `story[:before[:after[:margin]]]`: the step `before` times
    /// the hires step until the story starts, the hires step through it, and `after` times it
    /// from `margin` Myr after the last engagement, the merger or the parting.
    public struct Plan: Sendable, Equatable, CustomStringConvertible {
        public var before: Int
        public var after: Int
        public var margin: Double

        public init(before: Int, after: Int, margin: Double = 100) {
            self.before = before
            self.after = after
            self.margin = margin
        }

        public var description: String { String(format: "story:%d:%d:%g", before, after, margin) }
    }

    /// The schedule every hires takes unless `--dt-schedule` says otherwise (#312), nil for the
    /// hires step throughout: twice the hires step before the story and from 100 Myr after the
    /// merger or the parting, the hires step through the story. 14 (`before: 4`) moves the
    /// orbit (#307).
    public static let standard: Plan? = Plan(before: 2, after: 2, margin: 100)

    /// What `--dt-schedule` asks: nothing, a plan made from the preview, or entries as written.
    public enum Asked: Sendable, Equatable {
        case off
        case story(Plan)
        case entries(StepSchedule)

        /// `nil` (the option absent) is the standard plan.
        public init(_ text: String?) throws {
            guard let text else {
                self = StepSchedule.standard.map { .story($0) } ?? .off
                return
            }
            if text == "off" {
                self = .off
                return
            }
            guard text.hasPrefix("story") else {
                self = .entries(try StepSchedule(parsing: text))
                return
            }
            let fields = text.split(separator: ":", omittingEmptySubsequences: false).dropFirst()
            guard text == "story" || text.hasPrefix("story:"), fields.count <= 3 else {
                throw Problem.badPlan(text)
            }
            var plan = StepSchedule.standard ?? Plan(before: 2, after: 2)
            let values = fields.map { Double($0) }
            guard values.allSatisfy({ $0 != nil }) else { throw Problem.badPlan(text) }
            for (index, value) in values.compactMap({ $0 }).enumerated() {
                switch index {
                case 0: plan.before = Int(value)
                case 1: plan.after = Int(value)
                default: plan.margin = value
                }
            }
            for scale in [plan.before, plan.after] where scale < 1 || scale & (scale - 1) != 0 {
                throw Problem.badPlan(text)
            }
            guard plan.margin >= 0 else { throw Problem.badPlan(text) }
            self = .story(plan)
        }
    }

    /// The schedule `plan` gives a hires whose captured frames run from `clipStartMyr` to
    /// `clipEndMyr`, `perFrame` steps of `frameMyr` a frame, on its preview's last engagement
    /// (`StoryPace.Engagement`, nil when no pair ever engaged): coarse through the settle, fine
    /// from the first captured frame, coarse again from the engagement plus the margin. A scale
    /// a frame does not hold whole is halved until it does. The run judges its own centres with
    /// the same margin. Nil when nothing would be coarser.
    public static func planned(
        _ plan: Plan, clipStartMyr: Double, clipEndMyr: Double, frameMyr: Double, perFrame: Int,
        lastEngagementMyr: Double?
    ) -> StepSchedule? {
        func fitted(_ scale: Int) -> Int {
            var fitted = max(scale, 1)
            while fitted > 1 && max(perFrame, 1) % fitted != 0 { fitted /= 2 }
            return fitted
        }
        var entries: [Entry] = []
        let before = fitted(plan.before)
        if before > 1, clipStartMyr >= frameMyr {
            // Between the settle's last stretch, a frame before the first captured frame, and
            // the first frame itself, whatever the rounding of the step.
            let fine = ((clipStartMyr - frameMyr / 2) * 10 + 1e-6).rounded(.down) / 10
            entries += [Entry(fromMyr: 0, scale: before), Entry(fromMyr: max(fine, 0), scale: 1)]
        }
        let after = fitted(plan.after)
        if after > 1, let engaged = lastEngagementMyr {
            let from = (max(engaged + plan.margin, clipStartMyr) * 10 - 1e-6).rounded(.up) / 10
            if from < clipEndMyr - frameMyr { entries.append(Entry(fromMyr: from, scale: after)) }
        }
        return entries.isEmpty ? nil : StepSchedule(entries: entries, margin: plan.margin)
    }

    /// The last engagement of the curves `csv`, judged with `story`, as a pace reads it.
    public static func lastEngagement(csv: String, story: Story) -> Double? {
        var engagement = StoryPace.Engagement(story: story)
        for sample in Story.samples(csv: csv) { engagement.append(sample) }
        return engagement.untilMyr
    }
}

// MARK: - Judged by the run

/// Where a run following a schedule stands (#312): the scale of each stretch of its own steps,
/// the planned one unless its judge holds the fine step, and each switch as it happens, which
/// `hires.json` keeps for the full pass and a resumed run to follow.
public struct StepScheduler: Sendable {
    public let schedule: StepSchedule
    /// The run's own step, in Myr.
    public let stepMyr: Double
    public private(set) var judge: StepJudge?
    public private(set) var scale = 1
    public private(set) var ownSteps = 0
    public private(set) var stepsRun = 0
    public private(set) var switches: [StepSchedule.Switch] = []

    /// A schedule with a margin is judged on `story`'s reading of the run's centres.
    public init(schedule: StepSchedule, stepMyr: Double, story: Story?) {
        self.schedule = schedule
        self.stepMyr = stepMyr
        if let margin = schedule.margin, let story { judge = StepJudge(story: story, margin: margin) }
    }

    /// The moment the next stretch starts, from the run's own steps.
    public var myr: Double { Double(ownSteps) * stepMyr }

    /// The scale the next `count` own steps take, and whether it changed: the step is then
    /// `scale` times the run's own from here. Counts them as run.
    public mutating func next(_ count: Int, frame: Int?) -> (scale: Int, switched: Bool) {
        var wanted = schedule.scale(atMyr: myr, count: count)
        if wanted > 1, let judge, !judge.allowsCoarse(atMyr: myr) { wanted = 1 }
        let switched = wanted != scale
        if switched {
            scale = wanted
            switches.append(.init(step: ownSteps, myr: myr, scale: wanted, frame: frame))
        }
        ownSteps += count
        stepsRun += count / wanted
        return (wanted, switched)
    }

    /// The run's centres once a stretch is stepped, for its judge.
    public mutating func observe(timeMyr: Double, centres: [SIMD3<Float>]) {
        judge?.observe(timeMyr: timeMyr, centres: centres)
    }

    /// Steps `count` of the run's own steps on `solver`, whose own step is `ownStep`, at the
    /// scale `next` gives them, and shows its centres to the judge after. Returns the steps run
    /// and whether the step changed.
    @discardableResult
    public mutating func step(_ count: Int, frame: Int?, on solver: some StepChangingSolver, ownStep: Float)
        -> (steps: Int, switched: Bool)
    {
        let (scale, switched) = next(count, frame: frame)
        if switched { solver.changeStep(to: ownStep * Float(scale)) }
        solver.step(count: count / scale)
        observe(timeMyr: Double(solver.time) * Physics.megayearsPerTimeUnit, centres: solver.centers)
        return (count / scale, switched)
    }
}

/// The switches a run took (`hires.json`'s `stepSwitches`), which a full pass and a resumed run
/// follow to the bit (#312): `--dt-switches <step>:<scale>,...`, in the run's own steps from its
/// first, settle included.
public struct StepSwitches: Sendable, Equatable, CustomStringConvertible {
    public struct Problem: Error, CustomStringConvertible {
        public var why: String
        public var description: String { "--dt-switches: \(why)" }
    }

    /// In order of steps.
    public private(set) var entries: [(step: Int, scale: Int)]

    public init(_ switches: [StepSchedule.Switch]) {
        entries = switches.map { ($0.step, $0.scale) }.sorted { $0.0 < $1.0 }
    }

    public init(parsing text: String) throws {
        entries = try text.split(separator: ",").map { part in
            let fields = part.split(separator: ":")
            guard fields.count == 2, let step = Int(fields[0]), step >= 0, let scale = Int(fields[1]),
                scale >= 1, scale & (scale - 1) == 0
            else { throw Problem(why: "\"\(part)\" is not <step>:<scale>, a power of two") }
            return (step, scale)
        }
        .sorted { $0.0 < $1.0 }
        guard !entries.isEmpty else { throw Problem(why: "no switch in \"\(text)\"") }
    }

    public static func == (a: StepSwitches, b: StepSwitches) -> Bool {
        a.entries.map(\.step) == b.entries.map(\.step) && a.entries.map(\.scale) == b.entries.map(\.scale)
    }

    public var description: String { entries.map { "\($0.step):\($0.scale)" }.joined(separator: ",") }

    /// The scale own step `step` runs at.
    public func scale(forStep step: Int) -> Int { entries.last { $0.step <= step }?.scale ?? 1 }

    /// The next switch after own step `step`.
    public func next(after step: Int) -> Int? { entries.first { $0.step > step }?.step }

    /// The steps run from own step `from` to own step `to`.
    public func steps(from: Int, to: Int) -> Int {
        var run = 0
        var own = from
        while own < to {
            let end = min(next(after: own) ?? to, to)
            run += (end - own) / scale(forStep: own)
            own = end
        }
        return run
    }

    /// Refuses switches a run of `settle` steps and `frames` frames of `perFrame` steps could
    /// not have taken: inside a frame, at a scale a frame does not hold whole, or leaving a
    /// stretch that is not whole coarse steps.
    public func check(settle: Int, frames: Int, perFrame: Int) throws {
        let end = settle + frames * perFrame
        for (index, entry) in entries.enumerated() {
            guard perFrame % entry.scale == 0 else {
                throw Problem(why: "a scale of \(entry.scale) does not divide a frame's \(perFrame) steps")
            }
            guard entry.step <= end, entry.step < settle || (entry.step - settle) % perFrame == 0 else {
                throw Problem(why: "step \(entry.step) is not on a frame boundary")
            }
            let stretch = (index + 1 < entries.count ? entries[index + 1].step : end) - entry.step
            guard stretch % entry.scale == 0 else {
                throw Problem(
                    why: "\(stretch) steps from step \(entry.step) are not whole steps of \(entry.scale)")
            }
        }
    }
}

/// A solver whose step can change between two steps, for a step schedule (#307, #312).
public protocol StepChangingSolver: Solver {
    func changeStep(to step: Float)
}
