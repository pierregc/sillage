/// Metal Shading Language source, compiled at runtime by `MTLDevice.makeLibrary(source:)`.
/// MSL is host-language agnostic: this string is the part of the renderer that would survive
/// a port to C++ or Rust unchanged.
enum Shaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        constexpr sampler bilinear(filter::linear, address::clamp_to_edge, coord::normalized);

        struct SplatUniforms {
            float4x4 viewProjection;
            float pointSize;
            float brightness;
            float colorRadius;
            float _pad;
        };

        struct BloomParams {
            float threshold;
            float softKnee;
            float _pad0;
            float _pad1;
        };

        struct CompositeParams {
            float exposure;
            float bloomIntensity;
            float stretch;
            float _pad;
        };

        struct SplatOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
        };

        // Three-stop ramp: hot core, white mid-disk, cool outskirts. The two galaxies are
        // offset in hue so their tidal tails stay readable once they overlap.
        static half3 particleColor(float birthRadius, uint galaxy, float colorRadius) {
            float t = saturate(birthRadius / colorRadius);
            half3 core = galaxy == 0 ? half3(1.00h, 0.82h, 0.52h) : half3(1.00h, 0.72h, 0.60h);
            half3 mid = galaxy == 0 ? half3(0.96h, 0.94h, 0.92h) : half3(0.98h, 0.92h, 0.96h);
            half3 edge = galaxy == 0 ? half3(0.38h, 0.58h, 1.00h) : half3(0.62h, 0.50h, 1.00h);
            half k = half(smoothstep(0.0, 0.45, t));
            half3 inner = mix(core, mid, k);
            half j = half(smoothstep(0.35, 1.0, t));
            return mix(inner, edge, j);
        }

        vertex SplatOut splatVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const float *birthRadius [[buffer(1)]],
                                    device const uint *galaxy [[buffer(2)]],
                                    constant SplatUniforms &u [[buffer(3)]]) {
            SplatOut out;
            out.position = u.viewProjection * float4(positions[vid], 1.0);
            out.pointSize = u.pointSize;
            out.color = particleColor(birthRadius[vid], galaxy[vid], u.colorRadius)
                        * half(u.brightness);
            return out;
        }

        fragment half4 splatFragment(SplatOut in [[stage_in]], float2 coord [[point_coord]]) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }
            half falloff = half(exp(-4.5 * r2));
            return half4(in.color * falloff, falloff);
        }

        // Box average of the supersampled accumulation down to output resolution.
        kernel void resolve(texture2d<float, access::read> src [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(1)]],
                            constant uint &factor [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float4 sum = float4(0.0);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    sum += src.read(gid * factor + uint2(x, y));
                }
            }
            dst.write(sum / float(factor * factor), gid);
        }

        kernel void brightPass(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant BloomParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
            float3 c = src.sample(bilinear, uv).rgb;
            float brightness = max(c.r, max(c.g, c.b));
            float knee = max(p.threshold * p.softKnee, 1e-5);
            float soft = clamp(brightness - p.threshold + knee, 0.0, 2.0 * knee);
            soft = soft * soft / (4.0 * knee);
            float weight = max(soft, brightness - p.threshold) / max(brightness, 1e-5);
            dst.write(float4(c * weight, 1.0), gid);
        }

        // Kawase dual filter, the downsample half.
        kernel void downsample(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
            float2 hp = 0.5 / float2(src.get_width(), src.get_height());
            float3 sum = src.sample(bilinear, uv).rgb * 4.0;
            sum += src.sample(bilinear, uv - hp).rgb;
            sum += src.sample(bilinear, uv + hp).rgb;
            sum += src.sample(bilinear, uv + float2(hp.x, -hp.y)).rgb;
            sum += src.sample(bilinear, uv + float2(-hp.x, hp.y)).rgb;
            dst.write(float4(sum / 8.0, 1.0), gid);
        }

        // Kawase dual filter, the upsample half, accumulating the finer level underneath.
        kernel void upsampleAdd(texture2d<float, access::sample> src [[texture(0)]],
                                texture2d<float, access::read> base [[texture(1)]],
                                texture2d<float, access::write> dst [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float2 size = float2(dst.get_width(), dst.get_height());
            float2 uv = (float2(gid) + 0.5) / size;
            float2 hp = 0.5 / size;
            float3 sum = src.sample(bilinear, uv + float2(-hp.x * 2.0, 0.0)).rgb;
            sum += src.sample(bilinear, uv + float2(-hp.x, hp.y)).rgb * 2.0;
            sum += src.sample(bilinear, uv + float2(0.0, hp.y * 2.0)).rgb;
            sum += src.sample(bilinear, uv + float2(hp.x, hp.y)).rgb * 2.0;
            sum += src.sample(bilinear, uv + float2(hp.x * 2.0, 0.0)).rgb;
            sum += src.sample(bilinear, uv + float2(hp.x, -hp.y)).rgb * 2.0;
            sum += src.sample(bilinear, uv + float2(0.0, -hp.y * 2.0)).rgb;
            sum += src.sample(bilinear, uv + float2(-hp.x, -hp.y)).rgb * 2.0;
            dst.write(float4(sum / 12.0 + base.read(gid).rgb, 1.0), gid);
        }

        static float3 acesFilmic(float3 x) {
            const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
            return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
        }

        kernel void composite(texture2d<float, access::read> hdr [[texture(0)]],
                              texture2d<float, access::sample> bloom [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant CompositeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
            float3 energy = hdr.read(gid).rgb + bloom.sample(bilinear, uv).rgb * p.bloomIntensity;
            energy *= p.exposure;
            // Logarithmic stretch, as astronomical imaging does: it keeps faint tidal debris
            // visible without turning the cores into featureless discs.
            float3 lifted = p.stretch > 0.0
                ? log(1.0 + energy * p.stretch) / log(1.0 + p.stretch)
                : energy;
            float3 mapped = acesFilmic(lifted);
            output.write(float4(pow(mapped, 1.0 / 2.2), 1.0), gid);
        }
        """
}
