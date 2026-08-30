import Foundation
import Metal

/// A window of snapshots kept resident ahead of the playhead.
///
/// Playback used to copy both surrounding snapshots into a staging buffer from the main
/// thread on every displayed frame: sixty megabytes at five million particles, measured at
/// 33 ms against a 16.7 ms budget, and most of it recopying what was already there, since at
/// the default speed the playhead crosses a snapshot only every other frame. That is the
/// stutter — the GPU sat half idle waiting for a memcpy, and on a take too large for the page
/// cache the copy went to the disk as well.
///
/// Each snapshot is copied once here, on a background queue, before it is wanted. The cache
/// is direct-mapped — slot `index % slots` — which is exactly right for playback, where the
/// wanted indices are consecutive; it also means a seek costs one blocking copy rather than a
/// scan. Two slots are kept clear ahead of the playhead so the reader never overwrites a
/// snapshot the GPU is still reading.
public final class SnapshotStream {
    public let slotCount: Int
    public var buffer: MTLBuffer { storage }

    private let recording: Recording
    private let storage: MTLBuffer
    private let slotStride: Int
    private let reader = DispatchQueue(
        label: "dev.pierregc.sillage.snapshots", qos: .userInitiated)
    /// Guards the residency table only, so a frame can ask what is resident without ever
    /// waiting behind a copy.
    private let table = NSLock()
    /// Held for the length of a copy, so the reader and a blocking fetch cannot write the
    /// same slot at once.
    private let copying = NSLock()
    private var resident: [Int]
    private var wanted = 0
    private var reading = false

    public init?(device: MTLDevice, recording: Recording, slots: Int = 8) {
        self.recording = recording
        self.slotCount = max(slots, 4)
        // Metal wants a bound offset aligned, and a snapshot of an odd number of particles
        // is not even four-byte aligned on its own.
        let frameBytes = max(recording.particleCount, 1) * 3 * 2
        self.slotStride = (frameBytes + 255) / 256 * 256
        guard
            let storage = device.makeBuffer(
                length: slotStride * self.slotCount, options: .storageModeShared)
        else { return nil }
        self.storage = storage
        self.resident = [Int](repeating: -1, count: self.slotCount)
    }

    private func slot(_ index: Int) -> Int { index % slotCount }

    /// The byte offset of a snapshot if it is already here. Never blocks.
    public func offset(of index: Int) -> Int? {
        table.lock()
        defer { table.unlock() }
        let place = slot(index)
        return resident[place] == index ? place * slotStride : nil
    }

    /// The byte offset of a snapshot, copying it here and now if the reader has not reached
    /// it yet. That only happens on the first frame after a seek.
    public func fetch(_ index: Int) -> Int? {
        if let offset = offset(of: index) { return offset }
        let place = slot(index)
        copying.lock()
        defer { copying.unlock() }
        // Another thread may have filled it while this one waited for the lock.
        if let offset = offset(of: index) { return offset }
        guard recording.copy(frame: index, into: storage, atByteOffset: place * slotStride) != nil
        else { return nil }
        table.lock()
        resident[place] = index
        table.unlock()
        return place * slotStride
    }

    /// Says where the playhead is. Cheap enough to call on every frame.
    public func prepare(from index: Int) {
        table.lock()
        wanted = index
        let busy = reading
        reading = true
        table.unlock()
        guard !busy else { return }
        reader.async { [weak self] in self?.fill() }
    }

    private func fill() {
        while true {
            table.lock()
            let from = wanted
            table.unlock()

            var copied = false
            for ahead in 0..<(slotCount - 2) {
                let index = from + ahead
                guard index < recording.count else { break }
                if offset(of: index) != nil { continue }
                copying.lock()
                if offset(of: index) == nil {
                    let place = slot(index)
                    if recording.copy(frame: index, into: storage, atByteOffset: place * slotStride)
                        != nil
                    {
                        table.lock()
                        resident[place] = index
                        table.unlock()
                        copied = true
                    }
                }
                copying.unlock()
                // The playhead may have moved on while that copy ran; start again from there.
                table.lock()
                let moved = wanted != from
                table.unlock()
                if moved { break }
            }

            table.lock()
            if !copied, wanted == from {
                reading = false
                table.unlock()
                return
            }
            table.unlock()
        }
    }

    /// After the take underneath changes, nothing held here is trustworthy.
    public func invalidate() {
        copying.lock()
        table.lock()
        for index in resident.indices { resident[index] = -1 }
        table.unlock()
        copying.unlock()
    }
}
