// What Metal's rasteriser does with a point: which pixels it covers and what `point_coord` reads
// there, measured for the CUDA renderer's splats (#276), which have no rasteriser to ask.
//
// Each case draws one point alone into a cleared rgba32Float target with no blending, 64 x 64
// unless the case says otherwise.
// The vertex function passes its clip position and point size through; the fragment function
// writes float4(point_coord.x, point_coord.y, 1, 0). A covered pixel has 1 in its blue channel.
//
//   swiftc -O raster-probe.swift -o raster-probe && ./raster-probe <output directory>

import Foundation
import Metal

let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Probe {
        float4 position;
        float size;
    };

    struct ProbeOut {
        float4 position [[position]];
        float pointSize [[point_size]];
    };

    vertex ProbeOut probeVertex(uint vid [[vertex_id]], constant Probe &probe [[buffer(0)]]) {
        ProbeOut out;
        out.position = probe.position;
        out.pointSize = probe.size;
        return out;
    }

    fragment float4 probeFragment(ProbeOut in [[stage_in]], float2 coord [[point_coord]]) {
        return float4(coord.x, coord.y, 1.0f, 0.0f);
    }
    """

struct Probe {
    var position: SIMD4<Float>
    var size: Float
}

struct Case {
    var name: String
    var size: Float
    /// The point's centre in pixels, x to the right and y down from the top left corner, and
    /// its clip depth and w.
    var centre: SIMD2<Float>
    var z: Float = 0.5
    var w: Float = 1
    var note: String? = nil
    var width = 64
    var height = 64
}

func clip(_ c: Case) -> SIMD4<Float> {
    let x = c.centre.x / Float(c.width) * 2 - 1
    let y = 1 - c.centre.y / Float(c.height) * 2
    return SIMD4(x * c.w, y * c.w, c.z * c.w, c.w)
}

var cases: [Case] = []
let sizes: [Float] = [0.5, 1, 1.3, 2, 2.2, 3, 5.5, 16, 61.7, 200, 600, 1200]
let centres: [SIMD2<Float>] = [
    SIMD2(32, 32), SIMD2(32.5, 32.5), SIMD2(32.25, 32.75), SIMD2(32.1234, 31.9876),
]
for size in sizes {
    for (index, centre) in centres.enumerated() {
        cases.append(Case(name: "size-\(size)-centre-\(index)", size: size, centre: centre))
    }
}
for (index, centre) in [SIMD2<Float>(-1.5, 32), SIMD2(0.3, 32), SIMD2(63.9, 63.9), SIMD2(65, 32)]
    .enumerated()
{
    cases.append(Case(name: "edge-\(index)", size: 8, centre: centre, note: "a point at the frame's edge"))
}
cases.append(
    Case(name: "near", size: 8, centre: SIMD2(32, 32), z: -0.25, note: "in front of the near plane"))
cases.append(
    Case(name: "far", size: 8, centre: SIMD2(32, 32), z: 1.25, note: "behind the far plane"))
cases.append(
    Case(
        name: "w-3.7", size: 5.5, centre: SIMD2(32.25, 32.75), w: 3.7,
        note: "as size-5.5-centre-2 through a perspective divide"))
cases.append(Case(name: "size-0", size: 0, centre: SIMD2(32.5, 32.5), note: "a point of no size"))
let wide: [(size: Float, centre: SIMD2<Float>)] = [
    (200, SIMD2(-50, 32)), (200, SIMD2(32, -90)), (400, SIMD2(-150, 32)), (511, SIMD2(300, 32)),
    (512, SIMD2(32.5, 32.5)), (511, SIMD2(32.5, 32.5)), (510.5, SIMD2(32.5, 32.5)),
]
for (index, point) in wide.enumerated() {
    cases.append(
        Case(
            name: "wide-\(index)", size: point.size, centre: point.centre,
            note: "a wide point, its centre out of the frame or its size at the limit"))
}
// Sizes off the quarter pixel, to tell how the size is rounded for the coverage and for
// point_coord, and two whose edge passes a pixel centre between the size asked and its rounding.
for size: Float in [1.1, 1.6, 1.9, 2.6, 3.4, 4.7, 7.05, 10.06, 33.3, 99.9] {
    cases.append(
        Case(
            name: "fraction-\(size)", size: size, centre: SIMD2(32.25, 32.75),
            note: "a size off the quarter pixel"))
}
cases.append(Case(name: "rounding-1.3", size: 1.3, centre: SIMD2(32.14, 32.5), note: "size 1.3, a pixel centre between its edge and the edge of 1.25"))
cases.append(Case(name: "rounding-2.2", size: 2.2, centre: SIMD2(32.61, 32.5), note: "size 2.2, a pixel centre between its edge and the edge of 2.25"))
// How far out of the frame a point's centre may stand before the whole point is dropped, in
// frames of several sizes, to the left and above: around a quarter of the frame's side.
for (width, height) in [(64, 64), (256, 64), (64, 256), (960, 540)] {
    for (axis, side) in [("left", width), ("above", height)] {
        let quarter = Float(side) / 4
        for out in [1, quarter - 1, quarter - 0.25, quarter, quarter + 0.25, quarter + 1, 2 * quarter] {
            let centre =
                axis == "left"
                ? SIMD2(-out, Float(height) / 2) : SIMD2(Float(width) / 2, -out)
            cases.append(
                Case(
                    name: "\(axis)-\(width)x\(height)-\(out)", size: 511, centre: centre,
                    note: "its centre \(out) pixels out of a \(width) x \(height) frame",
                    width: width, height: height))
        }
    }
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: raster-probe <output directory>\n".utf8))
    exit(2)
}
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("no Metal device")
}
let library = try device.makeLibrary(source: source, options: nil)
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = library.makeFunction(name: "probeVertex")
pipelineDescriptor.fragmentFunction = library.makeFunction(name: "probeFragment")
pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba32Float
let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

var targets: [String: MTLTexture] = [:]
func target(_ width: Int, _ height: Int) -> MTLTexture {
    if let held = targets["\(width)x\(height)"] { return held }
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba32Float, width: width, height: height, mipmapped: false)
    descriptor.usage = [.renderTarget, .shaderRead]
    descriptor.storageMode = .shared
    guard let made = device.makeTexture(descriptor: descriptor) else { fatalError("no texture") }
    targets["\(width)x\(height)"] = made
    return made
}

struct Entry: Encodable {
    var name: String
    /// Absent for a case that covers nothing or is summed up by its box alone.
    var file: String?
    var width: Int
    var height: Int
    var size: Float
    var centre: [Float]
    var clip: [Float]
    var note: String?
    /// Pixels covered, and the box they fill: first and last column and row, both included.
    var covered: Int
    var columns: [Int]?
    var rows: [Int]?
    /// point_coord at the first and at the last covered pixel of the box's diagonal.
    var first: [Float]?
    var last: [Float]?
}

struct Manifest: Encodable {
    var format = "sillage-raster-probe"
    var version = 1
    var byteOrder = "little"
    var rows = "top to bottom"
    var device: String
    var system: String
    var type = "rgba32Float"
    var stride = 16
    var channels = "point_coord.x, point_coord.y, 1 where covered, 0"
    var cases: [Entry]
}

var entries: [Entry] = []
for c in cases {
    var probe = Probe(position: clip(c), size: c.size)
    let pass = MTLRenderPassDescriptor()
    let (width, height) = (c.width, c.height)
    let target = target(width, height)
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    guard let buffer = queue.makeCommandBuffer(),
        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)
    else { fatalError("no encoder") }
    encoder.setRenderPipelineState(pipeline)
    encoder.setVertexBytes(&probe, length: MemoryLayout<Probe>.stride, index: 0)
    encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: 1)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()

    var pixels = [Float](repeating: 0, count: width * height * 4)
    pixels.withUnsafeMutableBytes {
        target.getBytes(
            $0.baseAddress!, bytesPerRow: width * 16, from: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0)
    }
    // The sweeps out of the frame are told by their boxes: no file.
    let file = c.note?.contains("pixels out of a") == true ? nil : c.name + ".f32"
    if let file {
        try pixels.withUnsafeBytes { Data($0) }.write(to: directory.appendingPathComponent(file))
    }

    var covered = 0
    var (minX, maxX, minY, maxY) = (width, -1, height, -1)
    for y in 0..<height {
        for x in 0..<width where pixels[(y * width + x) * 4 + 2] > 0 {
            covered += 1
            (minX, maxX, minY, maxY) = (min(minX, x), max(maxX, x), min(minY, y), max(maxY, y))
        }
    }
    func coord(_ x: Int, _ y: Int) -> [Float] {
        [pixels[(y * width + x) * 4], pixels[(y * width + x) * 4 + 1]]
    }
    let position = clip(c)
    entries.append(
        Entry(
            name: c.name, file: file, width: width, height: height, size: c.size, centre: [c.centre.x, c.centre.y],
            clip: [position.x, position.y, position.z, position.w], note: c.note, covered: covered,
            columns: covered > 0 ? [minX, maxX] : nil, rows: covered > 0 ? [minY, maxY] : nil,
            first: covered > 0 ? coord(minX, minY) : nil, last: covered > 0 ? coord(maxX, maxY) : nil))
    print(
        String(
            format: "%-22@ size %7.2f at (%8.4f, %8.4f): %4d pixels%@", c.name as NSString, c.size,
            c.centre.x, c.centre.y, covered,
            covered > 0
                ? String(
                    format: ", columns %d-%d, rows %d-%d, point_coord %.5f, %.5f to %.5f, %.5f", minX,
                    maxX, minY, maxY, coord(minX, minY)[0], coord(minX, minY)[1], coord(maxX, maxY)[0],
                    coord(maxX, maxY)[1]) : ""))
}

let manifest = Manifest(
    device: device.name, system: ProcessInfo.processInfo.operatingSystemVersionString, cases: entries)
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
try encoder.encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))
