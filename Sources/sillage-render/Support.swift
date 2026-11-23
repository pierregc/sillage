import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// Set by the stages that tell the status files what they are doing.
var reporter: StageReporter?

func fail(_ message: String, code: Int32 = 2) -> Never {
    RunSummary.end(status: code, error: message)
    FileHandle.standardError.write(Data((message + "\n").utf8))
    if let reporter {
        var event = RunEvent(RunEvent.Kind.error)
        event.stage = reporter.stage
        event.message = message
        reporter.record(event)
        reporter.finish()
    }
    exit(code)
}

/// The repository's own looks, `looks/*.look.json`, with the built in catalogue first.
func catalogueLooks() -> [LookFile] {
    do { return try LookCatalogue.fromRepository() } catch { fail("\(error)") }
}

/// The measured Hubble and Webb colour sets of `references/telescope`.
func telescopeReferences() -> [TelescopeReference] {
    do { return try TelescopeReference.fromRepository() } catch { fail("\(error)") }
}

extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}

/// The most the process has had resident at once, GPU buffers included: on unified memory
/// they count against the same footprint.
func peakFootprint() -> Int? {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Int(info.ledger_phys_footprint_peak) : nil
}
