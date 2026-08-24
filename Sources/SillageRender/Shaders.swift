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
            float dustStrength;
            float starSize;
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
            float saturation;
        };

        struct SplatOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
            half opticalDepth;
            half spikes;
        };

        // Two attachments: emitted light, and the optical depth of intervening dust. Both blend
        // additively, so a fragment contributing to one writes zero to the other.
        struct SplatTargets {
            half4 light [[color(0)]];
            half4 dust [[color(1)]];
        };

        // Stellar colour by population age, following the sequence a real galaxy shows: an old
        // K and G giant bulge, an intermediate disk, and blue O and B associations on the arms.
        static float3 populationColor(float population) {
            const float3 oldStars = float3(1.00, 0.74, 0.45);
            const float3 midStars = float3(1.00, 0.94, 0.83);
            const float3 youngStars = float3(0.62, 0.75, 1.00);
            return population < 0.5
                ? mix(oldStars, midStars, population * 2.0)
                : mix(midStars, youngStars, (population - 0.5) * 2.0);
        }

        // HII regions glow in Halpha with a little [OIII], which reads pink shading to magenta.
        constant float3 hiiColor = float3(1.00, 0.32, 0.50);

        vertex SplatOut splatVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const float *population [[buffer(1)]],
                                    device const float *luminosity [[buffer(2)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]]) {
            SplatOut out;
            out.position = u.viewProjection * float4(positions[vid], 1.0);
            out.spikes = 0.0h;
            uint kind = component[vid];
            float weight = luminosity[vid];

            if (kind == 2u) {
                // Dust neither emits nor follows exposure; it removes light further down.
                out.pointSize = u.pointSize * 1.4;
                out.color = half3(0.0h);
                out.opticalDepth = half(weight * u.dustStrength);
            } else {
                float3 tint = kind == 1u ? hiiColor : populationColor(population[vid]);
                out.pointSize = u.pointSize * (kind == 1u ? 1.15 : 1.0);
                out.color = half3(tint * (u.brightness * weight));
                out.opticalDepth = 0.0h;
            }
            return out;
        }

        struct BackgroundStar {
            float4 direction;
            float4 color;
        };

        // Foreground field stars, sitting far enough out that orbiting the galaxy does not
        // parallax them. The brightest ones carry diffraction spikes, which is most of what
        // makes an image read as a telescope exposure rather than a plot.
        vertex SplatOut starfieldVertex(uint vid [[vertex_id]],
                                        device const BackgroundStar *stars [[buffer(0)]],
                                        constant SplatUniforms &u [[buffer(4)]]) {
            BackgroundStar star = stars[vid];
            float magnitude = star.direction.w;
            SplatOut out;
            out.position = u.viewProjection * float4(star.direction.xyz, 1.0);
            out.pointSize = u.starSize * mix(1.6, 9.0, magnitude * magnitude);
            out.color = half3(star.color.rgb * (magnitude * magnitude * magnitude * 9.0));
            out.opticalDepth = 0.0h;
            out.spikes = half(star.color.a);
            return out;
        }

        fragment SplatTargets splatFragment(SplatOut in [[stage_in]],
                                            float2 coord [[point_coord]]) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }

            float falloff;
            if (in.spikes > 0.0h) {
                // A field star needs a tight core, otherwise the bloom halo is all that is left
                // of it and the image reads as defocused rather than as a long exposure.
                float ax = abs(d.x) * 2.0;
                float ay = abs(d.y) * 2.0;
                float cross = exp(-210.0 * ax * ax - 4.0 * ay)
                            + exp(-210.0 * ay * ay - 4.0 * ax);
                falloff = exp(-13.0 * r2) + float(in.spikes) * 0.5 * cross;
            } else {
                falloff = exp(-4.5 * r2);
            }

            SplatTargets out;
            out.light = half4(in.color * half(falloff), half(falloff));
            out.dust = half4(in.opticalDepth * half(falloff), 0.0h, 0.0h, 0.0h);
            return out;
        }

        // Box average of the supersampled accumulation down to output resolution, with dust
        // extinction applied on the way. Interstellar dust removes blue far more than red, so a
        // lane crossing a bright disk reads brown rather than grey.
        kernel void resolve(texture2d<float, access::read> light [[texture(0)]],
                            texture2d<float, access::read> dust [[texture(1)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant uint &factor [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float3 emitted = float3(0.0);
            float depth = 0.0;
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    uint2 at = gid * factor + uint2(x, y);
                    emitted += light.read(at).rgb;
                    depth += dust.read(at).r;
                }
            }
            float inverse = 1.0 / float(factor * factor);
            emitted *= inverse;
            depth *= inverse;
            // There is no depth ordering here, so the column includes dust behind the stars as
            // well as in front. Statistically about half of it lies in front, and the clamp keeps
            // a compressed geometry, where the columns of both galaxies overlap, from going black.
            depth = min(depth * 0.5, 2.6);
            const float3 reddening = float3(1.0, 1.22, 1.52);
            dst.write(float4(emitted * exp(-depth * reddening), 1.0), gid);
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
            // Tone mapping pulls every bright value toward white, so the warm bulge and the blue
            // arms are re-separated before the curve is applied.
            float luma = dot(lifted, float3(0.2126, 0.7152, 0.0722));
            lifted = max(mix(float3(luma), lifted, p.saturation), 0.0);
            float3 mapped = acesFilmic(lifted);
            output.write(float4(pow(mapped, 1.0 / 2.2), 1.0), gid);
        }
        """
}
