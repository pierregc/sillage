import Foundation

/// What `Renderer.particleTargets()` captures of a frame (#276): the targets the particle passes
/// left, before any post-processing, and the buffers and uniforms they drew from, byte for byte
/// as the GPU holds them, for the CUDA renderer to draw the same frame and compare.
public struct ParticleTargets {
    public struct File {
        public var name: String
        public var type: String
        public var stride: Int
        public var count: Int
        /// Of a texture, whose rows run from the top.
        public var width: Int?
        public var height: Int?
        public var bytes: Data

        init(
            _ name: String, _ type: String, _ stride: Int, _ count: Int, _ bytes: Data,
            width: Int? = nil, height: Int? = nil
        ) {
            (self.name, self.type, self.stride, self.count, self.bytes) = (name, type, stride, count, bytes)
            (self.width, self.height) = (width, height)
        }
    }

    /// One value a particle, the same for every frame of a take.
    public var particles: [File]
    /// What a frame draws from whatever its look.
    public var frame: [File]
    /// The uniforms of a look on a frame, and the targets they left.
    public var target: [File]
    /// Samples of the baked lace, when the frame drew the dust web.
    public var lace: [File]
    public var laceMean: Float?

    public var width: Int
    public var height: Int
    public var supersample: Int
    public var plain: Bool
    public var starCount: Int
    public var dustWeb: Float
    public var columnSmoothing: Float
    public var holeShadow: Float
    public var mapped: Bool
    public var luminosityNormalisation: Float
    public var drawn: Int
    public var galaxies: Int
    public var galaxySlots: Int
    /// Light tracers drawn behind the `drawn` massive particles, and the depth of the tree
    /// their spacing is read from; zero for a take, which draws none.
    public var tracers = 0
    public var tracerDepth = 0
}

/// The folder `export --dump-targets` fills, a look an export: `manifest.json`
/// (`sillage-render-targets`, version 1) lists every file with its type, stride and count, and
/// each export adds its look's targets to the one already there. The format is in
/// docs/notes/cuda-engine.md.
public struct RenderTargetManifest: Codable {
    public struct Entry: Codable {
        public var file: String
        public var type: String
        public var stride: Int
        public var count: Int
        public var width: Int?
        public var height: Int?
    }

    public struct Take: Codable {
        public var file: String
        public var scene: String
        public var particles: Int
        public var drawn: Int
        public var capturedFrames: Int
        public var capturedRate: Int

        public init(
            file: String, scene: String, particles: Int, drawn: Int, capturedFrames: Int,
            capturedRate: Int
        ) {
            (self.file, self.scene, self.particles) = (file, scene, particles)
            (self.drawn, self.capturedFrames, self.capturedRate) = (drawn, capturedFrames, capturedRate)
        }
    }

    public struct Frame: Codable {
        public var name: String
        /// Where the frame stands in the take's captured frames.
        public var captured: Double
        public var time: Float
        public var timeMyr: Double
        public var files: [String: Entry]
    }

    public struct Lace: Codable {
        public var mean: Float
        public var files: [String: Entry]
    }

    public struct CameraEntry: Codable {
        public var eye: [Float]
        public var target: [Float]
        public var up: [Float]
        public var fieldOfView: Float
        public var near: Float
        public var far: Float
        public var aspect: Float
    }

    public struct Target: Codable {
        public var look: String
        public var lookFile: String
        public var frame: String
        public var captured: Double
        public var time: Float
        public var timeMyr: Double
        public var shot: String?
        public var supersample: Int
        public var plain: Bool
        public var starCount: Int
        public var dustWeb: Float
        public var columnSmoothing: Float
        public var holeShadow: Float
        public var mapped: Bool
        public var luminosityNormalisation: Float
        public var drawn: Int
        /// Light tracers drawn too, and their tree's depth: a run's frame, not a take's.
        public var tracers: Int?
        public var tracerDepth: Int?
        public var galaxies: Int
        public var galaxySlots: Int
        public var laceMean: Float?
        public var camera: CameraEntry
        public var files: [String: Entry]
    }

    public var format = "sillage-render-targets"
    public var version = 1
    public var byteOrder = "little"
    public var rows = "top to bottom"
    public var source = "Metal, sillage-render export --dump-targets"
    public var commit: String
    public var device: String
    public var system: String
    public var width: Int
    public var height: Int
    public var take: Take
    public var particles: [String: Entry] = [:]
    public var frames: [Frame] = []
    public var lace: Lace?
    public var targets: [Target] = []

