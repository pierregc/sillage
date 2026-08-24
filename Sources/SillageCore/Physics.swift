import simd

/// Unit system: lengths in kpc, masses in 1e10 solar masses, G = 1.
/// The derived velocity unit is 207.4 km/s and the time unit is 4.71 Myr.
public enum Physics {
    public static let G: Float = 1

    public static let kpcPerLengthUnit: Double = 1
    public static let solarMassesPerMassUnit: Double = 1e10
    public static let kilometersPerSecondPerVelocityUnit: Double = 207.4
    public static let megayearsPerTimeUnit: Double = 4.71
}
