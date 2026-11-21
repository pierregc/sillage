import Foundation
import SillageCore

#if canImport(simd)
    import simd
#endif

/// What a flight's frames are drawn with once the camera goes into a galaxy (#297,
/// docs/notes/inside-a-galaxy.md): the `inside` block of a flight file, every field optional.
/// The defaults are the settings #296 arrived at and Pierre chose (variant C, rich point stars).
/// Far from any matter every one of them leaves the frame as the export draws it.
public struct InsideSettings: Codable, Sendable, Equatable {
    /// Point stars a near particle's light is handed to; 0 draws none.
    public var stars = 128
    /// The most a particle draws once its kernel covers more of the frame than `nearFrom`: its
    /// count grows as the square of the kernel's size past that, as a star field resolves more
    /// of its faint stars the nearer it is (#357).
    public var nearStars = 4096
    /// The kernel's size on screen, as a share of the frame's height, past which a particle
    /// draws more than `stars`.
    public var nearFrom: Float = 0.3
    /// A star's share of the light falls as its rank to minus this: 1 gives a few bright stars
    /// over a crowd of faint ones, 0 equal shares.
    public var starShare: Float = 1
    /// Each star's share is drawn around its rank's from a Pareto tail of this index, its mean
    /// kept: most stars a little fainter, two in a hundred five times brighter or more, as rare
    /// giants stand out of a population (#357). 0 for the rank's share alone.
    public var starTail: Float = 1.5
    /// How far the stars' colours are drawn around their population's, 0 for the particle's own.
    public var starColours: Float = 1
    /// Pixels of a frame 2160 high: a star covers the same share of the frame at any size (#357).
    public var starSize: Float = 1.5
    /// The most light a star lays, against what the tone curve takes to white: past it a star
    /// keeps its size and gains a glint, not a disk of bloom (#357).
    public var starPeak: Float = 2
    /// Kernel lengths the stars of a particle are scattered over.
    public var starSpread: Float = 1
    /// The shares of the look's kernel ceiling between which a particle's light goes over from
    /// its splat to its stars.
    public var starFrom: Float = 0.05
    public var starFull: Float = 0.2
    /// The near field, in kiloparsecs from the eye: stars and the capped kernels' law apply
    /// wholly nearer than the first, not at all past the second.
    public var field: [Float] = [3, 8]
    /// Kernel lengths over which a particle fades before the near plane; 0 for none.
    public var fade: Float = 3
    /// Where the dust's depth slabs start from the eye once inside, in kiloparsecs.
    public var slabs: [Float] = [0.3, 1.5, 7.5]
    /// The distances to the nearest matter between which the slabs slide from the eye's layout
    /// (nearer than the first) to the one around the aim point every export has (past the second).
    public var slabsWithin: [Float] = [1.5, 6]
    /// How near a disk, in its radii (seven scale lengths), the lace of its dust web is carried
    /// through the depth of its dust layer: wholly within the first, not at all past the second,
    /// where it lies in the mid-plane as every export draws it (#354).
    public var web: [Float] = [1, 2]
    /// The near dust's structure finer than a grain (#356): filaments and clumps from a noise in
    /// three dimensions read through each grain of the near field, the log of its density spread
    /// this many times its noise's (log-normal, as interstellar gas is); 0 for none.
    public var dustFine: Float = 1.75
    /// The coarsest cell of that structure along a disk's plane, in kiloparsecs, half that across
    /// it; two finer octaves follow it.
    public var dustCell: Float = 0.12
    /// What the dust opacity of a disk the eye is in is multiplied by (#356): a look's dust is set
    /// for a galaxy seen whole, and seen along a disk's plane from inside it the column was three
    /// to six times a real lane's. Another galaxy seen whole from there keeps its lanes.
    public var dustInside: Float = 0.3
    /// The distances to the nearest matter between which that trim comes in: wholly nearer than
    /// the first, not at all past the second.
    public var dustWithin: [Float] = [0.5, 2]
    /// The mean luminance the automatic exposure holds a frame under; 0 turns it off.
    public var exposure: Float = 0.16
    /// Seconds of video the automatic exposure is eased over.
    public var exposureEase = 1.0
    /// The most renders a frame is averaged from when the camera moves fast near matter; 1 for
    /// no motion blur.
    public var subframes = 8
    /// The share of a frame's interval the shutter stays open.
    public var shutter = 0.5

