import simd

/// Spherical camera rig around a target, which is what mouse orbiting maps onto naturally.
public struct OrbitCamera: Sendable {
    public var target: SIMD3<Float>
    public var distance: Float
    public var azimuth: Float
    public var elevation: Float
    public var fieldOfView: Float

    /// Kept clear of the poles, where the up vector degenerates.
    public static let elevationLimit: Float = 1.52

    public init(
        target: SIMD3<Float> = .zero,
        distance: Float = 260,
        azimuth: Float = 0,
        elevation: Float = 1.15,
        fieldOfView: Float = 0.6
    ) {
        self.target = target
        self.distance = distance
        self.azimuth = azimuth
        self.elevation = min(max(elevation, -Self.elevationLimit), Self.elevationLimit)
        self.fieldOfView = fieldOfView
    }

    public var camera: Camera {
        let horizontal = cos(elevation) * distance
        let offset = SIMD3<Float>(
            horizontal * sin(azimuth),
            -horizontal * cos(azimuth),
            sin(elevation) * distance)
        return Camera(eye: target + offset, target: target, fieldOfView: fieldOfView)
    }

    public mutating func orbit(deltaAzimuth: Float, deltaElevation: Float) {
        azimuth += deltaAzimuth
        elevation = min(max(elevation + deltaElevation, -Self.elevationLimit), Self.elevationLimit)
    }

    public mutating func zoom(factor: Float) {
        distance = min(max(distance * factor, 5), 20_000)
    }

    /// Distance at which a sphere of the given radius fills the frame.
    public mutating func frame(radius: Float) {
        distance = radius / tan(fieldOfView / 2) * 1.05
    }
}
