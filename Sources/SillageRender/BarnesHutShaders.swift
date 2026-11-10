/// Barnes-Hut traversal and integration in Metal Shading Language.
enum BarnesHutShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct BHNode {
            float4 comMass;
            // Width squared, then the range start and the signed count carried as bit
            // patterns rather than as values: a float cannot count past 16 777 216, and a
            // tree over more particles than that rounded its leaf starts and read past the
            // end of `order`. Positive is a child count, negative a leaf's particle count.
            float4 packed;
        };

        inline int bhRange(BHNode node) { return as_type<int>(node.packed.y); }
        inline int bhSignedCount(BHNode node) { return as_type<int>(node.packed.z); }

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
            float r = max(length(offset), 1e-6f);
            float s = r + scale;
            return -mass * offset / (r * s * s);
        }

        static float3 halos(float3 position, constant HaloGPU *list, uint count, bool after) {
            float3 total = float3(0.0f);
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
            float3 v = velocities[i] + accelerations[i] * (p.timeStep * 0.5f);
            velocities[i] = v;
            positions[i] += v * p.timeStep;
        }

        kernel void bhKick(device float3 *velocities [[buffer(0)]],
                           device const float3 *accelerations [[buffer(1)]],
                           constant BHParams &p [[buffer(2)]],
                           uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            velocities[i] += accelerations[i] * (p.timeStep * 0.5f);
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
        static float3 bhCool(float3 position, float3 velocity, float3 acceleration,
                             DiskCooling disk) {
            float damping = disk.motion.w;
            if (damping <= 0.0f) { return velocity; }

            float3 axis = disk.axis.xyz;
            float3 offset = position - disk.center.xyz;
            float height = dot(offset, axis);
            float3 inPlane = offset - axis * height;
            float radius = length(inPlane);
            if (radius < 1e-3f) { return velocity; }

            // Fades out rather than stopping at an edge, or the disk would gain a ring where
            // the cooling ends.
            float radial = 1.0f - smoothstep(disk.reach.x, disk.reach.y, radius);
            float vertical = 1.0f - smoothstep(disk.reach.z, disk.reach.w, abs(height));
            float weight = damping * radial * vertical;
            if (weight <= 0.0f) { return velocity; }

            float3 outward = inPlane / radius;
            float inward = -dot(acceleration, outward);
            if (inward <= 0.0f) { return velocity; }
            float speed = sqrt(inward * radius);

            float3 along = cross(axis, outward);
            float3 target = disk.motion.xyz + along * speed;

            // Cooling all the way to a circular orbit is not what gas does and not what a
            // disk survives: below a Toomre parameter of one it fragments into clumps, which
            // is exactly what happened when this pulled the whole way. The random motion
            // decays towards the dispersion the disk is meant to hold and stops there.
            float3 peculiar = velocity - target;
            float random = length(peculiar);
            float floorSpeed = disk.center.w * speed;
            if (random <= floorSpeed || random < 1e-6f) { return velocity; }
            float cooled = max(random * (1.0f - weight), floorSpeed);
            return target + peculiar * (cooled / random);
        }

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
            // Dark matter has no gas in it; a bulge is held up by the very motion this takes
            // away; and the thick disk is old enough that there is no gas left in it to cool
            // through. Measured on the last of those: cooled along with the thin disk, its
            // median height fell from 0.91 kpc to 0.32 and its outer radius from 25 kpc to 17
            // over three hundred megayears, so the galaxy's soft edge lasted about as long as
            // it took to look away.
            if (kind >= 3u) { return; }
            DiskCooling disk = disks[galaxy[i]];
            if (disk.motion.w <= 0.0f) { return; }
            velocities[i] = bhCool(positions[i], velocities[i], accelerations[i], disk);
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
            return float(h) * (1.0f / 4294967296.0f);
        }

        // Light tracers (#187) are not in the tree, so their gas reads the chance of a massive
        // gas particle's leaf: each leaf writes its chance into its gas slots, and -1 into the
        // others.
        constant bool bhLeafChances [[function_constant(2)]];

        static void bhWriteChances(device float *slotChances, device const uint *order,
                                   device const uint *component, uint start, uint count,
                                   float chance) {
            for (uint k = 0u; k < count; ++k) {
                slotChances[start + k] = component[order[start + k]] == 2u ? chance : -1.0f;
            }
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
                                device float *slotChances [[buffer(8)]],
                                uint n [[thread_position_in_grid]]) {
            if (n >= s.nodeCount) { return; }
            BHNode node = nodes[n];
            // A positive count is a branch; a leaf carries minus the particles it holds.
            if (bhSignedCount(node) > 0) { return; }
            uint count = uint(-bhSignedCount(node));
            if (count == 0u) { return; }
            uint start = uint(bhRange(node));
            if (bhLeafChances) { bhWriteChances(slotChances, order, component, start, count, 0.0f); }
            float width = sqrt(max(node.packed.x, 1e-12f));

            float baryons = 0.0f;
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
            float3 meanPosition = float3(0.0f);
            float3 meanVelocity = float3(0.0f);
            uint baryonCount = 0u;
            for (uint k = 0u; k < count; ++k) {
                uint i = order[start + k];
                if (component[i] == 3u) { continue; }
                meanPosition += positions[i];
                meanVelocity += velocities[i];
                baryonCount += 1u;
            }
            float freeFall = sqrt(s.gravitationalConstant * density);
            float compression = 0.0f;
            if (baryonCount >= 4u && freeFall > 1e-12f) {
                float inv = 1.0f / float(baryonCount);
                meanPosition *= inv;
                meanVelocity *= inv;
                float flux = 0.0f;
                float spread = 0.0f;
                for (uint k = 0u; k < count; ++k) {
                    uint i = order[start + k];
                    if (component[i] == 3u) { continue; }
                    float3 dr = positions[i] - meanPosition;
                    flux += dot(velocities[i] - meanVelocity, dr);
                    spread += dot(dr, dr);
                }
                if (spread > 1e-12f) {
                    // Trace of the velocity gradient. Negative is converging.
                    float divergence = 3.0f * flux / spread;
                    // Above the floor only. Taking the converging half of a noisy estimator
                    // turns its noise into a rate everywhere, which burned a quiescent disk's
                    // whole gas reservoir before its encounter arrived.
                    compression = max(-divergence / freeFall - s.compressionFloor, 0.0f);
                }
            }

            float rate = s.efficiency
                * sqrt(32.0f * s.gravitationalConstant * density / (3.0f * M_PI_F))
                * (1.0f + s.compressionBoost * compression);
            float chance = 1.0f - exp(-rate * s.timeStep);
            if (bhLeafChances) {
                bhWriteChances(slotChances, order, component, start, count, max(chance, 0.0f));
            }
            if (chance <= 0.0f) { return; }

            for (uint k = 0u; k < count; ++k) {
                uint i = order[start + k];
                // Gas only, and only gas that has not already made its stars. Written once
                // and never unwritten, which is what lets one static array replay the whole
                // history of a run.
                if (component[i] != 2u) { continue; }
                if (formation[i] < 1e8f) { continue; }
                if (hashUnit(i, s.seed) >= chance) { continue; }
                formation[i] = s.time;
            }
        }

        inline ulong bhSpread(uint value) {
            ulong x = ulong(value) & 0x1FFFFFul;
            x = (x | (x << 32)) & 0x001F00000000FFFFul;
            x = (x | (x << 16)) & 0x001F0000FF0000FFul;
            x = (x | (x << 8)) & 0x100F00F00F00F00Ful;
            x = (x | (x << 4)) & 0x10C30C30C30C30C3ul;
            x = (x | (x << 2)) & 0x1249249249249249ul;
            return x;
        }

        // A tracer's gas forms its stars at the chance of the massive gas particle just before
        // it in Morton order, almost always in its own cell or the next one. Drawn from the
        // same distribution, tracer gas is equally likely to follow any massive gas particle,
        // so the chances it reads are distributed as theirs are. A tracer's formation time is
        // the w of its position, its kind in the word in the w of its velocity (#238).
        kernel void bhTracerFormStars(device float4 *states [[buffer(0)]],
                                      device const uint4 *motions [[buffer(1)]],
                                      device const ulong *codes [[buffer(3)]],
                                      device const float *frame [[buffer(4)]],
                                      device const float *slotChances [[buffer(5)]],
                                      constant SFParams &s [[buffer(6)]],
                                      constant uint2 &counts [[buffer(7)]],
                                      uint i [[thread_position_in_grid]]) {
            if (i >= counts.x || counts.y == 0u || s.nodeCount == 0u) { return; }
            if (((motions[i].w >> 4) & 7u) != 2u) { return; }
            float4 state = states[i];
            if (state.w < 1e8f) { return; }
            const float resolution = 2097151.0f;
            float3 local = (state.xyz - float3(frame[0], frame[1], frame[2])) * frame[3];
            local = clamp(local, 0.0f, resolution);
            ulong code = (bhSpread(uint(local.x)) << 2) | (bhSpread(uint(local.y)) << 1)
                       | bhSpread(uint(local.z));
            uint low = 0u;
            uint high = counts.y;
            while (low < high) {
                uint middle = (low + high) / 2u;
                if (codes[middle] < code) { low = middle + 1u; } else { high = middle; }
            }
            // Gas is a minority of the tree, dark matter included, so it may be a few slots
            // back. Far from any, there is none to read.
            float chance = -1.0f;
            for (uint back = 0u; back < 256u && back < low && chance < 0.0f; ++back) {
                chance = slotChances[low - 1u - back];
            }
            for (uint ahead = low; ahead < min(low + 256u, counts.y) && chance < 0.0f; ++ahead) {
                chance = slotChances[ahead];
            }
            if (chance <= 0.0f) { return; }
            if (hashUnit(i | 0x80000000u, s.seed) >= chance) { return; }
            state.w = s.time;
            states[i] = state;
        }

        // The particles in Morton order with their mass beside them, so a leaf's direct sum
        // reads one contiguous run rather than two scattered reads per neighbour. Gathered
        // before every force pass rather than once per build: a tree may be reused or built
        // a step behind, and the sum has to see where the particles are now.
        kernel void bhGather(device float4 *sorted [[buffer(0)]],
                             device const float3 *positions [[buffer(1)]],
                             device const float *mass [[buffer(2)]],
                             device const uint *order [[buffer(3)]],
                             constant BHParams &p [[buffer(4)]],
                             uint slot [[thread_position_in_grid]]) {
            if (slot >= p.particleCount) { return; }
            uint i = order[slot];
            sorted[slot] = float4(positions[i], mass[i]);
        }

        // Black holes pull outside the tree. A hole is one particle up to a hundred thousand
        // times heavier than a star; summed through the tree it would be softened at the
        // stars' length and fold into every cell it sits in. Here it pulls on every particle
        // directly at a softening of its own, and takes the exact reaction back, so the pair
        // forces stay equal and opposite. The tree sees it with no mass.
        struct HoleGPU {
            // xyz unused, w the mass times the gravitational constant.
            float4 massG;
            // x the softening squared, y the particle's index as a bit pattern.
            float4 shape;
        };

        constant uint bhHoleLimit = 4;

        kernel void bhHolePull(device const float3 *positions [[buffer(0)]],
                               device float3 *accelerations [[buffer(1)]],
                               device const float *mass [[buffer(2)]],
                               device const uint *component [[buffer(3)]],
                               constant HoleGPU *holes [[buffer(4)]],
                               constant uint &holeCount [[buffer(5)]],
                               constant BHParams &p [[buffer(6)]],
                               device float4 *partial [[buffer(7)]],
                               uint i [[thread_position_in_grid]],
                               uint lane [[thread_index_in_threadgroup]],
                               uint group [[threadgroup_position_in_grid]],
                               uint width [[threads_per_threadgroup]],
                               uint simdLane [[thread_index_in_simdgroup]],
                               uint simdGroup [[simdgroup_index_in_threadgroup]]) {
            threadgroup float3 sums[bhHoleLimit][32];
            bool counted = i < p.particleCount && component[i] != 6u;
            float3 position = counted ? positions[i] : float3(0.0f);
            float3 pulled = float3(0.0f);
            for (uint h = 0; h < holeCount; ++h) {
                float3 back = float3(0.0f);
                if (counted) {
                    float3 d = position - positions[as_type<uint>(holes[h].shape.y)];
                    float r2 = dot(d, d) + holes[h].shape.x;
                    float inverse = 1.0f / (r2 * sqrt(r2));
                    pulled -= d * (holes[h].massG.w * inverse);
                    back = d * (p.gravitationalConstant * mass[i] * inverse);
                }
                back = simd_sum(back);
                if (simdLane == 0) { sums[h][simdGroup] = back; }
            }
            if (counted) { accelerations[i] += pulled; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (lane != 0) { return; }
            uint groups = (width + 31) / 32;
            for (uint h = 0; h < holeCount; ++h) {
                float3 total = float3(0.0f);
                for (uint g = 0; g < groups; ++g) { total += sums[h][g]; }
                partial[group * bhHoleLimit + h] = float4(total, 0.0f);
            }
        }

        // One thread: the reactions added up in a fixed order, so a run repeats exactly, and
        // the holes' pull on each other. The analytic halos the tree added are kept.
        kernel void bhHoleSettle(device const float3 *positions [[buffer(0)]],
                                 device float3 *accelerations [[buffer(1)]],
                                 constant HoleGPU *holes [[buffer(2)]],
                                 constant uint &holeCount [[buffer(3)]],
                                 constant uint &groups [[buffer(4)]],
                                 device const float4 *partial [[buffer(5)]],
                                 constant HaloGPU *haloList [[buffer(6)]],
                                 constant BHParams &p [[buffer(7)]],
                                 uint gid [[thread_position_in_grid]]) {
            if (gid != 0) { return; }
            for (uint h = 0; h < holeCount; ++h) {
                uint index = as_type<uint>(holes[h].shape.y);
                float3 position = positions[index];
                float3 total = float3(0.0f);
                for (uint g = 0; g < groups; ++g) { total += partial[g * bhHoleLimit + h].xyz; }
                for (uint o = 0; o < holeCount; ++o) {
                    if (o == h) { continue; }
                    float3 d = positions[as_type<uint>(holes[o].shape.y)] - position;
                    float r2 = dot(d, d) + max(holes[o].shape.x, holes[h].shape.x);
                    total += d * (holes[o].massG.w / (r2 * sqrt(r2)));
                }
                accelerations[index] = total + halos(position, haloList, p.haloCount, true);
            }
        }

        constant bool bhQuadrupole [[function_constant(0)]];
        // Off only to measure the walk that took a branch around the particle whole (#221).
        constant bool bhOpensHoldingCells [[function_constant(3)]];

        // One traversal from `position`. A cell is accepted whole when its width subtends less
        // than the opening angle, and opened otherwise; leaves fall back to direct summation.
        //
        // A cell that holds the particle is always opened. Inside a cube the centre of mass can
        // be up to 1.7 widths away, past the 1.11 the angle asks at 0.9, and a particle in the
        // far corner of a lopsided cell took it as one point: a dwarf took the whole root, its
        // own stars with it, and lost its own gravity (#221). A cell holds the particle when its
        // parent does and the particle's Morton `code` has the cell's digit at the cell's level;
        // the stack carries the first half down with each range of siblings. `own` is the
        // walker's Morton slot, which its own leaf's sum skips; a light tracer is in no leaf and
        // passes 0xFFFFFFFF.
        static float3 bhWalk(float3 position, ulong code, bool inRoot, uint own,
                             device const float4 *sorted, device const BHNode *nodes,
                             device const float4 *moments, float openingAngleSquared,
                             float softeningSquared, float gravitationalConstant,
                             thread uint &work) {
            float3 total = float3(0.0f);
            // Sibling cells are contiguous, so the stack holds ranges rather than single
            // nodes: one entry per level of the tree instead of one per pending sibling.
            // The old form could hold seven entries per level, so sixty-four slots were
            // already not enough at ten levels — and running out meant silently dropping
            // whole cells, and their mass, out of the sum. An entry packs the next node of
            // the range in the high bits, which leaves room for 2^27 nodes, then whether their
            // parent holds the particle, then how many siblings follow it in the low three.
            int stack[32];
            int top = 0;
            stack[top++] = inRoot ? 8 : 0;

            while (top > 0) {
                int entry = stack[--top];
                int index = entry >> 4;
                int around = entry & 8;
                int following = entry & 7;
                if (following > 0) { stack[top++] = ((index + 1) << 4) | around | (following - 1); }
                BHNode node = nodes[index];
                if (node.comMass.w <= 0.0f) { continue; }
                work += 1;

                float3 offset = node.comMass.xyz - position;
                float distanceSquared = dot(offset, offset) + softeningSquared;
                bool leaf = bhSignedCount(node) <= 0;
                int start = bhRange(node);
                int span = -bhSignedCount(node);
                // Whether this node holds the particle. For a leaf of massive particles it is
                // the leaf whose run of the Morton order holds this slot, so a node may never
                // stand in for itself.
                uint digit = as_type<uint>(node.packed.w);
                bool holdsMe = bhOpensHoldingCells
                    ? around != 0 && uint((code >> (digit >> 3)) & 7ul) == (digit & 7u)
                    : leaf && own >= uint(start) && own < uint(start + span);

                if (!holdsMe && node.packed.x <= openingAngleSquared * distanceSquared) {
                    // Far enough that the centre of mass stands in — for a leaf as much as
                    // for a branch. Summing a distant leaf particle by particle was the
                    // single largest cost in an evolved scene: as the disk concentrates,
                    // leaves at the depth limit grow to hundreds of particles, and every one
                    // of them was being summed in full by every particle that reached it.
                    total += offset
                           * (gravitationalConstant * node.comMass.w
                              / (distanceSquared * sqrt(distanceSquared)));
                    if (bhQuadrupole) {
                        // The next term of the softened potential about the centre of mass.
                        // With softening the trace no longer drops out, so all six are kept.
                        float4 qa = moments[2 * index];
                        float4 qb = moments[2 * index + 1];
                        float3 qr = float3(qa.x * offset.x + qa.w * offset.y + qb.x * offset.z,
                                           qa.w * offset.x + qa.y * offset.y + qb.y * offset.z,
                                           qb.x * offset.x + qb.y * offset.y + qa.z * offset.z);
                        float inverse = 1.0f / distanceSquared;
                        float fifth = inverse * inverse / sqrt(distanceSquared);
                        float radial = 7.5f * dot(offset, qr) * inverse - 1.5f * (qa.x + qa.y + qa.z);
                        total += (offset * radial - 3.0f * qr) * (gravitationalConstant * fifth);
                    }
                } else if (leaf) {
                    work += uint(span);
                    for (int k = start; k < start + span; ++k) {
                        if (uint(k) == own) { continue; }
                        float4 other = sorted[k];
                        float3 d = other.xyz - position;
                        float r2 = dot(d, d) + softeningSquared;
                        total += d * (gravitationalConstant * other.w / (r2 * sqrt(r2)));
                    }
                } else {
                    int first = bhRange(node);
                    int children = bhSignedCount(node);
                    if (children > 0) {
                        stack[top++] = (first << 4) | (holdsMe ? 8 : 0) | (children - 1);
                    }
                }
            }
            return total;
        }

        // One traversal per massive particle, its own pieces of the force pass.
        kernel void bhAcceleration(device const float4 *sorted [[buffer(0)]],
                                   device float3 *accelerations [[buffer(1)]],
                                   device const BHNode *nodes [[buffer(2)]],
                                   device const uint *order [[buffer(3)]],
                                   constant HaloGPU *haloList [[buffer(4)]],
                                   constant BHParams &p [[buffer(5)]],
                                   device uint *cost [[buffer(6)]],
                                   device const float4 *moments [[buffer(7)]],
                                   device const ulong *codes [[buffer(10)]],
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
            float3 position = sorted[slot].xyz;
            // The code the tree sorted this particle by.
            ulong code = bhOpensHoldingCells ? codes[slot] : 0ul;
            // What this lane actually does. Divergence inside a SIMD group is the whole
            // question for a cooperative traversal, and it cannot be reasoned about: the
            // group already executes the union of its lanes' paths with the idle ones masked
            // off, so what a shared traversal would buy back is exactly the masking.
            uint work = 0;
            float3 total = bhWalk(position, code, true, slot, sorted, nodes, moments,
                                  p.openingAngleSquared, p.softeningSquared,
                                  p.gravitationalConstant, work);
            accelerations[i] = total + halos(position, haloList, p.haloCount, true);
            cost[slot] = work;
        }

        // Light tracers (#238) hold a position with the time their stars formed in w, and a
        // velocity with a packed word in w: galaxy in bits 0 to 3, kind in 4 to 6.
        kernel void bhTracerDrift(device float4 *states [[buffer(0)]],
                                  device const uint4 *motions [[buffer(1)]],
                                  constant BHParams &p [[buffer(2)]],
                                  uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            float4 state = states[i];
            state.xyz += as_type<float3>(motions[i].xyz) * p.timeStep;
            states[i] = state;
        }

        struct TracerStepParams {
            uint tracerCount;
            uint haloCount;
            float timeStep;
            float openingAngleSquared;
            float softeningSquared;
            float gravitationalConstant;
            uint chunkStart;
            /// The walk order is sorted a chunk at a time and counts from each chunk's start.
            uint sortChunk;
            uint holeCount;
            /// Zero when no disk is being cooled.
            uint diskCount;
            /// 0 opens the first step, 1 closes this one and opens the next, 2 only writes
            /// the acceleration.
            uint mode;
            uint _pad;
        };

        // A light tracer's whole force pass, fused so it keeps no acceleration of its own: the
        // walk through the massive tree, which no leaf of holds it, the analytic halos and the
        // black holes, then this step's closing half kick, the cooling and the next step's
        // opening half kick, which is what a massive particle gets from the kick, the cooling
        // and the next step's kick and drift. The drift alone is left for the next step.
        kernel void bhTracerStep(device float4 *states [[buffer(0)]],
                                 device uint4 *motions [[buffer(1)]],
                                 device const float4 *sorted [[buffer(2)]],
                                 device const BHNode *nodes [[buffer(3)]],
                                 device const float4 *moments [[buffer(4)]],
                                 device const uint *order [[buffer(5)]],
                                 device const float *frame [[buffer(6)]],
                                 constant HaloGPU *haloList [[buffer(7)]],
                                 constant HoleGPU *holes [[buffer(8)]],
                                 device const float3 *massive [[buffer(9)]],
                                 constant DiskCooling *disks [[buffer(10)]],
                                 constant TracerStepParams &p [[buffer(11)]],
                                 device float3 *probe [[buffer(12)]],
                                 uint gid [[thread_position_in_grid]]) {
            uint slot = gid + p.chunkStart;
            if (slot >= p.tracerCount) { return; }
            uint i = slot - slot % p.sortChunk + order[slot];
            float3 position = states[i].xyz;
            uint4 motion = motions[i];
            // Placed by the rule the tree sorted by; outside the root it is in no cell at all.
            const float resolution = 2097151.0f;
            float3 local = (position - float3(frame[0], frame[1], frame[2])) * frame[3];
            bool inRoot = all(local >= 0.0f) && all(local <= resolution);
            local = clamp(local, 0.0f, resolution);
            ulong code = (bhSpread(uint(local.x)) << 2) | (bhSpread(uint(local.y)) << 1)
                       | bhSpread(uint(local.z));
            uint work = 0;
            float3 acceleration = bhWalk(position, code, inRoot, 0xFFFFFFFFu, sorted, nodes,
                                         moments, p.openingAngleSquared, p.softeningSquared,
                                         p.gravitationalConstant, work)
                                + halos(position, haloList, p.haloCount, true);
            for (uint h = 0; h < p.holeCount; ++h) {
                float3 d = position - massive[as_type<uint>(holes[h].shape.y)];
                float r2 = dot(d, d) + holes[h].shape.x;
                float inverse = 1.0f / (r2 * sqrt(r2));
                acceleration -= d * (holes[h].massG.w * inverse);
            }
            if (p.mode == 2u) {
                probe[i] = acceleration;
                return;
            }
            float3 velocity = as_type<float3>(motion.xyz);
            float halfStep = p.timeStep * 0.5f;
            if (p.mode == 1u) {
                velocity += acceleration * halfStep;
                uint kind = (motion.w >> 4) & 7u;
                if (kind < 3u && p.diskCount > 0u) {
                    DiskCooling disk = disks[min(motion.w & 15u, p.diskCount - 1u)];
                    velocity = bhCool(position, velocity, acceleration, disk);
                }
            }
            velocity += acceleration * halfStep;
            motions[i] = uint4(as_type<uint3>(velocity), motion.w);
        }
        """
}
