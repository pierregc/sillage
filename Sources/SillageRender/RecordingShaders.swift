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
        kernel void expandSnapshots(device const ushort *snapshots [[buffer(0)]],
                                    device float3 *positions [[buffer(1)]],
                                    constant ExpandParams &p [[buffer(2)]],
                                    uint i [[thread_position_in_grid]]) {
            if (i >= p.particleCount) { return; }
            uint base = i * 3;
            uint second = p.particleCount * 3;

            float3 a = p.originA.xyz
                     + float3(snapshots[base], snapshots[base + 1], snapshots[base + 2])
                     * p.originA.w;
            float3 b = p.originB.xyz
                     + float3(snapshots[second + base], snapshots[second + base + 1],
                              snapshots[second + base + 2])
                     * p.originB.w;
            positions[i] = mix(a, b, p.blend);
        }
        """
}
