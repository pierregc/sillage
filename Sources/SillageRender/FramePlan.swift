import SillageCore
#if canImport(simd)
    import simd
#else
    import Foundation
#endif

/// What every particle pass reads of the frame; mirrors `SplatUniforms` in `Shaders`.
public struct SplatUniforms: Sendable {
    public var viewProjection: simd_float4x4
    /// Simulated time of this frame and how to read it in megayears, so a knot's colour and
    /// brightness can be worked out from its own age rather than painted from a pattern.
    public var time: Float
    public var megayearsPerUnit: Float
    public var ionisedMyr: Float
    public var ionisingRiseMyr: Float
    public var ionisedStrength: Float
    public var populationYoungMyr: Float
    public var populationSpan: Float
    public var populationLast: Float
    public var luminosityNormalisation: Float
    public var brightness: Float
    public var dustStrength: Float
    public var starSize: Float
    public var projectionScale: Float
    public var smoothingScale: Float
    public var referenceArea: Float
    public var minimumSize: Float
    public var maximumSize: Float
    public var galaxyTint: Float
    public var slabNear: Float
    public var slabScale: Float
    public var pass: UInt32
    public var mapped: UInt32 = 0
    public var holeShadow: Float = 0
    public var columnSmoothing: Float = 0
    public var columnCell: Float = 8
    public var glint: Float = 1
}

/// The passes of one frame that draw particles and what they are given, worked out once for
/// the Metal renderer and for the CUDA one (#276). Each executes `passes` in order through a
/// switch with no default, so a pass added here stops both from compiling until they draw it.
public struct FramePlan: Sendable {
    public enum Pass: Sendable, Equatable, CaseIterable {
        /// One count for each particle that emits, into the coarse cells a splat sizes its
        /// kernel from. Over every drawn particle, whatever part of the frame is being drawn.
        case column
        /// The dust the web multiplies, into the coarse carrier and its tags, which start
        /// empty.
        case webCarrier
        /// The field stars, behind everything and dimmed by nothing.
        case starfield
        /// The grains' dust, each into its depth slab.
        case dust
        /// The same under the web: what the painted strands lay.
        case paintedDust
        /// The carrier times the web of the disk tagged there, once a pixel, into the dust.
        case webResolve
        /// Everything that emits, each pixel through the finished dust standing in front.
        case stars
        /// The raw look's points, alone in their frame.
        case plain

        /// The value of `SplatUniforms.pass` the pass is drawn with.
        public var stage: UInt32 { self == .stars ? 1 : 0 }
    }

    /// Accumulation pixels per column-density cell, per axis.
    public static let columnCell = 8

    public var passes: [Pass]
    /// Whether the light and the dust start empty. False for a later part of a frame drawn in
    /// several, which adds to what the parts before left.
    public var clears: Bool
    /// With `pass` at 0: `uniforms(for:)` gives a pass its own.
    public var splat: SplatUniforms
    /// Nil when the frame draws no web.
    public var web: WebUniforms?

    public func uniforms(for pass: Pass) -> SplatUniforms {
        var uniforms = splat
        uniforms.pass = pass.stage
        return uniforms
    }

    /// Whether these settings ask for the dust web in a part of a frame that draws `stages`.
    public static func drawsWeb(_ settings: RenderSettings, stages: ClosedRange<UInt32> = 0...1) -> Bool {
        !settings.plain && settings.dustWeb > 0 && stages.contains(0)
    }

    /// The size of the supersampled light and dust, of the column density's cells and of the
    /// web's coarse carrier.
    public static func accumulationSize(_ settings: RenderSettings) -> (width: Int, height: Int) {
        (settings.width * settings.supersample, settings.height * settings.supersample)
    }

    public static func columnSize(_ settings: RenderSettings) -> (width: Int, height: Int) {
        let scale = settings.supersample
        return (
            settings.plain ? 1 : settings.width * scale / columnCell,
            settings.plain ? 1 : settings.height * scale / columnCell
        )
    }

    public static func carrierSize(_ settings: RenderSettings) -> (width: Int, height: Int) {
        let size = accumulationSize(settings)
        return (max(size.width / DustWeb.carrierCoarse, 1), max(size.height / DustWeb.carrierCoarse, 1))
    }