    public init() {}

    public init(from decoder: any Decoder) throws {
        try rejectUnknownFields(decoder, CodingKeys.self)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        stars = try c.value(.stars, or: stars)
        nearStars = try c.value(.nearStars, or: nearStars)
        nearFrom = try c.value(.nearFrom, or: nearFrom)
        starShare = try c.value(.starShare, or: starShare)
        starTail = try c.value(.starTail, or: starTail)
        starColours = try c.value(.starColours, or: starColours)
        starSize = try c.value(.starSize, or: starSize)
        starPeak = try c.value(.starPeak, or: starPeak)
        starSpread = try c.value(.starSpread, or: starSpread)
        starFrom = try c.value(.starFrom, or: starFrom)
        starFull = try c.value(.starFull, or: starFull)
        field = try c.value(.field, or: field)
        fade = try c.value(.fade, or: fade)
        slabs = try c.value(.slabs, or: slabs)
        slabsWithin = try c.value(.slabsWithin, or: slabsWithin)
        web = try c.value(.web, or: web)
        dustFine = try c.value(.dustFine, or: dustFine)
        dustCell = try c.value(.dustCell, or: dustCell)
        dustInside = try c.value(.dustInside, or: dustInside)
        dustWithin = try c.value(.dustWithin, or: dustWithin)
        exposure = try c.value(.exposure, or: exposure)
        exposureEase = try c.value(.exposureEase, or: exposureEase)
        subframes = try c.value(.subframes, or: subframes)
        shutter = try c.value(.shutter, or: shutter)
    }

    /// The first thing wrong with the settings, nil when they can be drawn.
    public var fault: String? {
        func rising(_ values: [Float], _ count: Int) -> Bool {
            values.count == count && values.allSatisfy { $0 > 0 && $0.isFinite }
                && zip(values, values.dropFirst()).allSatisfy { $0 < $1 }
        }
        if !(0...1024).contains(stars) { return "stars \(stars): 0 to 1024" }
        if !(stars...16_384).contains(nearStars) { return "nearStars \(nearStars): stars to 16384" }
        if !(nearFrom > 0 && nearFrom <= 4) { return "nearFrom \(nearFrom): above 0, to 4" }
        if !(starShare >= 0 && starShare <= 2) { return "starShare \(starShare): 0 to 2" }
        if !(starTail == 0 || (starTail >= 1.1 && starTail <= 8)) {
            return "starTail \(starTail): 0, or 1.1 to 8"
        }
        if !(starColours >= 0 && starColours <= 2) { return "starColours \(starColours): 0 to 2" }
        if !(starSize >= 0.5 && starSize <= 16) { return "starSize \(starSize) px: 0.5 to 16" }
        if !(starPeak > 0 && starPeak <= 1000) { return "starPeak \(starPeak): above 0, to 1000" }
        if !(starSpread > 0 && starSpread <= 8) { return "starSpread \(starSpread): above 0, to 8" }
        if !(starFrom >= 0 && starFrom < starFull && starFull <= 1) {
            return "starFrom \(starFrom) and starFull \(starFull): shares of the ceiling, the first lower"
        }
        if !rising(field, 2) { return "field \(field): two distances in kpc, the first nearer" }
        if !(fade >= 0 && fade <= 32) { return "fade \(fade): 0 to 32 kernel lengths" }
        if !rising(slabs, 3) { return "slabs \(slabs): three distances in kpc, each past the one before" }
        if !rising(slabsWithin, 2) {
            return "slabsWithin \(slabsWithin): two distances in kpc, the first nearer"
        }
        if !rising(web, 2) { return "web \(web): two distances in disk radii, the first nearer" }
        if !(dustFine >= 0 && dustFine <= 2.5) { return "dustFine \(dustFine): 0 to 2.5" }
        if !(dustCell >= 0.005 && dustCell <= 1) { return "dustCell \(dustCell) kpc: 0.005 to 1" }
        if !(dustInside > 0 && dustInside <= 4) { return "dustInside \(dustInside): above 0, to 4" }
        if !rising(dustWithin, 2) {
            return "dustWithin \(dustWithin): two distances in kpc, the first nearer"
        }
        if !(exposure >= 0 && exposure < 1) { return "exposure \(exposure): a mean luminance, 0 to 1" }
        if !(exposureEase >= 0 && exposureEase <= 30) { return "exposureEase \(exposureEase) s: 0 to 30" }
        if !(1...64).contains(subframes) { return "subframes \(subframes): 1 to 64" }
        if !(shutter > 0 && shutter <= 1) { return "shutter \(shutter): above 0, to 1" }
        return nil
    }
}

