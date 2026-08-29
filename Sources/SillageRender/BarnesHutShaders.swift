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

        struct DiskCooling {
            // xyz centre of the disk, w the dispersion it may not be cooled below, as a
            // fraction of the local circular speed.
            float4 center;
            // xyz how fast the whole galaxy is moving, w the share of the gap closed per step.
            float4 motion;
            // xyz the axis the disk turns about, w the direction it turns in.
            float4 axis;
            // Radial and vertical reach, beyond which the material is no longer disk.
            float4 reach;
        };

        // Sheds the random motion a disk picks up, which is the one thing that keeps its arms.
        //
        // A disk of stars alone can only heat. Each spiral it raises stirs it further, the
        // Toomre parameter climbs past the point where anything can be amplified, and within a
        // gigayear the galaxy is a smooth spheroid. Real disks escape that because their gas
        // radiates the motion away and forms new stars on circular orbits faster than the
        // spirals heat them. There is no gas here, so the effect goes in directly: pull each
        // particle a little towards the circular orbit it would be on.
        //
        // The speed of that orbit is not tabulated. The solver has just worked out the force
        // on this particle, and a circular orbit is what balances it, so v = sqrt(|a_r| r)
        // reads straight out of the field, self-consistent with whatever mass is really there.
        //
        // Only material still in the disk is touched. A tidal tail is gas and stars thrown
        // clear, on no circular orbit at all, and cooling it would quietly erase the very
        // thing an encounter is watched for.
        kernel void bhDissipate(device const float3 *positions [[buffer(0)]],
                                device float3 *velocities [[buffer(1)]],
                                device const float3 *accelerations [[buffer(2)]],
                                device const uint *component [[buffer(3)]],
                                device const uint *galaxy [[buffer(4)]],
                                constant DiskCooling *disks [[buffer(5)]],
                                constant BHParams &p [[buffer(6)]],
                                uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            uint kind = component[i];
            // Dark matter has no gas in it, and a bulge is held up by the very motion this
            // takes away.
            if (kind == 3u || kind == 4u) { return; }

            DiskCooling disk = disks[galaxy[i]];
            float damping = disk.motion.w;
            if (damping <= 0.0) { return; }

            float3 axis = disk.axis.xyz;
            float3 offset = positions[i] - disk.center.xyz;
            float height = dot(offset, axis);
            float3 inPlane = offset - axis * height;
            float radius = length(inPlane);
            if (radius < 1e-3) { return; }

            // Fades out rather than stopping at an edge, or the disk would gain a ring where
            // the cooling ends.
            float radial = 1.0 - smoothstep(disk.reach.x, disk.reach.y, radius);
            float vertical = 1.0 - smoothstep(disk.reach.z, disk.reach.w, abs(height));
            float weight = damping * radial * vertical;
            if (weight <= 0.0) { return; }

            float3 outward = inPlane / radius;
            float inward = -dot(accelerations[i], outward);
            if (inward <= 0.0) { return; }
            float speed = sqrt(inward * radius);

            float3 along = cross(axis, outward) * disk.axis.w;
            float3 target = disk.motion.xyz + along * speed;

            // Cooling all the way to a circular orbit is not what gas does and not what a
            // disk survives: below a Toomre parameter of one it fragments into clumps, which
            // is exactly what happened when this pulled the whole way. The random motion
            // decays towards the dispersion the disk is meant to hold and stops there.
            float3 peculiar = velocities[i] - target;
            float random = length(peculiar);
            float floorSpeed = disk.center.w * speed;
            if (random <= floorSpeed || random < 1e-6) { return; }
            float cooled = max(random * (1.0 - weight), floorSpeed);
            velocities[i] = target + peculiar * (cooled / random);
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
