import CoreGraphics
import Foundation
import Metal
import SillageCore
import simd

/// Spike #296: frames of a take drawn from anywhere, inside a galaxy too, with the variants of
/// `InsideSettings`, measured; and short clips along camera paths. Not merged.
public enum InsideSpike {
    struct View: Codable {
        var eye: [Float]
        var target: [Float]
        var up: [Float]?
        var fov: Float?
        var near: Float?

        var camera: Camera {
            Camera(
                eye: SIMD3(eye[0], eye[1], eye[2]), target: SIMD3(target[0], target[1], target[2]),
                up: up.map { SIMD3($0[0], $0[1], $0[2]) } ?? SIMD3(0, 0, 1),
                fieldOfView: fov ?? 0.6, near: near ?? 1, far: 40_000)
        }
    }

    struct Trim: Codable {
        var brightness: Float?
        var stretch: Float?
        var smoothingScale: Float?
        var maximumKernel: Float?
        var columnSmoothing: Float?
        var dustWeb: Float?
        var dustStrength: Float?
        /// Exposure trim in stops below the look, the stretch brought down with it.
        var stops: Float?

        func apply(_ look: inout RenderLook) {
            if let stops {
                look.brightness *= pow(2, -stops)
                look.stretch *= pow(2, -1.46 * stops)
            }
            if let brightness { look.brightness *= brightness }
            if let stretch { look.stretch = stretch }
            if let smoothingScale { look.smoothingScale = smoothingScale }
            if let maximumKernel { look.maximumKernel = maximumKernel }
            if let columnSmoothing { look.columnSmoothing = columnSmoothing }
            if let dustWeb { look.dustWeb = dustWeb }
            if let dustStrength { look.dustStrength = dustStrength }
        }
    }

    struct Render: Codable {
        var out: String
        var frame: Double
        var view: View
        var inside: InsideSettings?
        var trim: Trim?
        var width: Int
        var height: Int
        var supersample: Int?
        var measure: Bool?
        var timing: Bool?
    }

    struct Clip: Codable {
        var out: String
        var width: Int
        var height: Int
        var fps: Int
        var supersample: Int?
        var inside: InsideSettings?
        var trim: Trim?
        var frames: [Double]
        var views: [View]
        var crf: Int?
        /// Views in this galaxy's disk axes (u, v, normal) about its centre at each frame.
        var anchor: Int?
        /// Carried round with the disk at its angular rate at this radius, in kpc.
        var corotate: Float?
        /// An exposure trim per frame, in stops.
        var stops: [Float]?
        /// Renders averaged per frame, the camera and the time spread over the frame interval.
        var subframes: Int?
    }

    struct Probe: Codable {
        var frame: Double
        var out: String
        var bins: Int?
        /// Half width of the face-on map, in scale lengths.
        var extent: Float?
        var slab: Float?
    }

    struct Job: Codable {
        var take: String
        var look: String
        var capturedRate: Int?
        var probes: [Probe]?
        var renders: [Render]?
        var clips: [Clip]?
    }

