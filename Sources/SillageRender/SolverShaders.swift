/// Level 1 integrator in Metal Shading Language. Compiled at runtime, and portable verbatim
/// to a C++ or Rust host.
enum SolverShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct GalaxyGPU {
            float3 centerBefore;
            float3 centerAfter;
            float mass;
            float scaleRadius;
            uint profile;
            uint _pad;
        };

        struct IntegrateParams {
            uint particleCount;
            uint galaxyCount;
            float timeStep;
            float _pad;
        };

        // profile 0 is Plummer, 1 is Hernquist. Mass already carries the gravitational constant.
        static float3 potentialAcceleration(float3 offset, float mass, float scale, uint profile) {
            if (profile == 0) {
                float d2 = dot(offset, offset) + scale * scale;
                return -mass * offset / (d2 * sqrt(d2));
            }
            float r = max(length(offset), 1e-6);
            float s = r + scale;
            return -mass * offset / (r * s * s);
        }

        static float3 totalAcceleration(float3 position, constant GalaxyGPU *galaxies, uint count,
                                        bool after) {
            float3 total = float3(0.0);
            for (uint g = 0; g < count; ++g) {
                float3 center = after ? galaxies[g].centerAfter : galaxies[g].centerBefore;
                total += potentialAcceleration(position - center, galaxies[g].mass,
                                               galaxies[g].scaleRadius, galaxies[g].profile);
            }
            return total;
        }

        // Kick-drift-kick. The two half kicks straddle the drift, using the galaxy centres
        // before and after their own step, which makes this identical to the CPU reference.
        kernel void integrate(device float3 *positions [[buffer(0)]],
                              device float3 *velocities [[buffer(1)]],
                              constant GalaxyGPU *galaxies [[buffer(2)]],
                              constant IntegrateParams &p [[buffer(3)]],
                              uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            float dt = p.timeStep;
            float halfStep = dt * 0.5;

            float3 x = positions[i];
            float3 v = velocities[i];
            v += totalAcceleration(x, galaxies, p.galaxyCount, false) * halfStep;
            x += v * dt;
            v += totalAcceleration(x, galaxies, p.galaxyCount, true) * halfStep;
            positions[i] = x;
            velocities[i] = v;
        }
        """
}
