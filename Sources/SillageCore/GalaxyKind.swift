/// Shape of the stellar distribution. The potential stays spherical and analytic in every
/// case; this only changes where the visible particles are placed and how they move.
public enum GalaxyKind: String, Codable, Sendable, CaseIterable {
    /// Thin rotating disk with a logarithmic spiral density modulation.
    case spiral
    /// Thin rotating disk, featureless.
    case disk
    /// Pressure-supported sphere with no ordered rotation.
    case globular

    public var displayName: String {
        switch self {
        case .spiral: "Spirale"
        case .disk: "Disque"
        case .globular: "Globulaire"
        }
    }

    public var isRotating: Bool { self != .globular }
}
