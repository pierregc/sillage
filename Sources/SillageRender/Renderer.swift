import Metal
import SillageCore
import simd

struct Uniforms {
    var viewProjection: simd_float4x4
    var pointSize: Float
    var exposure: Float
    var brightness: Float
    var pad: Float = 0
}

public struct RenderSettings {
    public var width: Int
    public var height: Int
    public var pointSize: Float
    public var exposure: Float
    public var brightness: Float

    public init(
        width: Int = 1920,
        height: Int = 1080,
        pointSize: Float = 2.4,
        exposure: Float = 1.0,
        brightness: Float = 0.016
    ) {
        self.width = width
        self.height = height
        self.pointSize = pointSize
        self.exposure = exposure
        self.brightness = brightness
    }
}

public enum RenderError: Error, CustomStringConvertible {
    case noDevice
    case shaderCompilation(String)
    case pipelineCreation(String)

    public var description: String {
        switch self {
        case .noDevice: "No Metal device available"
        case .shaderCompilation(let message): "Shader compilation failed: \(message)"
        case .pipelineCreation(let message): "Pipeline creation failed: \(message)"
        }
    }
}

/// Additively accumulates particles into an HDR target, then tone maps to 8-bit sRGB.
public final class Renderer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let splatPipeline: MTLRenderPipelineState
    private let tonemapPipeline: MTLComputePipelineState
    private let accumulation: MTLTexture
    private let output: MTLTexture
    private let settings: RenderSettings

    private var positionBuffer: MTLBuffer
    private var radiusBuffer: MTLBuffer
    private var galaxyBuffer: MTLBuffer
    private let particleCount: Int

    public init(particles: ParticleSystem, settings: RenderSettings) throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw RenderError.noDevice }
        self.device = device
        self.settings = settings
        self.particleCount = particles.count

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Shaders.source, options: nil)
        } catch {
            throw RenderError.shaderCompilation("\(error)")
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "splatVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "splatFragment")
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .rgba16Float
        attachment.isBlendingEnabled = true
        attachment.rgbBlendOperation = .add
        attachment.alphaBlendOperation = .add
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .one
        attachment.destinationAlphaBlendFactor = .one

        do {
            splatPipeline = try device.makeRenderPipelineState(descriptor: descriptor)
            tonemapPipeline = try device.makeComputePipelineState(
                function: library.makeFunction(name: "tonemap")!)
        } catch {
            throw RenderError.pipelineCreation("\(error)")
        }

        guard let queue = device.makeCommandQueue() else { throw RenderError.noDevice }
        self.queue = queue

        let hdr = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: settings.width, height: settings.height, mipmapped: false)
        hdr.usage = [.renderTarget, .shaderRead]
        hdr.storageMode = .private
        accumulation = device.makeTexture(descriptor: hdr)!

        let ldr = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: settings.width, height: settings.height, mipmapped: false)
        ldr.usage = [.shaderWrite, .shaderRead]
        ldr.storageMode = .shared
        output = device.makeTexture(descriptor: ldr)!

        let stride = MemoryLayout<SIMD3<Float>>.stride
        positionBuffer = device.makeBuffer(length: max(particles.count, 1) * stride)!
        radiusBuffer = device.makeBuffer(
            bytes: particles.birthRadius, length: max(particles.count, 1) * 4)!
        galaxyBuffer = device.makeBuffer(
            bytes: particles.galaxyIndex, length: max(particles.count, 1) * 4)!
        upload(positions: particles.positions)
    }

    /// Unified memory means this is a plain memcpy into a buffer the GPU already sees.
    public func upload(positions: [SIMD3<Float>]) {
        positions.withUnsafeBytes { source in
            positionBuffer.contents().copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
    }

    public func render(camera: Camera) -> [UInt8] {
        let aspect = Float(settings.width) / Float(settings.height)
        var uniforms = Uniforms(
            viewProjection: camera.viewProjection(aspectRatio: aspect),
            pointSize: settings.pointSize,
            exposure: settings.exposure,
            brightness: settings.brightness)

        let buffer = queue.makeCommandBuffer()!

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = accumulation
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
        encoder.setRenderPipelineState(splatPipeline)
        encoder.setVertexBuffer(positionBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(radiusBuffer, offset: 0, index: 1)
        encoder.setVertexBuffer(galaxyBuffer, offset: 0, index: 2)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: particleCount)
        encoder.endEncoding()

        let compute = buffer.makeComputeCommandEncoder()!
        compute.setComputePipelineState(tonemapPipeline)
        compute.setTexture(accumulation, index: 0)
        compute.setTexture(output, index: 1)
        compute.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        let groupWidth = 16
        compute.dispatchThreadgroups(
            MTLSize(
                width: (settings.width + groupWidth - 1) / groupWidth,
                height: (settings.height + groupWidth - 1) / groupWidth,
                depth: 1),
            threadsPerThreadgroup: MTLSize(width: groupWidth, height: groupWidth, depth: 1))
        compute.endEncoding()

        buffer.commit()
        buffer.waitUntilCompleted()

        var pixels = [UInt8](repeating: 0, count: settings.width * settings.height * 4)
        pixels.withUnsafeMutableBytes { destination in
            output.getBytes(
                destination.baseAddress!,
                bytesPerRow: settings.width * 4,
                from: MTLRegionMake2D(0, 0, settings.width, settings.height),
                mipmapLevel: 0)
        }
        return pixels
    }

    public var gpuName: String { device.name }
}
