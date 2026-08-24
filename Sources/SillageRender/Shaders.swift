/// Metal Shading Language source, compiled at runtime by `MTLDevice.makeLibrary(source:)`.
/// MSL is host-language agnostic: this string is the part of the renderer that would survive
/// a port to C++ or Rust unchanged.
enum Shaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        struct Uniforms {
            float4x4 viewProjection;
            float pointSize;
            float exposure;
            float brightness;
            float _pad;
        };

        struct SplatOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
        };

        // Warm dense core through to cool outskirts, offset per galaxy so the two
        // tidal tails stay distinguishable once they overlap.
        static half3 particleColor(float birthRadius, uint galaxy) {
            float t = saturate(birthRadius / 14.0);
            half3 core = galaxy == 0 ? half3(1.0h, 0.86h, 0.62h) : half3(1.0h, 0.78h, 0.72h);
            half3 edge = galaxy == 0 ? half3(0.42h, 0.60h, 1.0h) : half3(0.55h, 0.52h, 1.0h);
            return mix(core, edge, half(t * t));
        }

        vertex SplatOut splatVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const float *birthRadius [[buffer(1)]],
                                    device const uint *galaxy [[buffer(2)]],
                                    constant Uniforms &u [[buffer(3)]]) {
            SplatOut out;
            out.position = u.viewProjection * float4(positions[vid], 1.0);
            out.pointSize = u.pointSize;
            out.color = particleColor(birthRadius[vid], galaxy[vid]) * half(u.brightness);
            return out;
        }

        fragment half4 splatFragment(SplatOut in [[stage_in]], float2 coord [[point_coord]]) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }
            half falloff = half(exp(-4.5 * r2));
            return half4(in.color * falloff, falloff);
        }

        static float3 acesFilmic(float3 x) {
            const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
            return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
        }

        kernel void tonemap(texture2d<float, access::read> accumulation [[texture(0)]],
                            texture2d<float, access::write> output [[texture(1)]],
                            constant Uniforms &u [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            float3 hdr = accumulation.read(gid).rgb * u.exposure;
            float3 mapped = acesFilmic(hdr);
            output.write(float4(pow(mapped, 1.0 / 2.2), 1.0), gid);
        }
        """
}
