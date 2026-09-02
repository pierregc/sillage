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
            float time;
            float megayearsPerUnit;
            float ionisedMyr;
            float populationYoungMyr;
            float populationSpan;
            float populationLast;
            float luminosityNormalisation;
            float brightness;
            float dustStrength;
            float starSize;
            float projectionScale;
            float smoothingScale;
            float referenceArea;
            float minimumSize;
            float maximumSize;
            float galaxyTint;
            /// View depth of the near face of the slab stack, and one over its thickness.
            float slabNear;
            float slabScale;
            /// 0 draws the dust, 1 draws everything that emits. Two draws over one buffer,
            /// because the extinction has to be in the attachment before a star reads it.
            uint pass;
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
            /// The lifted value that maps to white. Everything below it keeps a hue.
            float whitePoint;
            /// 1 shows the frame, 0 shows black. Applied after the tone curve so a fade goes
            /// evenly to black instead of sliding down the curve's shoulder first.
            float fade;
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
            /// Which of the four depth slabs this point belongs to, and for a star, which of
            /// them lie in front of it. One varying serves both: a grain of dust writes its
            /// opacity into its own slab, and a star reads the slabs ahead of its own.
            half4 slab;
        };

        // Two attachments: emitted light, and the optical depth of intervening dust. Both blend
        // additively, so a fragment contributing to one writes zero to the other.
        //
        // The dust attachment carries four channels, and they are four slabs of view depth
        // rather than four colours. Dust is drawn first and writes into the slab it sits in;
        // stars are drawn second and read the attachment back out of tile memory, so a star
        // can be dimmed by exactly the dust that stands between it and the camera. Before
        // this the whole column was collected without any ordering and halved on the grounds
        // that on average half of it is in front — which is true of the picture as a whole
        // and false of every individual lane in it, so no lane ever passed in front of
        // anything. It only ever greyed the galaxy down uniformly.
        struct SplatTargets {
            half4 light [[color(0)]];
            half4 dust [[color(1)]];
        };

        /// The dust attachment as it stands, read back in the fragment shader. Apple GPUs keep
        /// the attachments in tile memory for the length of a render pass, so the second draw
        /// sees what the first one wrote without a resolve or a second pass.
        struct SplatFetch {
            half4 dust [[color(1)]];
        };

        /// Extinction is steeper in the blue than in the red, which is why a lane crossing a
        /// bright disk reads brown rather than grey.
        constant float3 reddening = float3(1.0, 1.22, 1.52);

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

        // Colour temperature and visible light per unit mass of a population of this age,
        // read off the table `StellarPopulation` computes: a real initial mass function over
        // a real stellar sequence, with a giant branch, integrated at each age.
        //
        // What was here before interpolated between 4100 K and 13000 K on a ramp fitted by
        // eye, alongside a power law for the brightness capped at twelve. Both were wrong the
        // same way: the young end of the real curve is 18000 K and the real contrast between
        // a ten-megayear population and a ten-gigayear one is a factor of fifty. Young stars
        // came out too red and too faint at once, which is why a galaxy had no blue in it.
        static float2 synthesised(device const float2 *table, constant SplatUniforms &u,
                                  float ageMyr) {
            float f = log(max(ageMyr, u.populationYoungMyr) / u.populationYoungMyr)
                / u.populationSpan;
            float at = saturate(f) * u.populationLast;
            uint index = uint(min(at, u.populationLast - 1.0));
            return mix(table[index], table[index + 1u], at - float(index));
        }

        // The legacy path: a take written before every particle carried an age has only the
        // sampler's old zero-to-one population value, so it keeps the ramp that value meant.
        static float3 legacyColour(float age) {
            return blackbody(exp(mix(log(4100.0), log(13000.0), saturate(age))));
        }

        // A star-forming knot is not a blackbody: most of its light leaves in Halpha at
        // 656 nm, on the continuum of the hot stars ionising it, which is why the knots read
        // pink rather than blue. This is the colour such a region shows through broadband
        // filters, stated directly; deriving it from line ratios needs an emission model and
        // the CIE colour matching functions.
        static float3 hiiColour() {
            // Halpha at 656 nm carries the region, and the rest of what a broadband camera
            // sees of one is Hbeta and [OIII] at 486 and 500 — comparable to each other and
            // both well under the red. So the blue sits *below* the green, where it used to
            // sit above: a blue above the green is magenta, and magenta is neither what an
            // HII region looks like through a telescope nor a colour a blackbody can make, so
            // it read as the one thing in the frame that was not a star.
            return chromaticity(float3(1.00, 0.34, 0.30));
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
                                    device const float *formation [[buffer(8)]],
                                    device const float *luminosity [[buffer(2)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const uint *galaxy [[buffer(5)]],
                                    constant DiskFrame *frames [[buffer(6)]],
                                    device const float *smoothing [[buffer(7)]],
                                    device const float2 *stellar [[buffer(9)]],
                                    device const float *warming [[buffer(10)]]) {
            SplatOut out;
            float3 position = positions[vid];
            DiskFrame frame = frames[galaxy[vid]];
            out.position = u.viewProjection * float4(position, 1.0);
            out.spikes = 0.0h;
            out.slab = half4(0.0h);
            uint kind = component[vid];
            float weight = luminosity[vid];

            // Age of this particle's stars, in megayears. Two sentinels sit outside any real
            // time: material sampled as already old reads as infinitely old, and gas that has
            // formed nothing yet reads as not yet born and is still drawn as dust.
            float born = formation[vid];
            float ageMyr = (u.time - born) * u.megayearsPerUnit;
            bool knot = born > -1e8 && born < 1e8 && ageMyr >= 0.0;
            bool absorbing = kind == 2u && !knot;

            // Dark matter carries mass but no light, and every particle is skipped by one of
            // the two draws. Pushing them outside the clip volume drops them before any
            // fragment work rather than drawing a black point over the galaxy.
            if (kind == 3u || absorbing != (u.pass == 0u)) {
                out.position = float4(2.0, 2.0, 2.0, 1.0);
                out.pointSize = 0.0;
                out.color = half3(0.0h);
                out.opticalDepth = 0.0h;
                return out;
            }

            // Which slab of view depth this point falls in. `position.w` is the view depth for
            // a standard perspective projection, and the stack is centred on the camera's
            // target and as deep as the frame is wide, so a disk seen at an angle spans it.
            float slabAt = clamp((out.position.w - u.slabNear) * u.slabScale, 0.0, 0.999) * 4.0;
            uint slabIndex = uint(slabAt);
            if (u.pass == 0u) {
                // Dust writes into its own slab and nowhere else.
                out.slab = half4(slabIndex == 0u, slabIndex == 1u, slabIndex == 2u, slabIndex == 3u);
            } else {
                // A star is dimmed by everything in front of it, and by half of its own slab:
                // it sits somewhere inside that one, so on average half of the slab's dust is
                // between it and the camera. Without that half term a lane and the stars
                // embedded in it would be exactly as bright as a lane with nothing in it.
                out.slab = half4(
                    slabIndex > 0u ? 1.0h : 0.5h,
                    slabIndex > 1u ? 1.0h : (slabIndex == 1u ? 0.5h : 0.0h),
                    slabIndex > 2u ? 1.0h : (slabIndex == 2u ? 0.5h : 0.0h),
                    slabIndex == 3u ? 0.5h : 0.0h);
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

            // Gas that has made its stars is no longer a dust lane. That is not a rendering
            // convenience: the cloud a cluster forms out of is the cloud it consumes, and a
            // starburst clearing its own lanes is the visible half of running out of gas.
            // Decided up in the culling, because it is also what separates the two draws.
            if (absorbing) {
                // Dust neither emits nor follows exposure; it removes light further down.
                //
                // The lane has to come from the wave rather than from where the grains sit.
                // The sampler puts them on the arms it drew, but a disk turns differentially
                // and within an orbit they are spread evenly round it: after that, whatever
                // the wave does not darken is not a lane at all.
                // Concentrated hard into the lanes rather than spread over the disk. Spread
                // out it is optically thin everywhere — measured at the old strength, an
                // optical depth of about a tenth, where exp(-tau) is 1 - tau and it makes no
                // difference at all where the dust stands. That is why depth ordering looked
                // like it did nothing: there was nothing to order.
                float lane = 1.0 + 9.0 * pow(wave, 2.0) * pattern.y;
                out.pointSize = span * 1.3;
                out.color = half3(0.0h);
                out.opticalDepth = half(weight * u.dustStrength * lane * spread * 1.3);
            } else {
                // An arm is brighter than the disk around it, by about the factor of two a
                // grand-design spiral shows between arm and interarm. This is the only thing
                // the painted wave still does to starlight: it used to set colour as well,
                // and because `wave` is read at the particle's *current* position that made
                // every star swing between five and ten thousand kelvin twice an orbit. A
                // population does not redden and blue again as it turns. An arm is bluer
                // because of what it contains, and what it contains is fixed when the star
                // forms.
                float ambient = 0.55 + 0.95 * wave;
                // Colour and light per unit mass, both from the same synthesised population
                // at this particle's age. One table, one law: a knot three megayears old and
                // a bulge star of eleven gigayears are the same lookup at different ages.
                //
                // Normalised by the mean of the same curve over this scene's own ages, so
                // that changing the population model moves no exposure and none of the five
                // looks needs retuning.
                float2 synth = synthesised(stellar, u, ageMyr);
                float massToLight = knot ? synth.y * u.luminosityNormalisation : 1.0;
                float gain = ambient * massToLight;
                // Composition as well as age. A metal-rich population is redder at the same age
                // because metal lines blanket its blue, and a disk is metal-rich in the middle
                // and metal-poor at the edge — which is the other half of why a galaxy has a
                // warm core and a cool disk, and the half that was missing. Age alone gives a
                // gradient of the right sign and far too weak to see.
                float3 stellarLight = knot
                    ? blackbody(synth.x * warming[vid])
                    : legacyColour(population[vid]);
                // Halpha for as long as the O stars ionising the gas are alive, which is a few
                // million years and no longer. This used to be driven by the *painted* spiral
                // pattern, so the pink knots followed a texture rather than the physics: they
                // sat where the sampler had left them an orbit earlier and never appeared
                // anywhere new, however violently the galaxy was disturbed.
                float alive = knot ? exp(-ageMyr / max(u.ionisedMyr, 1e-3)) : 0.0;
                float3 emitted = mix(stellarLight, hiiColour(), alive);
                // A tint per galaxy is what keeps stars pulled into the other one legible.
                // It is a departure from the physical colour, so it is dialled rather than
                // applied: at 0 the two galaxies are coloured by their populations alone.
                emitted *= mix(float3(1.0), chromaticity(frame.tint.rgb), u.galaxyTint);
                out.pointSize = span * (alive > 0.15 ? 1.3 : 1.0);
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
                                            float2 coord [[point_coord]],
                                            SplatFetch prior) {
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
            // Everything standing between this point and the camera: the slabs in front of
            // its own, plus half of its own. `in.slab` holds the weights the vertex worked
            // out, so dust picks out the one slab it writes into and a star picks out the
            // ones it is behind.
            float column = dot(float4(prior.dust), float4(in.slab));
            float3 extinction = exp(-column * reddening);
            out.light = half4(in.color * half3(extinction) * half(falloff), half(falloff));
            out.dust = half4(in.opticalDepth * half(falloff) * in.slab);
            return out;
        }

        // Box average of the supersampled accumulation down to output resolution, with dust
        // extinction applied on the way. Interstellar dust removes blue far more than red, so a
        // lane crossing a bright disk reads brown rather than grey.
        kernel void resolve(texture2d<float, access::read> light [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant uint &factor [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float3 emitted = float3(0.0);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    emitted += light.read(gid * factor + uint2(x, y)).rgb;
                }
            }
            float inverse = 1.0 / float(factor * factor);
            // Nothing is extinguished here any more. Each star was dimmed by the dust actually
            // in front of it while it was drawn, in the slab pass, so all that is left to do
            // is the box average. What used to happen instead was that the whole dust column
            // of a pixel — in front of the stars and behind them alike — was halved and
            // applied to the total, which cannot make a lane pass in front of anything and
            // only ever pulled the whole galaxy down towards brown.
            dst.write(float4(emitted * inverse, 1.0), gid);
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

        /// Smoothed value noise over the frame, for the things that must not be uniform.
        static float smoothNoise(float2 v) {
            float2 i = floor(v);
            float2 f = v - i;
            float2 u = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash2(i), hash2(i + float2(1.0, 0.0)), u.x),
                       mix(hash2(i + float2(0.0, 1.0)), hash2(i + float2(1.0, 1.0)), u.x), u.y);
        }

        /// A few octaves of it, which is what makes a glow read as cirrus rather than as a
        /// gradient someone painted.
        static float cirrus(float2 v) {
            return smoothNoise(v) * 0.55 + smoothNoise(v * 2.7 + 11.3) * 0.28
                 + smoothNoise(v * 6.1 + 41.7) * 0.17;
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
            //
            // And none of it is flat. A uniform lift is a grey card behind the galaxy and
            // reads as one; the sky has structure in it at every scale, so this runs a few
            // octaves of noise across the frame and lets the level wander by a factor of
            // three. Warm where it is faint and cool where it is not, as scattered starlight
            // and zodiacal light divide up.
            float cloud = cirrus(uv * 3.1 + p.seed * 0.013);
            float3 nearGround = mix(float3(0.42, 0.36, 0.34), float3(0.30, 0.38, 0.62), cloud);
            energy += p.skyLevel * (0.45 + 1.75 * cloud) * nearGround;
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
            // Tone mapping pulls every bright value toward white, so the warm bulge and the
            // blue arms are re-separated around the curve rather than only before it. Doing
            // it all beforehand does not survive: a filmic shoulder desaturates highlights by
            // design, which is right for a photograph and wrong for a galaxy whose core is the
            // most interesting colour in the frame. Half the amount either side gives the same
            // overall push while leaving the bright parts a hue.
            float half_amount = sqrt(max(p.saturation, 0.0));
            float luma = max(dot(lifted, float3(0.2126, 0.7152, 0.0722)), 0.0);
            lifted = max(mix(float3(luma), lifted, half_amount), 0.0);
            luma = max(dot(lifted, float3(0.2126, 0.7152, 0.0722)), 1e-5);

            // Where the flat white core came from, and it was not the exposure. The stretch
            // above is normalised so that an energy of one lands on one, and a bulge is two
            // orders of magnitude above the disk around it — so it came out of the stretch at
            // three or more, and every value over one was flattened onto white by the curve
            // that followed. A plateau with a hard edge, exactly where the most interesting
            // colour in the picture is.
            //
            // This maps the *luminance* through a curve with a white point instead, so a core
            // three times over the disk lands below white and keeps falling rather than
            // clipping, and the colour is carried through unchanged by scaling the pixel by
            // the ratio. Hue survives the shoulder, which is the whole point.
            float white = max(p.whitePoint, 1.0);
            float toned = luma * (1.0 + luma / (white * white)) / (1.0 + luma);
            float3 preserved = lifted * (toned / luma);

            // Preserving hue can still push a channel past one where the colour is saturated
            // and bright at once. There the filmic curve takes over, because something has to
            // give and losing a little saturation is better than clipping a channel flat.
            float3 filmic = acesFilmic(lifted);
            float over = max(preserved.r, max(preserved.g, preserved.b));
            float3 mapped = mix(preserved, filmic, smoothstep(0.85, 1.15, over));
            float mappedLuma = dot(mapped, float3(0.2126, 0.7152, 0.0722));
            mapped = max(mix(float3(mappedLuma), mapped, half_amount), 0.0);
            mapped = saturate(mapped);
            output.write(float4(pow(mapped, 1.0 / 2.2) * p.fade, 1.0), gid);
        }
        """
}