/// What one frame of a flight hands its renderer: the settings, and how far the eye is from
/// matter there.
public struct InsideFrame: Sendable, Equatable {
    public var settings: InsideSettings
    /// Kiloparsecs from the eye to the nearest matter (`Nearness`).
    public var nearness: Float
    /// Where a flight's frame lays its slabs past the near field (`MatterDepth`), empty for the
    /// stack around the aim point.
    public var matter: [Float]
    /// How much the camera is still the look's: 1 at a flight's look keys, where the frame is
    /// the export's, 0 from `Flight.slabEase` seconds away (#355).
    public var look: Float

    public init(settings: InsideSettings, nearness: Float, matter: [Float] = [], look: Float = 0) {
        self.settings = settings
        self.nearness = nearness
        self.matter = matter
        self.look = look
    }
}

/// Mirrors `InsideUniforms` in `Shaders`, which a frame drawn from inside reads behind its
/// `SplatUniforms`.
public struct InsideUniforms: Sendable {
    public var nextViewProjection: simd_float4x4
    public var slabKnots: SIMD4<Float>
    public var slabEnd: Float
    public var slabSoft: Float
    public var nearPlane: Float
    public var fadeLengths: Float
    public var windowNear: Float
    public var windowFar: Float
    public var starStart: Float
    public var starEnd: Float
    public var starSpread: Float
    public var starPointSize: Float
    public var starShareExponent: Float
    public var starShareNorm: Float
    public var starColours: Float
    public var starNearest: Float = 0.001
    public var starCap: Float = 30_000
    public var starCount: UInt32
    public var projectionX: Float
    public var projectionY: Float
    /// The most stars a particle draws, and the kernel's size in accumulation pixels past which
    /// it draws more than `starCount`.
    public var nearStars: Float
    public var nearFrom: Float
    /// The Pareto index each star's share is drawn with, 0 for none.
    public var starTail: Float
    /// The near dust's fine structure and its coarsest cell in kpc, and what the frame's dust
    /// opacity is multiplied by (#356).
    public var dustFine: Float
    public var dustCell: Float
    public var dustTrim: Float

