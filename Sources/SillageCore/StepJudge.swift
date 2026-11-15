import Foundation

#if canImport(simd)
    import simd
#endif

/// Whether a run may take the coarser step its schedule plans (#312), judged on its own centres
/// as they come: not while a pair is engaged, nor for `margin` Myr after, by the definition the
/// pace reads (`StoryPace.Engagement`). So a run keeps the fine step while its own pair is still
/// engaged, whatever its preview did, and comes back to it if its own story starts early. Only
/// the centres count, so a massive pass and a run with light tracers judge alike.
public struct StepJudge: Sendable {
    public private(set) var engagement: StoryPace.Engagement
    public let margin: Double

    public init(story: Story, margin: Double) {
        engagement = StoryPace.Engagement(story: story)
        self.margin = margin
    }

    /// The run's centres at `timeMyr`, rounded as its curves write them, so that judging the
    /// curves again gives the same answer.
    public mutating func observe(timeMyr: Double, centres: [SIMD3<Float>]) {
        func rounded(_ value: Double, _ format: String) -> Double {
            Double(String(format: format, value)) ?? value
        }
        engagement.append(
            Story.Sample(
                timeMyr: rounded(timeMyr, "%.3f"),
                centres: centres.map {
                    SIMD3(
                        rounded(Double($0.x), "%.4f"), rounded(Double($0.y), "%.4f"),
                        rounded(Double($0.z), "%.4f"))
                }, extent: 0, tails: 0, disruption: []))
    }

    /// Whether a coarser step may run from `myr` on.
    public func allowsCoarse(atMyr myr: Double) -> Bool {
        guard let engaged = engagement.untilMyr else { return true }
        return myr - engaged >= margin
    }
}
