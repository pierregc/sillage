import Foundation
import Testing

@testable import SillageCUDA

/// The C API's contexts, buffers and errors (#273), on whichever library the build linked.
@Suite("CUDA context")
struct CUDAContextTests {
    @Test func theContextSaysWhatItRunsOn() throws {
        let context = try CUDAContext()
        switch CUDAContext.target {
        case .cpu:
            #expect(CUDAContext.deviceCount == 1)
            #expect(context.name.contains("CPU target"))
            #expect(context.warpSize == 1 && context.memory == 0)
        case .gpu:
            #expect(CUDAContext.deviceCount >= 1)
            #expect(context.warpSize == 32 && context.memory > 0)
            #expect(context.computeCapability.major >= 8)
        }
        try context.synchronize()
    }

    @Test func aDeviceThatIsNotThereIsAnError() {
        let missing = CUDAContext.deviceCount
        let error = #expect(throws: CUDAError.self) { try CUDAContext(device: missing) }
        #expect(error?.code == .noDevice)
        #expect(error?.message.contains("no device \(missing)") == true)
    }

    @Test func aBufferHoldsWhatIsUploaded() throws {
        let context = try CUDAContext()
        let buffer = try context.makeBuffer(length: 64)
        #expect(try buffer.download(UInt8.self, count: 64).allSatisfy { $0 == 0 })
        try buffer.upload([UInt32](0..<8), at: 16)
        #expect(try buffer.download(UInt32.self, count: 8, from: 16) == Array(0..<8))
        #expect(try buffer.download(UInt32.self, count: 4) == [0, 0, 0, 0])
        try buffer.fill(0xAB)
        #expect(try buffer.download(UInt8.self, count: 64).allSatisfy { $0 == 0xAB })
        let other = try context.makeBuffer([Float](repeating: 2.5, count: 16))
        try buffer.copy(32, from: other, at: 8)
        #expect(try buffer.download(Float.self, count: 8) == [Float](repeating: 2.5, count: 8))
        #expect(try buffer.download(UInt8.self, count: 32, from: 32).allSatisfy { $0 == 0xAB })
    }

    @Test func aBufferRefusesWhatDoesNotFit() throws {
        let context = try CUDAContext()
        let buffer = try context.makeBuffer(length: 16)
        let past = #expect(throws: CUDAError.self) {
            try buffer.upload([UInt32](repeating: 1, count: 4), at: 4)
        }
        #expect(past?.code == .invalidArgument)
        #expect(past?.message.contains("do not fit") == true)
        #expect(throws: CUDAError.self) { try buffer.download(UInt8.self, count: 17) }
        #expect(throws: CUDAError.self) { try buffer.copy(8, from: buffer, at: 12) }
        let empty = try context.makeBuffer(length: 0)
        #expect(empty.length == 0)
        try empty.upload([UInt8]())
        #expect(try empty.download(UInt8.self, count: 0).isEmpty)
    }

    @Test func pinnedMemoryGoesBothWays() throws {
        let context = try CUDAContext()
        let pinned = try CUDAHostMemory(context: context, length: 4096)
        let floats = pinned.bytes.bindMemory(to: Float.self)
        for index in floats.indices { floats[index] = Float(index) }
        let buffer = try context.makeBuffer(length: 4096)
        try buffer.upload(UnsafeRawBufferPointer(pinned.bytes))
        for index in floats.indices { floats[index] = 0 }
        try buffer.download(into: pinned.bytes)
        #expect(floats.enumerated().allSatisfy { $0.element == Float($0.offset) })
    }
}
