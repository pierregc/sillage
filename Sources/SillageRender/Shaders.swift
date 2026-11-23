/// Metal Shading Language source, compiled at runtime by `MTLDevice.makeLibrary(source:)`.
/// MSL is host-language agnostic: this string is the part of the renderer that would survive
/// a port to C++ or Rust unchanged.
enum Shaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // What is outside `#if defined(__METAL_VERSION__)` is shared with the CUDA engine, which
        // compiles it through cuda/include/msl_compat.h (docs/notes/one-kernel-source.md). #276
        // shared the particle passes and #277 the post-processing kernels: their work is the
        // functions ending in Pixel, and the kernels at the end only read and write textures.
        #if defined(__METAL_VERSION__)
        #define SHARED static
        #define SHARED_CONSTANT constant

        constexpr sampler bilinear(filter::linear, address::clamp_to_edge, coord::normalized);
        #endif

        // What a frame drawn from inside a galaxy reads on top (#297,
        // docs/notes/inside-a-galaxy.md). Metal compiles it, and every line it adds to the passes,
        // only into the library of a frame that asks for it, as it does a population's width:
        // every other frame draws from the text it always had.
        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        struct InsideUniforms {
            /// The camera at the end of the time this render stands for, a moment after the one
            /// the frame is drawn through: a point star is drawn as the streak it leaves from one
            /// to the other.
            float4x4 nextViewProjection;
            /// The view depths where the four slabs of dust start, and where the last ends.
            float4 slabKnots;
            float slabEnd;
            /// 0 keeps a grain in its slab and a star behind half of its own, as every frame
            /// does; 1 spreads a grain over a slab's depth and a star's dimming with it.
            float slabSoft;
            /// The camera's near distance, and the kernel lengths a particle fades over before it.
            float nearPlane;
            float fadeLengths;
            /// The near field, in view depth: all of it nearer than the first, none of it past
            /// the second.
            float windowNear;
            float windowFar;
            /// The kernel sizes, in accumulation pixels, between which a particle's light goes
            /// over to its point stars.
            float starStart;
            float starEnd;
            /// Kernel lengths the stars are scattered over, and their size in accumulation pixels.
            float starSpread;
            float starPointSize;
            /// A star's share of its particle's light: its rank to minus this, times the norm.
            float starShareExponent;
            float starShareNorm;
            /// How far the stars' colours are drawn around their population's, 0 for its own.
            float starColours;
            /// The depth under which a star stops brightening, and the most light one lays.
            float starNearest;
            float starCap;
            uint starCount;
            /// The projection's scales across and up.
            float projectionX;
            float projectionY;
            /// The most stars a particle draws, and the kernel's size past which it draws more
            /// than `starCount` (#357).
            float nearStars;
            float nearFrom;
            /// The Pareto index a star's share is drawn with around its rank's, 0 for none.
            float starTail;
            /// The near dust's structure finer than a grain (#356): its contrast, 0 for none, and
            /// its coarsest cell in kiloparsecs; and the share of a disk's dust opacity taken away
            /// while the eye is in it, 0 for none.
            float dustFine;
            float dustCell;
            float dustThin;
            /// The one galaxy whose dust the web's carrier takes in this pass, plus one; 0 for
            /// every galaxy's, as every frame carries it (#399).
            float webOnly;
            /// The clusters a young particle's stars gather in, 0 for none, their radius at birth
            /// in kiloparsecs and its growth a megayear, and the share of stars in them (#405).
            float clusterCentres;
            float clusterBirth;
            float clusterGrowth;
            float clusterShare;
            /// How many times wider a near grain's glow is drawn once the stars of its size have
            /// taken all the light, its light kept, and the share of the glow taken away there:
            /// a haze where the grains would show as blobs (1 and 0 for none).
            float glowHaze;
            float glowFade;
            /// The particles of its kind a kernel that shows alone is widened to cover in
            /// projection, 0 for none (docs/notes/lone-kernels.md); the kernel sizes, in pixels,
            /// between which a star's widens, and the widest such a kernel is drawn.
            float neighbours;
            float loneStart;
            float loneEnd;
            float loneWidest;
            /// The share of the stars that show alone kept as points, 0 for none.
            float lonePoints;
        };
        #endif

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
            /// Each population's kernel against the tree's (#339): the old disk, the bulge, the
            /// stars under 300 Myr and the knots gas formed under 50 Myr.
            float oldWidth;
            float bulgeWidth;
            float youngWidth;
            float knotWidth;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            InsideUniforms inside;
            #endif
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
        SHARED float3 rampColour(constant GalaxyRamp &ramp, float radius, uint kind, float born) {
            if (ramp.params.y > 0.5f) {
                if (kind == 1u || kind == 2u || (born >= 0.0f && born < 1e8f)) { return ramp.young.rgb; }
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

        // What a splat hands from its particle to its pixels: where its point lands and how wide,
        // then what every pixel of it reads.
        struct Splat {
            float4 position;
            float pointSize;
            half3 color;
            half opticalDepth;
            half spikes;
            /// Which of the four depth slabs this point belongs to, and for a star, which of
            /// them lie in front of it. One varying serves both: a grain of dust writes its
            /// opacity into its own slab, and a star reads the slabs ahead of its own.
            half4 slab;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            /// A near grain's place in the fine dust's noise and how much of it it takes, then the
            /// noise's steps across its point and through its depth, a kernel radius each, with
            /// a pixel's width in the noise, the log contrast and its mean (#356).
            float4 grain;
            float4 grainX;
            float4 grainY;
            float4 grainZ;
            #endif
        };

        #if defined(__METAL_VERSION__)
        struct SplatOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
            half opticalDepth;
            half spikes;
            half4 slab;
            #if defined(SILLAGE_INSIDE)
            float4 grain;
            float4 grainX;
            float4 grainY;
            float4 grainZ;
            #endif
        };

        static SplatOut splatOut(Splat point) {
            SplatOut out;
            out.position = point.position;
            out.pointSize = point.pointSize;
            out.color = point.color;
            out.opticalDepth = point.opticalDepth;
            out.spikes = point.spikes;
            out.slab = point.slab;
            #if defined(SILLAGE_INSIDE)
            out.grain = point.grain;
            out.grainX = point.grainX;
            out.grainY = point.grainY;
            out.grainZ = point.grainZ;
            #endif
            return out;
        }

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
        #endif

        /// Extinction is steeper in the blue than in the red, which is why a lane crossing a
        /// bright disk reads brown rather than grey.
        SHARED_CONSTANT float3 reddening = float3(1.0f, 1.22f, 1.52f);

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
        SHARED float hash1(float i) {
            int k = int(i);
            uint n = uint(k * 374761393 + 668265263);
            n = (n ^ (n >> 13u)) * 1274126177u;
            n = n ^ (n >> 16u);
            return float(n) * (1.0f / 4294967296.0f);
        }

        SHARED float valueNoise(float x) {
            float i = floor(x);
            float f = x - i;
            float u = f * f * (3.0f - 2.0f * f);
            return mix(hash1(i), hash1(i + 1.0f), u);
        }

        SHARED float fractalNoise(float x) {
            return valueNoise(x) * 0.65f + valueNoise(x * 2.3f + 19.1f) * 0.35f;
        }

        // Strips the luminance out of a colour, leaving only its hue and saturation. Every
        // emitter in this renderer carries unit luminance, so `brightness` stays the single
        // control over exposure and changing a colour can never change how bright a frame is.
        SHARED float3 chromaticity(float3 rgb) {
            return max(rgb, 0.0f) / max(dot(max(rgb, 0.0f), float3(0.2126f, 0.7152f, 0.0722f)), 1e-4f);
        }

        // Linear sRGB of a Planckian radiator. Chromaticity from Kang et al. (2002), then
        // CIE xy to sRGB primaries. Y is fixed at 1, so the conversion lands on unit
        // luminance before the negative lobe of a saturated hue is clipped away.
        SHARED float3 blackbody(float kelvin) {
            float t = clamp(kelvin, 2222.0f, 25000.0f);
            float inv = 1.0f / t;
            float x = t < 4000.0f
                ? ((-0.2661239e9f * inv - 0.2343589e6f) * inv + 0.8776956e3f) * inv + 0.179910f
                : ((-3.0258469e9f * inv + 2.1070379e6f) * inv + 0.2226347e3f) * inv + 0.240390f;
            float y = t < 4000.0f
                ? ((-0.9549476f * x - 1.37418593f) * x + 2.09137015f) * x - 0.16748867f
                : ((3.0817580f * x - 5.87338670f) * x + 3.75112997f) * x - 0.37001483f;
            float scale = 1.0f / max(y, 1e-4f);
            float3 xyz = float3(x * scale, 1.0f, (1.0f - x - y) * scale);
            return chromaticity(float3(
                dot(xyz, float3(3.2406f, -1.5372f, -0.4986f)),
                dot(xyz, float3(-0.9689f, 1.8758f, 0.0415f)),
                dot(xyz, float3(0.0557f, -0.2040f, 1.0570f))));
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
        SHARED float2 synthesised(device const float2 *table, constant SplatUniforms &u,
                                  float ageMyr) {
            float f = log(max(ageMyr, u.populationYoungMyr) / u.populationYoungMyr)
                / u.populationSpan;
            float at = saturate(f) * u.populationLast;
            uint index = uint(min(at, u.populationLast - 1.0f));
            return mix(table[index], table[index + 1u], at - float(index));
        }

        // The legacy path: a take written before every particle carried an age has only the
        // sampler's old zero-to-one population value, so it keeps the ramp that value meant.
        SHARED float3 legacyColour(float age) {
            return blackbody(exp(mix(log(4100.0f), log(13000.0f), saturate(age))));
        }

        // A star-forming knot is not a blackbody: most of its light leaves in Halpha at
        // 656 nm, on the continuum of the hot stars ionising it, which is why the knots read
        // pink rather than blue. This is the colour such a region shows through broadband
        // filters, stated directly; deriving it from line ratios needs an emission model and
        // the CIE colour matching functions.
        SHARED float3 hiiColour() {
            // Halpha at 656 nm carries the region, and the rest of what a broadband camera
            // sees of one is Hbeta and [OIII] at 486 and 500 — comparable to each other and
            // both well under the red. So the blue sits *below* the green, where it used to
            // sit above: a blue above the green is magenta, and magenta is neither what an
            // HII region looks like through a telescope nor a colour a blackbody can make, so
            // it read as the one thing in the frame that was not a star.
            return chromaticity(float3(1.00f, 0.34f, 0.30f));
        }

        // Where a particle sits relative to the spiral density wave, 0 between the arms and
        // 1 on a ridge, evaluated at the current position so the arms do not wind up. The
        // ideal logarithmic spiral is then made to wander and to break into segments: no
        // real galaxy has two unbroken arms of constant pitch.
        // Mirrored from `SpiralPattern.ridge` in SillageCore, which the sampler uses to lay
        // the particles down. The two have to stay the same expression: this is what makes the
        // light and the matter agree about where the arms are, and it is what lets a lopsided
        // galaxy be lopsided in its mass rather than only in its paint.
        SHARED float spiralRidge(float extent, float phi, float arms, float windRate,
                                 float irregular, float seed, float phase) {
            float wander = (fractalNoise(extent * 1.5f + seed) - 0.5f) * 2.6f * irregular;
            float wound = phi - windRate * log(max(extent, 1e-3f)) - phase + wander;

            float armPhase = arms * wound;
            float ridge = 0.5f + 0.5f * cos(armPhase);

            float breaks = (0.18f + 1.05f * fractalNoise(wound * 0.62f + extent * 0.9f + seed * 3.1f))
                         / 0.705f;
            ridge *= 1.0f + irregular * (breaks - 1.0f);

            float perArm = (0.35f + 1.25f * fractalNoise(armPhase * 0.159f + seed * 7.7f)) / 0.975f;
            ridge *= 1.0f + irregular * (perArm - 1.0f);

            float spurPhase = (arms + 3.0f) * (phi - 1.7f * windRate * log(max(extent, 1e-3f)))
                            + 2.1f;
            float spur = max(cos(spurPhase), 0.0f);
            float spurWhere = fractalNoise(extent * 0.9f + seed * 2.3f + 31.0f);
            ridge += irregular * 0.55f * spur * spur * spur
                   * smoothstep(0.55f, 0.85f, spurWhere);

            float lopsided = 1.0f + irregular * 0.30f * cos(phi + seed * 2.1f);
            return clamp(ridge * lopsided, 0.0f, 1.0f);
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
        SHARED float laneDetail(float3 position, DiskFrame frame) {
            float3 rel = position - frame.center.xyz;
            float u = dot(rel, frame.axisU.xyz);
            float v = dot(rel, frame.axisV.xyz);
            float radius = sqrt(u * u + v * v);
            float scale = max(frame.center.w, 1e-3f);
            float extent = radius / scale;
            float wound = atan2(v, u)
                        - frame.pattern.x * log(max(radius, 1e-3f) / scale)
                        - frame.pattern.y;
            // The angle is warped before the strands are read off it, which is what makes
            // them snake. Sampled straight, the noise lays down threads that all run along the
            // arm at the same pitch — clean, parallel, and obviously drawn. Displacing the
            // coordinate first bends every strand by a different amount at every radius, and
            // the result reads as torn membrane rather than as combed hair.
            float warp = fractalNoise(wound * 2.1f + extent * 3.7f + frame.pattern.w * 1.9f) - 0.5f;
            float twist = fractalNoise(wound * 5.9f - extent * 1.3f + frame.pattern.w * 4.1f) - 0.5f;
            float bent = wound + 0.88f * warp + 0.30f * twist;

            // High along the arm and higher still across it, which is what makes a strand a
            // strand rather than a patch.
            float fine = fractalNoise(bent * 7.3f + extent * 2.1f + frame.pattern.w * 5.3f);
            float finer = fractalNoise(bent * 19.0f - extent * 5.7f + frame.pattern.w * 2.9f);
            return 0.18f + 1.5f * fine * (0.45f + 0.9f * finer);
        }

        // Where a particle sits relative to the spiral pattern, evaluated at its current
        // position so the arms do not wind up with the disk.
        SHARED float2 armWave(float3 position, DiskFrame frame) {
            float strength = frame.axisV.w;
            if (strength <= 0.0f) { return float2(0.5f, 0.0f); }
            float3 rel = position - frame.center.xyz;
            float u = dot(rel, frame.axisU.xyz);
            float v = dot(rel, frame.axisV.xyz);
            float radius = sqrt(u * u + v * v);
            float scale = max(frame.center.w, 1e-3f);
            float extent = radius / scale;
            float envelope = smoothstep(0.55f, 1.5f, extent)
                           * (1.0f - smoothstep(4.0f, 6.5f, extent));

            float ridge = spiralRidge(extent, atan2(v, u), frame.axisU.w, frame.pattern.x,
                                      frame.pattern.z, frame.pattern.w, frame.pattern.y);
            return float2(mix(0.5f, ridge, strength * envelope), envelope * (1.0f - frame.tint.w));
        }

        // What the vertex stages read of a drawn particle: a massive one's from its buffers, a
        // light tracer's from the 32 bytes it carries and the massive tree around it (#238).
        struct Drawn {
            float3 position;
            uint kind;
            uint galaxy;
            float weight;
            float kernelScale;
            float born;
            float spacing;
            float warming;
            float population;
            float rampKey;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            /// A point star's share of its particle's light, 0 for the particle itself, and
            /// what its colour is drawn from.
            float starShare;
            float starHash;
            /// Which particle it is, the same one at every moment of a take: what a near grain
            /// of dust draws its own structure from (#394).
            uint id;
            #endif
        };

        SHARED Drawn massiveDrawn(uint vid, device const float3 *positions,
                                  device const float *formation, device const float *luminosity,
                                  device const uint *component, device const uint *galaxy,
                                  device const float *smoothing, device const float2 *traits) {
            Drawn p;
            p.position = positions[vid];
            p.kind = component[vid];
            p.galaxy = galaxy[vid];
            p.weight = luminosity[vid];
            p.kernelScale = traits[vid].y;
            p.born = formation[vid];
            p.spacing = smoothing[vid];
            p.warming = 1.0f;
            p.population = 0.5f;
            p.rampKey = 1.7f;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            p.starShare = 0.0f;
            p.starHash = 0.0f;
            p.id = vid;
            #endif
            return p;
        }

        SHARED_CONSTANT float tracerKernels[5] = {1.0f, 0.75f, 0.9f, 2.2f, 1.35f};

        // A light tracer's word decoded as `TracerWord` packs it; its spacing is left to the
        // caller, which reads it off the tree only for what it draws.
        SHARED Drawn tracerDrawn(float4 state, uint word, constant float *scales) {
            Drawn p;
            p.position = state.xyz;
            p.born = state.w;
            p.galaxy = word & 15u;
            p.kind = (word >> 4) & 7u;
            uint kernelClass = (word >> 7) & 7u;
            p.kernelScale = kernelClass < 5u ? tracerKernels[kernelClass] : 1.0f;
            uint light = (word >> 10) & 255u;
            p.weight = light == 0u ? 0.0f : exp2(float(light - 1u) * 20.0f / 254.0f - 12.0f);
            uint code = word >> 18;
            float radius = code == 0u ? 0.0f : exp2(float(code - 1u) * 24.0f / 16382.0f - 12.0f);
            float scale = scales[p.galaxy];
            float iron = 0.25f - 0.22f * clamp(radius / max(scale, 1e-6f), 0.0f, 5.0f);
            p.warming = scale > 0.0f ? exp(-0.25f * clamp(iron, -1.5f, 0.6f)) : 1.0f;
            p.rampKey = scale > 0.0f ? radius / scale : 1.7f;
            p.population = 0.5f;
            p.spacing = 0.0f;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            p.starShare = 0.0f;
            p.starHash = 0.0f;
            p.id = 0u;
            #endif
            return p;
        }

        // The spacing a tracer's kernel spans: that of the deepest cell of the massive tree
        // around it holding anything drawn, one read a level (`gtSpacingLeaves`).
        SHARED float tracerSpacing(float3 position, device const uint2 *cells,
                                   device const float *frame, uint depth) {
            float length = as_type<float>(cells[0].x);
            if (depth == 0u) { return length; }
            const float resolution = 2097151.0f;
            float3 local = (position - float3(frame[0], frame[1], frame[2])) * frame[3];
            if (any(local < 0.0f) || any(local > resolution)) { return length; }
            uint3 q = uint3(local);
            uint node = 0u;
            for (uint level = 0u; level < depth; ++level) {
                uint links = cells[node].y;
                uint mask = links & 255u;
                uint shift = 20u - level;
                uint digit = (((q.x >> shift) & 1u) << 2) | (((q.y >> shift) & 1u) << 1)
                           | ((q.z >> shift) & 1u);
                if ((mask & (1u << digit)) == 0u) { break; }
                node = (links >> 8) + popcount(mask & ((1u << digit) - 1u));
                float here = as_type<float>(cells[node].x);
                if (here > 0.0f) { length = here; }
            }
            return length;
        }

        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        // A splat that carries no fine dust: every splat but a near grain's.
        SHARED void insideBare(thread Splat &out) {
            out.grain = float4(0.0f);
            out.grainX = float4(0.0f);
            out.grainY = float4(0.0f);
            out.grainZ = float4(0.0f);
        }
        #endif

        SHARED Splat culledSplat() {
            Splat out;
            out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
            out.pointSize = 0.0f;
            out.color = half3(half(0.0f));
            out.opticalDepth = half(0.0f);
            out.spikes = half(0.0f);
            out.slab = half4(half(0.0f));
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            insideBare(out);
            #endif
            return out;
        }

        // How much wider than its kernel a population is drawn (#339). A young population has up
        // to fifty times the light per mass of an old one, so at the old stars' width its few
        // per cent read as sand. Ages blend over a factor of two either side, so that a star
        // the run formed narrows over many frames as it ages. Metal compiles it only into the
        // library of a look that asks for it: with fast math, code that never runs still moves
        // the roundings of a frame drawn without it.
        #if defined(SILLAGE_POPULATION_WIDTHS) || !defined(__METAL_VERSION__)
        SHARED float populationWidth(uint kind, bool nursery, bool knot, float ageMyr,
                                     constant SplatUniforms &u) {
            if (kind == 4u) { return u.bulgeWidth; }
            if (!knot) { return u.oldWidth; }
            float age = max(ageMyr, 1.0f);
            float old = smoothstep(-1.0f, 1.0f, log2(age / 300.0f));
            float width = u.youngWidth + (u.oldWidth - u.youngWidth) * old;
            if (!nursery) { return width; }
            float grown = smoothstep(-1.0f, 1.0f, log2(age / 50.0f));
            return u.knotWidth + (width - u.knotWidth) * grown;
        }
        #endif

        // Whether this pass leaves the particle out, as `splat` decides it.
        SHARED bool splatSkips(uint kind, float born, constant SplatUniforms &u) {
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0f)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8f && born < 1e8f && ageMyr >= 0.0f;
            bool hole = kind == 6u;
            bool absorbing = (kind == 2u && !knot) || hole;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            return kind == 3u || (hole && u.holeShadow <= 0.0f) || absorbing != (u.pass != 1u);
            #else
            return kind == 3u || (hole && u.holeShadow <= 0.0f) || absorbing != (u.pass == 0u);
            #endif
        }

        // The column density as each engine holds it, and the count around a point of the frame:
        // Metal samples its texture, the CUDA engine reads its cells with the same filter.
        #if defined(__METAL_VERSION__)
        typedef texture2d<float, access::sample> ColumnDensity;
        static float columnRead(ColumnDensity column, float2 uv) {
            return column.sample(bilinear, uv).r;
        }
        #else
        typedef texels2d ColumnDensity;
        SHARED float columnRead(ColumnDensity column, float2 uv) {
            return sample_bilinear(column, uv).x;
        }
        #endif

        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        // The column of a frame that widens its lone kernels (docs/notes/lone-kernels.md), at a
        // level of its pyramid: the particles that emit in x, the grains of dust in y, each
        // level's cell the mean of the four under it.
        #if defined(__METAL_VERSION__)
        constexpr sampler columnPyramid(filter::linear, mip_filter::nearest, address::clamp_to_edge,
                                        coord::normalized);
        static float2 columnKinds(ColumnDensity column, float2 uv, uint mip) {
            return column.sample(columnPyramid, uv, level(float(mip))).rg;
        }
        #else
        SHARED float2 columnKinds(ColumnDensity column, float2 uv, uint mip) {
            float4 kinds = sample_linear_level(column, uv, min(mip, column.levels - 1u), false);
            return float2(kinds.x, kinds.y);
        }
        #endif

        // The levels read: the last one's cell is 256 accumulation pixels across.
        SHARED_CONSTANT uint columnLevels = 6u;

        // The particles of a kind over a point of the frame, to an accumulation pixel squared:
        // read from the finest level whose cell holds enough of them to say, six with the
        // particle itself. Where a kernel shows alone a cell of the first level holds less than
        // one, and its count is the particle's own.
        SHARED float insideColumn(ColumnDensity column, float2 uv, bool grain, float cell) {
            float density = 0.0f;
            float left = 1.0f;
            for (uint mip = 0u; mip < columnLevels; ++mip) {
                float2 kinds = columnKinds(column, uv, mip);
                float mean = grain ? kinds.y : kinds.x;
                float held = mean * float(1u << (2u * mip));
                float sure = mip + 1u == columnLevels ? 1.0f : saturate((held - 1.0f) / 5.0f);
                density += left * sure * mean;
                left *= 1.0f - sure;
            }
            return density / (cell * cell);
        }

        // A particle's own draw, 0 to 1, the same wherever the camera is.
        SHARED float loneDraw(uint id) {
            uint h = id * 747796405u + 2891336453u;
            h = ((h >> ((h >> 28u) + 4u)) ^ h) * 277803737u;
            h = h ^ (h >> 22u);
            return float(h) * (1.0f / 4294967296.0f);
        }

        // How wide a kernel `raw` across is drawn. The tree's spacing is a volume's: a sparse
        // stretch of a disk seen face on stacks nothing along a line of sight, and a kernel one
        // spacing wide, once it is wide enough on screen to be told from a point, shows as a
        // disk of its own. Such a kernel is widened until it covers `neighbours` particles of
        // its kind in projection, its light kept; a kernel's profile holds its light within
        // 2 pi sigma squared, sigma a sixth of its width. A star's from a size on screen, under
        // which it is a point and stays one; a grain's glow at any size, as what the dust
        // gives off is never a point.
        SHARED float insideMerged(float raw, float2 uv, bool grain, float bright, uint id,
                                  ColumnDensity column, constant SplatUniforms &u) {
            if (u.inside.neighbours <= 0.0f) { return raw; }
            float lone = grain ? 1.0f : smoothstep(u.inside.loneStart, u.inside.loneEnd, raw);
            if (lone <= 0.0f) { return raw; }
            float density = max(insideColumn(column, uv, grain, u.columnCell), 1e-12f);
            // A star `bright` times its neighbours stands that much higher over them at the
            // same width: it takes as many times more of them under it to stand no higher.
            float needed = u.inside.neighbours * max(bright, 1.0f);
            float wide = min(6.0f * sqrt(needed / (2.0f * M_PI_F * density)), u.inside.loneWidest);
            if (wide <= raw) { return raw; }
            // A share of the stars stay points instead, the bright ones first and the same ones
            // wherever the camera is: no wider than a point star however near, so that a field
            // keeps stars over its glow and none is ever a disk on the way from a point to a haze.
            if (!grain && u.inside.lonePoints > 0.0f
                && loneDraw(id) < u.inside.lonePoints * max(bright, 1.0f)) {
                float point = min(raw, u.inside.starPointSize);
                return raw + (point - raw) * lone * saturate(wide / raw - 1.0f);
            }
            return raw + (wide - raw) * lone;
        }

        // Where a view depth falls in the stack of four dust slabs, 0 to 4: straight between
        // the knots. Around the aim point they are evenly spaced, which is the stack every
        // frame has; from inside they are placed from the eye, a factor apart.
        SHARED float insideSlabAt(float depth, constant SplatUniforms &u) {
            // Far from any matter, the very expression every frame places its slabs with.
            if (u.inside.slabSoft <= 0.0f) {
                return clamp((depth - u.slabNear) * u.slabScale, 0.0f, 0.999f) * 4.0f;
            }
            float4 k = u.inside.slabKnots;
            if (depth <= k.x) { return 0.0f; }
            if (depth < k.y) { return (depth - k.x) / (k.y - k.x); }
            if (depth < k.z) { return 1.0f + (depth - k.y) / (k.z - k.y); }
            if (depth < k.w) { return 2.0f + (depth - k.z) / (k.w - k.z); }
            return min(3.0f + (depth - k.w) / (u.inside.slabEnd - k.w), 3.999f);
        }

        // The slabs a grain writes into. Soft, it is spread over a slab's depth, half either
        // side of where it stands, so nothing switches when a boundary passes through a lane.
        SHARED half4 insideDustSlabs(float x, constant InsideUniforms &i) {
            uint s = uint(x);
            float4 hard = float4(float(s == 0u), float(s == 1u), float(s == 2u), float(s == 3u));
            float a = x - 0.5f;
            float b = x + 0.5f;
            float4 soft = float4(saturate(1.0f - a), max(min(b, 2.0f) - max(a, 1.0f), 0.0f),
                                 max(min(b, 3.0f) - max(a, 2.0f), 0.0f), saturate(b - 3.0f));
            return half4(mix(hard, soft, i.slabSoft));
        }

        // The share of each slab a star stands behind. Soft, it is how far through the slab
        // the star is, where every frame takes half of the star's own slab.
        SHARED half4 insideStarSlabs(float x, constant InsideUniforms &i) {
            uint s = uint(x);
            float4 hard = float4(s > 0u ? 1.0f : 0.5f, s > 1u ? 1.0f : (s == 1u ? 0.5f : 0.0f),
                                 s > 2u ? 1.0f : (s == 2u ? 0.5f : 0.0f), s == 3u ? 0.5f : 0.0f);
            float4 soft = float4(saturate(x), saturate(x - 1.0f), saturate(x - 2.0f),
                                 saturate(x - 3.0f));
            return half4(mix(hard, soft, i.slabSoft));
        }

        // How much a particle belongs to the near field: all of it nearer than the window,
        // none of it past, so that a frame with nothing that near draws as it always did.
        SHARED float insideNear(float depth, constant InsideUniforms &i) {
            return 1.0f - smoothstep(i.windowNear, i.windowFar, depth);
        }

        // A kernel the ceiling caps keeps all its light on fewer pixels, and from inside that
        // is a flare: the nearer a particle, the brighter its blob. In the near field it keeps
        // the surface brightness of its own size instead, for a star and for a grain of dust,
        // whose optical depth is spread the same way.
        SHARED float insideSpread(float spread, float raw, float span, float depth,
                                  constant InsideUniforms &i) {
            if (raw <= span) { return spread; }
            return spread * mix(1.0f, (span * span) / (raw * raw), insideNear(depth, i));
        }

        // To nothing over the last kernel lengths before the near plane, so nothing pops there.
        SHARED float insideFade(float depth, float length, constant InsideUniforms &i) {
            if (i.fadeLengths <= 0.0f) { return 1.0f; }
            return saturate((depth - i.nearPlane) / (i.fadeLengths * max(length, 1e-6f)));
        }

        // The near dust (#356). A grain stands for a cloud 50 to 100 pc across, so from a few
        // hundred parsecs the grains are soft blobs: cotton. Within the near field each grain's
        // opacity is shaped by a noise in three dimensions, read where each pixel's ray passes
        // through the grain, so the filaments hold still while the camera moves. The noise is
        // the grain's own: a piece of the field it carries with it, turned as its galaxy's
        // frame (#394). Laid in the galaxy's frame instead, the field stood still while the
        // grains moved through it, 2 pc a frame of the Mice flight with time running, and every
        // cloud changed shape from one frame to the next. Ridged gradient noise: its creases
        // are sheets, and a sheet seen through is a filament. The density is the exponential of
        // it (below), not the noise itself.
        SHARED uint dustHash(int x, int y, int z) {
            uint v = (uint(x) * 1597334677u) ^ (uint(y) * 3812015801u) ^ (uint(z) * 2798796415u);
            v = v * 747796405u + 2891336453u;
            v = ((v >> ((v >> 28u) + 4u)) ^ v) * 277803737u;
            return (v >> 22u) ^ v;
        }

        SHARED float dustGradient(uint h, float x, float y, float z) {
            uint g = h & 15u;
            float a = g < 8u ? x : y;
            float b = g < 4u ? y : ((g == 12u || g == 14u) ? x : z);
            return ((g & 1u) == 0u ? a : -a) + ((g & 2u) == 0u ? b : -b);
        }

        SHARED float dustPerlin(float3 p) {
            float fx = floor(p.x);
            float fy = floor(p.y);
            float fz = floor(p.z);
            int ix = int(fx);
            int iy = int(fy);
            int iz = int(fz);
            float x = p.x - fx;
            float y = p.y - fy;
            float z = p.z - fz;
            float u = x * x * x * (x * (x * 6.0f - 15.0f) + 10.0f);
            float v = y * y * y * (y * (y * 6.0f - 15.0f) + 10.0f);
            float w = z * z * z * (z * (z * 6.0f - 15.0f) + 10.0f);
            float a = mix(dustGradient(dustHash(ix, iy, iz), x, y, z),
                          dustGradient(dustHash(ix + 1, iy, iz), x - 1.0f, y, z), u);
            float b = mix(dustGradient(dustHash(ix, iy + 1, iz), x, y - 1.0f, z),
                          dustGradient(dustHash(ix + 1, iy + 1, iz), x - 1.0f, y - 1.0f, z), u);
            float c = mix(dustGradient(dustHash(ix, iy, iz + 1), x, y, z - 1.0f),
                          dustGradient(dustHash(ix + 1, iy, iz + 1), x - 1.0f, y, z - 1.0f), u);
            float d = mix(dustGradient(dustHash(ix, iy + 1, iz + 1), x, y - 1.0f, z - 1.0f),
                          dustGradient(dustHash(ix + 1, iy + 1, iz + 1), x - 1.0f, y - 1.0f, z - 1.0f), u);
            return mix(mix(a, b, v), mix(c, d, v), w);
        }

        SHARED_CONSTANT int dustOctaves = 3;
        // A ridge's mean and spread over the noise.
        SHARED_CONSTANT float dustRidgeMean = 0.3023f;
        SHARED_CONSTANT float dustRidgeSpread = 0.2895f;
        // A cell is this many times wider along the disk's plane than across it: the filaments
        // of a disk's dust lie along it.
        SHARED_CONSTANT float dustStretch = 2.0f;

        // The mean of exp(s x) over the ridges' sum x at unit spread, fitted within half a per
        // cent for s up to 2.5, so that the structure moves no opacity.
        SHARED float dustLogMean(float s) {
            return exp(s * s * (0.53694f + s * (0.058776f - 0.024273f * s)));
        }

        // The ridges' sum at `p`, in cells of the coarsest octave, mean zero and spread one.
        // `pixel` is a pixel's width in the same cells: an octave whose walls, a tenth of its
        // cell, are under two pixels fades out rather than shimmer. `.y` is how much of the
        // coarsest octave is left.
        SHARED float2 dustFineAt(float3 p, float pixel) {
            float total = 0.0f;
            float norm = 0.0f;
            float amplitude = 1.0f;
            float size = 1.0f;
            float coarsest = 0.0f;
            for (int o = 0; o < dustOctaves; ++o) {
                float detail = smoothstep(0.6f, 2.0f, 0.1f * size / max(pixel, 1e-9f));
                if (o == 0) { coarsest = detail; }
                if (detail <= 0.0f) { break; }
                float r = saturate(1.0f - 1.4f * abs(dustPerlin(p)));
                float r2 = r * r;
                float weight = amplitude * detail;
                total += weight * (r2 * r2 * r - dustRidgeMean);
                norm += weight * weight;
                // The next octave turned, so that no lattice axis lines its creases up.
                p = float3(0.8f * p.y + 0.6f * p.z, -0.8f * p.x + 0.36f * p.y - 0.48f * p.z,
                           -0.6f * p.x - 0.48f * p.y + 0.64f * p.z) * 2.0f + float3(5.2f, 1.3f, 7.7f);
                size *= 0.5f;
                amplitude *= 0.5f;
            }
            return float2(norm > 0.0f ? total / (dustRidgeSpread * sqrt(norm)) : 0.0f, coarsest);
        }

        // The piece of the noise particle `id` carries: where its middle reads the field, in
        // cells, the same at every moment of a take.
        SHARED float3 dustAnchor(uint id) {
            int i = int(id & 0x7fffffffu);
            return float3(float(dustHash(i, 17, 59) & 65535u), float(dustHash(i, 31, 7) & 65535u),
                          float(dustHash(i, 5, 43) & 65535u)) * (1.0f / 256.0f);
        }

        // Where a near grain reads the noise, and the noise's steps across its point and
        // through it, a kernel radius each, and across a pixel. Past the near field it is left a
        // plain grain.
        SHARED void insideFineGrain(thread Splat &out, uint id, float depth, float perPixel,
                                    DiskFrame frame, constant SplatUniforms &u) {
            float strength = insideNear(depth, u.inside);
            float contrast = u.inside.dustFine;
            if (contrast <= 0.0f || strength <= 0.0f || out.pointSize <= 0.0f) { return; }
            // In the disk's axes, its normal last, in cells: wide along the plane, thin across it.
            float across = max(u.inside.dustCell, 1e-4f) / dustStretch;
            float3 axisU = frame.axisU.xyz / (across * dustStretch);
            float3 axisV = frame.axisV.xyz / (across * dustStretch);
            float3 normal = cross(frame.axisU.xyz, frame.axisV.xyz) / across;
            float4x4 m = u.viewProjection;
            float3 right = normalize(float3(m[0][0], m[1][0], m[2][0]));
            float3 up = normalize(float3(m[0][1], m[1][1], m[2][1]));
            float3 forward = cross(right, up);
            float radius = 0.5f * out.pointSize / max(perPixel, 1e-9f);
            float3 x = right * radius;
            float3 y = up * -radius;
            float3 z = forward * radius;
            out.grain = float4(dustAnchor(id), strength);
            out.grainX = float4(dot(x, axisU), dot(x, axisV), dot(x, normal), 1.0f / (max(perPixel, 1e-9f) * across));
            out.grainY = float4(dot(y, axisU), dot(y, axisV), dot(y, normal), contrast);
            out.grainZ = float4(dot(z, axisU), dot(z, axisV), dot(z, normal), dustLogMean(contrast));
        }

        // What a grain's opacity is multiplied by: the frame's thinning, only for a disk the eye is in
        // (within half a scale length of its plane, nothing past one), so that a galaxy seen
        // whole from inside another keeps its lanes. The eye is found from where the grain lands.
        SHARED float insideDustTrim(float4 clip, float3 position, DiskFrame frame, constant SplatUniforms &u) {
            if (u.inside.dustThin == 0.0f) { return 1.0f; }
            float4x4 m = u.viewProjection;
            float3 right = normalize(float3(m[0][0], m[1][0], m[2][0]));
            float3 up = normalize(float3(m[0][1], m[1][1], m[2][1]));
            float3 forward = normalize(float3(m[0][3], m[1][3], m[2][3]));
            float3 eye = position - right * (clip.x / u.inside.projectionX) - up * (clip.y / u.inside.projectionY)
                - forward * clip.w;
            float3 normal = cross(frame.axisU.xyz, frame.axisV.xyz);
            float3 rel = eye - frame.center.xyz;
            float height = dot(rel, normal);
            float h = max(frame.center.w, 1e-3f);
            float beyond = max(length(rel - normal * height) - 7.0f * h, 0.0f);
            float away = sqrt(height * height + beyond * beyond);
            return 1.0f - u.inside.dustThin * (1.0f - smoothstep(0.5f * h, h, away));
        }

        // A grain of the frame's own dust pass, once its point is laid: the trim, then the noise.
        SHARED void insideNearDust(thread Splat &out, float3 position, uint id, float perPixel,
                                   DiskFrame frame, constant SplatUniforms &u) {
            float trim = insideDustTrim(out.position, position, frame, u);
            if (trim != 1.0f) { out.opticalDepth = half(float(out.opticalDepth) * trim); }
            insideFineGrain(out, id, out.position.w, perPixel, frame, u);
        }

        // A near grain's dust on a pixel of its point: the noise read twice through the grain's
        // depth, a third of its radius either side of its middle, where a Gaussian's two-point
        // rule puts them.
        SHARED half4 insideDustPixel(half opticalDepth, half4 slab, float r2, float2 coord, float4 grain,
                                     float4 grainX, float4 grainY, float4 grainZ) {
            float2 c = (coord - 0.5f) * 2.0f;
            float3 at = grain.xyz + grainX.xyz * c.x + grainY.xyz * c.y;
            float3 along = grainZ.xyz * 0.3333f;
            float2 a = dustFineAt(at - along, grainX.w);
            float2 b = dustFineAt(at + along, grainX.w);
            float fine = 0.5f * (exp(grainY.w * a.x) + exp(grainY.w * b.x)) / grainZ.w;
            float shaped = 1.0f + grain.w * a.y * (fine - 1.0f);
            // A dense knot of a thick grain could pass what a half holds, and its infinity times
            // the slabs it is not in would be a NaN.
            return half4(float4(slab) * min(float(opticalDepth) * shaped * exp(-4.5f * r2), 6.0e4f));
        }

        // A near grain's glow, drawn wider and fainter as the stars of its size take their
        // particles' light: there are a sixth as many grains as stars, and at the size where the
        // stars turn to points the grains stood out as blobs.
        SHARED void insideGlowHaze(thread Splat &out, float raw, constant InsideUniforms &i) {
            if (i.glowHaze <= 1.0f || i.starEnd <= 0.0f) { return; }
            float haze = smoothstep(i.starStart, i.starEnd, raw) * insideNear(out.position.w, i);
            float wide = clamp(mix(1.0f, i.glowHaze, haze), 1.0f, max(511.0f / max(out.pointSize, 1e-3f), 1.0f));
            out.pointSize *= wide;
            out.opticalDepth = half(float(out.opticalDepth) * (1.0f - i.glowFade * haze) / (wide * wide));
        }

        // How much of a particle's light its point stars carry, from its kernel's size on
        // screen where it stands: none while the kernel is small, all of it once the kernel is
        // large, and only in the near field. Keyed on the size alone, the wide kernels of a
        // disk's sparse edge seen from tens of kiloparsecs would turn to stars too.
        SHARED float insideStarred(float raw, float depth, constant InsideUniforms &i) {
            if (i.starCount == 0u || i.starEnd <= 0.0f) { return 0.0f; }
            return smoothstep(i.starStart, i.starEnd, raw) * insideNear(depth, i);
        }

        // The sum of the first `n` stars' shares before the norm, rank to minus `e` each, for any
        // `n`, whole or not: the integral, with the first three terms of Euler and Maclaurin's
        // correction. Within 1 % of the sum for an exponent up to 2.
        SHARED float insideShareSum(float n, float e) {
            if (n <= 1.0f) { return max(n, 0.0f); }
            float integral = abs(e - 1.0f) < 1e-3f ? log(n) : (pow(n, 1.0f - e) - 1.0f) / (1.0f - e);
            return integral + 0.5f * (1.0f + pow(n, -e)) + e / 12.0f * (1.0f - pow(n, -e - 1.0f))
                - e * (e + 1.0f) * (e + 2.0f) / 720.0f * (1.0f - pow(n, -e - 3.0f));
        }

        // How many stars a particle stands for at its kernel's size on screen (#357): as many as
        // the settings give, and past `nearFrom` more as the square of the size, as a real
        // field shows more of its faint stars the nearer they are, up to `nearStars`.
        SHARED float insideStarTotal(float raw, constant InsideUniforms &i) {
            float grown = i.nearFrom > 0.0f && raw > i.nearFrom ? (raw * raw) / (i.nearFrom * i.nearFrom) : 1.0f;
            return min(float(i.starCount) * grown, max(i.nearStars, float(i.starCount)));
        }

        // One over the sum of the shares of `total` stars, so that they add up to the light.
        SHARED float insideShareNorm(float total, constant InsideUniforms &i) {
            return total <= float(i.starCount) ? i.starShareNorm
                : 1.0f / insideShareSum(total, i.starShareExponent);
        }

        // How many of its stars a particle draws: all of them once its light is wholly theirs,
        // the brightest first on the way there. The faint ones of a particle that has only
        // started to turn would cost as much to draw as the bright ones and show nothing.
        SHARED float insideStarsDrawn(float starred, float total) {
            return total * starred;
        }

        // The share of a particle's light its drawn stars carry, which its splat gives up.
        SHARED float insideStarLight(float starred, float raw, constant InsideUniforms &i) {
            // The CUDA engine reads this on every frame, most of them with no near field at all.
            if (starred <= 0.0f) { return 0.0f; }
            float total = insideStarTotal(raw, i);
            return starred * insideShareSum(insideStarsDrawn(starred, total), i.starShareExponent)
                * insideShareNorm(total, i);
        }

        SHARED uint2 insideHashBits(uint2 v) {
            v = v * 1664525u + 1013904223u;
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            return v;
        }

        SHARED float2 insideHash(uint2 v) {
            return float2(insideHashBits(v)) * (1.0f / 4294967296.0f);
        }

        // Where star `rank` of a particle stands against it, in kernel lengths (#357): the
        // ranks walk Roberts' three dimensional golden sequence from a place of the particle's
        // own, so that a particle's stars, and its brightest few first, fill its kernel evenly
        // rather than in random clumps; and they thin out as a Plummer sphere does, half of them
        // within 0.8 kernel lengths and the last tenth out to 2.2, so that one particle's stars
        // merge into its neighbours' instead of reading as a ball.
        SHARED float3 insideScatter(uint index, uint rank) {
            uint2 start = insideHashBits(uint2(index, 0x51ed270bu));
            uint3 at = uint3(start.x, start.y, start.x ^ start.y)
                + rank * uint3(0xd1b54a33u, 0xabc98389u, 0x8cb92ba7u);
            float3 u = float3(at) * (1.0f / 4294967296.0f);
            float z = 2.0f * u.x - 1.0f;
            float phi = 6.2831853f * u.y;
            float ring = sqrt(max(1.0f - z * z, 0.0f));
            float c = pow(max(0.9f * u.z, 1e-9f), 1.0f / 3.0f);
            float radius = 0.6f * c / sqrt(1.0f - c * c);
            return float3(ring * cos(phi), ring * sin(phi), z) * radius;
        }

        // Where star `rank` of a particle stands, in lengths of its stars' spread, its young
        // gathered (#405): stars are born in clusters and associations that come apart over tens
        // of megayears (Lada and Lada 2003, Grasha et al. 2017). A star of a young particle
        // stands, at `share`, in one of a few clusters of the particle's own, laid in its kernel
        // as its stars are, the cluster's own stars thinned out as a Plummer sphere `radius`
        // spreads wide. The radius grows with the age until it is the spread itself, where the
        // star stands where an old particle's would, to the bit: an old field is even.
        SHARED float3 insideClustered(uint index, uint rank, float ageMyr, bool aged, float spread,
                                      constant InsideUniforms &i) {
            float3 even = insideScatter(index, rank);
            if (!aged || i.clusterCentres < 1.0f) { return even; }
            float radius = (i.clusterBirth + i.clusterGrowth * ageMyr) / max(spread, 1e-9f);
            if (radius >= 1.0f) { return even; }
            float2 h = insideHash(uint2(index ^ 0x7f4a7c15u, rank * 2u + 1u));
            if (h.x >= i.clusterShare) { return even; }
            uint centres = uint(i.clusterCentres);
            uint centre = min(uint(h.y * i.clusterCentres), centres - 1u);
            float3 at = insideScatter(index ^ 0x2545f491u, centre);
            return at * (1.0f - radius) + even * radius;
        }

        // The size of an emitting particle's kernel on screen where `clip` puts it, in
        // accumulation pixels and before the floor and the ceiling, as `splat` works it out.
        SHARED float insideRaw(Drawn p, float4 clip, constant SplatUniforms &u,
                               ColumnDensity column) {
            float kernelScale = p.kernelScale < 0.8f ? mix(0.9f, p.kernelScale, u.glint) : p.kernelScale;
            float depth = max(clip.w, 1e-3f);
            float raw = max(p.spacing * u.smoothingScale * kernelScale, 1e-4f) * u.projectionScale / depth;
            if (u.columnSmoothing > 0.0f) {
                float2 uv = float2(0.5f, 0.5f) + float2(0.5f, -0.5f) * clip.xy / depth;
                float count = max(columnRead(column, uv), 0.25f);
                float density = count / (u.columnCell * u.columnCell);
                raw = max(raw, 2.0f * sqrt(u.columnSmoothing / (M_PI_F * density)));
            }
            bool nursery = p.kind == 1u || p.kind == 2u;
            float ageMyr = (nursery || p.born >= 0.0f)
                ? (u.time - p.born) * u.megayearsPerUnit : -p.born * u.megayearsPerUnit;
            bool knot = p.born > -1e8f && p.born < 1e8f && ageMyr >= 0.0f;
            return raw * populationWidth(p.kind, nursery, knot, ageMyr, u);
        }
        #endif

        SHARED Splat splat(Drawn p, constant SplatUniforms &u, constant DiskFrame *frames,
                           device const float2 *stellar, constant GalaxyRamp *ramps,
                           ColumnDensity column) {
            Splat out;
            float3 position = p.position;
            DiskFrame frame = frames[p.galaxy];
            out.position = u.viewProjection * float4(position, 1.0f);
            out.spikes = half(0.0f);
            out.slab = half4(half(0.0f));
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            insideBare(out);
            #endif
            uint kind = p.kind;
            float weight = p.weight;
            // The compact bright minority the sampler drew (DiskSampler, kernelScale 0.75):
            // two per cent of the stars carrying a quarter of the light as point sources. At
            // glint 0 they are given back the light and the width of an ordinary star.
            float kernelScale = p.kernelScale;
            if (kernelScale < 0.8f) {
                weight *= mix(0.07f, 1.0f, u.glint);
                kernelScale = mix(0.9f, kernelScale, u.glint);
            }

            // Age of this particle's stars, in megayears. Two sentinels sit outside any real
            // time: material sampled as already old reads as infinitely old, and gas that has
            // formed nothing yet reads as not yet born and is still drawn as dust.
            float born = p.born;
            // Only gas carries an age that has to advance. A sampled star stands for tens of
            // thousands of stars already in steady state, not for a coeval group, so its
            // colour has no business drifting over a run — and it was drifting hard: a whole
            // disk ageing in lockstep turned gold inside a gigayear while the four per cent
            // of particles the run forms could not repaint it. Frozen at the age it was drawn
            // with; gas, and anything the run itself formed, still ages.
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0f)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8f && born < 1e8f && ageMyr >= 0.0f;
            // A black hole emits nothing. Asked for, it absorbs like a knot of dust that lets
            // nothing through, so it is drawn with the dust and darkens what lies behind it.
            bool hole = kind == 6u;
            bool absorbing = (kind == 2u && !knot) || hole;

            // Dark matter carries mass but no light, and every particle is skipped by one of
            // the two draws. Pushing them outside the clip volume drops them before any
            // fragment work rather than drawing a black point over the galaxy.
            // From inside, pass 2 draws the dust's glow, from the dust.
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            bool dustDraw = u.pass != 1u;
            #else
            bool dustDraw = u.pass == 0u;
            #endif
            if (kind == 3u || (hole && u.holeShadow <= 0.0f) || absorbing != dustDraw) {
                out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
                out.pointSize = 0.0f;
                out.color = half3(half(0.0f));
                out.opticalDepth = half(0.0f);
                return out;
            }

            // Which slab of view depth this point falls in. `position.w` is the view depth for
            // a standard perspective projection, and the stack is centred on the camera's
            // target and as deep as the frame is wide, so a disk seen at an angle spans it.
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            float slabAt = insideSlabAt(out.position.w, u);
            #else
            float slabAt = clamp((out.position.w - u.slabNear) * u.slabScale, 0.0f, 0.999f) * 4.0f;
            #endif
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
                    slabIndex > 0u ? half(1.0f) : half(0.5f),
                    slabIndex > 1u ? half(1.0f) : (slabIndex == 1u ? half(0.5f) : half(0.0f)),
                    slabIndex > 2u ? half(1.0f) : (slabIndex == 2u ? half(0.5f) : half(0.0f)),
                    slabIndex == 3u ? half(0.5f) : half(0.0f));
            }
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            out.slab = u.pass == 0u ? insideDustSlabs(slabAt, u.inside) : insideStarSlabs(slabAt, u.inside);
            #endif
            float2 pattern = armWave(position, frame);
            float wave = pattern.x;

            // Angular size of this particle's kernel, in pixels. position.w is the view
            // depth for a standard perspective projection, so this is just h over distance.
            float depth = max(out.position.w, 1e-3f);
            float perPixel = u.projectionScale / depth;
            // Two scales of emission. Most particles are drawn wide, and because widening a
            // kernel conserves its flux that is the same light spread thinner: enough of them
            // overlapping make a continuum instead of a stipple. A small minority are compact
            // and much brighter, and those are the sources the eye picks out one at a time.
            float raw = max(p.spacing * u.smoothingScale * kernelScale, 1e-4f) * perPixel;
            // The spacing above is the three-dimensional one, read off the solver's tree. A
            // thin disk seen face-on stacks many of those spacings along a line of sight, so
            // a kernel sized to one of them still resolves the particles. Sized instead so
            // that it covers `columnSmoothing` stars in projection, from the count the
            // column pass drew into coarse cells, it is wide where the picture is sparse and
            // narrow where it is dense, and never narrower than the tree's own answer.
            if (!absorbing && u.columnSmoothing > 0.0f) {
                float2 uv = float2(0.5f, 0.5f) + float2(0.5f, -0.5f) * out.position.xy / depth;
                float count = max(columnRead(column, uv), 0.25f);
                float density = count / (u.columnCell * u.columnCell);
                float projected = 2.0f * sqrt(u.columnSmoothing / (M_PI_F * density));
                raw = max(raw, projected);
            }
            #if defined(SILLAGE_POPULATION_WIDTHS) || !defined(__METAL_VERSION__)
            if (!absorbing) { raw *= populationWidth(kind, nursery, knot, ageMyr, u); }
            #endif
            float span = clamp(raw, u.minimumSize, u.maximumSize);
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            // A lone kernel's width, for what emits and is not a point star. A grain's glow takes
            // it further down; its dust keeps the tree's, and so do the stars' cross-fade, the
            // fade at the near plane and the capped kernels' law.
            float merged = raw;
            if (!hole && p.starShare <= 0.0f && u.inside.neighbours > 0.0f) {
                float2 at = float2(0.5f, 0.5f) + float2(0.5f, -0.5f) * out.position.xy / depth;
                // Against an old star's light: the compact minority's and the young's.
                float bright = (absorbing || !knot) ? weight
                    : weight * synthesised(stellar, u, ageMyr).y * u.luminosityNormalisation;
                merged = insideMerged(raw, at, absorbing, bright, p.id, column, u);
            }
            if (!absorbing && merged > raw) { span = max(merged, span); }
            if (!absorbing && merged < raw) { span = clamp(merged, u.minimumSize, span); }
            #endif
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
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            // From inside (#297): no flare from a capped kernel, nothing left of a particle at
            // the near plane, and the light of a near particle handed to its point stars, which
            // are drawn through here too, each with its share.
            bool starDraw = p.starShare > 0.0f;
            float fade = insideFade(out.position.w, raw / perPixel, u.inside);
            float starred = (absorbing || starDraw) ? 0.0f : insideStarred(raw, out.position.w, u.inside);
            spread = insideSpread(spread, raw, span, out.position.w, u.inside);
            #endif

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
                float lane = 1.0f + 7.0f * pow(wave, 2.0f) * pattern.y * laneDetail(position, frame);
                out.pointSize = span * 1.3f;
                out.color = half3(half(0.0f));
                #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
                out.opticalDepth = half(weight * u.dustStrength * lane * spread * 1.3f * fade);
                if (fade <= 0.0f && !hole) { return culledSplat(); }
                #else
                out.opticalDepth = half(weight * u.dustStrength * lane * spread * 1.3f);
                #endif
                if (hole) {
                    // Twice the radius, since the kernel falls to a hundredth at its edge.
                    out.pointSize = max(4.0f * u.holeShadow * perPixel, 2.0f);
                    out.opticalDepth = half(8.0f);
                }
                #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
                else {
                    insideNearDust(out, position, p.id, perPixel, frame, u);
                    if (u.pass == 2u) {
                        insideGlowHaze(out, raw, u.inside);
                        // The wider of the haze and the lone kernel, not one over the other.
                        float wide = min(merged * 1.3f, 511.0f) / max(out.pointSize, 1e-3f);
                        if (merged > raw && wide > 1.0f) {
                            out.pointSize *= wide;
                            out.opticalDepth = half(float(out.opticalDepth) / (wide * wide));
                        }
                    }
                }
                #endif
            } else {
                // An arm is brighter than the disk around it, by about the factor of two a
                // grand-design spiral shows between arm and interarm. This is the only thing
                // the painted wave still does to starlight: it used to set colour as well,
                // and because `wave` is read at the particle's *current* position that made
                // every star swing between five and ten thousand kelvin twice an orbit. A
                // population does not redden and blue again as it turns. An arm is bluer
                // because of what it contains, and what it contains is fixed when the star
                // forms.
                float ambient = 0.55f + 0.95f * wave;
                // Colour and light per unit mass, both from the same synthesised population
                // at this particle's age. One table, one law: a knot three megayears old and
                // a bulge star of eleven gigayears are the same lookup at different ages.
                //
                // Normalised by the mean of the same curve over this scene's own ages, so
                // that changing the population model moves no exposure and none of the five
                // looks needs retuning.
                float2 synth = synthesised(stellar, u, ageMyr);
                float massToLight = knot ? synth.y * u.luminosityNormalisation : 1.0f;
                float gain = ambient * massToLight;
                // Composition as well as age. A metal-rich population is redder at the same age
                // because metal lines blanket its blue, and a disk is metal-rich in the middle
                // and metal-poor at the edge — which is the other half of why a galaxy has a
                // warm core and a cool disk, and the half that was missing. Age alone gives a
                // gradient of the right sign and far too weak to see.
                float3 stellarLight = knot
                    ? blackbody(synth.x * p.warming)
                    : legacyColour(p.population);
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
                float rise = 1.0f - exp(-ageMyr / max(u.ionisingRiseMyr, 1e-3f));
                float alive = (knot && nursery)
                    ? u.ionisedStrength * rise * exp(-ageMyr / max(u.ionisedMyr, 1e-3f)) : 0.0f;
                float3 emitted = mix(stellarLight, hiiColour(), alive);
                // A tint per galaxy is what keeps stars pulled into the other one legible.
                // It is a departure from the physical colour, so it is dialled rather than
                // applied: at 0 the two galaxies are coloured by their populations alone.
                emitted *= mix(float3(1.0f), chromaticity(frame.tint.rgb), u.galaxyTint);
                if (u.mapped != 0u) {
                    constant GalaxyRamp &ramp = ramps[p.galaxy];
                    if (ramp.params.z > 0.5f) {
                        float3 painted = rampColour(ramp, p.rampKey, kind, born);
                        emitted = mix(mix(stellarLight, painted, ramp.params.x), ramp.knot.rgb, alive);
                    }
                }
                out.pointSize = span * (alive > 0.15f ? 1.3f : 1.0f);
                #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
                float kept = fade * (1.0f - insideStarLight(starred, raw, u.inside));
                if (starDraw) {
                    // A point star: its share of the particle's light at its own distance, on a
                    // few pixels, its colour drawn around its population's (an old star about
                    // 4 800 K, a young one 9 000 K).
                    if (u.inside.starColours > 0.0f) {
                        bool young = knot || nursery || kind == 1u;
                        float mean = young ? 9000.0f : 4800.0f;
                        float drawn = mean * exp2((p.starHash - 0.5f) * 1.6f * u.inside.starColours);
                        emitted = chromaticity(emitted * blackbody(drawn) / blackbody(mean));
                    }
                    float near = u.projectionScale / max(out.position.w, u.inside.starNearest);
                    float size = u.inside.starPointSize;
                    float3 light = emitted * (u.brightness * weight * gain * u.referenceArea * near * near
                                              * p.starShare * fade / (size * size));
                    // Past the cap a star brightens ever less and stays a point (#357): the light
                    // the bloom would have spread into a disk is not laid.
                    float top = max(max(light.x, light.y), light.z);
                    light *= u.inside.starCap / (u.inside.starCap + top);
                    out.pointSize = size;
                    out.color = half3(light);
                } else if (kept <= 0.0f) {
                    // All of its light is its stars', or it stands at the near plane.
                    return culledSplat();
                } else {
                    float3 lit = emitted * (u.brightness * weight * gain * spread * kept);
                    // A star kept a point brightens ever less past the point stars' cap.
                    if (merged < raw) {
                        lit *= u.inside.starCap / (u.inside.starCap + max(max(lit.x, lit.y), lit.z));
                    }
                    #if defined(__METAL_VERSION__)
                    out.color = half3(min(lit, 6.0e4f));
                    #else
                    // CUDA compiles this branch into every frame: one with no near field keeps
                    // the light it always had.
                    out.color = half3(u.inside.windowFar > -1.0e37f ? min(lit, float3(6.0e4f)) : lit);
                    #endif
                }
                #else
                out.color = half3(emitted * (u.brightness * weight * gain * spread));
                #endif
                out.opticalDepth = half(0.0f);
            }
            return out;
        }

        // A massive particle's splat, from the renderer's buffers.
        SHARED Splat massiveSplat(uint vid, device const float3 *positions,
                                  device const float *population, device const float *formation,
                                  device const float *luminosity, device const uint *component,
                                  constant SplatUniforms &u, device const uint *galaxy,
                                  constant DiskFrame *frames, device const float *smoothing,
                                  device const float2 *stellar, device const float2 *traits,
                                  device const float *rampKeys, constant GalaxyRamp *ramps,
                                  ColumnDensity column) {
            Drawn p = massiveDrawn(vid, positions, formation, luminosity, component, galaxy,
                                   smoothing, traits);
            p.warming = traits[vid].x;
            p.population = population[vid];
            p.rampKey = rampKeys[vid];
            return splat(p, u, frames, stellar, ramps, column);
        }

        // A light tracer's (#238), from its state and its word; its spacing is read off the tree
        // only when this pass draws it.
        SHARED Splat tracerSplat(uint vid, float4 state, uint word, constant SplatUniforms &u,
                                 constant DiskFrame *frames, device const float2 *stellar,
                                 constant GalaxyRamp *ramps, device const uint2 *cells,
                                 device const float *treeFrame, uint depth, constant float *scales,
                                 ColumnDensity column) {
            Drawn p = tracerDrawn(state, word, scales);
            if (splatSkips(p.kind, p.born, u)) { return culledSplat(); }
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            p.id = vid;
            #endif
            p.spacing = tracerSpacing(p.position, cells, treeFrame, depth);
            return splat(p, u, frames, stellar, ramps, column);
        }

        struct BackgroundStar {
            float4 direction;
            float4 color;
        };

        // Foreground field stars, sitting far enough out that orbiting the galaxy does not
        // parallax them. The brightest ones carry diffraction spikes, which is most of what
        // makes an image read as a telescope exposure rather than a plot.
        SHARED Splat starfieldSplat(BackgroundStar star, constant SplatUniforms &u) {
            float magnitude = star.direction.w;
            Splat out;
            out.position = u.viewProjection * float4(star.direction.xyz, 1.0f);
            out.pointSize = u.starSize * mix(1.6f, 9.0f, magnitude * magnitude);
            out.color = half3(star.color.rgb * (magnitude * magnitude * magnitude * 2.4f));
            out.opticalDepth = half(0.0f);
            out.spikes = half(star.color.a);
            out.slab = half4(half(0.0f));
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            insideBare(out);
            #endif
            return out;
        }

        // How far a pixel stands from the centre of its point's square, squared, in kernel radii.
        // `coord` is its place in the square, as Metal's point_coord gives it. Past one, in the
        // corners of the square, the splat leaves the pixel alone.
        SHARED float splatRadius2(float2 coord) {
            float2 d = coord - 0.5f;
            return dot(d, d) * 4.0f;
        }

        // The dust a grain lays on a pixel of its splat, into its own slab, `r2` from the centre.
        SHARED half4 dustPixel(half opticalDepth, half4 slab, float r2) {
            return half4(opticalDepth * half(exp(-4.5f * r2)) * slab);
        }

        #if defined(__METAL_VERSION__)
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
            return splatOut(massiveSplat(vid, positions, population, formation, luminosity,
                                         component, u, galaxy, frames, smoothing, stellar, traits,
                                         rampKeys, ramps, column));
        }

        // A light tracer (#238): positions with their formation times from buffer 18, velocities
        // with their words from 19, the tree's spacing from 14 to 16, and each galaxy's scale
        // length from 17.
        vertex SplatOut splatTracerVertex(uint vid [[vertex_id]],
                                          constant SplatUniforms &u [[buffer(4)]],
                                          constant DiskFrame *frames [[buffer(6)]],
                                          device const float2 *stellar [[buffer(9)]],
                                          constant GalaxyRamp *ramps [[buffer(12)]],
                                          device const uint2 *cells [[buffer(14)]],
                                          device const float *treeFrame [[buffer(15)]],
                                          constant uint &depth [[buffer(16)]],
                                          constant float *scales [[buffer(17)]],
                                          device const float4 *states [[buffer(18)]],
                                          device const uint *words [[buffer(19)]],
                                          texture2d<float, access::sample> column [[texture(0)]]) {
            return splatOut(tracerSplat(vid, states[vid], words[vid * 4u + 3u], u, frames, stellar,
                                        ramps, cells, treeFrame, depth, scales, column));
        }

        #endif

        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        // A particle's kernel length, which its point stars are scattered over.
        SHARED float insideLength(float spacing, float kernelScale, constant SplatUniforms &u) {
            float scale = kernelScale < 0.8f ? mix(0.9f, kernelScale, u.glint) : kernelScale;
            return max(spacing * u.smoothingScale * scale, 1e-4f);
        }

        // Stars are drawn eight to a list entry: a particle takes an entry for every eight stars
        // it draws.
        SHARED_CONSTANT uint insideGroup = 8u;

        // How many entries a particle takes in the list of the stars to draw: none when it does
        // not emit, stands past the near field, has given its stars none of its light yet, or
        // when the sphere they are scattered in misses the view.
        SHARED uint insideGroups(uint index, device const float3 *positions,
                                 device const float *luminosity, device const uint *component,
                                 device const uint *galaxy, device const float *formation,
                                 device const float *smoothing, device const float2 *traits,
                                 constant SplatUniforms &u, ColumnDensity column) {
            if (splatSkips(component[index], formation[index], u)) { return 0u; }
            float4 clip = u.viewProjection * float4(positions[index], 1.0f);
            float reach = insideLength(smoothing[index], traits[index].y, u) * u.inside.starSpread;
            if (clip.w > u.inside.windowFar || clip.w < -reach) { return 0u; }
            float room = clip.w + reach;
            if (abs(clip.x) > room + reach * u.inside.projectionX
                || abs(clip.y) > room + reach * u.inside.projectionY) { return 0u; }
            Drawn p = massiveDrawn(index, positions, formation, luminosity, component, galaxy,
                                   smoothing, traits);
            float raw = insideRaw(p, clip, u, column);
            float starred = insideStarred(raw, clip.w, u.inside);
            if (starred <= 0.0f) { return 0u; }
            float drawn = insideStarsDrawn(starred, insideStarTotal(raw, u.inside));
            return (uint(ceil(drawn)) + insideGroup - 1u) / insideGroup;
        }

        // The stars to draw, listed in the order of their particles' indices so that two
        // drawings of a frame lay them in the same order (#297): each block of particles counts
        // its entries, one thread turns the counts into where each block's entries start and
        // writes the draw's arguments, and each block writes its entries there, a particle's
        // index and which eight of its stars. `span` is the particles, the particles a block
        // and the entries the list holds.
        SHARED void insideCounted(uint block, device const float3 *positions,
                                  device const float *luminosity, device const uint *component,
                                  constant SplatUniforms &u, device const uint *galaxy,
                                  device const float *smoothing, device const float *formation,
                                  device const float2 *traits, device uint *counts, uint3 span,
                                  ColumnDensity column) {
            uint from = block * span.y;
            if (from >= span.x) { return; }
            uint to = min(from + span.y, span.x);
            uint count = 0u;
            for (uint index = from; index < to; ++index) {
                count += insideGroups(index, positions, luminosity, component, galaxy, formation,
                                      smoothing, traits, u, column);
            }
            counts[block] = count;
        }

        SHARED void insideOffset(device uint *counts, uint3 span, device uint *draw) {
            uint blocks = (span.x + span.y - 1u) / span.y;
            uint total = 0u;
            for (uint block = 0u; block < blocks; ++block) {
                uint count = counts[block];
                counts[block] = total;
                total += count;
            }
            // MTLDrawPrimitivesIndirectArguments: vertices, instances, first vertex and instance.
            draw[0] = min(total, span.z);
            draw[1] = insideGroup;
            draw[2] = 0u;
            draw[3] = 0u;
        }

        SHARED void insideFilled(uint block, device const float3 *positions,
                                 device const float *luminosity, device const uint *component,
                                 constant SplatUniforms &u, device const uint *galaxy,
                                 device const float *smoothing, device const float *formation,
                                 device const float2 *traits, device const uint *offsets,
                                 uint3 span, device uint2 *list, ColumnDensity column) {
            uint from = block * span.y;
            if (from >= span.x) { return; }
            uint to = min(from + span.y, span.x);
            uint at = offsets[block];
            for (uint index = from; index < to; ++index) {
                uint groups = insideGroups(index, positions, luminosity, component, galaxy,
                                           formation, smoothing, traits, u, column);
                for (uint group = 0u; group < groups && at < span.z; ++group) {
                    list[at] = uint2(index, group);
                    at += 1u;
                }
            }
        }

        // Star `iid` of the eight a list entry stands for (#297): the light a near particle's
        // splat gives up goes to a few bright stars over a crowd of faint ones, scattered in its
        // kernel from a hash of its index and the star's rank, so the same particle always has
        // the same stars, wherever the camera is.
        struct Star {
            float4 position;
            float pointSize;
            half3 color;
            half4 slab;
            /// Half of the streak, half the star's own width and a pixel, all in the point's
            /// square, which is one across.
            float2 half_streak;
            float radius;
            float pixel;
        };

        SHARED Star culledStar() {
            Star out;
            out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
            out.pointSize = 0.0f;
            out.color = half3(half(0.0f));
            out.slab = half4(half(0.0f));
            out.half_streak = float2(0.0f);
            out.radius = 0.5f;
            out.pixel = 1.0f;
            return out;
        }

        SHARED Star pointStar(uint vid, uint iid, device const float3 *positions,
                              device const float *population, device const float *formation,
                              device const float *luminosity, device const uint *component,
                              constant SplatUniforms &u, device const uint *galaxy,
                              constant DiskFrame *frames, device const float *smoothing,
                              device const float2 *stellar, device const float2 *traits,
                              device const float *rampKeys, constant GalaxyRamp *ramps,
                              device const uint2 *list, ColumnDensity column) {
            uint index = list[vid].x;
            uint rank = list[vid].y * insideGroup + iid;
            Drawn p = massiveDrawn(index, positions, formation, luminosity, component, galaxy,
                                   smoothing, traits);
            p.warming = traits[index].x;
            p.population = population[index];
            p.rampKey = rampKeys[index];
            float4 clip = u.viewProjection * float4(p.position, 1.0f);
            float raw = insideRaw(p, clip, u, column);
            float starred = insideStarred(raw, clip.w, u.inside);
            float total = insideStarTotal(raw, u.inside);
            // The last star a particle draws comes in as the particle turns.
            float present = saturate(insideStarsDrawn(starred, total) - float(rank));
            if (present <= 0.0f) { return culledStar(); }
            float2 b = insideHash(uint2(index ^ 0x9e3779b9u, rank * 2u + 2u));
            float spread = insideLength(p.spacing, p.kernelScale, u) * u.inside.starSpread;
            bool nursery = p.kind == 1u || p.kind == 2u;
            float ageMyr = (nursery || p.born >= 0.0f)
                ? (u.time - p.born) * u.megayearsPerUnit : -p.born * u.megayearsPerUnit;
            bool aged = p.born > -1e8f && p.born < 1e8f && ageMyr >= 0.0f;
            p.position += insideClustered(index, rank, ageMyr, aged, spread, u.inside)
                * insideLength(p.spacing, p.kernelScale, u) * u.inside.starSpread;
            p.starShare = pow(float(rank + 1u), -u.inside.starShareExponent)
                * insideShareNorm(total, u.inside) * present * starred;
            if (u.inside.starTail > 0.0f) {
                // A Pareto draw cut at 30, over its mean so that the shares still add up.
                float tail = u.inside.starTail;
                float least = (tail - 1.0f) / tail;
                float mean = 1.0f - pow(least, tail) * pow(30.0f, 1.0f - tail) / (tail - 1.0f);
                p.starShare *= min(pow(max(b.x, 1e-9f), -1.0f / tail) * least, 30.0f) / mean;
            }
            p.starHash = b.y;
            Splat star = splat(p, u, frames, stellar, ramps, column);
            if (star.pointSize <= 0.0f) { return culledStar(); }
            // The streak the star leaves while the shutter is open (#297): from where this
            // camera puts it to where the next one does, in pixels. The point grows to hold it,
            // the light is spread along it, and the fragment draws the star's own profile
            // across it. A string of renders then draws one unbroken streak, not a row of dots.
            float4 next = u.inside.nextViewProjection * float4(p.position, 1.0f);
            float2 extent = float2(u.projectionScale / u.inside.projectionX,
                                   u.projectionScale / u.inside.projectionY);
            float2 from = star.position.xy / star.position.w;
            float2 moved = float2(0.0f);
            if (next.w > u.inside.nearPlane && star.position.w > u.inside.nearPlane) {
                moved = (next.xy / next.w - from) * extent;
            }
            float travel = length(moved);
            // No point is wider than 511 pixels: a longer streak is cut short and keeps its light.
            float drawn = min(travel, 480.0f);
            if (travel > drawn) { moved *= drawn / travel; }
            float size = star.pointSize;
            Star out;
            out.position = float4((from + 0.5f * moved / extent) * star.position.w, star.position.zw);
            // The square holds every pixel the star's box touches, turned along its streak.
            out.pointSize = drawn > 0.0f ? drawn + 2.0f * size + 1.5f : size + 1.5f;
            // All of the light `splat` gives a profile of this size, which the pixels then share.
            out.color = half3(float3(star.color) * (0.1736f * size * size));
            out.slab = star.slab;
            // The square's y runs down the screen, the clip space's up.
            out.half_streak = 0.5f * float2(moved.x, -moved.y) / out.pointSize;
            out.radius = 0.5f * size / out.pointSize;
            out.pixel = 1.0f / out.pointSize;
            return out;
        }

        // The share of a point star's light a pixel of its square holds (#357): how much of the
        // pixel the star's box covers, `size` wide and drawn out along its streak, over the box's
        // area. A star narrower than a pixel lays all of its light on the few pixels it touches,
        // wherever it falls among them, and the same star is one picture at any frame size.
        SHARED float starShare(float2 coord, float2 half_streak, float radius, float pixel) {
            float2 d = coord - 0.5f;
            float half_length = length(half_streak);
            float2 along = half_length > 1e-9f ? half_streak / half_length : float2(1.0f, 0.0f);
            float a = dot(d, along);
            float c = dot(d, float2(-along.y, along.x));
            float reach = half_length + radius;
            float covered = clamp(min(a + 0.5f * pixel, reach) - max(a - 0.5f * pixel, -reach), 0.0f, pixel)
                * clamp(min(c + 0.5f * pixel, radius) - max(c - 0.5f * pixel, -radius), 0.0f, pixel);
            return covered / (4.0f * reach * radius);
        }

        SHARED half4 starPixel(half3 color, half4 slab, half4 dust, float share) {
            float column = dot(float4(dust), float4(slab));
            float3 extinction = exp(-column * reddening);
            return half4(half3(float3(color) * extinction * share), half(share));
        }
        #endif

        #if defined(SILLAGE_INSIDE) && defined(__METAL_VERSION__)
        kernel void insideCount(device const float3 *positions [[buffer(0)]],
                                device const float *luminosity [[buffer(2)]],
                                device const uint *component [[buffer(3)]],
                                constant SplatUniforms &u [[buffer(4)]],
                                device const uint *galaxy [[buffer(5)]],
                                device const float *smoothing [[buffer(7)]],
                                device const float *formation [[buffer(8)]],
                                device const float2 *traits [[buffer(10)]],
                                device uint *counts [[buffer(20)]],
                                constant uint3 &span [[buffer(21)]],
                                texture2d<float, access::sample> column [[texture(0)]],
                                uint block [[thread_position_in_grid]]) {
            insideCounted(block, positions, luminosity, component, u, galaxy, smoothing, formation,
                          traits, counts, span, column);
        }

        kernel void insideOffsets(device uint *counts [[buffer(20)]],
                                  constant uint3 &span [[buffer(21)]],
                                  device uint *draw [[buffer(22)]],
                                  uint first [[thread_position_in_grid]]) {
            if (first != 0u) { return; }
            insideOffset(counts, span, draw);
        }

        kernel void insideFill(device const float3 *positions [[buffer(0)]],
                               device const float *luminosity [[buffer(2)]],
                               device const uint *component [[buffer(3)]],
                               constant SplatUniforms &u [[buffer(4)]],
                               device const uint *galaxy [[buffer(5)]],
                               device const float *smoothing [[buffer(7)]],
                               device const float *formation [[buffer(8)]],
                               device const float2 *traits [[buffer(10)]],
                               device const uint *offsets [[buffer(20)]],
                               constant uint3 &span [[buffer(21)]],
                               device uint2 *list [[buffer(23)]],
                               texture2d<float, access::sample> column [[texture(0)]],
                               uint block [[thread_position_in_grid]]) {
            insideFilled(block, positions, luminosity, component, u, galaxy, smoothing, formation,
                         traits, offsets, span, list, column);
        }

        struct StarOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
            half4 slab;
            float2 half_streak;
            float radius;
            float pixel;
        };

        vertex StarOut pointStarVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
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
                                        device const uint2 *list [[buffer(23)]],
                                        texture2d<float, access::sample> column [[texture(0)]]) {
            Star star = pointStar(vid, iid, positions, population, formation, luminosity, component,
                                  u, galaxy, frames, smoothing, stellar, traits, rampKeys, ramps,
                                  list, column);
            StarOut out;
            out.position = star.position;
            out.pointSize = star.pointSize;
            out.color = star.color;
            out.slab = star.slab;
            out.half_streak = star.half_streak;
            out.radius = star.radius;
            out.pixel = star.pixel;
            return out;
        }
        #endif

        #if defined(__METAL_VERSION__)
        struct BackgroundGalaxy {
            float4 direction;
            float4 color;
            float4 shape;
        };

        struct GalaxyFieldOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
            float4 shape;
            float ratio;
        };

        // Galaxies behind the field stars, each an ellipse of a disk and a bulge at constant
        // surface brightness, so that a narrower field shows them larger and no brighter. Under a
        // pixel and a half one is a point whose light goes as its area.
        vertex GalaxyFieldOut galaxyFieldVertex(uint vid [[vertex_id]],
                                                device const BackgroundGalaxy *galaxies [[buffer(0)]],
                                                constant SplatUniforms &u [[buffer(4)]]) {
            BackgroundGalaxy g = galaxies[vid];
            GalaxyFieldOut out;
            out.position = u.viewProjection * float4(g.direction.xyz, 1.0f);
            float size = 2.0f * g.direction.w * u.projectionScale / max(out.position.w, 1e-3f);
            float small = min(size / 1.5f, 1.0f);
            out.pointSize = clamp(size, 1.5f, 480.0f);
            out.color = half3(g.color.rgb * (g.shape.w * small * small));
            out.shape = g.shape;
            out.ratio = max(g.color.w, 0.05f);
            return out;
        }

        fragment LightTarget galaxyFieldFragment(GalaxyFieldOut in [[stage_in]],
                                                 float2 coord [[point_coord]]) {
            float2 d = (coord - 0.5f) * 2.0f;
            float2 a = float2(dot(d, in.shape.xy), dot(d, float2(-in.shape.y, in.shape.x)) / in.ratio);
            float r = length(a);
            if (r > 1.0f) { discard_fragment(); }
            float profile = (1.0f - in.shape.z) * exp(-5.0f * r) + in.shape.z * exp(-60.0f * r * r);
            LightTarget out;
            out.light = half4(in.color * half(profile * (1.0f - smoothstep(0.6f, 1.0f, r))), 0.0h);
            return out;
        }

        vertex SplatOut starfieldVertex(uint vid [[vertex_id]],
                                        device const BackgroundStar *stars [[buffer(0)]],
                                        constant SplatUniforms &u [[buffer(4)]]) {
            return splatOut(starfieldSplat(stars[vid], u));
        }

        // Reading the dust attachment makes overlapping fragments on a pixel run in order, so
        // only the draw that needs it reads it: the dust writes its own slab without looking,
        // and the field stars sit behind the whole stack and are not dimmed by it.
        fragment DustTarget dustFragment(SplatOut in [[stage_in]],
                                         float2 coord [[point_coord]]) {
            float r2 = splatRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }

            DustTarget out;
            #if defined(SILLAGE_INSIDE)
            out.dust = in.grain.w > 0.0f
                ? insideDustPixel(in.opticalDepth, in.slab, r2, coord, in.grain, in.grainX, in.grainY,
                                  in.grainZ)
                : dustPixel(in.opticalDepth, in.slab, r2);
            #else
            out.dust = dustPixel(in.opticalDepth, in.slab, r2);
            #endif
            return out;
        }

        // The same grains drawn a second time into the light: what the dust gives
        // off, in proportion to what it holds, in one colour. Nothing dims it.
        fragment LightTarget dustGlowFragment(SplatOut in [[stage_in]],
                                              float2 coord [[point_coord]],
                                              constant float4 &glow [[buffer(0)]]) {
            float r2 = splatRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }

            LightTarget out;
            out.light = half4(half3(glow.rgb * (glow.w * float(in.opticalDepth) * exp(-4.5f * r2))), 0.0h);
            return out;
        }
        #endif

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
            /// its own pixels; from inside a galaxy (#354), the disk radii within which its lace is
            /// carried through the dust layer's depth.
            float4 carrier;
        };

        SHARED float2 webHash(uint2 v) {
            v = v * 1664525u + 1013904223u;
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            v.x += v.y * 1664525u;
            v.y += v.x * 1664525u;
            v = v ^ (v >> 16u);
            return float2(v) * (1.0f / 4294967296.0f);
        }

        // The lace tiles every `laceTile` cells: each lattice it is read off holds a whole
        // number of its cells in a tile, within 0.7 % of the frequencies the spike drew.
        SHARED_CONSTANT int laceTile = 64;

        SHARED int2 laceWrap(int2 cell, int period) {
            return (cell % period + period) % period;
        }

        SHARED float laceValue(float2 q, int period, float2 shift) {
            float2 p = q * (float(period) / float(laceTile)) + shift;
            float2 i = floor(p);
            float2 f = p - i;
            float2 s = f * f * (3.0f - 2.0f * f);
            int2 c = int2(i);
            float a = webHash(uint2(laceWrap(c, period))).x;
            float b = webHash(uint2(laceWrap(c + int2(1, 0), period))).x;
            float d = webHash(uint2(laceWrap(c + int2(0, 1), period))).x;
            float e = webHash(uint2(laceWrap(c + int2(1, 1), period))).x;
            return mix(mix(a, b, s.x), mix(d, e, s.x), s.y);
        }

        SHARED float laceFbm(float2 q, int low, int high, float2 shift) {
            float ratio = float(high) / float(low);
            return (0.5f * laceValue(q, low, shift)
                    + 0.25f * laceValue(q, high, shift * ratio + float2(17.1f, -9.7f))) / 0.75f;
        }

        SHARED float laceRidge(float2 p, int period, float2 shift) {
            float ridge = 1.0f - abs(2.0f * laceValue(p, period, shift) - 1.0f);
            return ridge * ridge * ridge * ridge * ridge;
        }

        // Threads that branch: ridged noise, each octave weighted by the ridge above it.
        SHARED float laceThreads(float2 p) {
            float first = laceRidge(p, 83, float2(0.0f));
            float second = laceRidge(p, 175, float2(5.3f, 1.9f));
            float third = laceRidge(p, 367, float2(16.43f, 5.89f));
            return 0.6f * first + 0.33f * second * saturate(first * 1.5f)
                + 0.1815f * third * saturate(second * 1.5f);
        }

        // Cell walls, each wall drawn at its own strength so the web stays open.
        SHARED float laceWalls(float2 q) {
            const int period = 51;
            float2 p = q * (float(period) / float(laceTile));
            int2 base = int2(floor(p));
            float first = 9.0f;
            float second = 9.0f;
            int2 near = base;
            int2 next = base;
            for (int y = -1; y <= 1; ++y) {
                for (int x = -1; x <= 1; ++x) {
                    int2 c = base + int2(x, y);
                    float d = distance(float2(c) + 0.1f + 0.8f * webHash(uint2(laceWrap(c, period))), p);
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
            float gap = (second - first) / 0.1f;
            return exp(-gap * gap) * (0.25f + 0.75f * wall);
        }

        // Threads and walls on a warped plane, with clear holes, in cells; not yet divided by
        // its mean.
        SHARED float webLace(float2 q) {
            float2 p = q + 2.2f * (float2(laceFbm(q, 32, 65, float2(11.3f, 2.9f)),
                                         laceFbm(q, 32, 65, float2(-7.1f, 17.7f))) - 0.5f);
            float threads = laceThreads(p);
            float walls = laceWalls(p);
            float holes = saturate((laceFbm(p, 58, 118, float2(4.4f, 6.6f)) - 0.58f) * 6.0f);
            return (0.15f + 2.0f * threads + 0.8f * walls) * (1.0f - 0.9f * holes);
        }

        // A texel of one tile of the lace, `width` texels on a side: four samples of it.
        SHARED float laceTexel(uint2 gid, uint width) {
            float texel = float(laceTile) / float(width);
            float total = 0.0f;
            for (int y = 0; y < 2; ++y) {
                for (int x = 0; x < 2; ++x) {
                    total += webLace((float2(gid) + (float2(float(x), float(y)) + 0.5f) * 0.5f) * texel);
                }
            }
            return 0.25f * total;
        }

        #if defined(__METAL_VERSION__)
        // One tile of the lace, baked once per device.
        kernel void bakeLace(texture2d<half, access::write> lace [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= lace.get_width() || gid.y >= lace.get_height()) { return; }
            lace.write(half4(half(laceTexel(gid, lace.get_width()))), gid);
        }
        #endif

        // The disk's angular rate at a radius, from eight samples a factor 1.68 apart; inside
        // the first it turns as a solid body, past the last its curve is flat.
        SHARED float webOmega(DiskFrame frame, float radius) {
            float h = max(frame.center.w, 1e-3f);
            float x = (log2(max(radius / h, 1e-4f)) + 2.0f) / 0.75f;
            if (x >= 7.0f) { return frame.omegaOuter.w * 9.5137f * h / max(radius, 1e-4f); }
            x = max(x, 0.0f);
            int i = min(int(x), 6);
            float a = i < 4 ? frame.omegaInner[i] : frame.omegaOuter[i - 4];
            float b = i < 3 ? frame.omegaInner[i + 1] : frame.omegaOuter[i - 3];
            return mix(a, b, x - float(i));
        }

        // How fast that rate falls with radius: the shear a copy has taken on since it rested.
        SHARED float webOmegaSlope(DiskFrame frame, float radius) {
            float h = max(frame.center.w, 1e-3f);
            float r = max(radius, 1e-4f);
            float x = (log2(max(r / h, 1e-4f)) + 2.0f) / 0.75f;
            if (x >= 7.0f) { return -webOmega(frame, r) / r; }
            if (x <= 0.0f) { return 0.0f; }
            int i = min(int(x), 6);
            float a = i < 4 ? frame.omegaInner[i] : frame.omegaOuter[i - 4];
            float b = i < 3 ? frame.omegaInner[i + 1] : frame.omegaOuter[i - 3];
            return (b - a) / (0.75f * M_LN2_F * r);
        }

        // A quarter of the dust stays even under the web: with none, a dense clump opens onto
        // whatever bright knot it holds and the core burns white.
        SHARED_CONSTANT float webDepth = 0.75f;

        // The baked lace as each engine holds it, and its value over a pixel's footprint, whose two
        // axes `dx` and `dy` are in the lace's own coordinates: Metal samples its texture, the CUDA
        // engine reads its levels by hand with a filter of the same kind.
        #if defined(__METAL_VERSION__)
        constexpr sampler laceSampler(filter::linear, mip_filter::linear, address::repeat,
                                      max_anisotropy(8));
        typedef texture2d<half> Lace;
        static float laceRead(Lace lace, float2 at, float2 dx, float2 dy) {
            return float(lace.sample(laceSampler, at, gradient2d(dx, dy)).r);
        }
        #else
        typedef texels2d Lace;
        SHARED float laceRead(Lace lace, float2 at, float2 dx, float2 dy) {
            return sample_anisotropic(lace, at, dx, dy, 8.0f).x;
        }
        #endif

        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        // From near a disk (#354) the lace is not read where the ray meets the mid-plane but
        // averaged along the stretch of ray that crosses the dust's layer, `layer` either side
        // of the plane: the lace is the dust's structure carried through the layer's depth.
        // Face on that stretch is shorter than a pixel and it is the mid-plane's lace; at a
        // grazing angle it runs over many cells and the lace evens out by itself, scale by
        // scale, with no angle at which it stops. Each tap reads the lace over its share of
        // the stretch, folded into the pixel's footprint.
        SHARED_CONSTANT int webTaps = 4;

        SHARED float webThrough(DiskFrame frame, constant WebUniforms &w, float3 ray, float3 stepX,
                                float3 stepY, Lace lace, float3 rel, float3 axis, float layer) {
            float height = dot(rel, axis);
            float least = 0.05f * length(ray);
            float along = dot(ray, axis);
            along = along < 0.0f ? min(along, -least) : max(along, least);
            float t0 = (-layer - height) / along;
            float t1 = (layer - height) / along;
            float enter = max(min(t0, t1), 0.0f);
            float leave = max(t0, t1);
            if (leave <= enter) { return 1.0f; }
            float h = max(frame.center.w, 1e-3f);
            float cell = clamp(w.params.y * h, w.params.z, w.params.w);
            float scale = 1.0f / (cell * float(laceTile));
            float3 u3 = frame.axisU.xyz;
            float3 v3 = frame.axisV.xyz;
            float share = (leave - enter) / float(webTaps);
            float2 stride = float2(dot(ray, u3), dot(ray, v3)) * share;
            float3 sx = stepX - ray * (dot(stepX, axis) / along);
            float3 sy = stepY - ray * (dot(stepY, axis) / along);
            float period = frame.web.y;
            float weights[2];
            float ages[2];
            float2 offsets[2];
            float norm = 0.0f;
            for (int k = 0; k < 2; ++k) {
                float s = w.up.w / period + frame.web.z + 0.5f * float(k);
                float cycle = floor(s);
                float phase = s - cycle;
                float weight = sinpi(phase);
                weights[k] = weight * weight;
                ages[k] = (phase - w.params.x) * period;
                offsets[k] = webHash(uint2(int2(int(cycle) * 2 + k, int(frame.pattern.w * 10.0f)))) * 400.0f;
                norm += weights[k] * weights[k];
            }
            float total = 0.0f;
            for (int i = 0; i < webTaps; ++i) {
                float t = enter + (float(i) + 0.5f) * share;
                float3 meet = rel + ray * t;
                float2 p = float2(dot(meet, u3), dot(meet, v3));
                float2 dx = float2(dot(sx, u3), dot(sx, v3)) * t;
                float2 dy = float2(dot(sy, u3), dot(sy, v3)) * t;
                float pixel = max(length(dx), length(dy));
                float detail = smoothstep(0.6f, 2.0f, 0.1f * cell / max(pixel, 1e-6f));
                if (detail <= 0.0f) { continue; }
                // The tap's stretch of ray lengthens whichever axis of the footprint lies nearer it.
                float ax = abs(dot(dx, stride)) * length(dy);
                float ay = abs(dot(dy, stride)) * length(dx);
                if (ax > ay) {
                    dx += dot(dx, stride) < 0.0f ? -stride : stride;
                } else {
                    dy += dot(dy, stride) < 0.0f ? -stride : stride;
                }
                float radius = length(p);
                float omega = webOmega(frame, radius);
                float shear = webOmegaSlope(frame, radius) / max(radius, 1e-4f);
                float sum = 0.0f;
                for (int k = 0; k < 2; ++k) {
                    float angle = omega * ages[k];
                    float c = cos(angle);
                    float n = sin(angle);
                    float2 q = float2(c * p.x + n * p.y, n * -p.x + c * p.y);
                    float2 turn = float2(n * -p.x + c * p.y, -c * p.x - n * p.y) * (shear * ages[k]);
                    float2 qx = float2(c * dx.x + n * dx.y, n * -dx.x + c * dx.y) + turn * dot(p, dx);
                    float2 qy = float2(c * dy.x + n * dy.y, n * -dy.x + c * dy.y) + turn * dot(p, dy);
                    float value = laceRead(lace, (q / cell + offsets[k]) / float(laceTile), qx * scale,
                                           qy * scale);
                    sum += weights[k] * (value * w.target.w - 1.0f);
                }
                total += detail * sum;
            }
            return max(1.0f + webDepth * total / float(webTaps) * rsqrt(max(norm, 1e-4f)), 0.0f);
        }
        #endif

        // The web where this pixel's ray meets the disk's mid-plane, which is the same point
        // whichever grain the dust came from, so an inclined disk shows it foreshortened. Each
        // copy is carried round from where it rests, a share of its life in, and fades in and
        // out with sin squared; the two weights always sum to one, and dividing by their root
        // sum of squares keeps the contrast through the cross-fade.
        SHARED float webAt(DiskFrame frame, constant WebUniforms &w, float3 ray, float3 stepX,
                           float3 stepY, Lace lace) {
            float period = frame.web.y;
            if (period <= 0.0f) { return 1.0f; }
            float3 axis = cross(frame.axisU.xyz, frame.axisV.xyz);
            float3 rel = w.eye.xyz - frame.center.xyz;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            if (w.carrier.w > 0.0f) {
                float radius = 7.0f * max(frame.center.w, 1e-3f);
                float above = dot(rel, axis);
                float beyond = max(length(rel - axis * above) - radius, 0.0f);
                float away = sqrt(above * above + beyond * beyond);
                float layer = frame.web.w * (1.0f - smoothstep(w.carrier.z * radius, w.carrier.w * radius, away));
                if (layer > 0.0f) { return webThrough(frame, w, ray, stepX, stepY, lace, rel, axis, layer); }
            }
            #endif
            float least = 0.05f * length(ray);
            float along = dot(ray, axis);
            along = along < 0.0f ? min(along, -least) : max(along, least);
            float t = -dot(rel, axis) / along;
            if (t <= 0.0f) { return 1.0f; }
            float3 meet = rel + ray * t;
            float3 ex = t * (stepX - ray * (dot(stepX, axis) / along));
            float3 ey = t * (stepY - ray * (dot(stepY, axis) / along));
            float2 p = float2(dot(meet, frame.axisU.xyz), dot(meet, frame.axisV.xyz));
            float2 dx = float2(dot(ex, frame.axisU.xyz), dot(ex, frame.axisV.xyz));
            float2 dy = float2(dot(ey, frame.axisU.xyz), dot(ey, frame.axisV.xyz));
            float h = max(frame.center.w, 1e-3f);
            float cell = clamp(w.params.y * h, w.params.z, w.params.w);
            // The thinnest wall is a tenth of a cell: under a pixel it would only shimmer.
            float pixel = max(length(dx), length(dy));
            float detail = smoothstep(0.6f, 2.0f, 0.1f * cell / max(pixel, 1e-6f));
            if (detail <= 0.0f) { return 1.0f; }
            float radius = length(p);
            float omega = webOmega(frame, radius);
            float shear = webOmegaSlope(frame, radius) / max(radius, 1e-4f);
            float scale = 1.0f / (cell * float(laceTile));
            float total = 0.0f;
            float norm = 0.0f;
            for (int k = 0; k < 2; ++k) {
                float s = w.up.w / period + frame.web.z + 0.5f * float(k);
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
                float2 offset = webHash(uint2(int2(int(cycle) * 2 + k, int(frame.pattern.w * 10.0f)))) * 400.0f;
                float value = laceRead(lace, (q / cell + offset) / float(laceTile), qx * scale,
                                       qy * scale);
                total += weight * (value * w.target.w - 1.0f);
                norm += weight * weight;
            }
            return max(1.0f + webDepth * detail * total * rsqrt(max(norm, 1e-4f)), 0.0f);
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

        SHARED bool webGrain(Drawn p, constant SplatUniforms &u, DiskFrame frame,
                             constant WebUniforms &w, thread WebGrain &grain) {
            float3 position = p.position;
            grain.position = u.viewProjection * float4(position, 1.0f);
            uint kind = p.kind;
            grain.weight = p.weight;
            grain.kernelScale = p.kernelScale;
            if (grain.kernelScale < 0.8f) {
                grain.weight *= mix(0.07f, 1.0f, u.glint);
                grain.kernelScale = mix(0.9f, grain.kernelScale, u.glint);
            }
            float born = p.born;
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0f)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8f && born < 1e8f && ageMyr >= 0.0f;
            grain.hole = kind == 6u;
            bool absorbing = (kind == 2u && !knot) || grain.hole;
            if (kind == 3u || (grain.hole && u.holeShadow <= 0.0f) || !absorbing) { return false; }
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            grain.slab = insideDustSlabs(insideSlabAt(grain.position.w, u), u.inside);
            #else
            float slabAt = clamp((grain.position.w - u.slabNear) * u.slabScale, 0.0f, 0.999f) * 4.0f;
            uint slabIndex = uint(slabAt);
            grain.slab = half4(slabIndex == 0u, slabIndex == 1u, slabIndex == 2u, slabIndex == 3u);
            #endif
            grain.perPixel = u.projectionScale / max(grain.position.w, 1e-3f);
            grain.amount = 0.0f;
            if (grain.hole) { return true; }
            float3 axis = cross(frame.axisU.xyz, frame.axisV.xyz);
            float3 rel = position - frame.center.xyz;
            float height = dot(rel, axis);
            float scale = max(frame.center.w, 1e-3f);
            float facing = dot(normalize(position - w.eye.xyz), axis);
            grain.amount = w.eye.w * frame.web.x
                * (1.0f - smoothstep(0.3f * scale, 0.8f * scale, abs(height)))
                * (1.0f - smoothstep(5.0f * scale, 7.0f * scale, length(rel - axis * height)))
                * smoothstep(0.12f, 0.35f, abs(facing));
            return true;
        }

        // The dust the painted strands lay, in the frame's own pass: all of it where the web
        // is off and none where it takes everything, so a grain it fully carries draws nothing
        // here.
        SHARED Splat dustWeb(Drawn p, bool dust, WebGrain grain, constant SplatUniforms &u,
                             DiskFrame frame, constant WebUniforms &w) {
            Splat out;
            out.color = half3(half(0.0f));
            out.spikes = half(0.0f);
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            insideBare(out);
            #endif
            if (!dust || grain.amount >= 1.0f) {
                out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
                out.pointSize = 0.0f;
                out.opticalDepth = half(0.0f);
                out.slab = half4(half(0.0f));
                return out;
            }
            out.position = grain.position;
            out.slab = grain.slab;
            if (grain.hole) {
                out.pointSize = max(4.0f * u.holeShadow * grain.perPixel, 2.0f);
                out.opticalDepth = half(8.0f);
                return out;
            }
            float3 position = p.position;
            float raw = max(p.spacing * u.smoothingScale * grain.kernelScale
                                * mix(1.0f, w.right.w, grain.amount), 1e-4f) * grain.perPixel;
            float span = clamp(raw, u.minimumSize, u.maximumSize);
            float reach = span / grain.perPixel;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            float spread = insideSpread(u.referenceArea / (reach * reach), raw, span, grain.position.w, u.inside)
                * insideFade(grain.position.w, raw / grain.perPixel, u.inside);
            #else
            float spread = u.referenceArea / (reach * reach);
            #endif
            float2 pattern = armWave(position, frame);
            float lane = 1.0f + 7.0f * pow(pattern.x, 2.0f) * pattern.y * laneDetail(position, frame);
            out.pointSize = span * 1.3f;
            out.opticalDepth = half(grain.weight * u.dustStrength * spread * 1.3f
                                    * (1.0f - grain.amount) * lane);
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            insideNearDust(out, position, p.id, grain.perPixel, frame, u);
            #endif
            return out;
        }

        // A massive particle's, from the renderer's buffers.
        SHARED Splat massiveDustWeb(uint vid, device const float3 *positions,
                                    device const float *formation, device const float *luminosity,
                                    device const uint *component, constant SplatUniforms &u,
                                    device const uint *galaxy, constant DiskFrame *frames,
                                    device const float *smoothing, device const float2 *traits,
                                    constant WebUniforms &w) {
            Drawn p = massiveDrawn(vid, positions, formation, luminosity, component, galaxy,
                                   smoothing, traits);
            DiskFrame frame = frames[p.galaxy];
            WebGrain grain;
            bool dust = webGrain(p, u, frame, w, grain);
            return dustWeb(p, dust, grain, u, frame, w);
        }

        // A light tracer's, from its state and its word.
        SHARED Splat tracerDustWeb(uint vid, float4 state, uint word, constant SplatUniforms &u,
                                   constant DiskFrame *frames, constant WebUniforms &w,
                                   device const uint2 *cells, device const float *treeFrame,
                                   uint depth, constant float *scales) {
            Drawn p = tracerDrawn(state, word, scales);
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            p.id = vid;
            #endif
            DiskFrame frame = frames[p.galaxy];
            WebGrain grain;
            bool dust = webGrain(p, u, frame, w, grain);
            if (dust && !grain.hole && grain.amount < 1.0f) {
                p.spacing = tracerSpacing(p.position, cells, treeFrame, depth);
            }
            return dustWeb(p, dust, grain, u, frame, w);
        }

        #if defined(__METAL_VERSION__)
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
            return splatOut(massiveDustWeb(vid, positions, formation, luminosity, component, u,
                                           galaxy, frames, smoothing, traits, w));
        }

        vertex SplatOut dustWebTracerVertex(uint vid [[vertex_id]],
                                            constant SplatUniforms &u [[buffer(4)]],
                                            constant DiskFrame *frames [[buffer(6)]],
                                            constant WebUniforms &w [[buffer(13)]],
                                            device const uint2 *cells [[buffer(14)]],
                                            device const float *treeFrame [[buffer(15)]],
                                            constant uint &depth [[buffer(16)]],
                                            constant float *scales [[buffer(17)]],
                                            device const float4 *states [[buffer(18)]],
                                            device const uint *words [[buffer(19)]]) {
            return splatOut(tracerDustWeb(vid, states[vid], words[vid * 4u + 3u], u, frames, w, cells,
                                          treeFrame, depth, scales));
        }
        #endif

        // What a carried grain hands from its particle to its pixels.
        struct WebCarrier {
            float4 position;
            float pointSize;
            float carried;
            half4 slab;
            /// The grain's galaxy plus one, over 255.
            half tag;
        };

        // The dust the web multiplies, drawn a few times coarser than the frame (#200): a
        // grain under the web is drawn twice as wide (its column kept) so the grains merge into
        // one even layer and the lace, not the grains, says where the dust is thin, and a layer
        // that smooth loses nothing at a quarter of the pixels.
        SHARED WebCarrier webCarrier(Drawn p, bool dust, WebGrain grain,
                                     constant SplatUniforms &u, DiskFrame frame,
                                     constant WebUniforms &w) {
            WebCarrier out;
            uint g = p.galaxy;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            // A frame whose grains are spread over two slabs carries each galaxy's dust apart,
            // a pass a galaxy, so that each is multiplied by its own web (#399).
            if (u.inside.webOnly > 0.0f && float(g + 1u) != u.inside.webOnly) { dust = false; }
            #endif
            if (!dust || grain.hole || grain.amount <= 0.0f) {
                out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
                out.pointSize = 0.0f;
                out.carried = 0.0f;
                out.slab = half4(half(0.0f));
                out.tag = half(0.0f);
                return out;
            }
            float3 position = p.position;
            float coarse = w.carrier.x;
            float raw = max(p.spacing * u.smoothingScale * grain.kernelScale
                                * mix(1.0f, w.right.w, grain.amount), 1e-4f) * grain.perPixel;
            // Never under a few of its own pixels, or the coarse target would drop part of it.
            float span = clamp(raw, max(u.minimumSize, w.carrier.y * coarse / 1.3f), u.maximumSize);
            float reach = span / grain.perPixel;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            float spread = insideSpread(u.referenceArea / (reach * reach), raw, span, grain.position.w, u.inside)
                * insideFade(grain.position.w, raw / grain.perPixel, u.inside);
            #else
            float spread = u.referenceArea / (reach * reach);
            #endif
            float2 pattern = armWave(position, frame);
            // The painted strands' own mean under the web, so the web moves no exposure.
            float lane = 1.0f + 7.0f * pow(pattern.x, 2.0f) * pattern.y * 0.855f;
            out.position = grain.position;
            out.pointSize = span * 1.3f / coarse;
            out.carried = grain.weight * u.dustStrength * spread * 1.3f * grain.amount * lane;
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            float trim = insideDustTrim(grain.position, position, frame, u);
            if (trim != 1.0f) { out.carried *= trim; }
            #endif
            out.slab = grain.slab;
            out.tag = half(float(g + 1u) / 255.0f);
            return out;
        }

        // A massive particle's, from the renderer's buffers.
        SHARED WebCarrier massiveWebCarrier(uint vid, device const float3 *positions,
                                            device const float *formation,
                                            device const float *luminosity,
                                            device const uint *component, constant SplatUniforms &u,
                                            device const uint *galaxy, constant DiskFrame *frames,
                                            device const float *smoothing, device const float2 *traits,
                                            constant WebUniforms &w) {
            Drawn p = massiveDrawn(vid, positions, formation, luminosity, component, galaxy,
                                   smoothing, traits);
            DiskFrame frame = frames[p.galaxy];
            WebGrain grain;
            bool dust = webGrain(p, u, frame, w, grain);
            return webCarrier(p, dust, grain, u, frame, w);
        }

        // A light tracer's, from its state and its word.
        SHARED WebCarrier tracerWebCarrier(float4 state, uint word, constant SplatUniforms &u,
                                           constant DiskFrame *frames, constant WebUniforms &w,
                                           device const uint2 *cells, device const float *treeFrame,
                                           uint depth, constant float *scales) {
            Drawn p = tracerDrawn(state, word, scales);
            DiskFrame frame = frames[p.galaxy];
            WebGrain grain;
            bool dust = webGrain(p, u, frame, w, grain);
            if (dust && !grain.hole && grain.amount > 0.0f) {
                p.spacing = tracerSpacing(p.position, cells, treeFrame, depth);
            }
            return webCarrier(p, dust, grain, u, frame, w);
        }

        // What a carried grain lays on a pixel of the coarse targets, `r2` from its centre: its dust
        // into its slab of the carrier, and its galaxy's tag there.
        SHARED half4 webCarrierPixel(float carried, half4 slab, float r2) {
            return half4(half(carried * exp(-4.5f * r2)) * slab);
        }

        SHARED half4 webTagPixel(half tag, half4 slab) {
            #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
            // A grain spread over two slabs tags both.
            return tag * half4(slab > half4(half(0.0f)));
            #else
            return tag * slab;
            #endif
        }

        #if defined(__METAL_VERSION__)
        struct WebCarrierOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            float carried;
            half4 slab;
            half tag;
        };

        struct WebCarrierTarget {
            half4 carrier [[color(0)]];
            half4 tags [[color(1)]];
        };

        static WebCarrierOut webCarrierOut(WebCarrier grain) {
            WebCarrierOut out;
            out.position = grain.position;
            out.pointSize = grain.pointSize;
            out.carried = grain.carried;
            out.slab = grain.slab;
            out.tag = grain.tag;
            return out;
        }

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
            return webCarrierOut(massiveWebCarrier(vid, positions, formation, luminosity, component,
                                                   u, galaxy, frames, smoothing, traits, w));
        }

        vertex WebCarrierOut webCarrierTracerVertex(uint vid [[vertex_id]],
                                                    constant SplatUniforms &u [[buffer(4)]],
                                                    constant DiskFrame *frames [[buffer(6)]],
                                                    constant WebUniforms &w [[buffer(13)]],
                                                    device const uint2 *cells [[buffer(14)]],
                                                    device const float *treeFrame [[buffer(15)]],
                                                    constant uint &depth [[buffer(16)]],
                                                    constant float *scales [[buffer(17)]],
                                                    device const float4 *states [[buffer(18)]],
                                                    device const uint *words [[buffer(19)]]) {
            return webCarrierOut(tracerWebCarrier(states[vid], words[vid * 4u + 3u], u, frames, w,
                                                  cells, treeFrame, depth, scales));
        }

        fragment WebCarrierTarget webCarrierFragment(WebCarrierOut in [[stage_in]],
                                                     float2 coord [[point_coord]]) {
            float r2 = splatRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }
            WebCarrierTarget out;
            out.carrier = webCarrierPixel(in.carried, in.slab, r2);
            out.tags = webTagPixel(in.tag, in.slab);
            return out;
        }

        struct WebResolveOut {
            float4 position [[position]];
        };

        vertex WebResolveOut webResolveVertex(uint vid [[vertex_id]]) {
            WebResolveOut out;
            float2 corner = float2(float((vid << 1u) & 2u), float(vid & 2u));
            out.position = float4(corner * 2.0f - 1.0f, 0.0f, 1.0f);
            return out;
        }

        constexpr sampler pointSampler(filter::nearest, address::clamp_to_edge, coord::normalized);
        #endif

        // Where a pixel of the frame reads the coarse targets, from its centre in pixels.
        SHARED float2 webResolveAt(float2 pixel, constant WebUniforms &w) {
            return pixel / w.target.xy;
        }

        // Once per pixel, after the painted dust and before the stars: each slab's carried dust
        // times the web of the disk that filled it. Where two disks carry dust into one slab of
        // one pixel, the later galaxy's web serves both, unless the frame carries each galaxy's
        // dust apart (#399). `carrier` and `tagged` are the coarse targets read at `uv`, the
        // first filtered and the second not. Where nothing was carried (`webCarried` false) the
        // pixel keeps the dust it has.
        SHARED bool webCarried(float4 carrier) {
            return !all(carrier <= 0.0f);
        }

        SHARED half4 webResolved(float2 uv, float4 carrier, float4 tagged, constant DiskFrame *frames,
                                 constant WebUniforms &w, Lace lace) {
            float4 tags = tagged * 255.0f;
            float2 ndc = float2(uv.x * 2.0f - 1.0f, 1.0f - uv.y * 2.0f);
            float3 across = w.right.xyz * (w.forward.w * w.target.z);
            float3 upward = w.up.xyz * w.forward.w;
            float3 ray = w.forward.xyz + ndc.x * across + ndc.y * upward;
            float3 stepX = across * (2.0f / w.target.x);
            float3 stepY = upward * (-2.0f / w.target.y);
            float4 webbed = carrier;
            int last = -1;
            float web = 1.0f;
            for (int s = 0; s < 4; ++s) {
                int g = int(tags[s] + 0.5f) - 1;
                if (carrier[s] <= 0.0f || g < 0) { continue; }
                if (g != last) {
                    web = webAt(frames[g], w, ray, stepX, stepY, lace);
                    last = g;
                }
                webbed[s] = carrier[s] * web;
            }
            return half4(webbed);
        }

        #if defined(__METAL_VERSION__)
        fragment DustTarget webResolveFragment(WebResolveOut in [[stage_in]],
                                               constant DiskFrame *frames [[buffer(0)]],
                                               constant WebUniforms &w [[buffer(1)]],
                                               texture2d<half> lace [[texture(0)]],
                                               texture2d<half> carried [[texture(1)]],
                                               texture2d<half> tagged [[texture(2)]]) {
            float2 uv = webResolveAt(in.position.xy, w);
            float4 carrier = float4(carried.sample(bilinear, uv));
            if (!webCarried(carrier)) { discard_fragment(); }
            DustTarget out;
            out.dust = webResolved(uv, carrier, float4(tagged.sample(pointSampler, uv)), frames, w,
                                   lace);
            return out;
        }

        // What the web's dust gives off, as the grains' glow does: the carried dust times its
        // web, summed over the slabs, in one colour, so the glow follows the filaments.
        fragment LightTarget webGlowFragment(WebResolveOut in [[stage_in]],
                                             constant DiskFrame *frames [[buffer(0)]],
                                             constant WebUniforms &w [[buffer(1)]],
                                             constant float4 &glow [[buffer(2)]],
                                             texture2d<half> lace [[texture(0)]],
                                             texture2d<half> carried [[texture(1)]],
                                             texture2d<half> tagged [[texture(2)]]) {
            float2 uv = webResolveAt(in.position.xy, w);
            float4 carrier = float4(carried.sample(bilinear, uv));
            if (!webCarried(carrier)) { discard_fragment(); }
            float4 webbed = float4(webResolved(uv, carrier, float4(tagged.sample(pointSampler, uv)),
                                               frames, w, lace));
            LightTarget out;
            out.light = half4(half3(glow.rgb * (glow.w * dot(webbed, float4(1.0f)))), 0.0h);
            return out;
        }
        #endif

        // The light a star lays on a pixel of its splat, through everything standing between it
        // and the camera: the slabs in front of its own, plus half of its own. `slab` holds the
        // weights the vertex worked out, so a star picks out the ones it is behind, and `dust` is
        // the finished dust of the pixel, `r2` from the splat's centre.
        SHARED half4 lightPixel(half3 color, half4 slab, half4 dust, float r2) {
            float falloff = exp(-4.5f * r2);
            float column = dot(float4(dust), float4(slab));
            float3 extinction = exp(-column * reddening);
            return half4(color * half3(extinction) * half(falloff), half(falloff));
        }

        #if defined(__METAL_VERSION__)
        fragment LightTarget splatFragment(SplatOut in [[stage_in]],
                                           float2 coord [[point_coord]],
                                           SplatFetch prior) {
            float r2 = splatRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }

            LightTarget out;
            out.light = lightPixel(in.color, in.slab, prior.dust, r2);
            return out;
        }
        #endif

        #if defined(SILLAGE_INSIDE) && defined(__METAL_VERSION__)
        // A pixel of a point star's streak (#297): the star's own profile across the line from
        // its first place to its last.
        fragment LightTarget pointStarFragment(StarOut in [[stage_in]],
                                               float2 coord [[point_coord]],
                                               SplatFetch prior) {
            float share = starShare(coord, in.half_streak, in.radius, in.pixel);
            if (share <= 0.0f) { discard_fragment(); }

            LightTarget out;
            out.light = starPixel(in.color, in.slab, prior.dust, share);
            return out;
        }
        #endif

        // The column pass: one count per emitting particle into coarse cells, which the
        // splat vertex reads back to size a kernel by how many stars share its patch of sky.
        struct CountPoint {
            float4 position;
            float pointSize;
        };

        SHARED CountPoint countPoint(float3 position, uint kind, float born,
                                     constant SplatUniforms &u) {
            CountPoint out;
            out.position = u.viewProjection * float4(position, 1.0f);
            out.pointSize = 1.0f;
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0f)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8f && born < 1e8f && ageMyr >= 0.0f;
            bool absorbing = (kind == 2u && !knot) || kind == 6u;
            if (kind == 3u || absorbing) {
                out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
                out.pointSize = 0.0f;
            }
            return out;
        }

        // The same for a frame that widens its lone kernels: a grain of dust is counted too, into
        // a channel of its own.
        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        SHARED CountPoint countKindPoint(float3 position, uint kind, float born,
                                         constant SplatUniforms &u, thread float &grain) {
            CountPoint out;
            out.position = u.viewProjection * float4(position, 1.0f);
            out.pointSize = 1.0f;
            bool nursery = kind == 1u || kind == 2u;
            float ageMyr = (nursery || born >= 0.0f)
                ? (u.time - born) * u.megayearsPerUnit : -born * u.megayearsPerUnit;
            bool knot = born > -1e8f && born < 1e8f && ageMyr >= 0.0f;
            grain = (kind == 2u && !knot) ? 1.0f : 0.0f;
            if (kind == 3u || kind == 6u) {
                out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
                out.pointSize = 0.0f;
            }
            return out;
        }

        SHARED float4 countKindPixel(float grain) {
            return float4(1.0f - grain, grain, 0.0f, 0.0f);
        }
        #endif

        // A light tracer's, from its state and its word.
        SHARED CountPoint countTracer(float4 state, uint word, constant SplatUniforms &u) {
            return countPoint(state.xyz, (word >> 4) & 7u, state.w, u);
        }

        // What a counted particle adds to the cell it falls in.
        SHARED float4 countPixel() {
            return float4(1.0f, 0.0f, 0.0f, 0.0f);
        }

        #if defined(__METAL_VERSION__)
        struct CountOut {
            float4 position [[position]];
            float pointSize [[point_size]];
        };

        static CountOut countOut(CountPoint point) {
            CountOut out;
            out.position = point.position;
            out.pointSize = point.pointSize;
            return out;
        }

        vertex CountOut countVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const float *formation [[buffer(8)]]) {
            return countOut(countPoint(positions[vid], component[vid], formation[vid], u));
        }

        vertex CountOut countTracerVertex(uint vid [[vertex_id]],
                                          constant SplatUniforms &u [[buffer(4)]],
                                          device const float4 *states [[buffer(18)]],
                                          device const uint *words [[buffer(19)]]) {
            return countOut(countTracer(states[vid], words[vid * 4u + 3u], u));
        }

        fragment float4 countFragment(CountOut in [[stage_in]]) {
            return countPixel();
        }

        #if defined(SILLAGE_INSIDE)
        struct CountKindOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            float grain [[flat]];
        };

        vertex CountKindOut countKindsVertex(uint vid [[vertex_id]],
                                             device const float3 *positions [[buffer(0)]],
                                             device const uint *component [[buffer(3)]],
                                             constant SplatUniforms &u [[buffer(4)]],
                                             device const float *formation [[buffer(8)]]) {
            CountKindOut out;
            float grain = 0.0f;
            CountPoint point = countKindPoint(positions[vid], component[vid], formation[vid], u, grain);
            out.position = point.position;
            out.pointSize = point.pointSize;
            out.grain = grain;
            return out;
        }

        vertex CountKindOut countKindsTracerVertex(uint vid [[vertex_id]],
                                                   constant SplatUniforms &u [[buffer(4)]],
                                                   device const float4 *states [[buffer(18)]],
                                                   device const uint *words [[buffer(19)]]) {
            CountKindOut out;
            float grain = 0.0f;
            CountPoint point = countKindPoint(states[vid].xyz, (words[vid * 4u + 3u] >> 4) & 7u,
                                              states[vid].w, u, grain);
            out.position = point.position;
            out.pointSize = point.pointSize;
            out.grain = grain;
            return out;
        }

        fragment float4 countKindsFragment(CountKindOut in [[stage_in]]) {
            return countKindPixel(in.grain);
        }
        #endif
        #endif

        // The raw look: one fixed-size point per particle in its galaxy's tint, none of the
        // per-particle state the full splat reads. Dark matter is pushed out of the clip volume.
        struct PlainPoint {
            float4 position;
            float pointSize;
            half3 color;
        };

        SHARED PlainPoint plainPoint(float3 position, uint kind, uint galaxy,
                                     constant SplatUniforms &u, constant DiskFrame *frames) {
            PlainPoint out;
            out.position = u.viewProjection * float4(position, 1.0f);
            out.pointSize = u.minimumSize;
            out.color = half3(frames[galaxy].tint.xyz * u.brightness);
            if (kind == 3u || kind == 6u) { out.position = float4(2.0f, 2.0f, 2.0f, 1.0f); }
            return out;
        }

        // A light tracer's, from its state and its word.
        SHARED PlainPoint plainTracer(float4 state, uint word, constant SplatUniforms &u,
                                      constant DiskFrame *frames) {
            return plainPoint(state.xyz, (word >> 4) & 7u, word & 15u, u, frames);
        }

        // What a plain point lays on every pixel of its square.
        SHARED half4 plainPixel(half3 color) {
            return half4(color, half(1.0f));
        }

        // The light a field star lays on a pixel of its point, `r2` from its centre.
        SHARED half4 starfieldPixel(half3 color, half spikes, float2 coord, float r2) {
            float2 d = coord - 0.5f;
            float falloff;
            if (spikes > half(0.0f)) {
                // A field star needs a tight core, otherwise the bloom halo is all that is left
                // of it and the image reads as defocused rather than as a long exposure.
                float ax = abs(d.x) * 2.0f;
                float ay = abs(d.y) * 2.0f;
                float cross = exp(-210.0f * ax * ax - 4.0f * ay)
                            + exp(-210.0f * ay * ay - 4.0f * ax);
                falloff = exp(-13.0f * r2) + float(spikes) * 0.5f * cross;
            } else {
                falloff = exp(-4.5f * r2);
            }

            return half4(color * half(falloff), half(falloff));
        }

        // The textures the post-processing kernels read, side by side as the column's and the
        // lace's are: Metal's own, and four floats a texel in device memory elsewhere (#277).
        #if defined(__METAL_VERSION__)
        typedef texture2d<float, access::read> PostRead;
        typedef texture2d<float, access::sample> PostSample;

        SHARED float3 postRead(PostRead t, uint2 at) { return t.read(at).rgb; }
        SHARED float3 postSample(PostSample t, float2 uv) { return t.sample(bilinear, uv).rgb; }
        SHARED float2 postExtent(PostSample t) { return float2(t.get_width(), t.get_height()); }
        #else
        typedef texels2d PostRead;
        typedef texels2d PostSample;

        SHARED float3 postRead(PostRead t, uint2 at) { return fetch_texel(t, 0u, at.x, at.y).rgb; }
        SHARED float3 postSample(PostSample t, float2 uv) { return sample_bilinear(t, uv).rgb; }
        SHARED float2 postExtent(PostSample t) { return float2(float(t.width), float(t.height)); }
        #endif

        // Box average of the supersampled accumulation down to output resolution, with dust
        // extinction applied on the way. Interstellar dust removes blue far more than red, so a
        // lane crossing a bright disk reads brown rather than grey.
        SHARED float4 resolvePixel(PostRead light, uint2 gid, uint factor) {
            float3 emitted = float3(0.0f);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    emitted += postRead(light, gid * factor + uint2(x, y));
                }
            }
            float3 averaged = emitted / float(factor * factor);
            // Nothing is extinguished here any more. Each star was dimmed by the dust actually
            // in front of it while it was drawn, in the slab pass, so all that is left to do
            // is the box average. What used to happen instead was that the whole dust column
            // of a pixel — in front of the stars and behind them alike — was halved and
            // applied to the total, which cannot make a lane pass in front of anything and
            // only ever pulled the whole galaxy down towards brown.
            return float4(averaged, 1.0f);
        }

        #if defined(SILLAGE_INSIDE) || !defined(__METAL_VERSION__)
        // One of the renders a frame is averaged from, into the picture's light (#297): the box
        // average `resolve` makes, times this render's share, on top of `before`, the renders
        // before it. Every sample is held under what a half float carries, so that a few near
        // stars on one pixel cannot turn it to infinity and the bloom to nothing.
        SHARED float4 insideResolvePixel(PostRead light, uint2 gid, uint factor, float2 share,
                                         float3 before) {
            float3 emitted = float3(0.0f);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    emitted += min(postRead(light, gid * factor + uint2(x, y)), float3(6.0e4f));
                }
            }
            return float4(before + emitted / float(factor * factor) * share.x, 1.0f);
        }
        #endif

        // The plain frames' exposure: asinh, linear in the faint light and logarithmic past it, so
        // a dense core keeps its gradient up to `plainWhite` instead of going white at a few
        // units, and what moves inside it stays readable.
        SHARED_CONSTANT float plainToe = 5.0f;
        SHARED_CONSTANT float plainWhite = 64.0f;

        SHARED float plainCurve(float energy) {
            float x = plainToe * max(energy, 0.0f);
            float w = plainToe * plainWhite;
            return min(log(x + sqrt(x * x + 1.0f)) / log(w + sqrt(w * w + 1.0f)), 1.0f);
        }

        // Box average of the accumulation through the plain curve, in the galaxy's hue.
        SHARED float4 plainCompositePixel(PostRead light, uint2 gid, uint factor, float fade) {
            float3 sum = float3(0.0f);
            for (uint y = 0; y < factor; ++y) {
                for (uint x = 0; x < factor; ++x) {
                    sum += postRead(light, gid * factor + uint2(x, y));
                }
            }
            float3 energy = sum / float(factor * factor);
            float3 curve = float3(plainCurve(energy.x), plainCurve(energy.y), plainCurve(energy.z));
            return float4(pow(curve, 1.0f / 2.2f) * fade, 1.0f);
        }

        SHARED float4 brightPixel(PostSample src, uint2 gid, uint2 size, constant BloomParams &p) {
            float2 uv = (float2(gid) + 0.5f) / float2(size);
            float3 c = postSample(src, uv);
            float brightness = max(c.r, max(c.g, c.b));
            float knee = max(p.threshold * p.softKnee, 1e-5f);
            float soft = clamp(brightness - p.threshold + knee, 0.0f, 2.0f * knee);
            soft = soft * soft / (4.0f * knee);
            float weight = max(soft, brightness - p.threshold) / max(brightness, 1e-5f);
            return float4(c * weight, 1.0f);
        }

        // Kawase dual filter, the downsample half.
        SHARED float4 downsamplePixel(PostSample src, uint2 gid, uint2 size) {
            float2 uv = (float2(gid) + 0.5f) / float2(size);
            float2 hp = 0.5f / postExtent(src);
            float3 sum = postSample(src, uv) * 4.0f;
            sum += postSample(src, uv - hp);
            sum += postSample(src, uv + hp);
            sum += postSample(src, uv + float2(hp.x, -hp.y));
            sum += postSample(src, uv + float2(-hp.x, hp.y));
            return float4(sum / 8.0f, 1.0f);
        }

        // Kawase dual filter, the upsample half, accumulating the finer level underneath.
        SHARED float4 upsamplePixel(PostSample src, PostRead base, uint2 gid, uint2 size) {
            float2 extent = float2(size);
            float2 uv = (float2(gid) + 0.5f) / extent;
            float2 hp = 0.5f / extent;
            float3 sum = postSample(src, uv + float2(-hp.x * 2.0f, 0.0f));
            sum += postSample(src, uv + float2(-hp.x, hp.y)) * 2.0f;
            sum += postSample(src, uv + float2(0.0f, hp.y * 2.0f));
            sum += postSample(src, uv + float2(hp.x, hp.y)) * 2.0f;
            sum += postSample(src, uv + float2(hp.x * 2.0f, 0.0f));
            sum += postSample(src, uv + float2(hp.x, -hp.y)) * 2.0f;
            sum += postSample(src, uv + float2(0.0f, -hp.y * 2.0f));
            sum += postSample(src, uv + float2(-hp.x, -hp.y)) * 2.0f;
            return float4(sum / 12.0f + postRead(base, gid), 1.0f);
        }

        // The light of a source with its surroundings taken off, so a star keeps nearly all of
        // its own and an extended core almost none: what throws thin spikes rather than cones.
        SHARED float4 compactPixel(PostSample point, PostSample broad, uint2 gid, uint2 size,
                                   float amount) {
            float2 uv = (float2(gid) + 0.5f) / float2(size);
            float3 around = postSample(broad, uv);
            return float4(max(postSample(point, uv) - amount * around, 0.0f), 1.0f);
        }

        // Diffraction spikes. A telescope's secondary supports and, on a segmented mirror, the
        // segment edges throw light into a fixed set of directions; six arms for a hexagonal
        // mirror, four for a Cassegrain spider, and on Webb two short ones from the strut.
        // Gathering bright light back along those directions is most of what makes a rendered
        // field read as an exposure.
        SHARED float4 spikesPixel(PostSample src, uint2 gid, uint2 size, constant SpikeParams &p) {
            float2 extent = float2(size);
            float2 uv = (float2(gid) + 0.5f) / extent;
            float3 total = float3(0.0f);
            if (p.arms == 0u || p.samples == 0u) {
                return float4(total, 1.0f);
            }
            for (uint arm = 0; arm < p.arms; ++arm) {
                float angle = p.baseAngle + float(arm) * 6.2831853f / float(p.arms);
                float2 step = float2(cos(angle), sin(angle)) / extent;
                for (uint sample = 1; sample <= p.samples; ++sample) {
                    float t = float(sample) / float(p.samples);
                    total += postSample(src, uv + step * (t * p.length))
                           * exp(-t * p.falloff);
                }
            }
            uint shortSamples = max(8u, uint(float(p.samples) * p.shortScale));
            for (uint arm = 0; arm < p.shortArms; ++arm) {
                float angle = p.shortBaseAngle + float(arm) * 6.2831853f / float(p.shortArms);
                float2 step = float2(cos(angle), sin(angle)) / extent;
                for (uint sample = 1; sample <= shortSamples; ++sample) {
                    float t = float(sample) / float(shortSamples);
                    total += postSample(src, uv + step * (t * p.length * p.shortScale))
                           * exp(-t * p.falloff);
                }
            }
            return float4(total / float(p.samples), 1.0f);
        }

        // The argument is of the order of 1e5, where the last bit of its rounding sets the whole
        // hash, so its fused multiply-add is written out: where it is left to the compiler,
        // Metal fuses it and CUDA, built without contraction, does not (#277).
        SHARED float hash2(float2 v) {
            float x = sin(fma(v.y, 311.7f, v.x * 127.1f)) * 43758.5453f;
            return x - floor(x);
        }

        SHARED float3 acesFilmic(float3 x) {
            const float a = 2.51f, b = 0.03f, c = 2.43f, d = 0.59f, e = 0.14f;
            return saturate((x * (a * x + b)) / (x * (c * x + d) + e));
        }

        SHARED float4 compositePixel(PostRead hdr, PostSample bloom, PostSample spikes, uint2 gid,
                                     uint2 size, constant CompositeParams &p) {
            float2 uv = (float2(gid) + 0.5f) / float2(size);
            float3 energy = postRead(hdr, gid)
                          + postSample(bloom, uv) * p.bloomIntensity
                          + postSample(spikes, uv) * p.spikeIntensity;
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
            if (p.noiseLevel > 0.0f) {
                float2 cell = float2(gid) + p.seed;
                float read = hash2(cell) - 0.5f;
                float shot = hash2(float2(gid) + (p.seed + 17.3f)) - 0.5f;
                float luma = max(dot(energy, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f);
                energy += p.noiseLevel * (read + shot * sqrt(luma) * 4.0f);
                energy = max(energy, 0.0f);
            }
            // Logarithmic stretch, as astronomical imaging does: it keeps faint tidal debris
            // visible without turning the cores into featureless discs.
            float3 lifted = p.stretch > 0.0f
                ? log(1.0f + energy * p.stretch) / log(1.0f + p.stretch)
                : energy;
            // Tone mapping pulls every bright value toward white, so the warm bulge and the
            // blue arms are re-separated around the curve rather than only before it. Doing
            // it all beforehand does not survive: a filmic shoulder desaturates highlights by
            // design, which is right for a photograph and wrong for a galaxy whose core is the
            // most interesting colour in the frame. Half the amount either side gives the same
            // overall push while leaving the bright parts a hue.
            float half_amount = sqrt(max(p.saturation, 0.0f));
            float luma = max(dot(lifted, float3(0.2126f, 0.7152f, 0.0722f)), 0.0f);
            lifted = max(mix(float3(luma), lifted, half_amount), 0.0f);
            luma = max(dot(lifted, float3(0.2126f, 0.7152f, 0.0722f)), 1e-5f);

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
            float white = max(p.whitePoint, 1.0f);
            float toned = luma * (1.0f + luma / (white * white)) / (1.0f + luma);
            float3 preserved = lifted * (toned / luma);

            // Preserving hue can still push a channel past one where the colour is saturated
            // and bright at once. There the filmic curve takes over, because something has to
            // give and losing a little saturation is better than clipping a channel flat.
            float3 filmic = acesFilmic(lifted);
            float over = max(preserved.r, max(preserved.g, preserved.b));
            float3 mapped = mix(preserved, filmic, smoothstep(0.85f, 1.15f, over));
            float mappedLuma = dot(mapped, float3(0.2126f, 0.7152f, 0.0722f));
            mapped = max(mix(float3(mappedLuma), mapped, half_amount), 0.0f);
            mapped = saturate(mapped);
            return float4(pow(mapped, 1.0f / 2.2f) * p.fade, 1.0f);
        }

        #if defined(__METAL_VERSION__)
        struct PlainOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
        };

        static PlainOut plainOut(PlainPoint point) {
            PlainOut out;
            out.position = point.position;
            out.pointSize = point.pointSize;
            out.color = point.color;
            return out;
        }

        vertex PlainOut plainVertex(uint vid [[vertex_id]],
                                    device const float3 *positions [[buffer(0)]],
                                    device const uint *component [[buffer(3)]],
                                    constant SplatUniforms &u [[buffer(4)]],
                                    device const uint *galaxy [[buffer(5)]],
                                    constant DiskFrame *frames [[buffer(6)]]) {
            return plainOut(plainPoint(positions[vid], component[vid], galaxy[vid], u, frames));
        }

        vertex PlainOut plainTracerVertex(uint vid [[vertex_id]],
                                          constant SplatUniforms &u [[buffer(4)]],
                                          constant DiskFrame *frames [[buffer(6)]],
                                          device const float4 *states [[buffer(18)]],
                                          device const uint *words [[buffer(19)]]) {
            return plainOut(plainTracer(states[vid], words[vid * 4u + 3u], u, frames));
        }

        fragment half4 plainFragment(PlainOut in [[stage_in]]) {
            return plainPixel(in.color);
        }

        fragment LightTarget starfieldFragment(SplatOut in [[stage_in]],
                                               float2 coord [[point_coord]]) {
            float r2 = splatRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }

            LightTarget out;
            out.light = starfieldPixel(in.color, in.spikes, coord, r2);
            return out;
        }

        kernel void resolve(texture2d<float, access::read> light [[texture(0)]],
                            texture2d<float, access::write> dst [[texture(2)]],
                            constant uint &factor [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(resolvePixel(light, gid, factor), gid);
        }

        #if defined(SILLAGE_INSIDE)
        kernel void insideResolve(texture2d<float, access::read> light [[texture(0)]],
                                  texture2d<float, access::read_write> dst [[texture(2)]],
                                  constant uint &factor [[buffer(0)]],
                                  constant float2 &share [[buffer(1)]],
                                  uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            float3 before = share.y > 0.5f ? dst.read(gid).rgb : float3(0.0f);
            dst.write(insideResolvePixel(light, gid, factor, share, before), gid);
        }
        #endif

        kernel void plainComposite(texture2d<float, access::read> light [[texture(0)]],
                                   texture2d<float, access::write> output [[texture(2)]],
                                   constant uint &factor [[buffer(0)]],
                                   constant float &fade [[buffer(1)]],
                                   uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            output.write(plainCompositePixel(light, gid, factor, fade), gid);
        }

        kernel void brightPass(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               constant BloomParams &p [[buffer(0)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(brightPixel(src, gid, uint2(dst.get_width(), dst.get_height()), p), gid);
        }

        kernel void downsample(texture2d<float, access::sample> src [[texture(0)]],
                               texture2d<float, access::write> dst [[texture(1)]],
                               uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(downsamplePixel(src, gid, uint2(dst.get_width(), dst.get_height())), gid);
        }

        kernel void upsampleAdd(texture2d<float, access::sample> src [[texture(0)]],
                                texture2d<float, access::read> base [[texture(1)]],
                                texture2d<float, access::write> dst [[texture(2)]],
                                uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(upsamplePixel(src, base, gid, uint2(dst.get_width(), dst.get_height())), gid);
        }

        kernel void compactLight(texture2d<float, access::sample> point [[texture(0)]],
                                 texture2d<float, access::sample> broad [[texture(1)]],
                                 texture2d<float, access::write> dst [[texture(2)]],
                                 constant float &amount [[buffer(0)]],
                                 uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(
                compactPixel(point, broad, gid, uint2(dst.get_width(), dst.get_height()), amount),
                gid);
        }

        kernel void diffractionSpikes(texture2d<float, access::sample> src [[texture(0)]],
                                      texture2d<float, access::write> dst [[texture(1)]],
                                      constant SpikeParams &p [[buffer(0)]],
                                      uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) { return; }
            dst.write(spikesPixel(src, gid, uint2(dst.get_width(), dst.get_height()), p), gid);
        }

        kernel void composite(texture2d<float, access::read> hdr [[texture(0)]],
                              texture2d<float, access::sample> bloom [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              texture2d<float, access::sample> spikes [[texture(3)]],
                              constant CompositeParams &p [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]]) {
            if (gid.x >= output.get_width() || gid.y >= output.get_height()) { return; }
            output.write(
                compositePixel(hdr, bloom, spikes, gid,
                               uint2(output.get_width(), output.get_height()), p),
                gid);
        }
        #endif
        """
}
