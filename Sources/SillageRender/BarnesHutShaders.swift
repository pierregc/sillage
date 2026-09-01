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
            /// First particle of the piece being dispatched.
            uint chunkStart;
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
            // xyz the axis the disk turns about, measured from the disk itself every time
            // the tree is rebuilt. It carries the sense of rotation in its direction, so
            // there is no separate spin sign; w is unused.
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

            float3 along = cross(axis, outward);
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

        struct SFParams {
            float efficiency;
            float threshold;
            float timeStep;
            float time;
            float gravitationalConstant;
            float compressionBoost;
            float compressionFloor;
            uint seed;
            uint nodeCount;
        };

        // A unit float from two integers. Per particle and per step, so a knot forming is an
        // independent draw rather than the same particles winning every time.
        static float hashUnit(uint a, uint b) {
            uint h = a * 747796405u + b * 2891336453u;
            h = (h ^ (h >> 16u)) * 2246822519u;
            h = (h ^ (h >> 13u)) * 3266489917u;
            h ^= h >> 16u;
            return float(h) * (1.0 / 4294967296.0);
        }

        // Turns gas into stars where it has been compressed, one thread per tree node.
        //
        // The tree already holds the only thing this needs. A leaf is a cell of known width
        // holding known mass, which is a density estimate for free — no neighbour search, no
        // second tree, and it is the same estimator everywhere so a nucleus and a tail are
        // being compared on the same footing.
        //
        // The mass counted is the visible material only. Dark matter is three particles in
        // five and most of a leaf's weight, and none of it is gas: including it would make the
        // rate follow the halo rather than the disk, and would light up the middle of every
        // galaxy from the first step.
        //
        // The rule is Schmidt's. A fixed efficiency per free-fall time, with
        // t_ff = sqrt(3 pi / 32 G rho), so the chance a given gas particle makes its stars in
        // one step goes as the square root of the density around it. Below a threshold nothing
        // forms at all, which is what keeps the outskirts dark: without one the whole disk
        // slowly turns into knots, evenly, which is the opposite of what an encounter shows.
        kernel void bhFormStars(device float *formation [[buffer(0)]],
                                device const uint *component [[buffer(1)]],
                                device const float *mass [[buffer(2)]],
                                device const BHNode *nodes [[buffer(3)]],
                                device const uint *order [[buffer(4)]],
                                constant SFParams &s [[buffer(5)]],
                                device const float3 *positions [[buffer(6)]],
                                device const float3 *velocities [[buffer(7)]],
                                uint n [[thread_position_in_grid]]) {
            if (n >= s.nodeCount) { return; }
            BHNode node = nodes[n];
            // A positive count is a branch; a leaf carries minus the particles it holds.
            if (node.packed.z > 0.0) { return; }
            uint count = uint(-node.packed.z);
            if (count == 0u) { return; }
            uint start = uint(node.packed.y);
            float width = sqrt(max(node.packed.x, 1e-12));

            float baryons = 0.0;
            for (uint k = 0u; k < count; ++k) {
                uint i = order[start + k];
                if (component[i] != 3u) { baryons += mass[i]; }
            }
            float density = baryons / (width * width * width);
            if (density < s.threshold) { return; }

            // Density alone gives no burst, and finding that out is the point of the term
            // below. Star formation eats the densest gas first, so by the time an encounter
            // arrives the nucleus has none left and the rate only ever falls — measured on a
            // merger, 40 knots a megayear at the start and 9 at coalescence, with nothing at
            // pericentre. Real mergers burst because tidal torques drive *fresh* gas inward
            // and shock it, and none of that inflow exists here.
            //
            // What can be seen is the shock itself: the convergence of the flow, which is a
            // least-squares trace of the velocity gradient over the leaf's own particles and
            // is what a compression looks like from inside. Made dimensionless against the
            // free-fall rate, so it says how hard the material is being squeezed compared with
            // how hard its own gravity is squeezing it.
            float3 meanPosition = float3(0.0);
            float3 meanVelocity = float3(0.0);
            uint baryonCount = 0u;
            for (uint k = 0u; k < count; ++k) {
                uint i = order[start + k];
                if (component[i] == 3u) { continue; }
                meanPosition += positions[i];
                meanVelocity += velocities[i];
                baryonCount += 1u;
            }
            float freeFall = sqrt(s.gravitationalConstant * density);
            float compression = 0.0;
            if (baryonCount >= 4u && freeFall > 1e-12) {
                float inv = 1.0 / float(baryonCount);
                meanPosition *= inv;
                meanVelocity *= inv;
                float flux = 0.0;
                float spread = 0.0;
                for (uint k = 0u; k < count; ++k) {
                    uint i = order[start + k];
                    if (component[i] == 3u) { continue; }
                    float3 dr = positions[i] - meanPosition;
                    flux += dot(velocities[i] - meanVelocity, dr);
                    spread += dot(dr, dr);
                }
                if (spread > 1e-12) {
                    // Trace of the velocity gradient. Negative is converging.
                    float divergence = 3.0 * flux / spread;
                    // Above the floor only. Taking the converging half of a noisy estimator
                    // turns its noise into a rate everywhere, which burned a quiescent disk's
                    // whole gas reservoir before its encounter arrived.
                    compression = max(-divergence / freeFall - s.compressionFloor, 0.0);
                }
            }

            float rate = s.efficiency
                * sqrt(32.0 * s.gravitationalConstant * density / (3.0 * M_PI_F))
                * (1.0 + s.compressionBoost * compression);
            float chance = 1.0 - exp(-rate * s.timeStep);
            if (chance <= 0.0) { return; }

            for (uint k = 0u; k < count; ++k) {
                uint i = order[start + k];
                // Gas only, and only gas that has not already made its stars. Written once
                // and never unwritten, which is what lets one static array replay the whole
                // history of a run.
                if (component[i] != 2u) { continue; }
                if (formation[i] < 1e8) { continue; }
                if (hashUnit(i, s.seed) >= chance) { continue; }
                formation[i] = s.time;
            }
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
                                   device uint *cost [[buffer(7)]],
                                   uint gid [[thread_position_in_grid]]) {
            // Dispatched in pieces, so the display has somewhere to get in. One kernel over
            // seven million particles keeps the GPU to itself for the best part of a second
            // and the whole machine feels it.
            uint slot = gid + p.chunkStart;
            if (slot >= p.particleCount) { return; }
            // Threads walk the tree in Morton order, so neighbours in a SIMD group are also
            // neighbours in space and take almost the same path. Traversing in sampling order
            // leaves every lane on a different branch and the divergence dominates the cost.
            uint i = order[slot];
            float3 position = positions[i];
            float3 total = float3(0.0);
            // What this lane actually does. Divergence inside a SIMD group is the whole
            // question for a cooperative traversal, and it cannot be reasoned about: the
            // group already executes the union of its lanes' paths with the idle ones masked
            // off, so what a shared traversal would buy back is exactly the masking.
            uint work = 0;

            // Sibling cells are contiguous, so the stack holds ranges rather than single
            // nodes: one entry per level of the tree instead of one per pending sibling.
            // The old form could hold seven entries per level, so sixty-four slots were
            // already not enough at ten levels — and running out meant silently dropping
            // whole cells, and their mass, out of the sum. An entry packs the next node of
            // the range in the high bits and how many siblings follow it in the low three.
            int stack[32];
            int top = 0;
            stack[top++] = 0;

            while (top > 0) {
                int entry = stack[--top];
                int index = entry >> 3;
                int following = entry & 7;
                if (following > 0) { stack[top++] = ((index + 1) << 3) | (following - 1); }
                BHNode node = nodes[index];
                if (node.comMass.w <= 0.0) { continue; }
                work += 1;

                float3 offset = node.comMass.xyz - position;
                float distanceSquared = dot(offset, offset) + p.softeningSquared;
                bool leaf = node.packed.z <= 0.0;
                int start = int(node.packed.y);
                int span = int(-node.packed.z);
                // Whether this leaf is the one holding the particle. Leaves address a
                // contiguous run of the Morton order and slot is this particle's place in
                // it, so the test is exact: a node may never stand in for itself.
                bool holdsMe = leaf && slot >= uint(start) && slot < uint(start + span);

                if (!holdsMe && node.packed.x <= p.openingAngleSquared * distanceSquared) {
                    // Far enough that the centre of mass stands in — for a leaf as much as
                    // for a branch. Summing a distant leaf particle by particle was the
                    // single largest cost in an evolved scene: as the disk concentrates,
                    // leaves at the depth limit grow to hundreds of particles, and every one
                    // of them was being summed in full by every particle that reached it.
                    total += offset
                           * (p.gravitationalConstant * node.comMass.w
                              / (distanceSquared * sqrt(distanceSquared)));
                } else if (leaf) {
                    work += uint(span);
                    for (int k = 0; k < span; ++k) {
                        uint j = order[start + k];
                        if (j == i) { continue; }
                        float3 d = positions[j] - position;
                        float r2 = dot(d, d) + p.softeningSquared;
                        total += d * (p.gravitationalConstant * mass[j] / (r2 * sqrt(r2)));
                    }
                } else {
                    int first = int(node.packed.y);
                    int children = int(node.packed.z);
                    if (children > 0) { stack[top++] = (first << 3) | (children - 1); }
                }
            }

            accelerations[i] = total + halos(position, haloList, p.haloCount, true);
            cost[slot] = work;
        }
        """
}
