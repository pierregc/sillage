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
            float ionisingRiseMyr;
            float ionisedStrength;
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
            /// Whether any galaxy has a colour ramp (#119).
            uint mapped;
            /// Radius in kpc of a black hole's dark dot, zero for none.
            float holeShadow;
            /// Stars a kernel should cover in projection, 0 to size it from the 3D spacing
            /// alone. Spike on the grain of a render (docs/notes/gigantism.md).
            float columnSmoothing;
            /// Accumulation pixels per column-density cell, per axis.
            float columnCell;
            /// Light kept by the compact bright minority: 1 as sampled, 0 as ordinary stars.
            float glint;
        };

        struct GalaxyRamp {
            float4 core;
            float4 disk;
            float4 outskirts;
            float4 young;
            float4 knot;
            /// Core, disk start, disk end and outskirts, in scale lengths of birth radius.
            float4 stops;
            /// Blend into the population colour, mix mapping, has a ramp.
            float4 params;
        };

        // The colour a galaxy's ramp gives this particle. With the mix mapping, gas and the
        // stars the run formed take the young colour, bulge and outskirts the ramp's ends.
        static float3 rampColour(constant GalaxyRamp &ramp, float radius, uint kind, float born) {
            if (ramp.params.y > 0.5) {
                if (kind == 1u || kind == 2u || (born >= 0.0 && born < 1e8)) { return ramp.young.rgb; }
                if (kind == 4u) { return ramp.core.rgb; }
                if (kind == 5u) { return ramp.outskirts.rgb; }
            }
            float4 s = ramp.stops;
            float3 inner = mix(ramp.core.rgb, ramp.disk.rgb, saturate((radius - s.x) / (s.y - s.x)));
            return mix(inner, ramp.outskirts.rgb, saturate((radius - s.z) / (s.w - s.z)));
        }

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
            float skyRed;
            float skyGreen;
            float skyBlue;
        };

        struct SpikeParams {
            uint arms;
            float baseAngle;
            float length;
            float falloff;
            uint samples;
            uint shortArms;
            float shortBaseAngle;
            float shortScale;
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
        // additively, and each draw writes only the one it contributes to; the other is masked
        // off in the pipeline.
        //
        // The dust attachment carries four channels, and they are four slabs of view depth
        // rather than four colours. Dust is drawn first and writes into the slab it sits in;
        // stars are drawn second and read the attachment back out of tile memory, so a star
        // can be dimmed by exactly the dust that stands between it and the camera. Before
        // this the whole column was collected without any ordering and halved on the grounds
        // that on average half of it is in front — which is true of the picture as a whole
        // and false of every individual lane in it, so no lane ever passed in front of
        // anything. It only ever greyed the galaxy down uniformly.
        struct LightTarget {
            half4 light [[color(0)]];
        };

        struct DustTarget {
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
            /// The material's angular rate at eight radii, for the dust web.
            float4 omegaInner;
            float4 omegaOuter;
            /// Intact, renewal period, phase.
            float4 web;
        };

        // Integer mixing rather than the usual fract(sin(x) * 43758.5453), and that is not a
        // preference. The sampler in SillageCore has to produce the *same* pattern as this one
        // or the matter sits where the paint says there is nothing, and a sine-based hash
        // cannot do that: the last bits of sin differ between a CPU and a GPU, and after
        // multiplying by forty thousand and taking the fraction, two implementations agreeing
        // to seven digits give unrelated numbers. This gives the same answer on both, exactly.
        // Mirrored in `SpiralPattern.hash`; edit both.
        static float hash1(float i) {
            int k = int(i);
            uint n = uint(k * 374761393 + 668265263);
            n = (n ^ (n >> 13u)) * 1274126177u;
            n = n ^ (n >> 16u);
            return float(n) * (1.0 / 4294967296.0);
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
        // Mirrored from `SpiralPattern.ridge` in SillageCore, which the sampler uses to lay
        // the particles down. The two have to stay the same expression: this is what makes the
        // light and the matter agree about where the arms are, and it is what lets a lopsided
        // galaxy be lopsided in its mass rather than only in its paint.
        static float spiralRidge(float extent, float phi, float arms, float windRate,
                                 float irregular, float seed, float phase) {
            float wander = (fractalNoise(extent * 1.5 + seed) - 0.5) * 2.6 * irregular;
            float wound = phi - windRate * log(max(extent, 1e-3)) - phase + wander;

            float armPhase = arms * wound;
            float ridge = 0.5 + 0.5 * cos(armPhase);

            float breaks = (0.18 + 1.05 * fractalNoise(wound * 0.62 + extent * 0.9 + seed * 3.1))
                         / 0.705;
            ridge *= 1.0 + irregular * (breaks - 1.0);

            float perArm = (0.35 + 1.25 * fractalNoise(armPhase * 0.159 + seed * 7.7)) / 0.975;
            ridge *= 1.0 + irregular * (perArm - 1.0);

            float spurPhase = (arms + 3.0) * (phi - 1.7 * windRate * log(max(extent, 1e-3)))
                            + 2.1;
            float spur = max(cos(spurPhase), 0.0);
            float spurWhere = fractalNoise(extent * 0.9 + seed * 2.3 + 31.0);
            ridge += irregular * 0.55 * spur * spur * spur
                   * smoothstep(0.55, 0.85, spurWhere);

            float lopsided = 1.0 + irregular * 0.30 * cos(phi + seed * 2.1);
            return clamp(ridge * lopsided, 0.0, 1.0);
        }

        // Fine strands inside a dust lane, at rest in the pattern's own frame.
        //
        // Paint, and deliberately so — unlike the arm pattern this has no counterpart in the
        // sampler. A lane is a *pattern* feature: gas piles up where the pattern is and flows
        // through it, so a lane sits still while the material crosses it, and painting the
        // strands is not a shortcut but the right frame to put them in. The filaments the
        // sampler lays down are carried by the grains and are therefore sheared away within
        // an orbit — measured, the lane structure was gone by two hundred megayears — so this
        // is what makes a galaxy still have dust in it after a turn.
        static float laneDetail(float3 position, DiskFrame frame) {
            float3 rel = position - frame.center.xyz;
            float u = dot(rel, frame.axisU.xyz);
            float v = dot(rel, frame.axisV.xyz);
            float radius = sqrt(u * u + v * v);
            float scale = max(frame.center.w, 1e-3);
            float extent = radius / scale;
            float wound = atan2(v, u)
                        - frame.pattern.x * log(max(radius, 1e-3) / scale)
                        - frame.pattern.y;
            // The angle is warped before the strands are read off it, which is what makes
            // them snake. Sampled straight, the noise lays down threads that all run along the
            // arm at the same pitch — clean, parallel, and obviously drawn. Displacing the
            // coordinate first bends every strand by a different amount at every radius, and
            // the result reads as torn membrane rather than as combed hair.
            float warp = fractalNoise(wound * 2.1 + extent * 3.7 + frame.pattern.w * 1.9) - 0.5;
            float twist = fractalNoise(wound * 5.9 - extent * 1.3 + frame.pattern.w * 4.1) - 0.5;
            float bent = wound + 0.88 * warp + 0.30 * twist;

            // High along the arm and higher still across it, which is what makes a strand a
            // strand rather than a patch.
            float fine = fractalNoise(bent * 7.3 + extent * 2.1 + frame.pattern.w * 5.3);
            float finer = fractalNoise(bent * 19.0 - extent * 5.7 + frame.pattern.w * 2.9);
            return 0.18 + 1.5 * fine * (0.45 + 0.9 * finer);
        }

        // Where a particle sits relative to the spiral pattern, evaluated at its current
        // position so the arms do not wind up with the disk.
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

            float ridge = spiralRidge(extent, atan2(v, u), frame.axisU.w, frame.pattern.x,
                                      frame.pattern.z, frame.pattern.w, frame.pattern.y);
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
                                    device const float2 *traits [[buffer(10)]],
                                    device const float *rampKeys [[buffer(11)]],
                                    constant GalaxyRamp *ramps [[buffer(12)]],
                                    texture2d<float, access::sample> column [[texture(0)]]) {
            SplatOut out;
            float3 position = positions[vid];
            DiskFrame frame = frames[galaxy[vid]];
            out.position = u.viewProjection * float4(position, 1.0);
            out.spikes = 0.0h;
            out.slab = half4(0.0h);
            uint kind = component[vid];
            float weight = luminosity[vid];
            // The compact bright minority the sampler drew (DiskSampler, kernelScale 0.75):
            // two per cent of the stars carrying a quarter of the light as point sources. At
            // glint 0 they are given back the light and the width of an ordinary star.
            float kernelScale = traits[vid].y;
            if (kernelScale < 0.8) {
                weight *= mix(0.07, 1.0, u.glint);
                kernelScale = mix(0.9, kernelScale, u.glint);
            }

            // Age of this particle's stars, in megayears. Two sentinels sit outside any real
            // time: material sampled as already old reads as infinitely old, and gas that has
            // formed nothing yet reads as not yet born and is still drawn as dust.
            float born = formation[vid];
            // Only gas carries an age that has to advance. A sampled star stands for tens of
            // thousands of stars already in steady state, not for a coeval group, so its
            // colour has no business drifting over a run — and it was drifting hard: a whole
            // disk ageing in lockstep turned gold inside a gigayear while the four per cent
            // of particles the run forms could not repaint it. Frozen at the age it was drawn
            // with; gas, and anything the run itself formed, still ages.
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8 && born < 1e8 && ageMyr >= 0.0;
            // A black hole emits nothing. Asked for, it absorbs like a knot of dust that lets
            // nothing through, so it is drawn with the dust and darkens what lies behind it.
            bool hole = kind == 6u;
            bool absorbing = (kind == 2u && !knot) || hole;

            // Dark matter carries mass but no light, and every particle is skipped by one of
            // the two draws. Pushing them outside the clip volume drops them before any
            // fragment work rather than drawing a black point over the galaxy.
            if (kind == 3u || (hole && u.holeShadow <= 0.0) || absorbing != (u.pass == 0u)) {
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
            // Two scales of emission. Most particles are drawn wide, and because widening a
            // kernel conserves its flux that is the same light spread thinner: enough of them
            // overlapping make a continuum instead of a stipple. A small minority are compact
            // and much brighter, and those are the sources the eye picks out one at a time.
            float raw = max(smoothing[vid] * u.smoothingScale * kernelScale, 1e-4) * perPixel;
            // The spacing above is the three-dimensional one, read off the solver's tree. A
            // thin disk seen face-on stacks many of those spacings along a line of sight, so
            // a kernel sized to one of them still resolves the particles. Sized instead so
            // that it covers `columnSmoothing` stars in projection, from the count the
            // column pass drew into coarse cells, it is wide where the picture is sparse and
            // narrow where it is dense, and never narrower than the tree's own answer.
            if (!absorbing && u.columnSmoothing > 0.0) {
                float2 uv = float2(0.5, 0.5) + float2(0.5, -0.5) * out.position.xy / depth;
                float count = max(column.sample(bilinear, uv).r, 0.25);
                float density = count / (u.columnCell * u.columnCell);
                float projected = 2.0 * sqrt(u.columnSmoothing / (M_PI_F * density));
                raw = max(raw, projected);
            }
            float span = clamp(raw, u.minimumSize, u.maximumSize);
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
                // At nine, with no detail in it, this painted band *was* the dust: a pair of
                // wide smooth arcs, which is what read as sausages. It is the same band times
                // a filament field now — the strands are what carry the shape, and they sit
                // in the pattern's frame, where a lane belongs.
                float lane = 1.0 + 7.0 * pow(wave, 2.0) * pattern.y * laneDetail(position, frame);
                out.pointSize = span * 1.3;
                out.color = half3(0.0h);
                out.opticalDepth = half(weight * u.dustStrength * lane * spread * 1.3);
                if (hole) {
                    // Twice the radius, since the kernel falls to a hundredth at its edge.
                    out.pointSize = max(4.0 * u.holeShadow * perPixel, 2.0);
                    out.opticalDepth = 8.0h;
                }
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
                    ? blackbody(synth.x * traits[vid].x)
                    : legacyColour(population[vid]);
                // Halpha, for as long as the region keeps a nebula lit inside it.
                //
                // Only gas can be ionised, and that is the whole of what this test says: a
                // particle sampled as an HII region, or gas the run itself turned into stars.
                // An ordinary disk star stands for a mixed population with no cloud around it
                // and cannot glow however young it is.
                //
                // It used to be every young particle, and that tied the length of the window
                // to the youngest age the sampler hands out — raise one past the other and the
                // *disk* is inside the window, which put sixty-six thousand particles alight
                // carrying seven tenths of the light. Tested on the component instead, the two
                // numbers have nothing to do with each other and the window can be as long as
                // the thing it represents actually lasts.
                // A region swells rather than arriving lit, and never reaches pure line
                // emission: the rise is what stops a knot popping into the frame at full
                // brightness, and the strength is what keeps it a star with a nebula around
                // it rather than a red dot.
                float rise = 1.0 - exp(-ageMyr / max(u.ionisingRiseMyr, 1e-3));
                float alive = (knot && nursery)
                    ? u.ionisedStrength * rise * exp(-ageMyr / max(u.ionisedMyr, 1e-3)) : 0.0;
                float3 emitted = mix(stellarLight, hiiColour(), alive);
                // A tint per galaxy is what keeps stars pulled into the other one legible.
                // It is a departure from the physical colour, so it is dialled rather than
                // applied: at 0 the two galaxies are coloured by their populations alone.
                emitted *= mix(float3(1.0), chromaticity(frame.tint.rgb), u.galaxyTint);
                if (u.mapped != 0u) {
                    constant GalaxyRamp &ramp = ramps[galaxy[vid]];
                    if (ramp.params.z > 0.5) {
                        float3 painted = rampColour(ramp, rampKeys[vid], kind, born);
                        emitted = mix(mix(stellarLight, painted, ramp.params.x), ramp.knot.rgb, alive);
                    }
                }
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

        // Reading the dust attachment makes overlapping fragments on a pixel run in order, so
        // only the draw that needs it reads it: the dust writes its own slab without looking,
        // and the field stars sit behind the whole stack and are not dimmed by it.
        fragment DustTarget dustFragment(SplatOut in [[stage_in]],
                                         float2 coord [[point_coord]]) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }

            DustTarget out;
            out.dust = half4(in.opticalDepth * half(exp(-4.5 * r2)) * in.slab);
            return out;
        }

        // The dust web (#173, docs/notes/dust-web.md): a field of filaments in each disk's own
        // plane, carried round by the disk's rotation curve and renewed before the shear can
        // wind it up, two copies half a period apart cross-faded so that no moment shows a
        // renewal (Max and Becker 1995, Neyret 2003). Paid once per pixel (#200): the grains
        // write the dust they hand to the web into a carrier of their own, slab by slab, and a
        // pass multiplies it by the web of the disk tagged there, read from a lace baked once.
        // Its own pipelines, so a look without it draws exactly what it drew before.
        struct WebUniforms {
            /// The eye, and how much of the web is drawn.
            float4 eye;
            /// The camera's right, and how much wider a grain is drawn under the web.
            float4 right;
            /// The camera's up, and the simulated time.
            float4 up;
            /// Rest phase, cell in scale lengths, smallest and largest cell in kpc.
            float4 params;
            /// The camera's forward, and the tangent of half the vertical field of view.
            float4 forward;
            /// The accumulation's width and height in pixels, its aspect, and one over the
            /// baked lace's mean.
            float4 target;
            /// How many times coarser the carrier is drawn, and the smallest grain it takes, in
            /// its own pixels.
            float4 carrier;
        };

        static float2 webHash(uint2 v) {
            v = v * 1664525u + 1013904223u;
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            return float2(v) * (1.0 / 4294967296.0);
        }

        // The lace tiles every `laceTile` cells: each lattice it is read off holds a whole
        // number of its cells in a tile, within 0.7 % of the frequencies the spike drew.
        constant int laceTile = 64;

        static int2 laceWrap(int2 cell, int period) {
            return (cell % period + period) % period;
        }

        static float laceValue(float2 q, int period, float2 shift) {
            float2 p = q * (float(period) / float(laceTile)) + shift;
            float2 i = floor(p);
            float2 f = p - i;
            float2 s = f * f * (3.0 - 2.0 * f);
            int2 c = int2(i);
            float a = webHash(uint2(laceWrap(c, period))).x;
            float b = webHash(uint2(laceWrap(c + int2(1, 0), period))).x;
            float d = webHash(uint2(laceWrap(c + int2(0, 1), period))).x;
            float e = webHash(uint2(laceWrap(c + int2(1, 1), period))).x;
            return mix(mix(a, b, s.x), mix(d, e, s.x), s.y);
        }

        static float laceFbm(float2 q, int low, int high, float2 shift) {
            float ratio = float(high) / float(low);
            return (0.5 * laceValue(q, low, shift)
                    + 0.25 * laceValue(q, high, shift * ratio + float2(17.1, -9.7))) / 0.75;
        }

        static float laceRidge(float2 p, int period, float2 shift) {
            float ridge = 1.0 - abs(2.0 * laceValue(p, period, shift) - 1.0);
            return ridge * ridge * ridge * ridge * ridge;
        }

        // Threads that branch: ridged noise, each octave weighted by the ridge above it.
        static float laceThreads(float2 p) {
            float first = laceRidge(p, 83, float2(0.0));
            float second = laceRidge(p, 175, float2(5.3, 1.9));
            float third = laceRidge(p, 367, float2(16.43, 5.89));
            return 0.6 * first + 0.33 * second * saturate(first * 1.5)
                + 0.1815 * third * saturate(second * 1.5);
        }

        // Cell walls, each wall drawn at its own strength so the web stays open.
        static float laceWalls(float2 q) {
            const int period = 51;
            float2 p = q * (float(period) / float(laceTile));
            int2 base = int2(floor(p));
            float first = 9.0;
            float second = 9.0;
            int2 near = base;
            int2 next = base;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    int2 c = base + int2(x, y);
                    float d = distance(float2(c) + 0.1 + 0.8 * webHash(uint2(laceWrap(c, period))), p);
                    if (d < first) {
                        second = first;
                        next = near;
                        first = d;
                        near = c;
                    } else if (d < second) {
                        second = d;
                        next = c;
                    }
                }
            }
            int2 a = laceWrap(near, period);
            int2 b = laceWrap(next, period);
            float wall = webHash(uint2(min(a, b) * int2(73, 37) + max(a, b) * int2(151, 197))).x;
            float gap = (second - first) / 0.1;
            return exp(-gap * gap) * (0.25 + 0.75 * wall);
        }

        // Threads and walls on a warped plane, with clear holes, in cells; not yet divided by
        // its mean.
        static float webLace(float2 q) {
            float2 p = q + 2.2 * (float2(laceFbm(q, 32, 65, float2(11.3, 2.9)),
                                         laceFbm(q, 32, 65, float2(-7.1, 17.7))) - 0.5);
            float threads = laceThreads(p);
            float walls = laceWalls(p);
            float holes = saturate((laceFbm(p, 58, 118, float2(4.4, 6.6)) - 0.58) * 6.0);
            return (0.15 + 2.0 * threads + 0.8 * walls) * (1.0 - 0.9 * holes);
        }

        // One tile of the lace, four samples a texel, baked once per device.
        kernel void bakeLace(texture2d<half, access::write> lace [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= lace.get_width() || gid.y >= lace.get_height()) { return; }
            float texel = float(laceTile) / float(lace.get_width());
            float total = 0.0;
            for (int y = 0; y < 2; ++y) {
                for (int x = 0; x < 2; ++x) {
                    total += webLace((float2(gid) + (float2(float(x), float(y)) + 0.5) * 0.5) * texel);
                }
            }
            lace.write(half4(half(0.25 * total)), gid);
        }

        // The disk's angular rate at a radius, from eight samples a factor 1.68 apart; inside
        // the first it turns as a solid body, past the last its curve is flat.
        static float webOmega(DiskFrame frame, float radius) {
            float h = max(frame.center.w, 1e-3);
            float x = (log2(max(radius / h, 1e-4)) + 2.0) / 0.75;
            if (x >= 7.0) { return frame.omegaOuter.w * 9.5137 * h / max(radius, 1e-4); }
            x = max(x, 0.0);
            int i = min(int(x), 6);
            float a = i < 4 ? frame.omegaInner[i] : frame.omegaOuter[i - 4];
            float b = i < 3 ? frame.omegaInner[i + 1] : frame.omegaOuter[i - 3];
            return mix(a, b, x - float(i));
        }

        // How fast that rate falls with radius: the shear a copy has taken on since it rested.
        static float webOmegaSlope(DiskFrame frame, float radius) {
            float h = max(frame.center.w, 1e-3);
            float r = max(radius, 1e-4);
            float x = (log2(max(r / h, 1e-4)) + 2.0) / 0.75;
            if (x >= 7.0) { return -webOmega(frame, r) / r; }
            if (x <= 0.0) { return 0.0; }
            int i = min(int(x), 6);
            float a = i < 4 ? frame.omegaInner[i] : frame.omegaOuter[i - 4];
            float b = i < 3 ? frame.omegaInner[i + 1] : frame.omegaOuter[i - 3];
            return (b - a) / (0.75 * M_LN2_F * r);
        }

        // A quarter of the dust stays even under the web: with none, a dense clump opens onto
        // whatever bright knot it holds and the core burns white.
        constant float webDepth = 0.75;

        constexpr sampler laceSampler(filter::linear, mip_filter::linear, address::repeat,
                                      max_anisotropy(8));

        // The web where this pixel's ray meets the disk's mid-plane, which is the same point
        // whichever grain the dust came from, so an inclined disk shows it foreshortened. Each
        // copy is carried round from where it rests, a share of its life in, and fades in and
        // out with sin squared; the two weights always sum to one, and dividing by their root
        // sum of squares keeps the contrast through the cross-fade.
        static float webAt(DiskFrame frame, constant WebUniforms &w, float3 ray, float3 stepX,
                           float3 stepY, texture2d<half> lace) {
            float period = frame.web.y;
            if (period <= 0.0) { return 1.0; }
            float3 axis = cross(frame.axisU.xyz, frame.axisV.xyz);
            float3 rel = w.eye.xyz - frame.center.xyz;
            float least = 0.05 * length(ray);
            float along = dot(ray, axis);
            along = along < 0.0 ? min(along, -least) : max(along, least);
            float t = -dot(rel, axis) / along;
            if (t <= 0.0) { return 1.0; }
            float3 meet = rel + ray * t;
            float3 ex = t * (stepX - ray * (dot(stepX, axis) / along));
            float3 ey = t * (stepY - ray * (dot(stepY, axis) / along));
            float2 p = float2(dot(meet, frame.axisU.xyz), dot(meet, frame.axisV.xyz));
            float2 dx = float2(dot(ex, frame.axisU.xyz), dot(ex, frame.axisV.xyz));
            float2 dy = float2(dot(ey, frame.axisU.xyz), dot(ey, frame.axisV.xyz));
            float h = max(frame.center.w, 1e-3);
            float cell = clamp(w.params.y * h, w.params.z, w.params.w);
            // The thinnest wall is a tenth of a cell: under a pixel it would only shimmer.
            float pixel = max(length(dx), length(dy));
            float detail = smoothstep(0.6, 2.0, 0.1 * cell / max(pixel, 1e-6));
            if (detail <= 0.0) { return 1.0; }
            float radius = length(p);
            float omega = webOmega(frame, radius);
            float shear = webOmegaSlope(frame, radius) / max(radius, 1e-4);
            float scale = 1.0 / (cell * float(laceTile));
            float total = 0.0;
            float norm = 0.0;
            for (int k = 0; k < 2; ++k) {
                float s = w.up.w / period + frame.web.z + 0.5 * float(k);
                float cycle = floor(s);
                float phase = s - cycle;
                float weight = sinpi(phase);
                weight *= weight;
                float age = (phase - w.params.x) * period;
                float angle = omega * age;
                float c = cos(angle);
                float n = sin(angle);
                float2 q = float2(c * p.x + n * p.y, n * -p.x + c * p.y);
                // A pixel's footprint turned with it, and sheared by how the rate falls.
                float2 turn = float2(n * -p.x + c * p.y, -c * p.x - n * p.y) * (shear * age);
                float2 qx = float2(c * dx.x + n * dx.y, n * -dx.x + c * dx.y) + turn * dot(p, dx);
                float2 qy = float2(c * dy.x + n * dy.y, n * -dy.x + c * dy.y) + turn * dot(p, dy);
                float2 offset = webHash(uint2(int2(int(cycle) * 2 + k, int(frame.pattern.w * 10.0)))) * 400.0;
                float value = float(lace.sample(laceSampler, (q / cell + offset) / float(laceTile),
                                                gradient2d(qx * scale, qy * scale)).r);
                total += weight * (value * w.target.w - 1.0);
                norm += weight * weight;
            }
            return max(1.0 + webDepth * detail * total * rsqrt(max(norm, 1e-4)), 0.0);
        }

        // What both dust passes under the web need of a grain: where it is, which slab, and how
        // much of it the web takes. Only inside an intact disk, near its plane and inside its
        // edge: a tail or a bridge keeps the dust its particles carry. Near rather than in,
        // since a disk an encounter has started to warp is still a disk. Seen edge on there is
        // no web. False for anything that is not dust.
        struct WebGrain {
            float4 position;
            half4 slab;
            float perPixel;
            float weight;
            float kernelScale;
            float amount;
            bool hole;
        };

        static bool webGrain(uint vid, device const float3 *positions, device const float *formation,
                             device const float *luminosity, device const uint *component,
                             constant SplatUniforms &u, DiskFrame frame,
                             device const float2 *traits, constant WebUniforms &w,
                             thread WebGrain &grain) {
            float3 position = positions[vid];
            grain.position = u.viewProjection * float4(position, 1.0);
            uint kind = component[vid];
            grain.weight = luminosity[vid];
            grain.kernelScale = traits[vid].y;
            if (grain.kernelScale < 0.8) {
                grain.weight *= mix(0.07, 1.0, u.glint);
                grain.kernelScale = mix(0.9, grain.kernelScale, u.glint);
            }
            float born = formation[vid];
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8 && born < 1e8 && ageMyr >= 0.0;
            grain.hole = kind == 6u;
            bool absorbing = (kind == 2u && !knot) || grain.hole;
            if (kind == 3u || (grain.hole && u.holeShadow <= 0.0) || !absorbing) { return false; }
            float slabAt = clamp((grain.position.w - u.slabNear) * u.slabScale, 0.0, 0.999) * 4.0;
            uint slabIndex = uint(slabAt);
            grain.slab = half4(slabIndex == 0u, slabIndex == 1u, slabIndex == 2u, slabIndex == 3u);
            grain.perPixel = u.projectionScale / max(grain.position.w, 1e-3);
            grain.amount = 0.0;
            if (grain.hole) { return true; }
            float3 axis = cross(frame.axisU.xyz, frame.axisV.xyz);
            float3 rel = position - frame.center.xyz;
            float height = dot(rel, axis);
            float scale = max(frame.center.w, 1e-3);
            float facing = dot(normalize(position - w.eye.xyz), axis);
            grain.amount = w.eye.w * frame.web.x
                * (1.0 - smoothstep(0.3 * scale, 0.8 * scale, abs(height)))
                * (1.0 - smoothstep(5.0 * scale, 7.0 * scale, length(rel - axis * height)))
                * smoothstep(0.12, 0.35, abs(facing));
            return true;
        }

        // The dust the painted strands lay, in the frame's own pass: all of it where the web
        // is off and none where it takes everything, so a grain it fully carries draws nothing
        // here.
        vertex SplatOut dustWebVertex(uint vid [[vertex_id]],
                                      device const float3 *positions [[buffer(0)]],
                                      device const float *formation [[buffer(8)]],
                                      device const float *luminosity [[buffer(2)]],
                                      device const uint *component [[buffer(3)]],
                                      constant SplatUniforms &u [[buffer(4)]],
                                      device const uint *galaxy [[buffer(5)]],
                                      constant DiskFrame *frames [[buffer(6)]],
                                      device const float *smoothing [[buffer(7)]],
                                      device const float2 *traits [[buffer(10)]],
                                      constant WebUniforms &w [[buffer(13)]]) {
            SplatOut out;
            out.color = half3(0.0h);
            out.spikes = 0.0h;
            DiskFrame frame = frames[galaxy[vid]];
            WebGrain grain;
            bool dust = webGrain(vid, positions, formation, luminosity, component, u, frame,
                                 traits, w, grain);
            if (!dust || grain.amount >= 1.0) {
                out.position = float4(2.0, 2.0, 2.0, 1.0);
                out.pointSize = 0.0;
                out.opticalDepth = 0.0h;
                out.slab = half4(0.0h);
                return out;
            }
            out.position = grain.position;
            out.slab = grain.slab;
            if (grain.hole) {
                out.pointSize = max(4.0 * u.holeShadow * grain.perPixel, 2.0);
                out.opticalDepth = 8.0h;
                return out;
            }
            float3 position = positions[vid];
            float raw = max(smoothing[vid] * u.smoothingScale * grain.kernelScale
                                * mix(1.0, w.right.w, grain.amount), 1e-4) * grain.perPixel;
            float span = clamp(raw, u.minimumSize, u.maximumSize);
            float reach = span / grain.perPixel;
            float spread = u.referenceArea / (reach * reach);
            float2 pattern = armWave(position, frame);
            float lane = 1.0 + 7.0 * pow(pattern.x, 2.0) * pattern.y * laneDetail(position, frame);
            out.pointSize = span * 1.3;
            out.opticalDepth = half(grain.weight * u.dustStrength * spread * 1.3
                                    * (1.0 - grain.amount) * lane);
            return out;
        }

        struct WebCarrierOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            float carried;
            half4 slab;
            /// The grain's galaxy plus one, over 255.
            half tag;
        };

        struct WebCarrierTarget {
            half4 carrier [[color(0)]];
            half4 tags [[color(1)]];
        };

        // The dust the web multiplies, drawn a few times coarser than the frame (#200): a
        // grain under the web is drawn twice as wide (its column kept) so the grains merge into
        // one even layer and the lace, not the grains, says where the dust is thin, and a layer
        // that smooth loses nothing at a quarter of the pixels.
        vertex WebCarrierOut webCarrierVertex(uint vid [[vertex_id]],
                                              device const float3 *positions [[buffer(0)]],
                                              device const float *formation [[buffer(8)]],
                                              device const float *luminosity [[buffer(2)]],
                                              device const uint *component [[buffer(3)]],
                                              constant SplatUniforms &u [[buffer(4)]],
                                              device const uint *galaxy [[buffer(5)]],
                                              constant DiskFrame *frames [[buffer(6)]],
                                              device const float *smoothing [[buffer(7)]],
                                              device const float2 *traits [[buffer(10)]],
                                              constant WebUniforms &w [[buffer(13)]]) {
            WebCarrierOut out;
            uint g = galaxy[vid];
            DiskFrame frame = frames[g];
            WebGrain grain;
            bool dust = webGrain(vid, positions, formation, luminosity, component, u, frame,
                                 traits, w, grain);
            if (!dust || grain.hole || grain.amount <= 0.0) {
                out.position = float4(2.0, 2.0, 2.0, 1.0);
                out.pointSize = 0.0;
                out.carried = 0.0;
                out.slab = half4(0.0h);
                out.tag = 0.0h;
                return out;
            }
            float3 position = positions[vid];
            float coarse = w.carrier.x;
            float raw = max(smoothing[vid] * u.smoothingScale * grain.kernelScale
                                * mix(1.0, w.right.w, grain.amount), 1e-4) * grain.perPixel;
            // Never under a few of its own pixels, or the coarse target would drop part of it.
            float span = clamp(raw, max(u.minimumSize, w.carrier.y * coarse / 1.3), u.maximumSize);
            float reach = span / grain.perPixel;
            float spread = u.referenceArea / (reach * reach);
            float2 pattern = armWave(position, frame);
            // The painted strands' own mean under the web, so the web moves no exposure.
            float lane = 1.0 + 7.0 * pow(pattern.x, 2.0) * pattern.y * 0.855;
            out.position = grain.position;
            out.pointSize = span * 1.3 / coarse;
            out.carried = grain.weight * u.dustStrength * spread * 1.3 * grain.amount * lane;
            out.slab = grain.slab;
            out.tag = half(float(g + 1u) / 255.0);
            return out;
        }

        fragment WebCarrierTarget webCarrierFragment(WebCarrierOut in [[stage_in]],
                                                     float2 coord [[point_coord]]) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }
            WebCarrierTarget out;
            out.carrier = half4(half(in.carried * exp(-4.5 * r2)) * in.slab);
            out.tags = in.tag * in.slab;
            return out;
        }

        struct WebResolveOut {
            float4 position [[position]];
        };

        vertex WebResolveOut webResolveVertex(uint vid [[vertex_id]]) {
            WebResolveOut out;
            float2 corner = float2(float((vid << 1u) & 2u), float(vid & 2u));
            out.position = float4(corner * 2.0 - 1.0, 0.0, 1.0);
            return out;
        }

        constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge, coord::normalized);

        // Once per pixel, after the painted dust and before the stars: each slab's carried dust
        // times the web of the disk that filled it. Where two disks carry dust into one slab of
        // one pixel, the later galaxy's web serves both.
        fragment DustTarget webResolveFragment(WebResolveOut in [[stage_in]],
                                               constant DiskFrame *frames [[buffer(0)]],
                                               constant WebUniforms &w [[buffer(1)]],
                                               texture2d<half> lace [[texture(0)]],
                                               texture2d<half> carried [[texture(1)]],
                                               texture2d<half> tagged [[texture(2)]]) {
            float2 uv = in.position.xy / w.target.xy;
            float4 carrier = float4(carried.sample(bilinear, uv));
            if (all(carrier <= 0.0)) { discard_fragment(); }
            float4 tags = float4(tagged.sample(pointSampler, uv)) * 255.0;
            float2 ndc = float2(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
            float3 across = w.right.xyz * (w.forward.w * w.target.z);
            float3 upward = w.up.xyz * w.forward.w;
            float3 ray = w.forward.xyz + ndc.x * across + ndc.y * upward;
            float3 stepX = across * (2.0 / w.target.x);
            float3 stepY = upward * (-2.0 / w.target.y);
            float4 webbed = carrier;
            int last = -1;
            float web = 1.0;
            for (int s = 0; s < 4; ++s) {
                int g = int(tags[s] + 0.5) - 1;
                if (carrier[s] <= 0.0 || g < 0) { continue; }
                if (g != last) {
                    web = webAt(frames[g], w, ray, stepX, stepY, lace);
                    last = g;
                }
                webbed[s] = carrier[s] * web;
            }
            DustTarget out;
            out.dust = half4(webbed);
            return out;
        }

        // Everything standing between this point and the camera: the slabs in front of its
        // own, plus half of its own. `in.slab` holds the weights the vertex worked out, so a
        // star picks out the ones it is behind.
        fragment LightTarget splatFragment(SplatOut in [[stage_in]],
                                           float2 coord [[point_coord]],
                                           SplatFetch prior) {
            float2 d = coord - 0.5;
            float r2 = dot(d, d) * 4.0;
            if (r2 > 1.0) { discard_fragment(); }

            float falloff = exp(-4.5 * r2);
            float column = dot(float4(prior.dust), float4(in.slab));
            float3 extinction = exp(-column * reddening);
            LightTarget out;
            out.light = half4(in.color * half3(extinction) * half(falloff), half(falloff));
            return out;
        }

        // The column pass: one count per emitting particle into coarse cells, which the
        // splat vertex reads back to size a kernel by how many stars share its patch of sky.
        struct CountOut {
            float4 position [[position]];
            float pointSize [[point_size]];
        };

        vertex CountOut countVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const float *formation [[buffer(8)]]) {
            CountOut out;
            out.position = u.viewProjection * float4(positions[vid], 1.0);
            out.pointSize = 1.0;
            uint kind = component[vid];
            float born = formation[vid];
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8 && born < 1e8 && ageMyr >= 0.0;
            bool absorbing = (kind == 2u && !knot) || kind == 6u;
            if (kind == 3u || absorbing) {
                out.position = float4(2.0, 2.0, 2.0, 1.0);
                out.pointSize = 0.0;
            }
            return out;
        }

        fragment float4 countFragment(CountOut in [[stage_in]]) {
            return float4(1.0, 0.0, 0.0, 0.0);
        }

        // The raw look: one fixed-size point per particle in its galaxy's tint, none of the
        // per-particle state the full splat reads. Dark matter is pushed out of the clip volume.
        struct PlainOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
        };

        vertex PlainOut plainVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const uint *galaxy [[buffer(5)]],
                                    constant DiskFrame *frames [[buffer(6)]]) {
            PlainOut out;
            out.position = u.viewProjection * float4(positions[vid], 1.0);
            out.pointSize = u.minimumSize;
            out.color = half3(frames[galaxy[vid]].tint.xyz * u.brightness);
            if (component[vid] == 3u || component[vid] == 6u) { out.position = float4(2.0, 2.0, 2.0, 1.0); }
            return out;
        }

        fragment half4 plainFragment(PlainOut in [[stage_in]]) {
            return half4(in.color, 1.0h);
        }

        fragment LightTarget starfieldFragment(SplatOut in [[stage_in]],
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

            LightTarget out;
            out.light = half4(in.color * half(falloff), half(falloff));
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
            float3 averaged = emitted / float(factor * factor);
            // Nothing is extinguished here any more. Each star was dimmed by the dust actually
            // in front of it while it was drawn, in the slab pass, so all that is left to do
            // is the box average. What used to happen instead was that the whole dust column
            // of a pixel — in front of the stars and behind them alike — was halved and
            // applied to the total, which cannot make a lane pass in front of anything and
            // only ever pulled the whole galaxy down towards brown.
            dst.write(float4(averaged, 1.0), gid);
        }

        // Box average of the accumulation and an exponential exposure curve, which keeps a
        // dense core in its galaxy's hue instead of clipping it to white.
        kernel void plainComposite(texture2d<float, access::read> light [[texture(0)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   constant uint &factor [[buffer(0)]],
                                   constant float &fade [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            float3 sum = float3(0.0);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    sum += light.read(gid * factor + uint2(x, y)).rgb;
                }
            }
            float3 energy = sum / float(factor * factor);
            output.write(float4(pow(1.0 - exp(-energy), 1.0 / 2.2) * fade, 1.0), gid);
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

        // The light of a source with its surroundings taken off, so a star keeps nearly all of
        // its own and an extended core almost none: what throws thin spikes rather than cones.
        kernel void compactLight(texture2d<float, access::sample> point [[texture(0)]],
                                 texture2d<float, access::sample> broad [[texture(1)]],
                                 texture2d<float, access::write> dst [[texture(2)]],
                                 constant float &amount [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float2 uv = (float2(gid) + 0.5) / float2(dst.get_width(), dst.get_height());
            float3 around = broad.sample(bilinear, uv).rgb;
            dst.write(float4(max(point.sample(bilinear, uv).rgb - amount * around, 0.0), 1.0), gid);
        }

        // Diffraction spikes. A telescope's secondary supports and, on a segmented mirror, the
        // segment edges throw light into a fixed set of directions; six arms for a hexagonal
        // mirror, four for a Cassegrain spider, and on Webb two short ones from the strut.
        // Gathering bright light back along those directions is most of what makes a rendered
        // field read as an exposure.
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
            uint shortSamples = max(8u, uint(float(p.samples) * p.shortScale));
            for (uint arm = 0; arm < p.shortArms; ++arm) {
                float angle = p.shortBaseAngle + float(arm) * 6.2831853 / float(p.shortArms);
                float2 step = float2(cos(angle), sin(angle)) / size;
                for (uint sample = 1; sample <= shortSamples; ++sample) {
                    float t = float(sample) / float(shortSamples);
                    total += src.sample(bilinear, uv + step * (t * p.length * p.shortScale)).rgb
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
            //
            // Flat, and it has to be. A few octaves of noise across the frame were tried here
            // to give the sky some structure, and they were offset by the *frame* seed — so
            // the whole field translated once a frame and the picture had clouds drifting
            // across it. That is not a sky, it is a screensaver, and even standing still the
            // patches read as cloud rather than as depth. What makes a background convincing
            // is the field stars and the shot noise, both of which are still there.
            energy += p.skyLevel * float3(p.skyRed, p.skyGreen, p.skyBlue);
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
