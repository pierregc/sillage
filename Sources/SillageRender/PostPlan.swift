import SillageCore

/// What `brightPass` reads; mirrors `BloomParams` in `Shaders`.
public struct BloomParams: Sendable {
    public var threshold: Float
    public var softKnee: Float
    public var pad0: Float = 0
    public var pad1: Float = 0

    public init(threshold: Float, softKnee: Float) {
        self.threshold = threshold
        self.softKnee = softKnee
    }
}

/// What `composite` reads; mirrors `CompositeParams` in `Shaders`.
public struct CompositeParams: Sendable {
    public var bloomIntensity: Float
    public var stretch: Float
    public var saturation: Float
    public var spikeIntensity: Float
    public var skyLevel: Float
    public var noiseLevel: Float
    public var seed: Float
    public var whitePoint: Float
    public var fade: Float = 1
    public var skyRed: Float = 0.36
    public var skyGreen: Float = 0.42
    public var skyBlue: Float = 0.60

    public init(
        bloomIntensity: Float, stretch: Float, saturation: Float, spikeIntensity: Float,
        skyLevel: Float, noiseLevel: Float, seed: Float, whitePoint: Float, fade: Float = 1,
        skyRed: Float = 0.36, skyGreen: Float = 0.42, skyBlue: Float = 0.60
    ) {
        self.bloomIntensity = bloomIntensity
        self.stretch = stretch
        self.saturation = saturation
        self.spikeIntensity = spikeIntensity
        self.skyLevel = skyLevel
        self.noiseLevel = noiseLevel
        self.seed = seed
        self.whitePoint = whitePoint
        self.fade = fade
        self.skyRed = skyRed
        self.skyGreen = skyGreen
        self.skyBlue = skyBlue
    }
}

/// What `diffractionSpikes` reads; mirrors `SpikeParams` in `Shaders`.
public struct SpikeParams: Sendable {
    public var arms: UInt32
    public var baseAngle: Float
    public var length: Float
    public var falloff: Float
    public var samples: UInt32
    public var shortArms: UInt32 = 0
    public var shortBaseAngle: Float = 0
    public var shortScale: Float = 0

    public init(
        arms: UInt32, baseAngle: Float, length: Float, falloff: Float, samples: UInt32,
        shortArms: UInt32 = 0, shortBaseAngle: Float = 0, shortScale: Float = 0
    ) {
        self.arms = arms
        self.baseAngle = baseAngle
        self.length = length
        self.falloff = falloff
        self.samples = samples
        self.shortArms = shortArms
        self.shortBaseAngle = shortBaseAngle
        self.shortScale = shortScale
    }
}

/// The film grain's place in a run of frames. Each frame drawn moves it on, so that the grain
/// does not hold still, and a run that resumes (#240) or a still drawn from the middle of a
/// video moves it on by the frames it did not draw.
public struct FrameGrain: Sendable {
    public private(set) var seed: Float = 1

    public init() {}

    /// The seed of the next frame.
    @discardableResult
    public mutating func advance() -> Float {
        seed = seed.truncatingRemainder(dividingBy: 4096) + 7.13
        return seed
    }

    /// Moves the grain on as `count` frames drawn would.
    public mutating func skip(_ count: Int) {
        for _ in 0..<max(count, 0) { advance() }
    }
}

/// The passes that turn a frame's supersampled light into its picture, and the images they run
/// on, worked out once for the Metal renderer and for the CUDA one (#277). Each executes `passes`
/// in order through a switch with no default, so a pass added here stops both from compiling
/// until they run it. The kernels are the shared MSL of `Shaders`; the plan is what chains them.
public struct PostPlan: Sendable {
    public struct Size: Sendable, Equatable {
        public var width: Int
        public var height: Int
    }

    /// An image a pass reads or writes: a texture on Metal, floats in device memory on CUDA.
    public enum Image: Sendable, Hashable {
        /// The supersampled light the particle passes accumulated, which no pass writes.
        case light
        /// The light averaged down to the picture's size.
        case resolved
        /// A level of the bloom's pyramid going down, then going up. Level 0 is half the size.
        case down(Int)
        case up(Int)
        /// The source of sharp spikes, and their result, at a quarter of the picture's size.
        case sharpSource
        case sharpSpikes
        /// The result of the broad spikes, at half the picture's size.
        case spikes
        /// The picture, before it is made into bytes.
        case output
    }

    public enum Pass: Sendable {
        /// `resolve`: the light, averaged `factor` by `factor` down into `resolved`.
        case resolve(factor: Int)
        /// `plainComposite`: the raw look's average and exposure curve, light to output.
        case plainComposite(factor: Int, fade: Float)
        /// `brightPass`: `resolved` into the pyramid's first level.
        case bright(BloomParams)
        /// `downsample`: `down(level - 1)` into `down(level)`.
        case downsample(level: Int)
        /// `upsampleAdd`: `source`, upsampled, and `down(level - 1)` added, into `up(level - 1)`.
        case upsample(level: Int, source: Image)
        /// `compactLight`: `down(1)` less `amount` of `down(broad)`, into `sharpSource`.
        case compact(amount: Float, broad: Int)
        /// `diffractionSpikes`.
        case spikes(SpikeParams, source: Image, into: Image)
        /// `composite`: `resolved`, the bloom and the spikes into `output`.
        case composite(CompositeParams, bloom: Image, spikes: Image)
    }

