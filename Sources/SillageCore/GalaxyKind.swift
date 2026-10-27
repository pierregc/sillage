/// Shape of the stellar distribution. The potential stays spherical and analytic in every
/// case; this only changes where the visible particles are placed and how they move.
public enum GalaxyKind: String, Codable, Sendable, CaseIterable {
    /// Thin rotating disk with a logarithmic spiral density modulation.
    case spiral
    /// Thin rotating disk, featureless.
    case disk
    /// Pressure-supported sphere with no ordered rotation.
    case globular
    /// A lone supermassive black hole: one heavy particle, no stars, no disk, no halo.
    case blackHole = "black-hole"

    public var displayName: String {
        switch self {
        case .spiral: "Spirale"
        case .disk: "Disque"
        case .globular: "Globulaire"
        case .blackHole: "Trou noir"
        }
    }

    public var isRotating: Bool { self == .spiral || self == .disk }
}
