/// Labels in which no two read alike: those that repeat take their place among the equals, as
/// "hubble-visible · complementary (2)" (#228).
public enum DistinctLabels {
    public static func make(_ labels: [String]) -> [String] {
        var totals: [String: Int] = [:]
        for label in labels { totals[label, default: 0] += 1 }
        var seen: [String: Int] = [:]
        return labels.map { label in
            guard totals[label, default: 0] > 1 else { return label }
            seen[label, default: 0] += 1
            return "\(label) (\(seen[label, default: 0]))"
        }
    }
}
