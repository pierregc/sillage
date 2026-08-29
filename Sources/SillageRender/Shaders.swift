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
            float brightness;
            float dustStrength;
            float starSize;
            float projectionScale;
            float smoothingScale;
            float referenceArea;
            float minimumSize;
            float maximumSize;
            float galaxyTint;
        };

        struct BloomParams {
            float threshold;
            float softKnee;
            float _pad0;
            float _pad1;
        };

        struct CompositeParams {
            float bloomIntensity;
            float stretch;
            float saturation;
            float spikeIntensity;
            float skyLevel;
            float noiseLevel;
            float seed;
            float _pad;
        };

        struct SpikeParams {
            uint arms;
            float baseAngle;
            float length;
            float falloff;
            uint samples;
            float _pad0;
            float _pad1;
            float _pad2;
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

        struct DiskFrame {
            float4 center;
            float4 axisU;
            float4 axisV;
            float4 pattern;
            float4 tint;
        };

        static float hash1(float i) {
            float x = sin(i * 127.1 + 311.7) * 43758.5453;
            return x - floor(x);
        }

        static float valueNoise(float x) {
            float i = floor(x);
            float f = x - i;
            float u = f * f * (3.0 - 2.0 * f);
            return mix(hash1(i), hash1(i + 1.0), u);
        }

        static float fractalNoise(float x) {
            return valueNoise(x) * 0.65 + valueNoise(x * 2.3 + 19.1) * 0.35;
        }

        // Strips the luminance out of a colour, leaving only its hue and saturation. Every
        // emitter in this renderer carries unit luminance, so `brightness` stays the single
        // control over exposure and changing a colour can never change how bright a frame is.
        static float3 chromaticity(float3 rgb) {
            return max(rgb, 0.0) / max(dot(max(rgb, 0.0), float3(0.2126, 0.7152, 0.0722)), 1e-4);
        }

        // Linear sRGB of a Planckian radiator. Chromaticity from Kang et al. (2002), then
        // CIE xy to sRGB primaries. Y is fixed at 1, so the conversion lands on unit
        // luminance before the negative lobe of a saturated hue is clipped away.
        static float3 blackbody(float kelvin) {
            float t = clamp(kelvin, 2222.0, 25000.0);
            float inv = 1.0 / t;
            float x = t < 4000.0
                ? ((-0.2661239e9 * inv - 0.2343589e6) * inv + 0.8776956e3) * inv + 0.179910
                : ((-3.0258469e9 * inv + 2.1070379e6) * inv + 0.2226347e3) * inv + 0.240390;
            float y = t < 4000.0
                ? ((-0.9549476 * x - 1.37418593) * x + 2.09137015) * x - 0.16748867
                : ((3.0817580 * x - 5.87338670) * x + 3.75112997) * x - 0.37001483;
            float scale = 1.0 / max(y, 1e-4);
            float3 xyz = float3(x * scale, 1.0, (1.0 - x - y) * scale);
            return chromaticity(float3(
                dot(xyz, float3(3.2406, -1.5372, -0.4986)),
                dot(xyz, float3(-0.9689, 1.8758, 0.0415)),
                dot(xyz, float3(0.0557, -0.2040, 1.0570))));
        }

        // Integrated colour of a stellar population, from an old bulge to the stars forming
        // in an arm. The ends are the colour temperatures the two actually show, near
        // B-V = 0.95 and B-V = -0.05, and the interpolation runs in log T because that is
        // roughly what makes it linear in colour index: a disk halfway along lands on the
        // B-V = 0.6 a real interarm region has, which a linear ramp in T misses by a lot.
        static float3 stellarColour(float age) {
            return blackbody(exp(mix(log(4100.0), log(13000.0), saturate(age))));
        }

        // A star-forming knot is not a blackbody: most of its light leaves in Halpha at
        // 656 nm, on the continuum of the hot stars ionising it, which is why the knots read
        // pink rather than blue. This is the colour such a region shows through broadband
        // filters, stated directly; deriving it from line ratios needs an emission model and
        // the CIE colour matching functions.
        static float3 hiiColour() {
            return chromaticity(float3(1.00, 0.36, 0.42));
        }

        // Where a particle sits relative to the spiral density wave, 0 between the arms and
        // 1 on a ridge, evaluated at the current position so the arms do not wind up. The
        // ideal logarithmic spiral is then made to wander and to break into segments: no
        // real galaxy has two unbroken arms of constant pitch.
        static float2 armWave(float3 position, DiskFrame frame) {
            float strength = frame.axisV.w;
            if (strength <= 0.0) { return float2(0.5, 0.0); }
            float3 rel = position - frame.center.xyz;
            float u = dot(rel, frame.axisU.xyz);
            float v = dot(rel, frame.axisV.xyz);
            float radius = sqrt(u * u + v * v);
            float scale = max(frame.center.w, 1e-3);
            float extent = radius / scale;
            float envelope = smoothstep(0.55, 1.5, extent)
                           * (1.0 - smoothstep(4.0, 6.5, extent));

            float irregular = frame.pattern.z;
            float seed = frame.pattern.w;
            float wander = (fractalNoise(extent * 1.5 + seed) - 0.5) * 2.6 * irregular;
            float wound = atan2(v, u)
                        - frame.pattern.x * log(max(radius, 1e-3) / scale)
                        - frame.pattern.y
                        + wander;

            float ridge = 0.5 + 0.5 * cos(frame.axisU.w * wound);
            float breaks = fractalNoise(wound * 0.62 + extent * 0.9 + seed * 3.1);
            ridge *= mix(1.0, 0.18 + 1.05 * breaks, irregular);
            ridge = clamp(ridge, 0.0, 1.0);
            return float2(mix(0.5, ridge, strength * envelope), envelope);
        }

        vertex SplatOut splatVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const float *population [[buffer(1)]],
                                    device const float *luminosity [[buffer(2)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const uint *galaxy [[buffer(5)]],
                                    constant DiskFrame *frames [[buffer(6)]],
                                    device const float *smoothing [[buffer(7)]]) {
            SplatOut out;
            float3 position = positions[vid];
            DiskFrame frame = frames[galaxy[vid]];
            out.position = u.viewProjection * float4(position, 1.0);
            out.spikes = 0.0h;
            uint kind = component[vid];
            float weight = luminosity[vid];

            // Dark matter carries mass but no light. Pushing it outside the clip volume drops
            // it before any fragment work rather than drawing a black point over the galaxy.
            if (kind == 3u) {
                out.position = float4(2.0, 2.0, 2.0, 1.0);
                out.pointSize = 0.0;
                out.color = half3(0.0h);
                out.opticalDepth = 0.0h;
                return out;
            }
            float2 pattern = armWave(position, frame);
            float wave = pattern.x;

            // Angular size of this particle's kernel, in pixels. position.w is the view
            // depth for a standard perspective projection, so this is just h over distance.
            float depth = max(out.position.w, 1e-3);
            float perPixel = u.projectionScale / depth;
            float span = clamp(max(smoothing[vid] * u.smoothingScale, 1e-4) * perPixel,
                               u.minimumSize, u.maximumSize);
            // Take the length back from the clamped span. Dividing by the unclamped one would
            // brighten every particle the floor caught, which made the softness control shift
            // the exposure as a side effect.
            float length = span / perPixel;
            // Spread the particle's light over the kernel's area in kiloparsecs, not in
            // pixels. Dividing by the pixel area would conserve flux per particle but make
            // the exposure depend on the resolution and the zoom; dividing by the physical
            // area gives surface brightness, which is what a telescope actually measures and
            // what stays put when the camera moves.
            float spread = u.referenceArea / (length * length);

            if (kind == 2u) {
                // Dust neither emits nor follows exposure; it removes light further down.
                //
                // The lane has to come from the wave rather than from where the grains sit.
                // The sampler puts them on the arms it drew, but a disk turns differentially
                // and within an orbit they are spread evenly round it: after that, whatever
                // the wave does not darken is not a lane at all.
                float lane = 1.0 + 4.2 * pow(wave, 1.6) * pattern.y;
                out.pointSize = span * 1.3;
                out.color = half3(0.0h);
                out.opticalDepth = half(weight * u.dustStrength * lane * spread * 1.3);
            } else {
                // Star formation happens where the wave is compressing the gas, so a knot
                // away from one is an old knot and has to be dim. The floor cannot go much
                // higher: the sampler's placement holds for an orbit at most, and after that
                // a generous floor is pink dots scattered over a disk that has turned.
                float forming = smoothstep(0.4, 0.95, wave) * pattern.y;

                // Arm contrast in starlight was set low back when the sampled density carried
                // the arms and this only had to nudge them. It carries them alone now, so it
                // runs at the factor of two a grand-design spiral shows between arm and
                // interarm.
                float gain = kind == 1u
                    ? (0.06 + 2.6 * forming)
                    : (0.55 + 0.95 * wave);
                // Colour comes from the population the sampler gave this particle: old and
                // warm in the bulge, young and blue in the disk. The wave shifts it a little
                // further, because an arm is bluer than the disk around it for the same
                // reason it is brighter, and the ridge moves while the stars pass through it.
                float age = population[vid] + 0.22 * (wave - 0.5) * pattern.y;
                // A knot only glows in Halpha while the O stars ionising it are alive, a few
                // million years. Material torn into a tail left its arm long ago and has
                // none left, so it fades back to the colour of the young cluster it is.
                // Where the arms are painted the wave says where star formation is now; a
                // self-gravitating disk grows its own arms and the sampler's placement is
                // the only thing available.
                float alive = forming;
                float3 emitted = kind == 1u
                    ? mix(stellarColour(1.0), hiiColour(), alive)
                    : stellarColour(age);
                // A tint per galaxy is what keeps stars pulled into the other one legible.
                // It is a departure from the physical colour, so it is dialled rather than
                // applied: at 0 the two galaxies are coloured by their populations alone.
                emitted *= mix(float3(1.0), chromaticity(frame.tint.rgb), u.galaxyTint);
                out.pointSize = span * (kind == 1u ? 1.3 : 1.0);
                out.color = half3(emitted * (u.brightness * weight * gain * spread));
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
            out.color = half3(star.color.rgb * (magnitude * magnitude * magnitude * 2.4));
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

        // Diffraction spikes. A telescope's secondary supports and, on a segmented mirror, the
        // segment edges throw light into a fixed set of directions; six arms for a hexagonal
        // mirror, four for a Cassegrain spider. Gathering bright light back along those
        // directions is most of what makes a rendered field read as an exposure.
        kernel void diffractionSpikes(texture2d<float, access::sample> src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant SpikeParams &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float2 size = float2(dst.get_width(), dst.get_height());
            float2 uv = (float2(gid) + 0.5) / size;
            float3 total = float3(0.0);
            if (p.arms == 0u || p.samples == 0u) {
                dst.write(float4(total, 1.0), gid);
                return;
            }
            for (uint arm = 0; arm < p.arms; ++arm) {
                float angle = p.baseAngle + float(arm) * 6.2831853 / float(p.arms);
                float2 step = float2(cos(angle), sin(angle)) / size;
                for (uint sample = 1; sample <= p.samples; ++sample) {
                    float t = float(sample) / float(p.samples);
                    total += src.sample(bilinear, uv + step * (t * p.length)).rgb
                           * exp(-t * p.falloff);
                }
            }
            dst.write(float4(total / float(p.samples), 1.0), gid);
        }

        static float hash2(float2 v) {
            float x = sin(dot(v, float2(127.1, 311.7))) * 43758.5453;
            return x - floor(x);
        }

        static float3 acesFilmic(float3 x) {
            const float a = 2.51, b = 0.03, c = 2.43, d = 0.59, e = 0.14;
            return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
        }

        kernel void composite(texture2d<float, access::read> hdr [[texture(0)]],
                              texture2d<float, access::sample> bloom [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              texture2d<float, access::sample> spikes [[texture(3)]],
                              constant CompositeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
            float3 energy = hdr.read(gid).rgb
                          + bloom.sample(bilinear, uv).rgb * p.bloomIntensity
                          + spikes.sample(bilinear, uv).rgb * p.spikeIntensity;
            // A real frame is never on pure black: there is airglow and zodiacal light under
            // everything, and the detector adds read noise and photon shot noise on top.
            // Counterintuitively, putting them back is what stops the image looking synthetic.
            energy += p.skyLevel * float3(0.36, 0.42, 0.60);
            if (p.noiseLevel > 0.0) {
                float2 cell = float2(gid) + p.seed;
                float read = hash2(cell) - 0.5;
                float shot = hash2(cell + 17.3) - 0.5;
                float luma = max(dot(energy, float3(0.2126, 0.7152, 0.0722)), 0.0);
                energy += p.noiseLevel * (read + shot * sqrt(luma) * 4.0);
                energy = max(energy, 0.0);
            }
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
