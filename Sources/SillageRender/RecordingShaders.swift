/// Snapshot expansion in Metal Shading Language.
enum RecordingShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // Metal only: the CUDA engine plays no take back (docs/notes/one-kernel-source.md).
        #if defined(__METAL_VERSION__)

        struct ExpandParams {
            float4 origin0;
            float4 origin1;
            float4 origin2;
            float4 origin3;
            float4 weights;
            uint particleCount;
            uint _pad0;
            uint _pad1;
            uint _pad2;
        };

        // Quantised snapshots blended into world positions. Interpolating between recorded
        // states is what turns a run captured at a few steps per second into continuous motion at
        // the display rate.
        // A cubic through the middle two, its tangents taken from the outer ones, folded into one
        // weight per snapshot on the CPU. A straight line between them would draw every orbit as
        // a polygon.
        // The snapshots are bound separately so each can sit anywhere in the cache of decoded
        // frames, rather than having to be copied side by side first.
        static inline float3 decode(device const ushort *q, uint i, float4 origin) {
            uint base = i * 3;
            return origin.xyz + float3(q[base], q[base + 1], q[base + 2]) * origin.w;
        }

        // 21 bits an axis in one 64-bit word, x lowest, read as two 32-bit halves: y straddles
        // them.
        static inline float3 decode(device const uint2 *q, uint i, float4 origin) {
            uint2 w = q[i];
            uint3 cell = uint3(
                w.x & 0x1FFFFFu, (w.x >> 21) | ((w.y & 0x3FFu) << 11), (w.y >> 10) & 0x1FFFFFu);
            return origin.xyz + float3(cell) * origin.w;
        }

        template <typename Q>
        static inline void expand(device const Q *before, device const Q *first,
                                  device const Q *second, device const Q *after,
                                  device float3 *positions, constant ExpandParams &p, uint i) {
            if (i >= p.particleCount) { return; }

            // A weight of zero is common — on a stored frame only one counts — and the same for
            // every thread, so skipping its read costs no divergence and saves the bandwidth.
            float3 sum = float3(0);
            if (p.weights.x != 0) { sum += p.weights.x * decode(before, i, p.origin0); }
            if (p.weights.y != 0) { sum += p.weights.y * decode(first, i, p.origin1); }
            if (p.weights.z != 0) { sum += p.weights.z * decode(second, i, p.origin2); }
            if (p.weights.w != 0) { sum += p.weights.w * decode(after, i, p.origin3); }
            positions[i] = sum;
        }

        kernel void expandSnapshots(device const ushort *before [[buffer(0)]],
                                    device const ushort *first [[buffer(1)]],
                                    device const ushort *second [[buffer(2)]],
                                    device const ushort *after [[buffer(3)]],
                                    device float3 *positions [[buffer(4)]],
                                    constant ExpandParams &p [[buffer(5)]],
                                    uint i [[thread_position_in_grid]]) {
            expand(before, first, second, after, positions, p, i);
        }

        kernel void expandSnapshots21(device const uint2 *before [[buffer(0)]],
                                      device const uint2 *first [[buffer(1)]],
                                      device const uint2 *second [[buffer(2)]],
                                      device const uint2 *after [[buffer(3)]],
                                      device float3 *positions [[buffer(4)]],
                                      constant ExpandParams &p [[buffer(5)]],
                                      uint i [[thread_position_in_grid]]) {
            expand(before, first, second, after, positions, p, i);
        }
        #endif
        """
}
