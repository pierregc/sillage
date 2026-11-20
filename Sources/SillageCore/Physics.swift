#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// Unit system: lengths in kpc, masses in 1e10 solar masses, G = 1.
/// The derived velocity unit is 207.4 km/s and the time unit is 4.71 Myr. One length unit is
/// one kpc and one mass unit is 1e10 solar masses.
public enum Physics {
    public static let gravitationalConstant: Float = 1

    public static let kilometersPerSecondPerVelocityUnit: Double = 207.4
    public static let megayearsPerTimeUnit: Double = 4.71
}
