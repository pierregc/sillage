import Foundation
import Metal

struct WebUniforms {
    var eye: SIMD4<Float>
    var right: SIMD4<Float>
    var up: SIMD4<Float>
    var params: SIMD4<Float>
    var forward: SIMD4<Float>
    var target: SIMD4<Float>
    var carrier: SIMD4<Float>
}

/// The dust web's tuning (#173, docs/notes/dust-web.md) and what it draws with (#200).
enum DustWeb {
    /// Where in its life a copy of the web rests unsheared: at a quarter, the two copies of a
    /// cross-fade lean the same way and never cross-hatch.
    static let rest: Float = 0.25
    /// A cell of the web in scale lengths, and the smallest and largest it may be in kpc.
    static let cellShare: Float = 0.18
    static let smallestCell: Float = 0.4
    static let largestCell: Float = 1.6
    /// How much wider a grain is drawn under the web: wide enough for the grains to merge into
    /// one even layer, so the web and not the grains says where the dust is thin.
    static let carrier: Float = 2
    /// Texels on a side of the baked lace, which tiles every 64 cells (`laceTile` in the
    /// shader): about an accumulation pixel a texel on a disk filling a 2560 x 1440 canvas.
    static let laceTexels = 4096
    /// How many times coarser than the frame the carrier is drawn, per axis, and the smallest
    /// grain it takes in its own pixels, under which a grain would fall between them.
    static let carrierCoarse = 2
    static let carrierSmallest: Float = 3

    /// What a frame with the web draws with: before the splat pass, the grains under the web
    /// draw the dust they hand to it and the galaxy it belongs to into two coarse targets;
    /// the splat pass draws the rest of the dust as the painted strands lay it, multiplies
    /// that carrier by the web once per pixel, and goes on to the stars as before.
    struct Pass {
        let carrierPipeline: MTLRenderPipelineState
        let painted: MTLRenderPipelineState
        /// The same two for light tracers (#238).
        let tracerCarrier: MTLRenderPipelineState
        let tracerPainted: MTLRenderPipelineState
        let resolve: MTLRenderPipelineState
        let carrier: MTLTexture
        let tags: MTLTexture
        let lace: MTLTexture
        /// One over the lace's mean, so that the web moves no exposure.
        let scale: Float

        init(library: MTLLibrary, device: MTLDevice, width: Int, height: Int) throws {
            func pipeline(
                _ vertex: String, _ fragment: String, _ formats: [MTLPixelFormat],
                _ blends: [Int: MTLBlendOperation]
            ) throws -> MTLRenderPipelineState {
                let descriptor = MTLRenderPipelineDescriptor()
                descriptor.vertexFunction = library.makeFunction(name: vertex)
                descriptor.fragmentFunction = library.makeFunction(name: fragment)
                for (index, format) in formats.enumerated() {
                    guard let attachment = descriptor.colorAttachments[index] else { continue }
                    let blend = blends[index]
                    attachment.pixelFormat = format
                    attachment.writeMask = blend == nil ? [] : .all
                    attachment.isBlendingEnabled = blend != nil
                    attachment.rgbBlendOperation = blend ?? .add
                    attachment.alphaBlendOperation = blend ?? .add
                    attachment.sourceRGBBlendFactor = .one
                    attachment.sourceAlphaBlendFactor = .one
                    attachment.destinationRGBBlendFactor = .one
                    attachment.destinationAlphaBlendFactor = .one
                }
                do {
                    return try device.makeRenderPipelineState(descriptor: descriptor)
                } catch {
                    throw RenderError.pipelineCreation("\(fragment): \(error)")
                }
            }
            let frame: [MTLPixelFormat] = [.rgba16Float, .rgba16Float]
            carrierPipeline = try pipeline(
                "webCarrierVertex", "webCarrierFragment", [.rgba16Float, .rgba8Unorm],
                [0: .add, 1: .max])
            painted = try pipeline("dustWebVertex", "dustFragment", frame, [1: .add])
            tracerCarrier = try pipeline(
                "webCarrierTracerVertex", "webCarrierFragment", [.rgba16Float, .rgba8Unorm],
                [0: .add, 1: .max])
            tracerPainted = try pipeline("dustWebTracerVertex", "dustFragment", frame, [1: .add])
            resolve = try pipeline("webResolveVertex", "webResolveFragment", frame, [1: .add])

            func target(_ format: MTLPixelFormat) throws -> MTLTexture {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: format, width: max(width / carrierCoarse, 1),
                    height: max(height / carrierCoarse, 1), mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]
                descriptor.storageMode = .private
                guard let texture = device.makeTexture(descriptor: descriptor) else {
                    throw RenderError.textureAllocation
                }
                return texture
            }
            carrier = try target(.rgba16Float)
            tags = try target(.rgba8Unorm)
            let baked = try DustWeb.lace(library: library, device: device)
            lace = baked.texture
            scale = 1 / max(baked.mean, 1e-6)
        }
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var laces: [ObjectIdentifier: (texture: MTLTexture, mean: Float)] =
        [:]

    /// The lace, baked once per device and kept for as long as the process runs: it is static
    /// in each copy's own frame, so a pixel reads it in two filtered samples where it used to
    /// evaluate ninety hashes for every grain over it. Baked under the lock and waited for, so
    /// no renderer ever samples it half written.
    static func lace(library: MTLLibrary, device: MTLDevice) throws -> (
        texture: MTLTexture, mean: Float
    ) {
        lock.lock()
        defer { lock.unlock() }
        if let held = laces[ObjectIdentifier(device)] { return held }
        guard let function = library.makeFunction(name: "bakeLace") else {
            throw RenderError.pipelineCreation("missing kernel bakeLace")
        }
        let pipeline: MTLComputePipelineState
        do {
            pipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw RenderError.pipelineCreation("bakeLace: \(error)")
        }
        let side = laceTexels
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Float, width: side, height: side, mipmapped: true)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
            let queue = device.makeCommandQueue(),
            let buffer = queue.makeCommandBuffer(),
            let readback = device.makeBuffer(length: 256, options: .storageModeShared),
            let compute = buffer.makeComputeCommandEncoder()
        else { throw RenderError.textureAllocation }
        compute.setComputePipelineState(pipeline)
        compute.setTexture(texture, index: 0)
        compute.dispatchThreadgroups(
            MTLSize(width: (side + 15) / 16, height: (side + 15) / 16, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
        guard let blit = buffer.makeBlitCommandEncoder() else { throw RenderError.textureAllocation }
        blit.generateMipmaps(for: texture)
        // The last level is one texel, the mean of the whole tile.
        blit.copy(
            from: texture, sourceSlice: 0, sourceLevel: texture.mipmapLevelCount - 1,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0), sourceSize: MTLSize(width: 1, height: 1, depth: 1),
            to: readback, destinationOffset: 0, destinationBytesPerRow: 256,
            destinationBytesPerImage: 256)
        blit.endEncoding()
        buffer.commit()
        buffer.waitUntilCompleted()
        let mean = Float(Float16(bitPattern: readback.contents().load(as: UInt16.self)))
        laces[ObjectIdentifier(device)] = (texture, mean)
        return (texture, mean)
    }
}
