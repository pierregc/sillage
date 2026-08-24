import simd

public struct Camera {
    public var eye: SIMD3<Float>
    public var target: SIMD3<Float>
    public var up: SIMD3<Float>
    public var fieldOfView: Float
    public var near: Float
    public var far: Float

    public init(
        eye: SIMD3<Float>,
        target: SIMD3<Float> = .zero,
        up: SIMD3<Float> = SIMD3<Float>(0, 0, 1),
        fieldOfView: Float = 0.6,
        near: Float = 1,
        far: Float = 40_000
    ) {
        self.eye = eye
        self.target = target
        self.up = up
        self.fieldOfView = fieldOfView
        self.near = near
        self.far = far
    }

    /// Places the camera so a sphere of the given radius fills the frame, viewed from
    /// slightly above the orbital plane.
    public static func framing(
        radius: Float,
        center: SIMD3<Float> = .zero,
        fieldOfView: Float = 0.6,
        elevation: Float = 0.45
    ) -> Camera {
        let distance = radius / tan(fieldOfView / 2) * 1.05
        let offset = SIMD3<Float>(0, -cos(elevation), sin(elevation)) * distance
        return Camera(eye: center + offset, target: center, fieldOfView: fieldOfView)
    }

    public func viewProjection(aspectRatio: Float) -> simd_float4x4 {
        projection(aspectRatio: aspectRatio) * view()
    }

    func view() -> simd_float4x4 {
        let forward = simd_normalize(target - eye)
        let right = simd_normalize(simd_cross(forward, up))
        let trueUp = simd_cross(right, forward)
        let rotation = simd_float4x4(
            SIMD4<Float>(right.x, trueUp.x, -forward.x, 0),
            SIMD4<Float>(right.y, trueUp.y, -forward.y, 0),
            SIMD4<Float>(right.z, trueUp.z, -forward.z, 0),
            SIMD4<Float>(-simd_dot(right, eye), -simd_dot(trueUp, eye), simd_dot(forward, eye), 1)
        )
        return rotation
    }

    func projection(aspectRatio: Float) -> simd_float4x4 {
        let scale = 1 / tan(fieldOfView / 2)
        let depth = far / (near - far)
        return simd_float4x4(
            SIMD4<Float>(scale / aspectRatio, 0, 0, 0),
            SIMD4<Float>(0, scale, 0, 0),
            SIMD4<Float>(0, 0, depth, -1),
            SIMD4<Float>(0, 0, depth * near, 0)
        )
    }
}
