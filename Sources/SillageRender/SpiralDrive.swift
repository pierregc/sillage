import Foundation
import Metal
import SillageCore
import simd

/// One galaxy's drive as the kernel reads it.
struct SpiralDriveGPU {
    var center: SIMD4<Float>
    var axis: SIMD4<Float>
    var u: SIMD4<Float>
    var v: SIMD4<Float>
    var window: SIMD4<Float>
    var ramp: SIMD4<Float>
}

struct SpiralDriveParams {
    var particleCount: UInt32
    var galaxyCount: UInt32
    var timeStep: Float
    var pad: Float = 0
}

/// A rigid spiral potential the disk material is driven with (#180): one harmonic of Cox &
/// Gómez (2002) in each spiral's measured frame, turning at its own speed, phased on the
/// sampled ridge at t = 0, ramped in on Dehnen's quintic, acting between the inner Lindblad
/// resonance and the corotation of its speed, and taken away by a companion's tide or a
/// wrecked disk as the cooling is. Its own library, so the solver's shaders stay as they are.
final class SpiralDrive {
    struct Galaxy {
        /// 4 pi G H rho0, set so the strongest in-plane pull at two scale lengths is
        /// `driveStrength` of the axisymmetric one.
        var amplitude: Float
        /// Radians per time unit, unsigned.
        var speed: Float
        var inner: Float
        var outer: Float
    }

    /// The window reaches the outer Lindblad resonance instead of stopping at corotation; the
    /// stars answer a spiral in phase all the way out there.
    nonisolated(unsafe) static var reachesOuterLindblad = false

    let galaxies: [Galaxy?]
    private let pipeline: MTLComputePipelineState

    init?(device: MTLDevice, scene: SceneConfig) throws {
        let galaxies = scene.galaxies.map(Self.facts)
        guard galaxies.contains(where: { $0 != nil }) else { return nil }
        self.galaxies = galaxies
        let library: MTLLibrary
        do { library = try ShaderCache.library(Self.source, on: device) } catch {
            throw RenderError.shaderCompilation("\(error)")
        }
        guard let function = library.makeFunction(name: "bhDrive") else {
            throw RenderError.pipelineCreation("missing kernel bhDrive")
        }
        do { pipeline = try device.makeComputePipelineState(function: function) } catch {
            throw RenderError.pipelineCreation("bhDrive: \(error)")
        }
    }

    /// The drive's amplitude, speed and window from the galaxy's equilibrium; none for a disk
    /// with no drive or no arms.
    static func facts(for galaxy: GalaxyConfig) -> Galaxy? {
        guard galaxy.kind == .spiral, galaxy.armCount > 0, galaxy.driveStrength > 0 else {
            return nil
        }
        let equilibrium = DiskEquilibrium(config: galaxy, selfGravitating: true)
        let h = max(galaxy.diskScaleLength, 0.1)
        let speed = equilibrium.driveSpeed()
        let resonances = equilibrium.resonances(of: speed)
        var outer =
            reachesOuterLindblad ? equilibrium.outerLindblad(of: speed) : resonances.corotation
        if !outer.isFinite { outer = 12 * h }
        // The unit potential's strongest in-plane pull at the reference radius, over the
        // angles of one pattern period, by the same differences the kernel takes.
        let reference = max(2 * h, 0.5)
        let m = Float(galaxy.armCount)
        let pitch = max(galaxy.armPitch, 0.02)
        let height = max(galaxy.diskThickness, 0.05)
        func unit(_ x: Float, _ y: Float) -> Float {
            let r = max((x * x + y * y).squareRoot(), 1e-3)
            let k = m / (r * sin(pitch))
            let kh = k * height
            let d = (1 + kh + 0.3 * kh * kh) / (1 + 0.3 * kh)
            let gamma = m * (atan2(y, x) + log(r / h) / tan(pitch))
            return -exp(-(r - reference) / h) / (k * d) * cos(gamma)
        }
        var strongest: Float = 0
        for sample in 0..<32 {
            let angle = Float(sample) / 32 * 2 * .pi / m
            let x = reference * cos(angle)
            let y = reference * sin(angle)
            let step: Float = 0.02
            let fx = (unit(x + step, y) - unit(x - step, y)) / (2 * step)
            let fy = (unit(x, y + step) - unit(x, y - step)) / (2 * step)
            strongest = max(strongest, (fx * fx + fy * fy).squareRoot())
        }
        let circular = equilibrium.circularSpeed(atRadius: reference)
        let axisymmetric = circular * circular / reference
        guard strongest > 0 else { return nil }
        return Galaxy(
            amplitude: galaxy.driveStrength * axisymmetric / strongest, speed: speed,
            inner: resonances.lindblad, outer: outer)
    }