    /// `laceScale` is one over the baked lace's mean, nil when the frame draws no web: the
    /// look asks for none, or the renderer could not build it. `stages` and `first` draw part
    /// of the frame into what earlier parts left: stage 0 is the dust and 1 the stars, and the
    /// first part alone counts the column and draws the field stars.
    public init(
        settings: RenderSettings, camera: Camera, time: Float, drawnCount: Int, tracerCount: Int,
        luminosityNormalisation: Float, mapped: Bool, laceScale: Float?,
        stages: ClosedRange<UInt32> = 0...1, first: Bool = true
    ) {
        let scale = settings.supersample
        let aspect = Float(settings.width) / Float(settings.height)
        if settings.plain {
            passes = [.plain]
            clears = true
            web = nil
            splat = SplatUniforms(
                viewProjection: camera.viewProjection(aspectRatio: aspect),
                time: time, megayearsPerUnit: 0, ionisedMyr: 0, ionisingRiseMyr: 0,
                ionisedStrength: 0, populationYoungMyr: 0, populationSpan: 0, populationLast: 0,
                luminosityNormalisation: 1,
                brightness: settings.brightness * 1_000_000 / Float(max(drawnCount + tracerCount, 1)),
                dustStrength: 0, starSize: 0, projectionScale: 0, smoothingScale: 0,
                referenceArea: 0, minimumSize: settings.minimumKernel * Float(scale),
                maximumSize: 0, galaxyTint: 1, slabNear: 0, slabScale: 0, pass: 0)
            return
        }

        // Pixels per unit length at unit depth. The vertex shader divides a particle's
        // smoothing length by its view depth to get the kernel's size on screen.
        let projectionScale =
            Float(settings.height * scale) / (2 * tan(camera.fieldOfView / 2))
        // Conserving flux per particle already makes surface brightness independent of the
        // zoom, so no separate area correction is needed here.
        //
        // Over the particles that reach a pixel, not over every particle simulated. Dividing
        // by the whole count meant that turning live halos on dimmed a scene by the halo
        // ratio — two and a half at the default — because three particles in five are dark
        // matter that never lands on a pixel. Exposure per drawn particle is what keeps a
        // scene looking the same whether it runs at 500 000 stars or at twenty million,
        // which is the whole point of normalising by count at all.
        let perParticle = 1_000_000 / Float(max(drawnCount + tracerCount, 1))

        // The stack of depth slabs, centred on what the camera is pointed at and as deep as
        // the frame is wide. A disk seen at any angle at all spans several of them, which is
        // what lets its near side shadow its far side; seen exactly face-on it does not, and
        // it should not — a thin disk seen flat has no lane in front of anything.
        let distance = simd_length(camera.eye - camera.target)
        let halfExtent = distance * tan(camera.fieldOfView / 2)
        let slabNear = distance - halfExtent

        splat = SplatUniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            time: time,
            megayearsPerUnit: Float(Physics.megayearsPerTimeUnit),
            ionisedMyr: StarFormation.ionisedMyr,
            ionisingRiseMyr: StarFormation.ionisingRiseMyr,
            ionisedStrength: StarFormation.ionisedStrength,
            populationYoungMyr: Float(StellarPopulation.youngestMyr),
            populationSpan: log(Float(StellarPopulation.oldestMyr / StellarPopulation.youngestMyr)),
            populationLast: Float(StellarPopulation.samples - 1),
            luminosityNormalisation: luminosityNormalisation,
            brightness: settings.brightness * perParticle,
            dustStrength: settings.dustStrength * perParticle,
            starSize: settings.starSize * Float(scale),
            projectionScale: projectionScale,
            smoothingScale: settings.smoothingScale,
            referenceArea: 0.01,
            minimumSize: settings.minimumKernel * Float(scale),
            maximumSize: settings.maximumKernel * Float(scale),
            galaxyTint: settings.galaxyTint,
            slabNear: slabNear,
            slabScale: 1 / max(2 * halfExtent, 1e-3),
            pass: 0, mapped: mapped ? 1 : 0, holeShadow: settings.holeShadow,
            columnSmoothing: settings.columnSmoothing, columnCell: Float(Self.columnCell),
            glint: settings.glint)

        // Its own passes, so a look without the web draws what it always drew.
        let webbed = Self.drawsWeb(settings, stages: stages) && laceScale != nil
        if webbed {
            let forward = simd_normalize(camera.target - camera.eye)
            let right = simd_normalize(simd_cross(forward, camera.up))
            let up = simd_cross(right, forward)
            web = WebUniforms(
                eye: SIMD4(camera.eye, min(max(settings.dustWeb, 0), 1)),
                right: SIMD4(right, DustWeb.carrier),
                up: SIMD4(up, time),
                params: SIMD4(
                    DustWeb.rest, DustWeb.cellShare, DustWeb.smallestCell, DustWeb.largestCell),
                forward: SIMD4(forward, tan(camera.fieldOfView / 2)),
                target: SIMD4(
                    Float(settings.width * scale), Float(settings.height * scale), aspect,
                    laceScale ?? 1),
                carrier: SIMD4(Float(DustWeb.carrierCoarse), DustWeb.carrierSmallest, 0, 0))
        } else {
            web = nil
        }

        var passes: [Pass] = []
        // The column pass, once per frame over every drawn particle: counts into coarse
        // cells, which the splat vertex reads back to size its kernel in projection.
        if first, settings.columnSmoothing > 0 { passes.append(.column) }
        // The dust the web multiplies, coarse, before the pass that multiplies it.
        if webbed { passes.append(.webCarrier) }
        if first, settings.starCount > 0 { passes.append(.starfield) }
        // The dust first, so that its opacity is standing in its target when the stars are
        // drawn and read it back.
        for stage in stages {
            if stage == 0 {
                passes.append(webbed ? .paintedDust : .dust)
                // Once per pixel, before any star reads the dust back.
                if webbed { passes.append(.webResolve) }
            } else {
                passes.append(.stars)
            }
        }
        self.passes = passes
        clears = first
    }
}
