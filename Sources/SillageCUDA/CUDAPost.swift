internal import CSillageCUDA
import Foundation
import SillageRender

/// The post-processing of a frame on CUDA (#277): the passes of a `PostPlan`, run over the
/// supersampled light the particle passes left, and the picture packed into 8-bit bytes in
/// pinned host memory. The kernels are the shared MSL of `Shaders`; every image is four floats a
/// texel in device memory, where Metal holds half floats.
public final class CUDAPost {
    /// What a pixel is in the bytes of a picture.
    public enum Format: Sendable {
        /// Three bytes a pixel.
        case rgb
        /// Four bytes, alpha 255.
        case rgba
        /// Four bytes in the order an encoder's BGRA wants, alpha 255.
        case bgra

        public var bytesPerPixel: Int { self == .rgb ? 3 : 4 }

        var raw: sc_post_format {
            switch self {
            case .rgb: SC_POST_RGB
            case .rgba: SC_POST_RGBA
            case .bgra: SC_POST_BGRA
            }
        }
    }

    public let context: CUDAContext
    public let sizes: PostPlan.Sizes
    private var images: [PostPlan.Image: CUDABuffer] = [:]
    private let packed: CUDABuffer
    private let host: CUDAHostMemory

    public init(context: CUDAContext, sizes: PostPlan.Sizes) throws {
        self.context = context
        self.sizes = sizes
        var wanted: [PostPlan.Image] = [.resolved, .sharpSource, .sharpSpikes, .spikes, .output]
        for level in sizes.levels.indices { wanted += [.down(level), .up(level)] }
        for image in wanted {
            let size = sizes.size(of: image)
            images[image] = try context.makeBuffer(length: size.width * size.height * 16)
        }
        let bytes = sizes.picture.width * sizes.picture.height * 4
        packed = try context.makeBuffer(length: bytes)
        host = try CUDAHostMemory(context: context, length: bytes)
    }

    /// An image of the frame: its floats, four a texel, rows from the top.
    public func image(_ which: PostPlan.Image) throws -> [Float] {
        guard let buffer = images[which] else {
            throw CUDAError(.invalidArgument, "the light is the renderer's, not this image's")
        }
        let size = sizes.size(of: which)
        return try buffer.download(Float.self, count: size.width * size.height * 4)
    }

    private func handle(_ which: PostPlan.Image, light: CUDABuffer?) throws -> sc_post_image {
        let size = sizes.size(of: which)
        guard let buffer = which == .light ? light : images[which] else {
            throw CUDAError(.invalidArgument, "no image \(which)")
        }
        return sc_post_image(
            texels: buffer.handle, width: UInt32(size.width), height: UInt32(size.height))
    }

    /// Runs the passes of `plan` over `light`, the renderer's supersampled accumulation, and
    /// leaves the picture in `output`.
    public func run(_ plan: PostPlan, light: CUDABuffer) throws {
        guard plan.sizes == sizes else {
            throw CUDAError(.invalidArgument, "a post-processing plan for other sizes")
        }
        guard light.length >= sizes.light.width * sizes.light.height * 16 else {
            throw CUDAError(.invalidArgument, "the light is smaller than the plan's")
        }
        func image(_ which: PostPlan.Image) throws -> sc_post_image {
            try handle(which, light: light)
        }
        for pass in plan.passes {
            switch pass {
            case .resolve(let factor):
                var source = try image(.light)
                var target = try image(.resolved)
                try check(sc_post_resolve(&source, &target, UInt32(factor)), "resolve")

            case .plainComposite(let factor, let fade):
                var source = try image(.light)
                var target = try image(.output)
                try check(
                    sc_post_plain_composite(&source, &target, UInt32(factor), fade),
                    "plainComposite")

            case .bright(let bloom):
                var source = try image(.resolved)
                var target = try image(.down(0))
                try withUnsafeBytes(of: bloom) { bytes in
                    try check(
                        sc_post_bright(&source, &target, bytes.baseAddress, bytes.count), "brightPass")
                }

            case .downsample(let level):
                var source = try image(.down(level - 1))
                var target = try image(.down(level))
                try check(sc_post_downsample(&source, &target), "downsample")

            case .upsample(let level, let from):
                var source = try image(from)
                var base = try image(.down(level - 1))
                var target = try image(.up(level - 1))
                try check(sc_post_upsample(&source, &base, &target), "upsampleAdd")

            case .compact(let amount, let broad):
                var point = try image(.down(1))
                var wide = try image(.down(broad))
                var target = try image(.sharpSource)
                try check(sc_post_compact(&point, &wide, &target, amount), "compactLight")

            case .spikes(let spike, let source, let into):
                var from = try image(source)
                var target = try image(into)
                try withUnsafeBytes(of: spike) { bytes in
                    try check(
                        sc_post_spikes(&from, &target, bytes.baseAddress, bytes.count),
                        "diffractionSpikes")
                }

            case .composite(let composite, let bloom, let spikes):
                var frame = try image(.resolved)
                var glow = try image(bloom)
                var rays = try image(spikes)
                var target = try image(.output)
                try withUnsafeBytes(of: composite) { bytes in
                    try check(
                        sc_post_composite(
                            &frame, &glow, &rays, &target, bytes.baseAddress, bytes.count),
                        "composite")
                }
            }
        }
    }

    /// The picture `run` left, as 8-bit bytes in pinned host memory: rows from the top, valid
    /// until the next call.
    public func pack(_ format: Format = .rgb) throws -> UnsafeRawBufferPointer {
        var target = try handle(.output, light: nil)
        let size = sizes.picture
        try check(sc_post_pack(&target, packed.handle, format.raw), "packing the picture")
        let length = size.width * size.height * format.bytesPerPixel
        let bytes = UnsafeMutableRawBufferPointer(rebasing: host.bytes[0..<length])
        try packed.download(into: bytes)
        return UnsafeRawBufferPointer(bytes)
    }
}
