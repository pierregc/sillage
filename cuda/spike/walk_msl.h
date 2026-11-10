// The tracer walk's MSL, copied from Sources/SillageRender/BarnesHutShaders.swift (#271):
// sed -n '4,24p;37,57p;79,147p;318,327p;386,397p;468,564p;612,689p', the Swift string's indentation removed, nothing else changed.
// cuda/spike/build.sh checks the copy. Compiled through msl_compat.h.

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

inline ulong bhSpread(uint value) {
    ulong x = ulong(value) & 0x1FFFFFul;
    x = (x | (x << 32)) & 0x001F00000000FFFFul;
    x = (x | (x << 16)) & 0x001F0000FF0000FFul;
    x = (x | (x << 8)) & 0x100F00F00F00F00Ful;
    x = (x | (x << 4)) & 0x10C30C30C30C30C3ul;
    x = (x | (x << 2)) & 0x1249249249249249ul;
    return x;
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