    /// How far inside the eye is for the slabs: 0 past `slabsWithin`'s far distance from any
    /// matter, 1 nearer than its near one.
    public static func depth(_ frame: InsideFrame) -> Float {
        let (near, far) = (frame.settings.slabsWithin[0], frame.settings.slabsWithin[1])
        let t = min(max((frame.nearness - near) / (far - near), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// How far inside the eye is for the dust's trim: 0 past `dustWithin`'s far distance from any
    /// matter, 1 nearer than its near one.
    public static func dustDepth(_ frame: InsideFrame) -> Float {
        let (near, far) = (frame.settings.dustWithin[0], frame.settings.dustWithin[1])
        let t = min(max((frame.nearness - near) / (far - near), 0), 1)
        return 1 - t * t * (3 - 2 * t)
    }

    /// `splat` is the frame's own, whose slab stack around the aim point the knots start from.
    /// `next` is the camera a moment later, to where the point stars' streaks run; nil, or the
    /// same camera, draws them as points.
    public init(
        _ frame: InsideFrame, camera: Camera, next: Camera? = nil, settings: RenderSettings,
        splat: SplatUniforms
    ) {
        let inside = frame.settings
        nextViewProjection = (next ?? camera).viewProjection(
            aspectRatio: Float(settings.width) / Float(max(settings.height, 1)))
        let scale = Float(settings.supersample)
        // The stack every export has: four slabs of a quarter of its thickness from its near face.
        let thickness = 1 / max(splat.slabScale, 1e-9)
        let aim = (0...4).map { max(splat.slabNear + Float($0) * thickness / 4, 1e-6) }
        // From the eye: the three boundaries given, and a slab's worth before and after.
        let ratio = (inside.slabs[2] / inside.slabs[0]).squareRoot()
        let eye = [inside.slabs[0] / ratio] + inside.slabs + [inside.slabs[2] * ratio]
        func blend(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] {
            t > 0 ? zip(a, b).map { exp(log($0) + (log($1) - log($0)) * t) } : a
        }
        let within = Self.depth(frame)
        // A flight's frame keeps its slabs in the matter and soft at every distance, nothing
        // switching as the camera moves, but on the look's own camera (#355).
        let away = frame.matter.count == 5 ? 1 - min(max(frame.look, 0), 1) : 0
        let far = away > 0 ? blend(aim, frame.matter, away) : aim
        let knots = blend(far, eye, within)
        slabKnots = SIMD4(knots[0], knots[1], knots[2], knots[3])
        slabEnd = knots[4]
        slabSoft = max(within, away)
        nearPlane = camera.near
        fadeLengths = inside.fade
        windowNear = inside.field[0]
        windowFar = inside.field[1]
        // Against the frame's height, so that 1080p and 4K turn the same particles to the same
        // stars (#357): the ceiling of a frame 1080 high, the size of one 2160 high.
        let lines = Float(settings.height) * scale
        let ceiling = settings.maximumKernel * lines / 1080
        starStart = inside.starFrom * ceiling
        starEnd = inside.starFull * ceiling
        starSpread = inside.starSpread
        // A star narrower than a pixel shares its light among the pixels it touches.
        starPointSize = max(inside.starSize * lines / 2160, 0.5)
        starShareExponent = inside.starShare
        starShareNorm = Self.shareNorm(stars: inside.stars, exponent: inside.starShare)
        starColours = inside.starColours
        starCap = Self.cap(peak: inside.starPeak, size: starPointSize, scale: scale, settings: settings)
        starCount = UInt32(max(inside.stars, 0))
        nearStars = Float(max(inside.nearStars, inside.stars))
        nearFrom = inside.nearFrom * lines
        starTail = inside.starTail
        dustFine = inside.dustFine
        dustCell = inside.dustCell
        dustTrim = 1 + (inside.dustInside - 1) * Self.dustDepth(frame)
        projectionY = 1 / tan(camera.fieldOfView / 2)
        projectionX = projectionY * Float(settings.height) / Float(max(settings.width, 1))
    }

    /// What a frame that is not drawn from inside reads there, on an engine whose passes always
    /// hold the inside of a galaxy (#347): no near field, no stars, no fade, the slabs of `splat`.
    /// Every line the inside adds to a pass then leaves its arithmetic as it was.
    public init(outside splat: SplatUniforms) {
        nextViewProjection = splat.viewProjection
        slabKnots = .zero
        slabEnd = 0
        slabSoft = 0
        nearPlane = 0
        fadeLengths = 0
        // Every depth is past the window.
        windowNear = -2e38
        windowFar = -1e38
        starStart = 0
        starEnd = 0
        starSpread = 0
        starPointSize = 0
        starShareExponent = 0
        starShareNorm = 0
        starColours = 0
        starCount = 0
        projectionX = 1
        projectionY = 1
        nearStars = 0
        nearFrom = 0
        starTail = 0
        dustFine = 0
        dustCell = 0
        dustTrim = 1
    }

    /// The most light a star's pixel takes, in the light of the accumulation, so that the one
    /// output pixel it falls in reaches `peak` times the energy the tone curve takes to white.
    /// Its profile over a point `size` pixels across holds 0.1736 of its centre times its area.
    public static func cap(peak: Float, size: Float, scale: Float, settings: RenderSettings) -> Float {
        let white = max(settings.whitePoint, 1)
        let stretch = settings.stretch
        let energy = stretch > 0 ? (pow(1 + stretch, white) - 1) / stretch : white
        return peak * energy * scale * scale / (0.1736 * size * size)
    }

    /// The sum of the first `count` stars' shares before the norm, for any count, as the shader's
    /// `insideShareSum` works it out.
    public static func shareSum(_ count: Float, exponent: Float) -> Float {
        guard count > 1 else { return max(count, 0) }
        let integral =
            abs(exponent - 1) < 1e-3 ? log(count) : (pow(count, 1 - exponent) - 1) / (1 - exponent)
        let third = exponent * (exponent + 1) * (exponent + 2) / 720 * (1 - pow(count, -exponent - 3))
        return integral + 0.5 * (1 + pow(count, -exponent)) + exponent / 12 * (1 - pow(count, -exponent - 1))
            - third
    }

    /// One over the sum of every star's share, so they add up to their particle's light.
    public static func shareNorm(stars: Int, exponent: Float) -> Float {
        stars > 0 ? 1 / shareSum(Float(stars), exponent: exponent) : 1
    }
}

/// `SplatUniforms` with `InsideUniforms` behind it, as the passes of a frame drawn from inside
/// read them (#297): Metal's library of such a frame, and every pass of the CUDA engine (#347).
public struct InsideSplatUniforms: Sendable {
    public var splat: SplatUniforms
    public var inside: InsideUniforms

    public init(splat: SplatUniforms, inside: InsideUniforms) {
        self.splat = splat
        self.inside = inside
    }
}

/// How far an eye is from matter: the distance within which a ten-thousandth of the drawn
/// particles lie. One stray particle does not make a camera "inside", a few hundred do, and
/// the distance cannot change faster than the eye moves or the particles do, so what is keyed
/// on it never jumps.
public enum Nearness {
    /// The particles within the distance, for `count` drawn.
    public static func rank(of count: Int) -> Int { min(max(count / 10_000, 1), max(count, 1)) }

    /// The distance from `eye` to the `rank`-th nearest of `count` points laid out as the
    /// renderer's positions are, sixteen bytes apart. Exact, whatever the thread count.
    public static func distance(
        from eye: SIMD3<Float>, to points: UnsafeRawPointer, count: Int, rank: Int? = nil
    ) -> Float {
        guard count > 0 else { return .infinity }
        let rank = min(max(rank ?? Self.rank(of: count), 1), count)
        let stride = MemoryLayout<SIMD3<Float>>.stride
        // A float's bits rise with it: the top twelve are a histogram bin an eighth of an octave
        // wide.
        func bin(_ squared: Float) -> Int { Int(squared.bitPattern >> 20) }
        func squared(_ index: Int) -> Float {
            let p = points.load(fromByteOffset: index * stride, as: SIMD3<Float>.self)
            let d = p - eye
            let value = d.x * d.x + d.y * d.y + d.z * d.z
            return value.isFinite ? value : .greatestFiniteMagnitude
        }
        let chunks = max(min(ProcessInfo.processInfo.activeProcessorCount, count / 65_536), 1)
        let bins = 2048
        var histograms = [Int](repeating: 0, count: chunks * bins)
        histograms.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let all = buffer
            concurrentPerform(iterations: chunks) { chunk in
                let base = chunk * bins
                for index in (chunk * count / chunks)..<((chunk + 1) * count / chunks) {
                    all[base + bin(squared(index))] += 1
                }
            }
        }
        var seen = 0
        var holding = bins - 1
        for candidate in 0..<bins {
            let here = (0..<chunks).reduce(0) { $0 + histograms[$1 * bins + candidate] }
            if seen + here >= rank {
                holding = candidate
                break
            }
            seen += here
        }
        var held: [Float] = []
        for index in 0..<count {
            let value = squared(index)
            if bin(value) == holding { held.append(value) }
        }
        held.sort()
        let at = min(max(rank - seen - 1, 0), max(held.count - 1, 0))
        return held.isEmpty ? .infinity : held[at].squareRoot()
    }
}

/// Where a flight lays its slabs of dust once the eye is out of the near field (#355): around
/// the matter in the frame rather than the aim point, each slab `slabShare` times as deep as that
/// matter, from its second to its ninety-eighth percentile of view depth. The stack every export
/// has is centred on the aim point and as deep as the frame is wide, so receding from a disk seen
/// edge on it grew and slid through the disk, and a lane went in and out of its bulge's slab;
/// laid on the matter, the slabs keep their place in it at every distance and wherever the
/// camera aims, and soft, nothing switches as a boundary passes.
public enum MatterDepth {
    /// The shares of the drawn particles in the frame the matter's depth is read between.
    public static let shares: (near: Float, far: Float) = (0.02, 0.98)
    /// A slab's depth against the matter's: about what the export's stack gives a galaxy it
    /// frames, the near side of a disk seen from 100 kpc a slab ahead of the far side.
    public static let slabShare: Float = 0.75
    /// The thinnest the matter is taken to be, as a share of its distance.
    public static let thinnest: Float = 0.01

    /// The five knots, nil with nothing in the frame. The depths' histogram by their float bits,
    /// 128 bins an octave, read through linearly: a particle crossing a bin's edge or the frame's
    /// moves a knot by a share of a bin over the bin's count, so the knots move as smoothly as
    /// the camera does.
    public static func knots(
        camera: Camera, aspectRatio: Float, points: UnsafeRawPointer, count: Int
    ) -> [Float]? {
        guard count > 0 else { return nil }
        let matrix = camera.viewProjection(aspectRatio: aspectRatio)
        let stride = MemoryLayout<SIMD3<Float>>.stride
        let near = max(camera.near, 1e-6)
        func bin(_ depth: Float) -> Int { Int(depth.bitPattern >> 16) }
        let bins = Int(Float.greatestFiniteMagnitude.bitPattern >> 16) + 1
        let chunks = max(min(ProcessInfo.processInfo.activeProcessorCount, count / 65_536), 1)
        var histograms = [Int32](repeating: 0, count: chunks * bins)
        histograms.withUnsafeMutableBufferPointer { buffer in
            nonisolated(unsafe) let all = buffer
            concurrentPerform(iterations: chunks) { chunk in
                let base = chunk * bins
                for index in (chunk * count / chunks)..<((chunk + 1) * count / chunks) {
                    let p = points.load(fromByteOffset: index * stride, as: SIMD3<Float>.self)
                    let clip = matrix * SIMD4(p, 1)
                    guard clip.w > near, clip.w.isFinite, abs(clip.x) <= clip.w, abs(clip.y) <= clip.w
                    else { continue }
                    all[base + bin(clip.w)] += 1
                }
            }
        }
        var counts = [Int](repeating: 0, count: bins)
        for b in 0..<bins {
            for chunk in 0..<chunks { counts[b] += Int(histograms[chunk * bins + b]) }
        }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }
        var (b, seen) = (0, 0)
        func depth(at share: Float) -> Float {
            let rank = Double(share) * Double(total)
            while b < bins - 1, Double(seen + counts[b]) < rank {
                seen += counts[b]
                b += 1
            }
            let low = Float(bitPattern: UInt32(b) << 16)
            let high = Float(bitPattern: UInt32(b + 1) << 16)
            let t = counts[b] > 0 ? Float(min(max((rank - Double(seen)) / Double(counts[b]), 0), 1)) : 0
            return low + (high - low) * t
        }
        let (front, back) = (depth(at: shares.near), depth(at: shares.far))
        let middle = (front + back) / 2
        let slab = max(back - front, middle * thinnest) * slabShare
        let start = max(middle - 2 * slab, near)
        return (0...4).map { start + Float($0) * slab }
    }
}

/// How many renders a frame is averaged from (#297): one for each `step` pixels the matter at
/// `nearness` crosses while the shutter is open, as the eye moves and the camera turns. Every
/// render draws the point stars as the streaks they leave during its share of that time, so the
/// renders are for what is not a point, a dust lane's edge or a splat, and a few are enough. Only
/// in the near field, where there are stars to streak: none, the frame drawn once through its
/// own camera, wherever the camera is at rest, or farther from matter than the field reaches.
public enum InsideBlur {
    /// Output pixels the near matter may cross between two renders.
    public static let step: Float = 4
    /// Under this many pixels over the whole shutter, the frame is still.
    public static let still: Float = 0.1