    /// The size of every image of a frame, which the renderers allocate from: the bloom's levels
    /// halve down from half the picture's size while they stay at 8 by 8 or more.
    public struct Sizes: Sendable, Equatable {
        public var light: Size
        public var picture: Size
        public var levels: [Size]
        public var spikes: Size
        public var sharp: Size

        public func size(of image: Image) -> Size {
            switch image {
            case .light: light
            case .resolved, .output: picture
            case .down(let level), .up(let level): levels[level]
            case .sharpSource, .sharpSpikes: sharp
            case .spikes: spikes
            }
        }
    }

    /// Light a spike has to carry before it is drawn.
    public static let spikeVisible: Float = 0.0001
    /// Webb's horizontal strut spikes, as a fraction of the long ones.
    public static let webbShortArm: Float = 0.4

    public var passes: [Pass]
    public var sizes: Sizes

    public static func sizes(for settings: RenderSettings) -> Sizes {
        var levels: [Size] = []
        var width = settings.width / 2
        var height = settings.height / 2
        while levels.count < settings.bloomLevels && width >= 8 && height >= 8 {
            levels.append(Size(width: width, height: height))
            width /= 2
            height /= 2
        }
        let scale = settings.supersample
        return Sizes(
            light: Size(
                width: max(settings.width * scale, 1), height: max(settings.height * scale, 1)),
            picture: Size(width: max(settings.width, 1), height: max(settings.height, 1)),
            levels: levels,
            spikes: Size(width: max(settings.width / 2, 1), height: max(settings.height / 2, 1)),
            sharp: Size(width: max(settings.width / 4, 1), height: max(settings.height / 4, 1)))
    }

    /// The passes of a frame drawn with `settings`, shown at `fade` (1 the picture, 0 black).
    /// A frame that is not the raw look moves `grain` on, as each frame drawn does.
    public init(settings: RenderSettings, fade: Float, grain: inout FrameGrain) {
        let sizes = Self.sizes(for: settings)
        self.sizes = sizes
        let visible = min(max(fade, 0), 1)
        if settings.plain {
            passes = [.plainComposite(factor: settings.supersample, fade: visible)]
            return
        }

        var passes: [Pass] = [.resolve(factor: settings.supersample)]
        let levels = sizes.levels.count
        let bloomOn = settings.bloomIntensity > 0
        let spikesOn = settings.spikeArms > 0 && settings.spikeIntensity >= Self.spikeVisible
        // A sharp spike source is the light one bloom level down, a little wider than a pixel so
        // taps two pixels apart do not bead, less the broad light two levels further down.
        let broadLevel = min(3, levels - 1)
        let sharp = spikesOn && settings.spikeSharpness > 0 && broadLevel > 1
        if levels > 0, bloomOn || spikesOn {
            passes.append(
                .bright(
                    BloomParams(
                        threshold: settings.bloomThreshold, softKnee: settings.bloomSoftKnee)))
            for level in 1..<levels where bloomOn || (sharp && level <= broadLevel) {
                passes.append(.downsample(level: level))
            }
        }

        var bloomResult: Image? = bloomOn && levels > 0 ? .down(levels - 1) : nil
        if bloomOn, levels > 1, var source = bloomResult {
            for level in stride(from: levels - 1, to: 0, by: -1) {
                passes.append(.upsample(level: level, source: source))
                source = .up(level - 1)
            }
            bloomResult = source
        }

        // Spikes are gathered from the bright pass, so they pick up stars and galaxy cores
        // rather than the whole frame.
        var spike = SpikeParams(
            arms: UInt32(max(settings.spikeArms, 0)), baseAngle: 0.32, length: settings.spikeLength,
            falloff: 4.2, samples: 28)
        // A sharp source is a pixel or two wide at quarter size, so the taps have to be that
        // close or a spike comes out as a string of beads. Lengths are in half-size pixels.
        if sharp {
            spike.length = settings.spikeLength / 2
            spike.samples = UInt32(min(max(28, settings.spikeLength / 2.5), 96))
        }
        if settings.spikePattern == .webb {
            spike.baseAngle = .pi / 2
            spike.shortArms = 2
            spike.shortScale = Self.webbShortArm
        }
        var spikeSource: Image = levels > 0 ? .down(0) : .resolved
        let spikeResult: Image = sharp ? .sharpSpikes : .spikes
        if sharp {
            passes.append(
                .compact(amount: min(max(settings.spikeSharpness, 0), 1), broad: broadLevel))
            spikeSource = .sharpSource
        }
        if spikesOn { passes.append(.spikes(spike, source: spikeSource, into: spikeResult)) }

        let composite = CompositeParams(
            bloomIntensity: bloomResult == nil ? 0 : settings.bloomIntensity,
            stretch: settings.stretch, saturation: settings.saturation,
            spikeIntensity: spikesOn ? settings.spikeIntensity : 0, skyLevel: settings.skyLevel,
            noiseLevel: settings.noiseLevel, seed: grain.advance(),
            whitePoint: settings.whitePoint, fade: visible, skyRed: settings.skyColour.x,
            skyGreen: settings.skyColour.y, skyBlue: settings.skyColour.z)
        passes.append(
            .composite(
                composite, bloom: bloomResult ?? .resolved, spikes: spikesOn ? spikeResult : .resolved))
        self.passes = passes
    }
}