    public init(commit: String, device: String, system: String, width: Int, height: Int, take: Take) {
        (self.commit, self.device, self.system) = (commit, device, system)
        (self.width, self.height, self.take) = (width, height, take)
    }

    /// One frame of an export, as `TakeExport.write` hands it over.
    public struct Capture {
        public var captured: Double
        public var time: Float
        public var shot: String?
        public var camera: Camera
        public var targets: ParticleTargets

        public init(
            captured: Double, time: Float, shot: String?, camera: Camera, targets: ParticleTargets
        ) {
            (self.captured, self.time, self.shot) = (captured, time, shot)
            (self.camera, self.targets) = (camera, targets)
        }
    }

    static let file = "manifest.json"

    /// The manifest already in `directory`, for the next look of the same take at the same size.
    public static func read(from directory: URL) -> RenderTargetManifest? {
        (try? Data(contentsOf: directory.appendingPathComponent(file))).flatMap {
            try? JSONDecoder().decode(RenderTargetManifest.self, from: $0)
        }
    }

    /// Writes what `capture` holds under `directory` and lists it: the look's own files under
    /// `targets/<look>/<name>/`, the frame's under `frames/<name>/`, the take's under
    /// `particles/`. A frame or a target already listed under the same name is replaced.
    public mutating func add(
        _ capture: Capture, look: String, lookFile: String, name: String, megayearsPerUnit: Double,
        to directory: URL
    ) throws {
        func write(_ files: [ParticleTargets.File], under folder: String) throws -> [String: Entry] {
            let url = directory.appendingPathComponent(folder, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            var entries: [String: Entry] = [:]
            for file in files {
                precondition(file.bytes.count == file.count * file.stride, file.name)
                try file.bytes.write(to: url.appendingPathComponent(file.name))
                let key = String(file.name.split(separator: ".").first ?? Substring(file.name))
                entries[key] = Entry(
                    file: "\(folder)/\(file.name)", type: file.type, stride: file.stride,
                    count: file.count, width: file.width, height: file.height)
            }
            return entries
        }
        let captured = capture.targets
        particles.merge(try write(captured.particles, under: "particles")) { $1 }
        let timeMyr = Double(capture.time) * megayearsPerUnit
        // A plain look draws from fewer buffers than the look before it may have listed.
        var files = frames.first { $0.name == name && $0.captured == capture.captured }?.files ?? [:]
        files.merge(try write(captured.frame, under: "frames/\(name)")) { $1 }
        frames.removeAll { $0.name == name }
        frames.append(
            Frame(
                name: name, captured: capture.captured, time: capture.time, timeMyr: timeMyr,
                files: files))
        frames.sort { $0.captured < $1.captured }
        if let mean = captured.laceMean, !captured.lace.isEmpty {
            lace = Lace(mean: mean, files: try write(captured.lace, under: "lace"))
        }
        let camera = capture.camera
        targets.removeAll { $0.look == look && $0.frame == name }
        targets.append(
            Target(
                look: look, lookFile: lookFile, frame: name, captured: capture.captured,
                time: capture.time, timeMyr: timeMyr, shot: capture.shot,
                supersample: captured.supersample, plain: captured.plain,
                starCount: captured.starCount, dustWeb: captured.dustWeb,
                columnSmoothing: captured.columnSmoothing, holeShadow: captured.holeShadow,
                mapped: captured.mapped,
                luminosityNormalisation: captured.luminosityNormalisation, drawn: captured.drawn,
                tracers: captured.tracers > 0 ? captured.tracers : nil,
                tracerDepth: captured.tracers > 0 ? captured.tracerDepth : nil,
                galaxies: captured.galaxies, galaxySlots: captured.galaxySlots,
                laceMean: captured.laceMean,
                camera: CameraEntry(
                    eye: [camera.eye.x, camera.eye.y, camera.eye.z],
                    target: [camera.target.x, camera.target.y, camera.target.z],
                    up: [camera.up.x, camera.up.y, camera.up.z], fieldOfView: camera.fieldOfView,
                    near: camera.near, far: camera.far,
                    aspect: Float(captured.width) / Float(max(captured.height, 1))),
                files: try write(captured.target, under: "targets/\(look)/\(name)")))
        targets.sort { ($0.look, $0.captured) < ($1.look, $1.captured) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(self).write(to: directory.appendingPathComponent(Self.file))
    }
}