    /// One kick of the drive, at `time`, where the positions are now. `quiet` is what the
    /// cooling's gate leaves of each galaxy, one for a disk alone.
    func encode(
        into buffer: MTLCommandBuffer, scene: SceneConfig, time: Float, centres: [SIMD3<Float>],
        disks: [DiskState], quiet: [Float], positions: MTLBuffer, velocities: MTLBuffer,
        component: MTLBuffer, galaxy: MTLBuffer, count: Int, timeStep: Float
    ) {
        let myr = Float(Physics.megayearsPerTimeUnit)
        var drives = scene.galaxies.enumerated().map { index, config -> SpiralDriveGPU in
            let none = SpiralDriveGPU(
                center: .zero, axis: .zero, u: .zero, v: .zero, window: .zero, ramp: .zero)
            guard let facts = galaxies[index], index < centres.count else { return none }
            let progress = min(max(time * myr / max(config.driveRampMyr, 1), 0), 1)
            let ramp = progress * progress * progress * (10 - 15 * progress + 6 * progress * progress)
            let gate = index < quiet.count ? quiet[index] : 1
            guard ramp * gate > 0 else { return none }
            let natal = config.orientation.columns.2 * config.spin.sign
            let state = index < disks.count ? disks[index] : DiskState.natal(config)
            let axis = simd_length_squared(state.axis) > 1e-12 ? simd_normalize(state.axis) : natal
            let (planeU, _) = DiskFrame.planeAxes(
                natal: config.orientation, normal: natal, axis: axis)
            let u = simd_normalize(planeU)
            // Right-handed about the axis the disk turns about, so the azimuth grows with the
            // rotation for either spin, and a trailing spiral is the same expression for both.
            let v = simd_cross(axis, u)
            let h = max(config.diskScaleLength, 0.1)
            let pitch = max(config.armPitch, 0.02)
            let centre = centres[index]
            return SpiralDriveGPU(
                center: SIMD4<Float>(centre.x, centre.y, centre.z, facts.amplitude),
                axis: SIMD4<Float>(axis.x, axis.y, axis.z, facts.speed * time),
                u: SIMD4<Float>(u.x, u.y, u.z, h),
                v: SIMD4<Float>(v.x, v.y, v.z, 1 / tan(pitch)),
                window: SIMD4<Float>(
                    Float(config.armCount), max(config.diskThickness, 0.05), facts.inner, facts.outer),
                ramp: SIMD4<Float>(ramp * gate, sin(pitch), max(2 * h, 0.5), 0))
        }
        guard drives.contains(where: { $0.center.w > 0 }),
            let encoder = buffer.makeComputeCommandEncoder()
        else { return }
        var params = SpiralDriveParams(
            particleCount: UInt32(count), galaxyCount: UInt32(drives.count), timeStep: timeStep)
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(positions, offset: 0, index: 0)
        encoder.setBuffer(velocities, offset: 0, index: 1)
        encoder.setBuffer(component, offset: 0, index: 2)
        encoder.setBuffer(galaxy, offset: 0, index: 3)
        encoder.setBytes(&drives, length: drives.count * MemoryLayout<SpiralDriveGPU>.stride, index: 4)
        encoder.setBytes(&params, length: MemoryLayout<SpiralDriveParams>.stride, index: 5)
        let group = MTLSize(width: pipeline.maxTotalThreadsPerThreadgroup, height: 1, depth: 1)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: group)
        encoder.endEncoding()
    }

    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct SpiralDrive {
            // xyz the disk's centre, w the amplitude 4 pi G H rho0, zero for no drive.
            float4 center;
            // xyz the axis the disk turns about, w the pattern angle now.
            float4 axis;
            // xyz the in-plane reference axis, w the scale length.
            float4 u;
            // xyz the second in-plane axis, right-handed about the axis, w cot(pitch).
            float4 v;
            // arms, the vertical scale, the inner Lindblad radius, the outer edge.
            float4 window;
            // x the ramp, y sin(pitch), z the reference radius, w unused.
            float4 ramp;
        };

        struct SpiralDriveParams {
            uint particleCount;
            uint galaxyCount;
            float timeStep;
            float pad;
        };

        // Cox & Gomez 2002, one harmonic: a logarithmic spiral's potential with an
        // exponential radial envelope and the sech-power vertical fall-off.
        static float spiralPotential(float x, float y, float z, SpiralDrive d) {
            float r = max(sqrt(x * x + y * y), 1e-3);
            float phi = atan2(y, x);
            float m = d.window.x;
            float H = d.window.y;
            float K = m / (r * d.ramp.y);
            float KH = K * H;
            float beta = KH * (1.0 + 0.4 * KH);
            float D = (1.0 + KH + 0.3 * KH * KH) / (1.0 + 0.3 * KH);
            float gamma = m * (phi + d.v.w * log(r / d.u.w) - d.axis.w);
            float vertical = pow(1.0 / cosh(K * z / max(beta, 1e-3)), beta);
            return -d.center.w * exp(-(r - d.ramp.z) / d.u.w) / (K * D) * cos(gamma) * vertical;
        }

        kernel void bhDrive(device const float3 *positions [[buffer(0)]],
                            device float3 *velocities [[buffer(1)]],
                            device const uint *component [[buffer(2)]],
                            device const uint *galaxy [[buffer(3)]],
                            constant SpiralDrive *drives [[buffer(4)]],
                            constant SpiralDriveParams &p [[buffer(5)]],
                            uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            // Disk material only: a bulge, a thick disk or dark matter has no arm to hold.
            if (component[i] >= 3u) { return; }
            uint g = galaxy[i];
            if (g >= p.galaxyCount) { return; }
            SpiralDrive d = drives[g];
            if (d.center.w <= 0.0 || d.ramp.x <= 0.0) { return; }
            float3 offset = positions[i] - d.center.xyz;
            float x = dot(offset, d.u.xyz);
            float y = dot(offset, d.v.xyz);
            float z = dot(offset, d.axis.xyz);
            float r = sqrt(x * x + y * y);
            float inner = d.window.z > 0.0 ? smoothstep(d.window.z, 1.3 * d.window.z, r) : 1.0;
            float weight = d.ramp.x * inner * (1.0 - smoothstep(0.9 * d.window.w, 1.1 * d.window.w, r));
            if (weight <= 0.0) { return; }
            float h = 0.02;
            float ax = -(spiralPotential(x + h, y, z, d) - spiralPotential(x - h, y, z, d)) / (2.0 * h);
            float ay = -(spiralPotential(x, y + h, z, d) - spiralPotential(x, y - h, z, d)) / (2.0 * h);
            float az = -(spiralPotential(x, y, z + h, d) - spiralPotential(x, y, z - h, d)) / (2.0 * h);
            velocities[i] += (d.u.xyz * ax + d.v.xyz * ay + d.axis.xyz * az) * (weight * p.timeStep);
        }
        """
}
