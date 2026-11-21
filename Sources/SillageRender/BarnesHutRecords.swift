import SillageCore

// The structs the Barnes-Hut kernels read from a buffer, as the MSL of BarnesHutShaders lays
// them out (#274). The Metal and the CUDA solvers fill them alike; KernelSourceTests holds each
// to the size cuda/src/kernels.cu holds the MSL's to.

public struct HaloGPU {
    public var centerBefore: SIMD4<Float>
    public var centerAfter: SIMD4<Float>
    /// Mass carrying G, scale radius, profile index, unused.
    public var shape: SIMD4<Float>
}

/// A black hole the solver pulls with outside the tree.
public struct HoleGPU {
    /// Mass times G in w.
    public var massG: SIMD4<Float>
    /// Softening squared, then the particle's index as a bit pattern.
    public var shape: SIMD4<Float>
}

public struct StarFormationGPU {
    public var efficiency: Float
    public var threshold: Float
    public var timeStep: Float
    public var time: Float
    public var gravitationalConstant: Float
    public var compressionBoost: Float
    public var compressionFloor: Float
    public var seed: UInt32
    public var nodeCount: UInt32
}

public struct DiskCoolingGPU {
    public var center: SIMD4<Float>
    public var motion: SIMD4<Float>
    public var axis: SIMD4<Float>
    public var reach: SIMD4<Float>
}

public struct BHParams {
    public var particleCount: UInt32
    public var haloCount: UInt32
    public var timeStep: Float
    public var openingAngleSquared: Float
    public var softeningSquared: Float
    public var gravitationalConstant: Float
    /// First particle of the piece being dispatched. The force pass is split so the display
    /// is not locked out for the length of one very large kernel.
    public var chunkStart: UInt32 = 0
    public var pad1: Float = 0
}

/// The sticky gas passes (#401), as `StickyParams` reads it.
public struct StickyGasGPU {
    public var soundSpeed: Float
    public var rate: Float
    public var crossing: Float
    public var reachSquared: Float
    public var timeStep: Float
    public var jeans: Float
    public var minimum: UInt32
    /// The nodes one dispatch runs over.
    public var first: UInt32 = 0
    public var end: UInt32 = 0
}

/// A copy of the drawn particles between two steps (#310), as `DrawnDriftParams` reads it.
public struct DrawnDriftGPU {
    public var tracerCount: UInt32
    public var massiveCount: UInt32
    public var timeStep: Float
    public var interval: Float

    public init(tracerCount: UInt32, massiveCount: UInt32, timeStep: Float, interval: Float) {
        self.tracerCount = tracerCount
        self.massiveCount = massiveCount
        self.timeStep = timeStep
        self.interval = interval
    }
}

/// The light tracers' fused force pass (#238), as `TracerStepParams` reads it.
public struct TracerStepGPU {
    public var tracerCount: UInt32
    public var haloCount: UInt32
    public var timeStep: Float
    public var openingAngleSquared: Float
    public var softeningSquared: Float
    public var gravitationalConstant: Float
    public var chunkStart: UInt32 = 0
    public var sortChunk: UInt32
    public var holeCount: UInt32
    public var diskCount: UInt32
    public var mode: UInt32
    public var pad: UInt32 = 0
}
