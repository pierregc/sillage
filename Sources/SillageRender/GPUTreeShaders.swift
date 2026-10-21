/// The Barnes-Hut tree built on the GPU, in Metal Shading Language.
enum GPUTreeShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct BHNode {
            float4 comMass;
            float4 packed;
        };

        inline int bhRange(BHNode node) { return as_type<int>(node.packed.y); }
        inline int bhSignedCount(BHNode node) { return as_type<int>(node.packed.z); }

        struct TreeParams {
            uint count;
            uint leafCapacity;
            uint maximumDepth;
            uint nodeCapacity;
            uint level;
            uint shift;
            uint tiles;
            uint tableLength;
            uint moments;
        };

        // counters: node count, overflow flag, then the bounds as ordered integers.
        constant uint counterNodes = 0;
        constant uint counterOverflow = 1;
        constant uint counterLower = 2;
        constant uint counterUpper = 5;

        // Floats compare as these integers do, so the bounds can be taken with integer atomics.
        inline uint orderedFloat(float value) {
            uint bits = as_type<uint>(value);
            return (bits & 0x80000000u) != 0u ? ~bits : (bits | 0x80000000u);
        }

        inline float unorderedFloat(uint key) {
            return as_type<float>((key & 0x80000000u) != 0u ? (key & 0x7FFFFFFFu) : ~key);
        }

        kernel void gtReset(device atomic_uint *counters [[buffer(0)]],
                            device uint *levels [[buffer(1)]],
                            uint gid [[thread_position_in_grid]]) {
            if (gid < 8u) {
                uint value = gid >= counterLower && gid < counterUpper ? 0xFFFFFFFFu : 0u;
                atomic_store_explicit(&counters[gid], value, memory_order_relaxed);
            }
            if (gid < 24u) { levels[gid] = 0u; }
        }

        kernel void gtBounds(device const float3 *positions [[buffer(0)]],
                             device atomic_uint *counters [[buffer(1)]],
                             constant TreeParams &p [[buffer(2)]],
                             uint gid [[thread_position_in_grid]],
                             uint threads [[threads_per_grid]],
                             uint t [[thread_index_in_threadgroup]],
                             uint simd [[simdgroup_index_in_threadgroup]],
                             uint lane [[thread_index_in_simdgroup]],
                             uint simds [[simdgroups_per_threadgroup]]) {
            float3 lower = float3(INFINITY);
            float3 upper = float3(-INFINITY);
            for (uint i = gid; i < p.count; i += threads) {
                float3 position = positions[i];
                if (!(isfinite(position.x) && isfinite(position.y) && isfinite(position.z))) {
                    continue;
                }
                lower = min(lower, position);
                upper = max(upper, position);
            }
            lower = simd_min(lower);
            upper = simd_max(upper);
            threadgroup float3 lowers[32];
            threadgroup float3 uppers[32];
            if (lane == 0u) {
                lowers[simd] = lower;
                uppers[simd] = upper;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (t != 0u) { return; }
            for (uint s = 1u; s < simds; ++s) {
                lower = min(lower, lowers[s]);
                upper = max(upper, uppers[s]);
            }
            for (uint axis = 0u; axis < 3u; ++axis) {
                atomic_fetch_min_explicit(
                    &counters[counterLower + axis], orderedFloat(lower[axis]), memory_order_relaxed);
                atomic_fetch_max_explicit(
                    &counters[counterUpper + axis], orderedFloat(upper[axis]), memory_order_relaxed);
            }
        }

        // The root cell and the frame the codes are taken in, exactly as the CPU build does.
        kernel void gtRoot(device atomic_uint *counters [[buffer(0)]],
                           device BHNode *nodes [[buffer(1)]],
                           device float *frame [[buffer(2)]],
                           device uint *levels [[buffer(3)]],
                           constant TreeParams &p [[buffer(4)]],
                           uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) { return; }
            float3 lower;
            float3 upper;
            for (uint axis = 0u; axis < 3u; ++axis) {
                lower[axis] = unorderedFloat(
                    atomic_load_explicit(&counters[counterLower + axis], memory_order_relaxed));
                upper[axis] = unorderedFloat(
                    atomic_load_explicit(&counters[counterUpper + axis], memory_order_relaxed));
            }
            levels[0] = 0u;
            if (p.count == 0u || !(lower.x <= upper.x)) {
                atomic_store_explicit(&counters[counterNodes], 0u, memory_order_relaxed);
                return;
            }
            float3 center = (lower + upper) * 0.5f;
            float3 extent = upper - lower;
            float radius = max(max(max(extent.x, extent.y), extent.z) * 0.5f, 1e-3f) * 1.001f;
            float inverse = 2097151.0f / (2.0f * radius);
            float3 origin = center - float3(radius);
            frame[0] = origin.x;
            frame[1] = origin.y;
            frame[2] = origin.z;
            frame[3] = inverse;
            frame[4] = radius;
            float width = radius * 2.0f;
            BHNode root;
            root.comMass = float4(0.0f);
            root.packed = float4(width * width, as_type<float>(0), as_type<float>(-int(p.count)), 0.0f);
            nodes[0] = root;
            atomic_store_explicit(&counters[counterNodes], 1u, memory_order_relaxed);
        }

        inline ulong spread(uint value) {
            ulong x = ulong(value) & 0x1FFFFFul;
            x = (x | (x << 32)) & 0x001F00000000FFFFul;
            x = (x | (x << 16)) & 0x001F0000FF0000FFul;
            x = (x | (x << 8)) & 0x100F00F00F00F00Ful;
            x = (x | (x << 4)) & 0x10C30C30C30C30C3ul;
            x = (x | (x << 2)) & 0x1249249249249249ul;
            return x;
        }

        kernel void gtMorton(device const float3 *positions [[buffer(0)]],
                             device ulong *codes [[buffer(1)]],
                             device uint *order [[buffer(2)]],
                             device const float *frame [[buffer(3)]],
                             constant TreeParams &p [[buffer(4)]],
                             uint i [[thread_position_in_grid]]) {
            if (i >= p.count) { return; }
            const float resolution = 2097151.0f;
            float3 origin = float3(frame[0], frame[1], frame[2]);
            float3 local = (positions[i] - origin) * frame[3];
            uint x = uint(min(max(local.x, 0.0f), resolution));
            uint y = uint(min(max(local.y, 0.0f), resolution));
            uint z = uint(min(max(local.z, 0.0f), resolution));
            codes[i] = (spread(x) << 2) | (spread(y) << 1) | spread(z);
            order[i] = i;
        }

        // Least significant digit radix sort, eight bits a pass. A tile is 256 threads of 8
        // keys; each SIMD group owns a contiguous run of 256 of them and walks it 32 at a time.
        constant uint radixBits = 8;
        constant uint buckets = 1u << radixBits;
        constant uint sortThreads = 256;
        constant uint sortItems = 8;
        constant uint sortSimds = sortThreads / 32u;
        constant uint tileSize = sortThreads * sortItems;
        constant uint simdItems = 32u * sortItems;

        // The lanes holding the same digit as this one. The extra bit marks a lane past the end.
        inline uint sameDigit(uint digit) {
            uint same = 0xFFFFFFFFu;
            for (uint bit = 0u; bit <= radixBits; ++bit) {
                bool set = ((digit >> bit) & 1u) != 0u;
                uint vote = uint(static_cast<simd_vote::vote_t>(simd_ballot(set)));
                same &= set ? vote : ~vote;
            }
            return same;
        }

        kernel void gtRadixCount(device const ulong *keys [[buffer(0)]],
                                 device uint *table [[buffer(1)]],
                                 constant TreeParams &p [[buffer(2)]],
                                 uint tile [[threadgroup_position_in_grid]],
                                 uint t [[thread_index_in_threadgroup]],
                                 uint simd [[simdgroup_index_in_threadgroup]],
                                 uint lane [[thread_index_in_simdgroup]]) {
            threadgroup uint counters[sortSimds * buckets];
            for (uint k = t; k < sortSimds * buckets; k += sortThreads) { counters[k] = 0u; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint first = tile * tileSize + simd * simdItems;
            uint below = (1u << lane) - 1u;
            threadgroup uint *mine = counters + simd * buckets;
            for (uint round = 0u; round < sortItems; ++round) {
                uint index = first + round * 32u + lane;
                bool valid = index < p.count;
                uint digit = valid ? uint((keys[index] >> p.shift) & ulong(buckets - 1u)) : buckets;
                uint same = sameDigit(digit);
                if (valid && popcount(same & below) == popcount(same) - 1u) {
                    mine[digit] += popcount(same);
                }
                simdgroup_barrier(mem_flags::mem_threadgroup);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint digit = t; digit < buckets; digit += sortThreads) {
                uint total = 0u;
                for (uint s = 0u; s < sortSimds; ++s) { total += counters[s * buckets + digit]; }
                table[digit * p.tiles + tile] = total;
            }
        }

        // The table is laid out digit by digit and tile by tile, so its exclusive scan is where
        // each tile's run of each digit lands. Scanned in blocks of 1024.
        kernel void gtScanReduce(device const uint *table [[buffer(0)]],
                                 device uint *sums [[buffer(1)]],
                                 constant TreeParams &p [[buffer(2)]],
                                 uint block [[threadgroup_position_in_grid]],
                                 uint t [[thread_index_in_threadgroup]],
                                 uint simd [[simdgroup_index_in_threadgroup]],
                                 uint lane [[thread_index_in_simdgroup]]) {
            uint base = block * 1024u + t * 4u;
            uint sum = 0u;
            for (uint k = 0u; k < 4u; ++k) {
                if (base + k < p.tableLength) { sum += table[base + k]; }
            }
            sum = simd_sum(sum);
            threadgroup uint partial[8];
            if (lane == 0u) { partial[simd] = sum; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (t == 0u) {
                uint total = 0u;
                for (uint s = 0u; s < 8u; ++s) { total += partial[s]; }
                sums[block] = total;
            }
        }

        kernel void gtScanTop(device uint *sums [[buffer(0)]],
                              constant TreeParams &p [[buffer(1)]],
                              uint t [[thread_index_in_threadgroup]],
                              uint simd [[simdgroup_index_in_threadgroup]],
                              uint lane [[thread_index_in_simdgroup]]) {
            threadgroup uint partial[32];
            threadgroup uint chunkTotal;
            uint blocks = (p.tableLength + 1023u) / 1024u;
            uint carry = 0u;
            for (uint chunk = 0u; chunk < blocks; chunk += 1024u) {
                uint i = chunk + t;
                uint value = i < blocks ? sums[i] : 0u;
                uint inclusive = simd_prefix_inclusive_sum(value);
                if (lane == 31u) { partial[simd] = inclusive; }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (simd == 0u) {
                    uint total = partial[lane];
                    uint running = simd_prefix_inclusive_sum(total);
                    partial[lane] = running - total;
                    if (lane == 31u) { chunkTotal = running; }
                }
                threadgroup_barrier(mem_flags::mem_threadgroup);
                if (i < blocks) { sums[i] = carry + partial[simd] + inclusive - value; }
                carry += chunkTotal;
                threadgroup_barrier(mem_flags::mem_threadgroup);
            }
        }

        kernel void gtScanDown(device uint *table [[buffer(0)]],
                               device const uint *sums [[buffer(1)]],
                               constant TreeParams &p [[buffer(2)]],
                               uint block [[threadgroup_position_in_grid]],
                               uint t [[thread_index_in_threadgroup]],
                               uint simd [[simdgroup_index_in_threadgroup]],
                               uint lane [[thread_index_in_simdgroup]]) {
            uint base = block * 1024u + t * 4u;
            uint values[4];
            uint own = 0u;
            for (uint k = 0u; k < 4u; ++k) {
                values[k] = base + k < p.tableLength ? table[base + k] : 0u;
                own += values[k];
            }
            uint inclusive = simd_prefix_inclusive_sum(own);
            threadgroup uint partial[8];
            if (lane == 31u) { partial[simd] = inclusive; }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint running = sums[block] + inclusive - own;
            for (uint s = 0u; s < simd; ++s) { running += partial[s]; }
            for (uint k = 0u; k < 4u; ++k) {
                if (base + k < p.tableLength) { table[base + k] = running; }
                running += values[k];
            }
        }

        // Each key goes to where its digit's run starts for its tile, plus the keys of the
        // same digit ahead of it in the tile. Ranked with ballots, so the sort stays stable.
        kernel void gtRadixScatter(device const ulong *keysIn [[buffer(0)]],
                                   device const uint *valuesIn [[buffer(1)]],
                                   device ulong *keysOut [[buffer(2)]],
                                   device uint *valuesOut [[buffer(3)]],
                                   device const uint *table [[buffer(4)]],
                                   constant TreeParams &p [[buffer(5)]],
                                   uint tile [[threadgroup_position_in_grid]],
                                   uint t [[thread_index_in_threadgroup]],
                                   uint simd [[simdgroup_index_in_threadgroup]],
                                   uint lane [[thread_index_in_simdgroup]]) {
            threadgroup uint counters[sortSimds * buckets];
            threadgroup uint starts[buckets];
            for (uint k = t; k < sortSimds * buckets; k += sortThreads) { counters[k] = 0u; }
            for (uint digit = t; digit < buckets; digit += sortThreads) {
                starts[digit] = table[digit * p.tiles + tile];
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            uint first = tile * tileSize + simd * simdItems;
            uint below = (1u << lane) - 1u;
            threadgroup uint *mine = counters + simd * buckets;
            ulong keys[sortItems];
            uint values[sortItems];
            uint ranks[sortItems];
            for (uint round = 0u; round < sortItems; ++round) {
                uint index = first + round * 32u + lane;
                bool valid = index < p.count;
                keys[round] = valid ? keysIn[index] : 0ul;
                values[round] = valid ? valuesIn[index] : 0u;
                uint digit = valid ? uint((keys[round] >> p.shift) & ulong(buckets - 1u)) : buckets;
                uint same = sameDigit(digit);
                uint ahead = valid ? mine[digit] : 0u;
                simdgroup_barrier(mem_flags::mem_threadgroup);
                uint rank = popcount(same & below);
                ranks[round] = ahead + rank;
                if (valid && rank == popcount(same) - 1u) { mine[digit] = ahead + popcount(same); }
                simdgroup_barrier(mem_flags::mem_threadgroup);
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint digit = t; digit < buckets; digit += sortThreads) {
                uint running = 0u;
                for (uint s = 0u; s < sortSimds; ++s) {
                    uint held = counters[s * buckets + digit];
                    counters[s * buckets + digit] = running;
                    running += held;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint round = 0u; round < sortItems; ++round) {
                uint index = first + round * 32u + lane;
                if (index >= p.count) { continue; }
                uint digit = uint((keys[round] >> p.shift) & ulong(buckets - 1u));
                uint slot = starts[digit] + mine[digit] + ranks[round];
                keysOut[slot] = keys[round];
                valuesOut[slot] = values[round];
            }
        }

        // Where each octant of a cell starts. Morton order makes them contiguous runs.
        inline void octantStarts(device const ulong *codes, uint start, uint count, uint shift,
                                 thread uint *offsets) {
            uint limit = start + count;
            offsets[0] = start;
            offsets[8] = limit;
            if (count <= 64u) {
                uint digit = 0u;
                for (uint position = start; position < limit; ++position) {
                    uint value = uint((codes[position] >> shift) & 7ul);
                    while (digit < value) {
                        digit += 1u;
                        offsets[digit] = position;
                    }
                }
                while (digit < 7u) {
                    digit += 1u;
                    offsets[digit] = limit;
                }
                return;
            }
            uint low = start;
            for (uint digit = 1u; digit < 8u; ++digit) {
                uint high = limit;
                while (low < high) {
                    uint middle = (low + high) / 2u;
                    if (uint((codes[middle] >> shift) & 7ul) < digit) { low = middle + 1u; } else { high = middle; }
                }
                offsets[digit] = low;
            }
        }

        // Closes a level: everything allocated so far ends it. Clamped, so that a build which ran
        // out of nodes never walks past the buffer; it is thrown away and run again anyway.
        kernel void gtCloseLevel(device atomic_uint *counters [[buffer(0)]],
                                 device uint *levels [[buffer(1)]],
                                 constant TreeParams &p [[buffer(2)]],
                                 uint gid [[thread_position_in_grid]]) {
            if (gid != 0u) { return; }
            uint allocated = atomic_load_explicit(&counters[counterNodes], memory_order_relaxed);
            levels[p.level + 1u] = min(allocated, p.nodeCapacity);
        }

        // Splits every cell of one level. A SIMD group takes one block of child slots for all
        // its cells, so siblings stay contiguous and families keep their parents' order.
        kernel void gtSplit(device BHNode *nodes [[buffer(0)]],
                            device const ulong *codes [[buffer(1)]],
                            device atomic_uint *counters [[buffer(2)]],
                            device const uint *levels [[buffer(3)]],
                            device const float *frame [[buffer(4)]],
                            constant TreeParams &p [[buffer(5)]],
                            uint gid [[thread_position_in_grid]],
                            uint threads [[threads_per_grid]],
                            uint lane [[thread_index_in_simdgroup]]) {
            uint level = p.level;
            uint begin = levels[level];
            uint end = levels[level + 1u];
            uint shift = 60u - 3u * level;
            float width = ldexp(frame[4], -int(level + 1u)) * 2.0f;
            float widthSquared = width * width;
            for (uint base = begin + gid - lane; base < end; base += threads) {
                uint n = base + lane;
                uint offsets[9];
                uint children = 0u;
                if (n < end && level < p.maximumDepth) {
                    BHNode node = nodes[n];
                    int count = -bhSignedCount(node);
                    if (count > int(p.leafCapacity)) {
                        octantStarts(codes, uint(bhRange(node)), uint(count), shift, offsets);
                        for (uint o = 0u; o < 8u; ++o) { children += offsets[o + 1u] > offsets[o] ? 1u : 0u; }
                    }
                }
                uint before = simd_prefix_exclusive_sum(children);
                uint total = simd_sum(children);
                uint first = 0u;
                if (lane == 0u && total > 0u) {
                    first = atomic_fetch_add_explicit(&counters[counterNodes], total, memory_order_relaxed);
                }
                first = simd_broadcast(first, 0);
                if (children == 0u) { continue; }
                uint at = first + before;
                if (at + children > p.nodeCapacity) {
                    atomic_store_explicit(&counters[counterOverflow], 1u, memory_order_relaxed);
                    continue;
                }
                for (uint o = 0u; o < 8u; ++o) {
                    uint size = offsets[o + 1u] - offsets[o];
                    if (size == 0u) { continue; }
                    BHNode child;
                    child.comMass = float4(0.0f);
                    child.packed = float4(widthSquared, as_type<float>(int(offsets[o])),
                                          as_type<float>(-int(size)), 0.0f);
                    nodes[at] = child;
                    at += 1u;
                }
                nodes[n].packed.y = as_type<float>(int(first + before));
                nodes[n].packed.z = as_type<float>(int(children));
            }
        }

        // The particles in Morton order with their mass beside them, as the force pass reads them.
        kernel void gtGather(device float4 *sorted [[buffer(0)]],
                             device const float3 *positions [[buffer(1)]],
                             device const float *mass [[buffer(2)]],
                             device const uint *order [[buffer(3)]],
                             constant TreeParams &p [[buffer(4)]],
                             uint slot [[thread_position_in_grid]]) {
            if (slot >= p.count) { return; }
            uint i = order[slot];
            sorted[slot] = float4(positions[i], mass[i]);
        }

        // Below, each product is added in a statement of its own, so that nothing is fused into
        // a multiply-add the CPU build does not do and the sums come out the same to the bit.

        // Each leaf sums its own run of gathered particles. Its second moment is taken about
        // its first particle, as on the CPU: x x^T summed raw cancels away far from the origin.
        kernel void gtLeafSums(device BHNode *nodes [[buffer(0)]],
                               device const float4 *sorted [[buffer(1)]],
                               device const uint *levels [[buffer(2)]],
                               constant TreeParams &p [[buffer(3)]],
                               device float4 *moments [[buffer(4)]],
                               device const uint *counters [[buffer(5)]],
                               uint gid [[thread_position_in_grid]],
                               uint threads [[threads_per_grid]]) {
            if (counters[counterOverflow] != 0u) { return; }
            uint total = levels[p.maximumDepth + 1u];
            for (uint n = gid; n < total; n += threads) {
                int signedCount = bhSignedCount(nodes[n]);
                if (signedCount > 0) { continue; }
                uint start = uint(bhRange(nodes[n]));
                uint limit = start + uint(-signedCount);
                float3 weighted = float3(0.0f);
                float sum = 0.0f;
                for (uint k = start; k < limit; ++k) {
                    float4 particle = sorted[k];
                    float3 product = particle.xyz * particle.w;
                    weighted += product;
                    sum += particle.w;
                }
                nodes[n].comMass = float4(weighted, sum);
                if (p.moments == 0u) { continue; }
                float3 origin = limit > start ? sorted[start].xyz : float3(0.0f);
                float3 shifted = float3(0.0f);
                float4 diagonal = float4(0.0f);
                float4 cross = float4(0.0f);
                for (uint k = start; k < limit; ++k) {
                    float4 particle = sorted[k];
                    float m = particle.w;
                    float3 d = particle.xyz - origin;
                    float3 moved = d * m;
                    shifted += moved;
                    float4 square = float4(d.x * d.x, d.y * d.y, d.z * d.z, d.x * d.y) * m;
                    diagonal += square;
                    float4 mixed = float4(d.x * d.z, d.y * d.z, 0.0f, 0.0f) * m;
                    cross += mixed;
                }
                float3 c = sum > 0.0f ? shifted / sum : float3(0.0f);
                float4 centreSquare = float4(c.x * c.x, c.y * c.y, c.z * c.z, c.x * c.y) * sum;
                float4 centreMixed = float4(c.x * c.z, c.y * c.z, 0.0f, 0.0f) * sum;
                moments[2u * n] = diagonal - centreSquare;
                moments[2u * n + 1u] = cross - centreMixed;
            }
        }

        // A node holds the sum of its children taken last to first, as the CPU fold does.
        kernel void gtFold(device BHNode *nodes [[buffer(0)]],
                           device const uint *levels [[buffer(1)]],
                           constant TreeParams &p [[buffer(2)]],
                           device const uint *counters [[buffer(3)]],
                           uint gid [[thread_position_in_grid]],
                           uint threads [[threads_per_grid]]) {
            if (counters[counterOverflow] != 0u) { return; }
            uint end = levels[p.level + 1u];
            for (uint n = levels[p.level] + gid; n < end; n += threads) {
                int children = bhSignedCount(nodes[n]);
                if (children <= 0) { continue; }
                int first = bhRange(nodes[n]);
                float4 sum = float4(0.0f);
                for (int c = children - 1; c >= 0; --c) { sum += nodes[first + c].comMass; }
                nodes[n].comMass = sum;
            }
        }

        kernel void gtNormalize(device BHNode *nodes [[buffer(0)]],
                                device const uint *levels [[buffer(1)]],
                                constant TreeParams &p [[buffer(2)]],
                                device const uint *counters [[buffer(3)]],
                                uint gid [[thread_position_in_grid]],
                                uint threads [[threads_per_grid]]) {
            if (counters[counterOverflow] != 0u) { return; }
            uint total = levels[p.maximumDepth + 1u];
            for (uint n = gid; n < total; n += threads) {
                float4 c = nodes[n].comMass;
                if (c.w > 0.0f) {
                    float inverse = 1.0f / c.w;
                    nodes[n].comMass = float4(c.x * inverse, c.y * inverse, c.z * inverse, c.w);
                }
            }
        }

        // A branch shifts each child's moment to its own centre of mass, children last to first,
        // which needs the centres normalised first.
        kernel void gtFoldMoments(device const BHNode *nodes [[buffer(0)]],
                                  device const uint *levels [[buffer(1)]],
                                  constant TreeParams &p [[buffer(2)]],
                                  device float4 *moments [[buffer(3)]],
                                  device const uint *counters [[buffer(4)]],
                                  uint gid [[thread_position_in_grid]],
                                  uint threads [[threads_per_grid]]) {
            if (counters[counterOverflow] != 0u) { return; }
            uint end = levels[p.level + 1u];
            for (uint n = levels[p.level] + gid; n < end; n += threads) {
                BHNode node = nodes[n];
                int children = bhSignedCount(node);
                if (children <= 0) { continue; }
                int first = bhRange(node);
                float3 centre = node.comMass.xyz;
                float4 diagonal = float4(0.0f);
                float4 cross = float4(0.0f);
                for (int c = children - 1; c >= 0; --c) {
                    uint child = uint(first + c);
                    float4 com = nodes[child].comMass;
                    float3 d = com.xyz - centre;
                    float4 square = float4(d.x * d.x, d.y * d.y, d.z * d.z, d.x * d.y) * com.w;
                    float4 movedSquare = moments[2u * child] + square;
                    diagonal += movedSquare;
                    float4 mixed = float4(d.x * d.z, d.y * d.z, 0.0f, 0.0f) * com.w;
                    float4 movedMixed = moments[2u * child + 1u] + mixed;
                    cross += movedMixed;
                }
                moments[2u * n] = diagonal;
                moments[2u * n + 1u] = cross;
            }
        }
        // A drawn particle's smoothing length, read off the leaf that holds it. Only the drawn
        // particles are counted: they come first, and the dark matter sharing their leaf would
        // make the spacing follow the halo. Needs no masses, so the cells are enough.
        kernel void gtSmoothing(device float *lengths [[buffer(0)]],
                                device const BHNode *nodes [[buffer(1)]],
                                device const uint *order [[buffer(2)]],
                                device const uint *levels [[buffer(3)]],
                                device const uint *counters [[buffer(4)]],
                                constant TreeParams &p [[buffer(5)]],
                                constant uint &drawnCount [[buffer(6)]],
                                uint gid [[thread_position_in_grid]],
                                uint threads [[threads_per_grid]]) {
            if (counters[counterOverflow] != 0u) { return; }
            uint total = levels[p.maximumDepth + 1u];
            for (uint n = gid; n < total; n += threads) {
                BHNode node = nodes[n];
                if (bhSignedCount(node) > 0) { continue; }
                uint count = uint(-bhSignedCount(node));
                uint start = uint(bhRange(node));
                uint drawn = 0u;
                for (uint k = 0u; k < count; ++k) {
                    if (order[start + k] < drawnCount) { drawn += 1u; }
                }
                if (drawn == 0u) { continue; }
                float width = sqrt(max(node.packed.x, 1e-12));
                float length = width * pow(1.0 / float(drawn), 1.0 / 3.0);
                for (uint k = 0u; k < count; ++k) {
                    uint i = order[start + k];
                    if (i < drawnCount) { lengths[i] = length; }
                }
            }
        }
        """
}