    public static func subframes(
        from opening: Camera, to closing: Camera, frame: InsideFrame, height: Int
    ) -> Int {
        let most = frame.settings.subframes
        let (near, far) = (frame.settings.field[0], frame.settings.field[1])
        guard most > 1, frame.nearness < far else { return 0 }
        let t = min(max((frame.nearness - near) / (far - near), 0), 1)
        let within = 1 - t * t * (3 - 2 * t)
        let scale = Float(height) / (2 * tan(opening.fieldOfView / 2))
        let moved = simd_length(closing.eye - opening.eye) / max(frame.nearness, 1e-4)
        let (a, b) = (opening.target - opening.eye, closing.target - closing.eye)
        let (la, lb) = (simd_length(a), simd_length(b))
        var turned: Float = 0
        if la > 0, lb > 0 { turned = acos(min(max(simd_dot(a, b) / (la * lb), -1), 1)) }
        let pixels = scale * (moved + turned) * within
        guard pixels.isFinite else { return most }
        guard pixels >= still else { return 0 }
        return min(max(Int((pixels / step).rounded(.up)), 1), most)
    }
}

/// The automatic exposure of a flight (#297): between the photograph and the inside of an arm
/// the frame brightens by up to five stops in a few seconds, which no trim written by hand
/// follows. A trim in stops that only ever darkens, so a frame under the target is left alone,
/// the photograph first of all.
public enum InsideExposure {
    /// The deepest trim, in stops.
    public static let deepest = 10.0
    /// How near the target a solved mean lands, as a ratio.
    public static let tolerance = 0.05

