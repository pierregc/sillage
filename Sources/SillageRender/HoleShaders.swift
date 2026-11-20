/// The black hole close up (#314) in Metal Shading Language: the torn cloud's tracers stepped in
/// Paczyński and Wiita's potential with a grid of the mean flow for the gas, and drawn where the
/// hole shows them. Compiled after `Shaders.source`, whose black body and post stages it uses.
enum HoleShaders {
    static let source = """
        #include <metal_stdlib>
        using namespace metal;

        // What is outside `#if defined(__METAL_VERSION__)` is shared with the CUDA engine, which
        // compiles it through cuda/include/msl_compat.h after Shaders, whose black body it calls
        // (#336, docs/notes/one-kernel-source.md).
        // kernel-sources: after Shaders
        #if defined(__METAL_VERSION__)
        #define SHARED static
        #define SHARED_CONSTANT constant
        #endif

        struct HoleStepParams {
            uint count;
            float timeStep;
            float swallow;
            float subStepAngle;
            uint maximumSubSteps;
            uint gridRadii;
            uint gridAngles;
            uint gridHeights;
            float logInner;
            float logScale;
            float heightCell;
            float stickiness;
            float crossing;
            float viscosity;
            float cooling;
        };

        SHARED float holeDynamical(float r) { return max(r - 1.0f, 1e-3f) * sqrt(r); }

        SHARED float3 holePull(float3 x) {
            float r = length(x);
            float d = max(r - 1.0f, 1e-3f);
            return -x / (r * d * d);
        }

        // Where a point falls on the grid of the mean flow, in cells: log of the cylindrical
        // radius, the angle round the hole, and the height over the radius, so that a cell is as
        // tall as it is wide; false outside it. One layer of height is the plane's grid alone.
        SHARED bool holeCell(float3 x, constant HoleStepParams &p, thread float3 &cell) {
            float r = length(x.xy);
            if (r <= 0.0f) { return false; }
            float u = (log(r) - p.logInner) * p.logScale - 0.5f;
            if (u < 0.0f || u >= float(p.gridRadii) - 1.0f) { return false; }
            float v = (atan2(x.y, x.x) / (2.0f * M_PI_F) + 0.5f) * float(p.gridAngles) - 0.5f;
            float w = 0.0f;
            if (p.gridHeights > 1u) {
                w = x.z / (r * p.heightCell) + 0.5f * float(p.gridHeights) - 0.5f;
                if (w < 0.0f || w >= float(p.gridHeights) - 1.0f) { return false; }
            }
            cell = float3(u, v, w);
            return true;
        }

        SHARED uint holeWrap(int j, uint n) { return uint((j % int(n) + int(n)) % int(n)); }

        // The eight cells round a point, trilinear, as an index and a weight each.
        SHARED uint holeCorner(float3 cell, constant HoleStepParams &p, uint corner,
                               thread float &weight) {
            float3 base = floor(cell);
            float3 f = cell - base;
            uint di = corner & 1u;
            uint dj = (corner >> 1) & 1u;
            uint dk = corner >> 2;
            weight = (di == 1u ? f.x : 1.0f - f.x) * (dj == 1u ? f.y : 1.0f - f.y)
                * (dk == 1u ? f.z : 1.0f - f.z);
            uint k = uint(base.z) + dk;
            return ((uint(base.x) + di) * p.gridAngles + holeWrap(int(base.y) + int(dj), p.gridAngles))
                * p.gridHeights + k;
        }

        SHARED uint holeCorners(constant HoleStepParams &p) { return p.gridHeights > 1u ? 8u : 4u; }

        // The grid's sums are kept as 64-bit fixed point, 2^24 to the unit, in two 32-bit words a
        // value, low first. Integers add the same in any order, so a run repeats to the bit,
        // which float atomics summed in whatever order the threads come do not (#332).
        SHARED void holeClearCell(device uint4 *fixed, uint cells, uint id) {
            if (id < 2u * cells) { fixed[id] = uint4(0u); }
        }

        SHARED void holeAddFixed(device atomic_uint *slot, float value) {
            ulong bits = as_type<ulong>(long(rint(value * 16777216.0f)));
            uint low = uint(bits & 0xffffffffUL);
            uint high = uint(bits >> 32);
            uint before = atomic_fetch_add_explicit(&slot[0], low, memory_order_relaxed);
            if (before + low < before) { high += 1u; }
            if (high != 0u) { atomic_fetch_add_explicit(&slot[1], high, memory_order_relaxed); }
        }

        // The fixed point sums back as the floats `holeStep` reads.
        SHARED void holeResolveCell(device const uint *fixed, device float4 *grid, uint cells, uint id) {
            if (id >= cells) { return; }
            float4 sum;
            for (uint c = 0; c < 4u; ++c) {
                uint at = (id * 4u + c) * 2u;
                ulong bits = ulong(fixed[at]) | (ulong(fixed[at + 1u]) << 32);
                sum[c] = float(as_type<long>(bits)) / 16777216.0f;
            }
            grid[id] = sum;
        }

        // Each tracer's velocity, and one for the count, shared among the eight cells around it.
        SHARED void holeDepositTracer(device const float4 *positions, device const float4 *velocities,
                                      device atomic_uint *grid, constant HoleStepParams &p, uint id) {
            if (id >= p.count) { return; }
            float4 v = velocities[id];
            if (v.w < 0.0f) { return; }
            float3 cell;
            if (!holeCell(positions[id].xyz, p, cell)) { return; }
            for (uint corner = 0; corner < holeCorners(p); ++corner) {
                float w;
                uint index = holeCorner(cell, p, corner, w) * 4u;
                holeAddFixed(&grid[(index + 0u) * 2u], w * v.x);
                holeAddFixed(&grid[(index + 1u) * 2u], w * v.y);
                holeAddFixed(&grid[(index + 2u) * 2u], w * v.z);
                holeAddFixed(&grid[(index + 3u) * 2u], w);
            }
        }

        // The tracers in each column of the grid, over every height.
        SHARED void holeColumnSum(device const float4 *grid, device float *column, constant HoleStepParams &p,
                                  uint id) {
            if (id >= p.gridRadii * p.gridAngles) { return; }
            float sum = 0.0f;
            for (uint k = 0; k < p.gridHeights; ++k) { sum += grid[id * p.gridHeights + k].w; }
            column[id] = sum;
        }

        // One step of a tracer: the gas's stickiness pulls its velocity towards the mean flow
        // of the others round it where streams cross, and the viscosity takes some of its
        // turning, both into heat; the heat it radiates, kept as a light that fades over a
        // fraction of an orbit; then the hole's pull in as many leapfrog sub-steps as its
        // radius asks for, as `TidalDisruption.advance`. Position w holds the light, velocity w
        // the tracers per unit area round it, or -1 once the tracer is swallowed.
        SHARED void holeStepTracer(device float4 *positions, device float4 *velocities,
                                   device const float4 *grid, device const float *column,
                                   constant HoleStepParams &p, uint id) {
            if (id >= p.count) { return; }
            float4 pw = positions[id];
            float4 vw = velocities[id];
            if (vw.w < 0.0f) { return; }
            float3 x = pw.xyz;
            float3 v = vw.xyz;
            float dt = p.timeStep;
            float r = length(x);
            float orbit = 2.0f * M_PI_F * holeDynamical(r);
            float heat = 0.0f;
            float density = 0.0f;
            float3 cell;
            if (holeCell(x, p, cell)) {
                float4 sum = float4(0.0f);
                float own = 0.0f;
                for (uint corner = 0; corner < holeCorners(p); ++corner) {
                    float w;
                    uint index = holeCorner(cell, p, corner, w);
                    sum += w * grid[index];
                    own += w * w;
                }
                // What the tracer deposited itself is not a neighbour's motion.
                sum -= own * float4(v, 1.0f);
                float3 base = floor(cell);
                float3 f = cell - base;
                float area = 0.0f;
                for (uint corner = 0; corner < 4u; ++corner) {
                    uint di = corner & 1u;
                    uint dj = corner >> 1;
                    float w = (di == 1u ? f.x : 1.0f - f.x) * (dj == 1u ? f.y : 1.0f - f.y);
                    area += w * column[(uint(base.x) + di) * p.gridAngles
                                       + holeWrap(int(base.y) + int(dj), p.gridAngles)];
                }
                float rc = exp(p.logInner + (cell.x + 0.5f) / p.logScale);
                density = area / (rc * rc / p.logScale * 2.0f * M_PI_F / float(p.gridAngles));
                if (p.stickiness > 0.0f && sum.w > 1.0f) {
                    // Only motion against the mean flow faster than a share of the orbit's own
                    // speed is a crossing. A stream's own stretch and shear is slower than that
                    // and stays cold, as gas expanding does, instead of glowing from the start.
                    float3 relative = v - sum.xyz / sum.w;
                    float speed = length(relative);
                    float slow = p.crossing * sqrt(r) / max(r - 1.0f, 1e-3f);
                    if (speed > slow) {
                        float3 excess = relative * (1.0f - slow / speed);
                        float keep = exp(-dt * p.stickiness / orbit);
                        v -= excess * (1.0f - keep);
                        heat += 0.5f * dot(excess, excess) * (1.0f - keep * keep);
                    }
                }
            }
            float around = length(x.xy);
            if (p.viscosity > 0.0f && around > 0.0f) {
                float2 along = float2(-x.y, x.x) / around;
                float turning = dot(v.xy, along);
                float keep = exp(-dt * p.viscosity / orbit);
                v.xy -= along * (turning * (1.0f - keep));
                heat += 0.5f * turning * turning * (1.0f - keep * keep);
            }
            float fade = exp(-dt / max(p.cooling, dt));
            float light = pw.w * fade + heat / dt * (1.0f - fade);

            uint count = uint(clamp(ceil(dt / (p.subStepAngle * holeDynamical(r))), 1.0f,
                                    float(p.maximumSubSteps)));
            float h = dt / float(count);
            bool swallowed = false;
            for (uint s = 0; s < count; ++s) {
                v += holePull(x) * (h * 0.5f);
                x += v * h;
                if (length(x) < p.swallow) { swallowed = true; break; }
                v += holePull(x) * (h * 0.5f);
            }
            positions[id] = float4(x, light);
            velocities[id] = float4(v, swallowed ? -1.0f : density);
        }

        struct HoleSplatUniforms {
            float4x4 viewProjection;
            /// The camera's position, the hole at the origin, and its distance from the hole.
            float4 camera;
            float projectionScale;
            float particleSize;
            float minimumSize;
            float maximumSize;
            float brightness;
            float hottest;
            uint image;
            uint lensed;
            uint radiusCount;
            uint angleCount;
            float lensInner;
            float lensSpan;
            float beaming;
            float shadowAngle;
            uint temperature;
            float crossingScale;
            float lightScale;
            float ambient;
            float innerEdge;
            float edgePeak;
            float supersample;
            /// Field stars instead of tracers: their light in position w, kelvin in velocity w.
            uint stars;
            /// The camera distances of the two lens tables round the camera's, and the far
            /// one's share.
            float lensNear;
            float lensFar;
            float lensBlend;
            /// Below this brightness, the images that go round the hole are drawn for that share
            /// of the tracers, as many times brighter.
            float thinning;
        };

        // What a tracer's point carries, without the attributes Metal's stage struct adds.
        struct HoleSplat {
            float4 position;
            float pointSize;
            half3 color;
        };

        // The lens table as `HoleLens.lookup` reads it: bilinear between the four cells round
        // the point, and no image where one of them has none.
        SHARED float4 holeLens(device const float4 *lens, constant HoleSplatUniforms &u, uint image,
                               float r, float phi) {
            float column = clamp(phi / M_PI_F * float(u.angleCount) - 0.5f, 0.0f,
                                 float(u.angleCount - 1u));
            float row = clamp(log(max(r, u.lensInner) / u.lensInner) / u.lensSpan
                              * float(u.radiusCount - 1u), 0.0f, float(u.radiusCount - 1u));
            uint j0 = uint(column);
            uint i0 = uint(row);
            uint j1 = min(j0 + 1u, u.angleCount - 1u);
            uint i1 = min(i0 + 1u, u.radiusCount - 1u);
            float tj = column - float(j0);
            float ti = row - float(i0);
            uint base = image * u.radiusCount * u.angleCount;
            float4 a = lens[base + i0 * u.angleCount + j0];
            float4 b = lens[base + i0 * u.angleCount + j1];
            float4 c = lens[base + i1 * u.angleCount + j0];
            float4 d = lens[base + i1 * u.angleCount + j1];
            if (min(min(a.w, b.w), min(c.w, d.w)) <= 0.0f) { return float4(0.0f); }
            return mix(mix(a, b, tj), mix(c, d, tj), ti);
        }

        SHARED float holeStraight(float r, float phi, float ro) {
            return atan2(r * sin(phi), ro - r * cos(phi));
        }

        // What `HoleLensSet.blend` interpolates between tables: the direct image's bend, the
        // others' impact parameter.
        SHARED float holeAlong(float4 entry, float ro, uint image, float r, float phi) {
            return image == 0u ? entry.x - holeStraight(r, phi, ro)
                               : sin(entry.x) * ro / sqrt(1.0f - 1.0f / ro);
        }

        // The two tables round the camera's distance blended as `HoleLensSet.blend` does.
        SHARED float4 holeLensBlend(device const float4 *nearLens, device const float4 *farLens,
                                    constant HoleSplatUniforms &u, uint image, float r, float phi) {
            float t = u.lensBlend;
            float4 a = t < 1.0f ? holeLens(nearLens, u, image, r, phi) : float4(0.0f);
            float4 b = t > 0.0f ? holeLens(farLens, u, image, r, phi) : float4(0.0f);
            bool hasA = a.w > 0.0f && t < 1.0f;
            bool hasB = b.w > 0.0f && t > 0.0f;
            if (!hasA && !hasB) { return float4(0.0f); }
            float q;
            float2 direction;
            float weight;
            if (hasA && hasB) {
                q = mix(holeAlong(a, u.lensNear, image, r, phi), holeAlong(b, u.lensFar, image, r, phi), t);
                float2 mixed = mix(a.yz, b.yz, t);
                direction = mixed / max(length(mixed), 1e-12f);
                weight = mix(a.w, b.w, t);
            } else if (hasA) {
                q = holeAlong(a, u.lensNear, image, r, phi);
                direction = a.yz;
                weight = a.w * (1.0f - t);
            } else {
                q = holeAlong(b, u.lensFar, image, r, phi);
                direction = b.yz;
                weight = b.w * t;
            }
            float ro = u.camera.w;
            float alpha = image == 0u ? q + holeStraight(r, phi, ro)
                                      : asin(clamp(q * sqrt(1.0f - 1.0f / ro) / ro, 0.0f, 1.0f));
            return float4(alpha, direction, weight);
        }

        // A number in [0, 1) fixed by `seed`, so a tracer's draw does not flicker between frames.
        SHARED float holeChance(uint seed) {
            seed ^= seed >> 16;
            seed *= 0x7feb352du;
            seed ^= seed >> 15;
            seed *= 0x846ca68bu;
            seed ^= seed >> 16;
            return float(seed >> 8) * (1.0f / 16777216.0f);
        }

        SHARED HoleSplat holeCulled() {
            HoleSplat out;
            out.position = float4(2.0f, 2.0f, 2.0f, 1.0f);
            out.pointSize = 0.0f;
            out.color = half3(half(0.0f));
            return out;
        }

        // A tracer where the hole shows it: its temperature, from its radius as a thin disk has
        // it or from the heat the run gave it; the image the table puts it at; the Doppler shift
        // of its motion along the light's last direction and the redshift of climbing out.
        SHARED HoleSplat holeSplat(uint vid, device const float4 *positions, device const float4 *velocities,
                                   constant HoleSplatUniforms &u, device const float4 *lens,
                                   device const float4 *farLens) {
            float4 pw = positions[vid];
            float4 vw = velocities[vid];
            if (vw.w < 0.0f && u.stars == 0u) { return holeCulled(); }
            float3 p = pw.xyz;
            float r = length(p);
            // Where the lens puts it first: most of the further images' tracers stop there.
            float3 eye = u.camera.xyz;
            float ro = u.camera.w;
            float3 axis = normalize(eye);
            float3 sight = p - eye;
            float distance = length(sight);
            float3 shown = p;
            float weight = 1.0f;
            float3 leaving = -sight / distance;
            if (u.lensed != 0u) {
                float phi = acos(clamp(dot(axis, p) / r, -1.0f, 1.0f));
                float3 across = p - dot(p, axis) * axis;
                float aside = length(across);
                float3 e = aside > 1e-6f * r ? across / aside
                         : normalize(cross(axis, abs(axis.z) < 0.9f ? float3(0.0f, 0.0f, 1.0f)
                                                                     : float3(1.0f, 0.0f, 0.0f)));
                float4 entry = holeLensBlend(lens, farLens, u, u.image, r, phi);
                if (entry.w <= 0.0f) { return holeCulled(); }
                weight = entry.w;
                if (u.image > 0u && u.thinning > 0.0f) {
                    float share = min(entry.w / u.thinning, 1.0f);
                    if (holeChance(vid * 3u + u.image) >= share) { return holeCulled(); }
                    weight = entry.w / share;
                }
                float side = u.image == 1u ? -1.0f : 1.0f;
                float3 direction = -axis * cos(entry.x) + e * (side * sin(entry.x));
                shown = eye + direction * distance;
                float3 outward = p / r;
                float3 along = (-sin(phi) * axis + cos(phi) * e) * side;
                leaving = entry.y * outward + entry.z * along;
            } else if (distance > ro) {
                // Drawn straight, the hole hides what is behind it within the shadow.
                float3 toward = -axis;
                if (dot(sight, toward) / distance > cos(u.shadowAngle)) { return holeCulled(); }
            }

            float kelvin;
            float light;
            if (u.stars != 0u) {
                kelvin = vw.w;
                light = pw.w;
            } else if (u.temperature == 0u) {
                // Shakura and Sunyaev: T falls as r to the -3/4 past the last stable orbit,
                // where the torque vanishes and the disk with it.
                float x = u.innerEdge / max(r, 1e-3f);
                float shape = x >= 1.0f ? 0.0f : pow(x, 0.75f) * pow(1.0f - sqrt(x), 0.25f) / u.edgePeak;
                kelvin = u.hottest * shape;
                light = shape * shape * shape * shape * u.lightScale + u.ambient;
            } else {
                // From the run: the light a tracer gives is the heat it radiates, and the
                // temperature goes as the fourth root of that light per unit area.
                float flux = max(pw.w, 0.0f) * max(vw.w, 0.0f) * u.crossingScale;
                kelvin = u.hottest * sqrt(sqrt(flux));
                light = max(pw.w, 0.0f) * u.lightScale + u.ambient;
            }
            if (light <= 0.0f) { return holeCulled(); }

            // Paczyński and Wiita's speeds pass light's inside the last stable orbit, where gas
            // plunges: held at what general relativity gives there, about 0.6 c.
            float3 beta = vw.xyz / sqrt(2.0f);
            float speed = length(beta);
            beta *= min(speed, 0.62f) / max(speed, 1e-6f);
            float doppler = sqrt(1.0f - dot(beta, beta)) / (1.0f - dot(beta, leaving));
            float climb = sqrt(max(1.0f - 1.0f / r, 1e-3f) / (1.0f - 1.0f / ro));
            float shift = mix(1.0f, doppler * climb, u.beaming);

            HoleSplat out;
            out.position = u.viewProjection * float4(shown, 1.0f);
            if (out.position.w <= 0.0f) { return holeCulled(); }
            float span = clamp(u.particleSize * u.projectionScale / out.position.w, u.minimumSize,
                               u.maximumSize);
            out.pointSize = span;
            float flux = u.brightness * light * weight * shift * shift * shift * shift;
            float spread = 18.0f / (M_PI_F * span * span) * u.supersample * u.supersample;
            // Half floats overflow at 65504, and an infinite pixel turns the bloom round it black:
            // no splat may bring more than a share of that.
            float3 color = blackbody(kelvin * shift) * min(flux * spread, 2000.0f);
            if (any(isnan(color))) { return holeCulled(); }
            out.color = half3(color);
            return out;
        }

        SHARED float holeRadius2(float2 coord) {
            float2 d = coord - 0.5f;
            return dot(d, d) * 4.0f;
        }

        SHARED half4 holeSplatPixel(half3 color, float r2) {
            return half4(color * half(exp(-4.5f * r2)), half(0.0f));
        }
        #if defined(__METAL_VERSION__)
        kernel void holeClear(device uint4 *fixed [[buffer(0)]],
                              constant uint &cells [[buffer(1)]],
                              uint id [[thread_position_in_grid]]) {
            holeClearCell(fixed, cells, id);
        }

        kernel void holeResolve(device const uint *fixed [[buffer(0)]],
                                device float4 *grid [[buffer(1)]],
                                constant uint &cells [[buffer(2)]],
                                uint id [[thread_position_in_grid]]) {
            holeResolveCell(fixed, grid, cells, id);
        }

        kernel void holeDeposit(device const float4 *positions [[buffer(0)]],
                                device const float4 *velocities [[buffer(1)]],
                                device atomic_uint *grid [[buffer(2)]],
                                constant HoleStepParams &p [[buffer(3)]],
                                uint id [[thread_position_in_grid]]) {
            holeDepositTracer(positions, velocities, grid, p, id);
        }

        kernel void holeColumn(device const float4 *grid [[buffer(0)]],
                               device float *column [[buffer(1)]],
                               constant HoleStepParams &p [[buffer(2)]],
                               uint id [[thread_position_in_grid]]) {
            holeColumnSum(grid, column, p, id);
        }

        kernel void holeStep(device float4 *positions [[buffer(0)]],
                             device float4 *velocities [[buffer(1)]],
                             device const float4 *grid [[buffer(2)]],
                             device const float *column [[buffer(4)]],
                             constant HoleStepParams &p [[buffer(3)]],
                             uint id [[thread_position_in_grid]]) {
            holeStepTracer(positions, velocities, grid, column, p, id);
        }

        struct HoleSplatOut {
            float4 position [[position]];
            float pointSize [[point_size]];
            half3 color;
        };

        vertex HoleSplatOut holeSplatVertex(uint vid [[vertex_id]],
                                            device const float4 *positions [[buffer(0)]],
                                            device const float4 *velocities [[buffer(1)]],
                                            constant HoleSplatUniforms &u [[buffer(2)]],
                                            device const float4 *lens [[buffer(3)]],
                                            device const float4 *farLens [[buffer(4)]]) {
            HoleSplat splat = holeSplat(vid, positions, velocities, u, lens, farLens);
            HoleSplatOut out;
            out.position = splat.position;
            out.pointSize = splat.pointSize;
            out.color = splat.color;
            return out;
        }

        fragment half4 holeSplatFragment(HoleSplatOut in [[stage_in]],
                                         float2 coord [[point_coord]]) {
            float r2 = holeRadius2(coord);
            if (r2 > 1.0f) { discard_fragment(); }
            return holeSplatPixel(in.color, r2);
        }
        #endif
        """
}
