import Foundation
import SillageCore

/// What a checkpoint keeps of a run besides its particles' buffers (#240): everything the
/// next step reads that the positions do not give back.
public struct SolverState: Codable, Sendable {
    public var count: Int
    public var tracers: Int
    public var time: Float
    public var stepsSinceTree: Int
    public var stepsSinceFormation: Int
    public var haloCenters: [SIMD3<Float>]
    public var massCenters: [SIMD3<Float>]
    public var galaxyMotion: [SIMD3<Float>]
    public var diskStates: [DiskState]
}

/// Where the drawing stands, for a checkpoint (#240): what a resumed run carries on from.
public struct VideoProgress: Codable, Sendable, Equatable {
    public var frames = 0
    public var seconds: [Double] = []
    public var drift: Float = 0
    public var firstDrift: Int?
    public var checkedFrames = 0
    /// The segment being written, and the frame it starts at; those before it are whole, in
    /// `segments`.
    public var segment = 0
    public var segmentStart = 0
    /// Per format, the file names of the whole segments, in order.
    public var segments: [[String]] = []

    public init() {}
}

/// A key frame of the massive pass a take kept, and where it came from (#239).
public struct KeyFrameEntry: Codable, Sendable, Equatable {
    /// The captured frame of the run, as the curves count it.
    public var frame: Int
    public var role: String
    public var timeMyr: Double
}
