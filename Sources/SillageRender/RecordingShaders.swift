/// Snapshot expansion in Metal Shading Language.
enum RecordingShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct ExpandParams {
            float4 originA;
            float4 originB;
            uint particleCount;
            float blend;
            float _pad0;
            float _pad1;
        };

        // Two quantised snapshots blended into world positions. Interpolating between recorded
        // states is what turns a run captured at a few steps per second into continuous motion at
        // the display rate.
        // The two snapshots are bound separately so each can sit anywhere in the cache of
        // decoded frames, rather than having to be copied side by side first.
        kernel void expandSnapshots(device const ushort *first [[buffer(0)]],
                                    device const ushort *second [[buffer(1)]],
                                    device float3 *positions [[buffer(2)]],
                                    constant ExpandParams &p [[buffer(3)]],
                                    uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            uint base = i * 3;

            float3 a = p.originA.xyz
                     + float3(first[base], first[base + 1], first[base + 2])
                     * p.originA.w;
            float3 b = p.originB.xyz
                     + float3(second[base], second[base + 1], second[base + 2])
                     * p.originB.w;
            positions[i] = mix(a, b, p.blend);
        }
        """
}