    public static func main(_ arguments: [String]) -> Int32 {
        guard let path = arguments.first else {
            print("usage: sillage-render inside <job.json>")
            return 2
        }
        do {
            let job = try JSONDecoder().decode(Job.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
            let spike = try Spike(job: job)
            for probe in job.probes ?? [] { try spike.probe(probe) }
            for render in job.renders ?? [] { try spike.render(render) }
            for clip in job.clips ?? [] { try spike.clip(clip) }
            return 0
        } catch {
            print("inside: \(error)")
            return 1
        }
    }

    final class Spike {
        let take: RecordingFile.Loaded
        let look: LookFile
        let device: MTLDevice
        let positions: MTLBuffer
        let expander: SnapshotExpander
        let smoothing: SmoothingField
        let stream: SnapshotStream
        let capturedRate: Int
        var expanded: Double?
        var renderers: [String: Renderer] = [:]

        init(job: Job) throws {
            guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
            self.device = device
            take = try RecordingFile.read(from: URL(fileURLWithPath: job.take))
            look = try LookFile.decoded(from: Data(contentsOf: URL(fileURLWithPath: job.look)))
            capturedRate = job.capturedRate ?? 30
            let count = take.recording.particleCount
            guard
                let positions = device.makeBuffer(
                    length: count * MemoryLayout<SIMD3<Float>>.stride, options: .storageModeShared),
                let stream = SnapshotStream(device: device, recording: take.recording)
            else { throw RenderError.noDevice }
            self.positions = positions
            self.stream = stream
            expander = try SnapshotExpander(device: device, recording: take.recording)
            smoothing = try SmoothingField(device: device, particleCount: count)
            print("inside     take \(count) particles, \(take.recording.capturedFrames) frames")
        }

        func expand(_ frame: Double) throws -> Recording.Blend {
            guard let blend = take.recording.blend(atCaptured: frame) else {
                throw RecordingFile.Failure.truncated
            }
            if expanded != frame {
                guard expander.expand(blend, of: take.recording, through: stream, into: positions)
                else { throw RecordingFile.Failure.truncated }
                smoothing.update(from: positions)
                expanded = frame
            }
            return blend
        }

        func renderer(width: Int, height: Int, supersample: Int) throws -> Renderer {
            let key = "\(width)x\(height)x\(supersample)"
            if let renderer = renderers[key] { return renderer }
            var file = look
            file.supersample = supersample
            let renderer = try Renderer(
                device: device, particles: take.particles,
                settings: file.renderSettings(width: width, height: height),
                externalPositions: positions)
            renderer.setSmoothing(smoothing.buffer)
            renderers = [key: renderer]
            return renderer
        }

        func prepare(
            _ renderer: Renderer, frame: Double, inside: InsideSettings?, trim: Trim?, width: Int,
            height: Int
        ) throws {
            let blend = try expand(frame)
            let replay = TakeFraming.replay(
                look: look, framing: take, capturedRate: capturedRate, width: width, height: height)
            let shot = replay.shot(atPlayed: frame)
            renderer.prepare(look, shot: shot, take: take, at: blend)
            var styled = shot.look
            trim?.apply(&styled)
            renderer.apply(styled)
            renderer.inside = inside ?? InsideSettings()
        }

        func render(_ job: Render) throws {
            let supersample = job.supersample ?? 2
            let renderer = try renderer(width: job.width, height: job.height, supersample: supersample)
            try prepare(
                renderer, frame: job.frame, inside: job.inside, trim: job.trim, width: job.width,
                height: job.height)
            let camera = job.view.camera
            var pixels = renderer.render(camera: camera)
            var gpu = renderer.lastGPUTime
            if job.timing == true {
                var times: [Double] = []
                for _ in 0..<3 {
                    pixels = renderer.render(camera: camera)
                    times.append(renderer.lastGPUTime)
                }
                gpu = times.sorted()[1]
            }
            let url = URL(fileURLWithPath: job.out)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PNGWriter.write(pixels, width: job.width, height: job.height, to: url)
            var report: [String: Double] = ["gpuMs": gpu * 1000]
            report.merge(Self.imageStats(pixels)) { $1 }
            if job.measure == true {
                report.merge(
                    particleStats(
                        renderer: renderer, camera: camera, inside: job.inside ?? InsideSettings(),
                        width: job.width, height: job.height, supersample: supersample)
                ) { $1 }
            }
            let data = try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
            try data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            print(
                String(
                    format: "render     %@  %.0f ms  mean %.3f  clipped %.4f", url.lastPathComponent,
                    gpu * 1000, report["meanLuminance"] ?? 0, report["clipped"] ?? 0))
        }

        /// Luminance of the 8-bit frame, linearised.
        static func imageStats(_ pixels: [UInt8]) -> [String: Double] {
            var lut = [Double](repeating: 0, count: 256)
            for i in 0..<256 {
                let c = Double(i) / 255
                lut[i] = c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            var sum = 0.0
            var logSum = 0.0
            var clipped = 0
            var count = 0
            var index = 0
            while index + 3 < pixels.count {
                let r = pixels[index]
                let g = pixels[index + 1]
                let b = pixels[index + 2]
                let y = 0.2126 * lut[Int(r)] + 0.7152 * lut[Int(g)] + 0.0722 * lut[Int(b)]
                sum += y
                logSum += log(y + 1e-4)
                if max(r, g, b) >= 254 { clipped += 1 }
                count += 1
                index += 4
            }
            let n = Double(max(count, 1))
            return [
                "meanLuminance": sum / n, "logAverage": exp(logSum / n),
                "clipped": Double(clipped) / n,
            ]
        }

        /// What the particle passes paint and where the light comes from, worked out on the CPU
        /// from the positions and the smoothing the frame was drawn with.
        func particleStats(
            renderer: Renderer, camera: Camera, inside: InsideSettings, width: Int, height: Int,
            supersample: Int
        ) -> [String: Double] {
            let settings = renderer.settings
            let count = take.recording.particleCount
            let points = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            let spacing = smoothing.buffer.contents().bindMemory(to: Float.self, capacity: count)
            let particles = take.particles
            let aspect = Float(width) / Float(height)
            let viewProjection = camera.viewProjection(aspectRatio: aspect)
            let projectionScale =
                Float(height * supersample) / (2 * tan(camera.fieldOfView / 2))
            let cap = settings.maximumKernel * Float(supersample)
            let floor = settings.minimumKernel * Float(supersample)
            var inView = 0
            var capped = 0
            var painted = 0.0
            var starPoints = 0.0
            var light = 0.0
            var nearLight = 0.0
            var nearCount = 0
            let starSize = Double(max(inside.starPointSize * Float(supersample), 1))
            for i in 0..<count {
                let kind = particles.component[i]
                guard kind != ParticleComponent.halo.rawValue, kind != ParticleComponent.hole.rawValue
                else { continue }
                let born = particles.formation[i]
                if kind == ParticleComponent.dust.rawValue && !(born > -1e8 && born < 1e8) { continue }
                let p = points[i]
                let clip = viewProjection * SIMD4(p, 1)
                let depth = clip.w
                guard depth > camera.near, abs(clip.x) <= depth, abs(clip.y) <= depth else { continue }
                inView += 1
                var scale = particles.kernelScale[i]
                if scale < 0.8 { scale = 0.9 + (scale - 0.9) * settings.glint }
                let length = max(spacing[i] * settings.smoothingScale * scale, 1e-4)
                let perPixel = projectionScale / depth
                let raw = length * perPixel
                let span = min(max(raw, floor), cap)
                if raw > cap { capped += 1 }
                painted += Double(span * span)
                var weight = Double(particles.luminosity[i]) * Double(perPixel * perPixel)
                if inside.nearFadeLengths > 0 {
                    weight *= Double(
                        min(max((depth - camera.near) / (inside.nearFadeLengths * length), 0), 1))
                }
                var starred: Float = 0
                if inside.starEnd > 0 {
                    let a = inside.starStart * cap
                    let b = inside.starEnd * cap
                    let t = min(max((raw - a) / max(b - a, 1e-6), 0), 1)
                    starred = t * t * (3 - 2 * t)
                    if inside.starFarKpc > 0 {
                        let f = min(max((depth - inside.starNearKpc) / max(inside.starFarKpc - inside.starNearKpc, 1e-6), 0), 1)
                        starred *= 1 - f * f * (3 - 2 * f)
                    }
                    if starred > 0 { starPoints += Double(inside.starCount) }
                }
                let law = inside.capLaw == 1 && raw > span ? Double(span * span / (raw * raw)) : 1
                weight *= Double(1 - starred) * law + Double(starred)
                light += weight
                if depth < 1 {
                    nearLight += weight
                    nearCount += 1
                }
            }
            return [
                "inView": Double(inView), "capped": Double(capped),
                "cappedShare": Double(capped) / Double(max(inView, 1)),
                "paintedMpx": painted / 1e6, "starPointsM": starPoints / 1e6,
                "starPaintedMpx": starPoints * starSize * starSize / 1e6,
                "nearCount": Double(nearCount), "nearLightShare": nearLight / max(light, 1e-30),
            ]
        }

        func clip(_ job: Clip) throws {
            let supersample = job.supersample ?? 2
            let renderer = try renderer(width: job.width, height: job.height, supersample: supersample)
            let url = URL(fileURLWithPath: job.out)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let ffmpeg = Process()
            ffmpeg.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg")
            ffmpeg.arguments = [
                "-y", "-loglevel", "error", "-f", "rawvideo", "-pix_fmt", "rgba", "-s",
                "\(job.width)x\(job.height)", "-r", "\(job.fps)", "-i", "-", "-c:v", "libx264",
                "-preset", "slow", "-crf", "\(job.crf ?? 18)", "-pix_fmt", "yuv420p", "-movflags",
                "+faststart", url.path,
            ]
            let pipe = Pipe()
            ffmpeg.standardInput = pipe
            try ffmpeg.run()
            let started = Date()
            var gpu: [Double] = []
            var firstTime: Float?
            func draw(_ frame: Double, _ view: View, _ stops: Float?) throws -> [UInt8] {
                var trim = job.trim ?? Trim()
                if let stops { trim.stops = stops }
                try prepare(
                    renderer, frame: frame, inside: job.inside, trim: trim, width: job.width,
                    height: job.height)
                var camera = view.camera
                if let anchor = job.anchor {
                    let blend = try expand(frame)
                    let replay = TakeFraming.replay(
                        look: look, framing: take, capturedRate: capturedRate, width: job.width,
                        height: job.height)
                    let moment = TakeFraming.moment(
                        look, shot: replay.shot(atPlayed: frame), take: take, at: blend)
                    let f = moment.diskFrames[anchor]
                    let start = firstTime ?? blend.time
                    firstTime = start
                    var turn: Float = 0
                    if let radius = job.corotate {
                        turn = Self.angularRate(f, radius: radius) * (blend.time - start)
                    }
                    camera = Self.anchored(camera, frame: f, turn: turn)
                }
                let pixels = renderer.render(camera: camera)
                gpu.append(renderer.lastGPUTime)
                return pixels
            }
            func mix(_ a: [Float], _ b: [Float], _ t: Float) -> [Float] {
                zip(a, b).map { $0 + ($1 - $0) * t }
            }
            let subframes = max(job.subframes ?? 1, 1)
            for (index, frame) in job.frames.enumerated() {
                let stops = job.stops?[index]
                guard subframes > 1 else {
                    let pixels = try draw(frame, job.views[index], stops)
                    pixels.withUnsafeBufferPointer { pipe.fileHandleForWriting.write(Data(buffer: $0)) }
                    continue
                }
                // A shutter open over the whole frame interval, averaged after the tone curve.
                let next = min(index + 1, job.frames.count - 1)
                let a = job.views[index]
                let b = job.views[next]
                var sum = [Float](repeating: 0, count: job.width * job.height * 4)
                for sub in 0..<subframes {
                    let t = Float(sub) / Float(subframes)
                    let view = View(
                        eye: mix(a.eye, b.eye, t), target: mix(a.target, b.target, t),
                        up: a.up.map { mix($0, b.up ?? $0, t) }, fov: a.fov, near: a.near)
                    let time = frame + (job.frames[next] - frame) * Double(t)
                    let pixels = try draw(time, view, stops)
                    for i in 0..<sum.count { sum[i] += Float(pixels[i]) }
                }
                let scale = 1 / Float(subframes)
                let pixels = sum.map { UInt8(min(max($0 * scale, 0), 255).rounded()) }
                pixels.withUnsafeBufferPointer { pipe.fileHandleForWriting.write(Data(buffer: $0)) }
            }
            try pipe.fileHandleForWriting.close()
            ffmpeg.waitUntilExit()
            let sorted = gpu.sorted()
            print(
                String(
                    format: "clip       %@  %d frames in %.1f s, GPU median %.0f ms, max %.0f ms",
                    url.lastPathComponent, job.frames.count, Date().timeIntervalSince(started),
                    (sorted.isEmpty ? 0 : sorted[sorted.count / 2]) * 1000, (sorted.last ?? 0) * 1000))
        }

        /// The disk's angular rate at `radius`, in radians per time unit, from the eight radii
        /// the frame carries.
        static func angularRate(_ f: DiskFrame, radius: Float) -> Float {
            let rates = [
                f.omegaInner.x, f.omegaInner.y, f.omegaInner.z, f.omegaInner.w, f.omegaOuter.x,
                f.omegaOuter.y, f.omegaOuter.z, f.omegaOuter.w,
            ]
            let scale = max(f.center.w, 1e-3)
            let at = min(max((log2(radius / scale) + 2) / 0.75, 0), 7)
            let i = min(Int(at), 6)
            let t = at - Float(i)
            return rates[i] * (1 - t) + rates[i + 1] * t
        }

        /// A camera given in disk coordinates (u, v, normal) about the centre, turned by `turn`
        /// about the normal, placed in the world.
        static func anchored(_ camera: Camera, frame f: DiskFrame, turn: Float) -> Camera {
            let u = SIMD3(f.axisU.x, f.axisU.y, f.axisU.z)
            let v = SIMD3(f.axisV.x, f.axisV.y, f.axisV.z)
            let n = simd_normalize(simd_cross(u, v))
            let c = SIMD3(f.center.x, f.center.y, f.center.z)
            let (s, k) = (sin(turn), cos(turn))
            func world(_ p: SIMD3<Float>) -> SIMD3<Float> {
                let a = p.x * k - p.y * s
                let b = p.x * s + p.y * k
                return u * a + v * b + n * p.z
            }
            var placed = camera
            placed.eye = c + world(camera.eye)
            placed.target = c + world(camera.target)
            placed.up = world(camera.up)
            return placed
        }

        /// The centres and disk axes at a moment, the export's camera there, and a face-on map
        /// of each galaxy's emitting particles near its plane: all of them and the young ones.
        func probe(_ job: Probe) throws {
            let blend = try expand(job.frame)
            let replay = TakeFraming.replay(
                look: look, framing: take, capturedRate: capturedRate, width: 3840, height: 2160)
            let shot = replay.shot(atPlayed: job.frame)
            let moment = TakeFraming.moment(look, shot: shot, take: take, at: blend)
            let count = take.recording.particleCount
            let points = positions.contents().bindMemory(to: SIMD3<Float>.self, capacity: count)
            let spacing = smoothing.buffer.contents().bindMemory(to: Float.self, capacity: count)
            let particles = take.particles
            let bins = job.bins ?? 256
            let frames = moment.diskFrames
            var galaxies: [[String: Any]] = []
            var maps = [[Float]](repeating: [Float](repeating: 0, count: bins * bins * 2), count: frames.count)
            var spacings = [[Float]](repeating: [], count: frames.count)
            for i in 0..<count {
                let kind = particles.component[i]
                guard let component = ParticleComponent(rawValue: kind), component.emits else { continue }
                let g = Int(particles.galaxyIndex[i])
                guard g < frames.count else { continue }
                let f = frames[g]
                let scale = max(f.center.w, 1e-3)
                let extent = (job.extent ?? 4) * scale
                let rel = points[i] - SIMD3(f.center.x, f.center.y, f.center.z)
                let u = simd_dot(rel, SIMD3(f.axisU.x, f.axisU.y, f.axisU.z))
                let v = simd_dot(rel, SIMD3(f.axisV.x, f.axisV.y, f.axisV.z))
                let normal = simd_cross(
                    SIMD3(f.axisU.x, f.axisU.y, f.axisU.z), SIMD3(f.axisV.x, f.axisV.y, f.axisV.z))
                let h = simd_dot(rel, normal)
                guard abs(h) < (job.slab ?? 1) else { continue }
                let x = Int((u / extent + 1) * 0.5 * Float(bins))
                let y = Int((v / extent + 1) * 0.5 * Float(bins))
                guard x >= 0, x < bins, y >= 0, y < bins else { continue }
                maps[g][(y * bins + x) * 2] += 1
                let born = particles.formation[i]
                if born > -1e8 && born < 1e8 || kind == ParticleComponent.hiiRegion.rawValue {
                    maps[g][(y * bins + x) * 2 + 1] += 1
                }
                if spacings[g].count < 200_000, i % 7 == 0 { spacings[g].append(spacing[i]) }
            }
            let centers = take.recording.centers(at: blend)
            for (g, f) in frames.enumerated() {
                let sortedSpacing = spacings[g].sorted()
                galaxies.append([
                    "center": [f.center.x, f.center.y, f.center.z], "scale": f.center.w,
                    "u": [f.axisU.x, f.axisU.y, f.axisU.z], "v": [f.axisV.x, f.axisV.y, f.axisV.z],
                    "recordedCenter": g < centers.count ? [centers[g].x, centers[g].y, centers[g].z] : [],
                    "spacingMedian": sortedSpacing.isEmpty ? 0 : sortedSpacing[sortedSpacing.count / 2],
                    "map": maps[g],
                ])
            }
            let camera = shot.camera
            let report: [String: Any] = [
                "frame": job.frame, "time": blend.time, "bins": bins, "extent": job.extent ?? 4,
                "camera": [
                    "eye": [camera.eye.x, camera.eye.y, camera.eye.z],
                    "target": [camera.target.x, camera.target.y, camera.target.z],
                    "up": [camera.up.x, camera.up.y, camera.up.z], "fov": camera.fieldOfView,
                ],
                "galaxies": galaxies,
            ]
            let url = URL(fileURLWithPath: job.out)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report).write(to: url)
            print("probe      \(url.lastPathComponent) at frame \(job.frame), time \(blend.time)")
        }
    }
}
