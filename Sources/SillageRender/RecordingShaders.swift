/// Snapshot expansion in Metal Shading Language.
enum RecordingShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

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
        static inline float3 decode(device const ushort *q, uint base, float4 origin) {
            return origin.xyz + float3(q[base], q[base + 1], q[base + 2]) * origin.w;
        }

        kernel void expandSnapshots(device const ushort *before [[buffer(0)]],
                                    device const ushort *first [[buffer(1)]],
                                    device const ushort *second [[buffer(2)]],
                                    device const ushort *after [[buffer(3)]],
                                    device float3 *positions [[buffer(4)]],
                                    constant ExpandParams &p [[buffer(5)]],
                                    uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            uint base = i * 3;

            // A weight of zero is common — on a stored frame only one counts — and the same for
            // every thread, so skipping its read costs no divergence and saves the bandwidth.
            float3 sum = float3(0);
            if (p.weights.x != 0) { sum += p.weights.x * decode(before, base, p.origin0); }
            if (p.weights.y != 0) { sum += p.weights.y * decode(first, base, p.origin1); }
            if (p.weights.z != 0) { sum += p.weights.z * decode(second, base, p.origin2); }
            if (p.weights.w != 0) { sum += p.weights.w * decode(after, base, p.origin3); }
            positions[i] = sum;
        }
        """
}
