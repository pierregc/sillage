/// Barnes-Hut traversal and integration in Metal Shading Language.
enum BarnesHutShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct BHNode {
            float4 comMass;
            // width squared, range start, signed count. Positive is a child count,
            // negative a leaf's particle count.
            float4 packed;
        };

        struct HaloGPU {
            float4 centerBefore;
            float4 centerAfter;
            float4 shape;
        };

        struct BHParams {
            uint particleCount;
            uint haloCount;
            float timeStep;
            float openingAngleSquared;
            float softeningSquared;
            float gravitationalConstant;
            float _pad0;
            float _pad1;
        };

        // profile 0 is Plummer, 1 is Hernquist. Mass already carries the gravitational constant.
        static float3 haloAcceleration(float3 offset, float mass, float scale, uint profile) {
            if (profile == 0u) {
                float d2 = dot(offset, offset) + scale * scale;
                return -mass * offset / (d2 * sqrt(d2));
            }
            float r = max(length(offset), 1e-6);
            float s = r + scale;
            return -mass * offset / (r * s * s);
        }

        static float3 halos(float3 position, constant HaloGPU *list, uint count, bool after) {
            float3 total = float3(0.0);
            for (uint h = 0; h < count; ++h) {
                float3 center = after ? list[h].centerAfter.xyz : list[h].centerBefore.xyz;
                total += haloAcceleration(
                    position - center, list[h].shape.x, list[h].shape.y, uint(list[h].shape.z));
            }
            return total;
        }

        // Half kick with the acceleration left over from the previous step, then drift. The tree
        // is rebuilt from the drifted positions before the second half kick.
        kernel void bhKickDrift(device float3 *positions [[buffer(0)]],
                                device float3 *velocities [[buffer(1)]],
                                device const float3 *accelerations [[buffer(2)]],
                                constant BHParams &p [[buffer(3)]],
                                uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            float3 v = velocities[i] + accelerations[i] * (p.timeStep * 0.5);
            velocities[i] = v;
            positions[i] += v * p.timeStep;
        }

        kernel void bhKick(device float3 *velocities [[buffer(0)]],
                           device const float3 *accelerations [[buffer(1)]],
                           constant BHParams &p [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            velocities[i] += accelerations[i] * (p.timeStep * 0.5);
        }

        // One traversal per particle. A cell is accepted whole when its width subtends less than
        // the opening angle, and opened otherwise; leaves fall back to direct summation. The
        // stack cannot exceed seven entries per level of the tree.
        kernel void bhAcceleration(device const float3 *positions [[buffer(0)]],
                                   device float3 *accelerations [[buffer(1)]],
                                   device const BHNode *nodes [[buffer(2)]],
                                   device const uint *order [[buffer(3)]],
                                   device const float *mass [[buffer(4)]],
                                   constant HaloGPU *haloList [[buffer(5)]],
                                   constant BHParams &p [[buffer(6)]],
                                   uint gid [[thread_position_in_grid]]) {
            if (gid >= p.particleCount) { return; }
            // Threads walk the tree in Morton order, so neighbours in a SIMD group are also
            // neighbours in space and take almost the same path. Traversing in sampling order
            // leaves every lane on a different branch and the divergence dominates the cost.
            uint i = order[gid];
            float3 position = positions[i];
            float3 total = float3(0.0);

            int stack[64];
            int top = 0;
            stack[top++] = 0;

            while (top > 0) {
                int index = stack[--top];
                BHNode node = nodes[index];
                if (node.comMass.w <= 0.0) { continue; }

                float3 offset = node.comMass.xyz - position;
                float distanceSquared = dot(offset, offset) + p.softeningSquared;
                                bool leaf = node.packed.z <= 0.0;

                if (!leaf && node.packed.x > p.openingAngleSquared * distanceSquared) {
                    int first = int(node.packed.y);
                    int children = int(node.packed.z);
                    for (int c = 0; c < children && top < 63; ++c) {
                        stack[top++] = first + c;
                    }
                } else if (leaf) {
                    int start = int(node.packed.y);
                    int count = int(-node.packed.z);
                    for (int k = 0; k < count; ++k) {
                        uint j = order[start + k];
                        if (j == i) { continue; }
                        float3 d = positions[j] - position;
                        float r2 = dot(d, d) + p.softeningSquared;
                        total += d * (p.gravitationalConstant * mass[j] / (r2 * sqrt(r2)));
                    }
                } else {
                    total += offset
                           * (p.gravitationalConstant * node.comMass.w
                              / (distanceSquared * sqrt(distanceSquared)));
                }
            }

            accelerations[i] = total + halos(position, haloList, p.haloCount, true);
        }
        """
}