    /// Brightness times 2^-stops and the stretch times 2^(-1.46 stops), the ratio
    /// contemplation's closeness trim and a flight key's exposure move them by.
    public static func trimmed(_ look: RenderLook, stops: Double) -> RenderLook {
        guard stops > 0 else { return look }
        var trimmed = look
        trimmed.brightness *= Float(pow(2, -stops))
        trimmed.stretch *= Float(pow(2, -stops * 1.9 / 1.3))
        return trimmed
    }

    /// The mean luminance of an 8-bit sRGB frame, linearised, 0 to 1.
    public static func meanLuminance(rgba: [UInt8]) -> Double {
        var linear = [Double](repeating: 0, count: 256)
        for level in 0..<256 {
            let c = Double(level) / 255
            linear[level] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        var sum = 0.0
        var index = 0
        while index + 3 < rgba.count {
            sum +=
                0.2126 * linear[Int(rgba[index])] + 0.7152 * linear[Int(rgba[index + 1])]
                + 0.0722 * linear[Int(rgba[index + 2])]
            index += 4
        }
        return sum / Double(max(rgba.count / 4, 1))
    }

    /// The mean luminance of every `step`-th pixel of every `step`-th row of an 8-bit sRGB
    /// picture, linearised, 0 to 1; `bgra` for a drawable's byte order. The canvas reads its frames
    /// this way, a sixteenth of them (#298).
    public static func meanLuminance(
        pixels: UnsafeRawPointer, width: Int, height: Int, bytesPerRow: Int, bgra: Bool, step: Int
    ) -> Double {
        var linear = [Double](repeating: 0, count: 256)
        for level in 0..<256 {
            let c = Double(level) / 255
            linear[level] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let step = max(step, 1)
        let (red, blue) = bgra ? (2, 0) : (0, 2)
        var (sum, count) = (0.0, 0)
        for y in Swift.stride(from: 0, to: height, by: step) {
            let row = pixels.advanced(by: y * bytesPerRow)
            for x in Swift.stride(from: 0, to: width, by: step) {
                let p = row.advanced(by: x * 4)
                sum +=
                    0.2126 * linear[Int(p.load(fromByteOffset: red, as: UInt8.self))]
                    + 0.7152 * linear[Int(p.load(fromByteOffset: 1, as: UInt8.self))]
                    + 0.0722 * linear[Int(p.load(fromByteOffset: blue, as: UInt8.self))]
                count += 1
            }
        }
        return count > 0 ? sum / Double(count) : 0
    }

    /// The trim a canvas holds while a camera of the pilot's is near matter (#298): the frames
    /// are not solved along the whole flight as an export's are, so each reading of the frame
    /// moves the trim by what it misses of the target, a little more than the miss itself (the
    /// mean falls by less than a stop for a stop of trim), eased, never under 0 and never
    /// past `deepest`.
    public struct Live: Sendable, Equatable {
        /// Seconds the trim takes to follow most of the way.
        public static let ease = 0.25
        /// The miss, in stops, under which a reading is left alone.
        public static let deadband = log2(1 + InsideExposure.tolerance)
        public static let gain = 1.25

        public private(set) var stops = 0.0

        public init() {}

        /// The frame had `mean` luminance, drawn at the trim held, `seconds` after the last reading.
        public mutating func update(mean: Double, target: Double, seconds: Double) {
            guard target > 0, mean.isFinite else { return }
            let miss = log2(max(mean, 1e-6) / target)
            guard abs(miss) > Self.deadband else { return }
            let wanted = min(max(stops + miss * Self.gain, 0), InsideExposure.deepest)
            stops += (wanted - stops) * (1 - exp(-max(seconds, 0) / Self.ease))
            if stops < 1e-3 { stops = 0 }
        }

        /// Away from matter the trim goes back to nothing, as the photograph is left alone.
        public mutating func relax(seconds: Double) {
            stops *= exp(-max(seconds, 0) / Self.ease)
            if stops < 1e-3 { stops = 0 }
        }

        public mutating func reset() { stops = 0 }
    }

    /// The trim that brings the frame's mean luminance down to `target`: 0 when it is under
    /// already. `draw` gives the mean at a trim; `guess` is the trim of the moment before, which
    /// is usually within a draw of this one's.
    public static func solve(target: Double, guess: Double = 0, draw: (Double) -> Double) -> Double {
        guard target > 0 else { return 0 }
        func miss(_ mean: Double) -> Double { log2(max(mean, 1e-6) / target) }
        var low = (stops: 0.0, miss: 0.0)
        var high: (stops: Double, miss: Double)?
        var stops = min(max(guess, 0), deepest)
        if stops > 0 {
            let here = miss(draw(stops))
            if abs(here) <= log2(1 + tolerance) { return stops }
            if here < 0 { high = (stops, here) } else { low = (stops, here) }
        }
        if low.stops == 0 {
            low.miss = miss(draw(0))
            if low.miss <= log2(1 + tolerance) { return 0 }
        }
        // The mean falls by less than a stop per stop of trim, the tone curve being what it is:
        // a first step of the miss itself undershoots, and the secant takes it from there.
        for _ in 0..<8 {
            if let high {
                let slope = (high.miss - low.miss) / (high.stops - low.stops)
                stops = slope < 0 ? low.stops - low.miss / slope : (low.stops + high.stops) / 2
                let margin = (high.stops - low.stops) * 0.05
                stops = min(max(stops, low.stops + margin), high.stops - margin)
            } else {
                stops = min(low.stops + max(low.miss * 1.25, 0.25), deepest)
            }
            let here = miss(draw(stops))
            if abs(here) <= log2(1 + tolerance) { return stops }
            if here < 0 { high = (stops, here) } else { low = (stops, here) }
            if high == nil, stops >= deepest { return deepest }
        }
        return stops
    }

    /// Trims solved every `step` seconds of a flight, from its first second.
    public struct Track: Sendable, Equatable {
        public var step: Double
        public var stops: [Double]
        /// Seconds the trim is eased over: each moment takes the mean of the trims around it,
        /// under a raised cosine this wide either side.
        public var ease: Double
        /// The seconds where the camera is the look's and the frame the export's: no trim
        /// there, and it comes on over `ease` seconds from them.
        public var still: [ClosedRange<Double>]

        public init(step: Double, stops: [Double], ease: Double, still: [ClosedRange<Double>] = []) {
            self.step = step
            self.stops = stops
            self.ease = ease
            self.still = still
        }

        /// The moments the trims are solved at for a flight of `seconds`.
        public static func moments(seconds: Double, step: Double) -> [Double] {
            let count = Int((seconds / step).rounded(.up)) + 1
            return (0..<count).map { min(Double($0) * step, seconds) }
        }

        public func stops(atSeconds seconds: Double) -> Double {
            guard !stops.isEmpty else { return 0 }
            // How far past the look's own camera, 0 on it and 1 from `ease` seconds off.
            var on = 1.0
            for span in still {
                let off = max(span.lowerBound - seconds, seconds - span.upperBound, 0)
                guard off > 0 else { return 0 }
                let t = ease > 0 ? min(off / ease, 1) : 1
                on = min(on, t * t * (3 - 2 * t))
            }
            func sample(_ index: Int) -> Double { stops[min(max(index, 0), stops.count - 1)] }
            let x = seconds / step
            guard ease > step / 2 else {
                let lower = Int(x.rounded(.down))
                let t = x - Double(lower)
                return on * (sample(lower) * (1 - t) + sample(lower + 1) * t)
            }
            let reach = ease / step
            var (sum, weight) = (0.0, 0.0)
            for index in Int((x - reach).rounded(.down))...Int((x + reach).rounded(.up)) {
                let distance = abs(Double(index) - x) / reach
                guard distance < 1 else { continue }
                let w = 0.5 + 0.5 * cos(.pi * distance)
                sum += w * sample(index)
                weight += w
            }
            return on * (weight > 0 ? sum / weight : sample(Int(x.rounded())))
        }

        public var deepest: Double { stops.max() ?? 0 }
    }
}
