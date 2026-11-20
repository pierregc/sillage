import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// `event <batch folder> <kind> [--field value]...`: one line appended to the batch's
/// `events.jsonl`, for the scripts that run the stages and have no JSON of their own to write.
func eventCommand(_ arguments: [String]) -> Int32 {
    guard arguments.count >= 2, !arguments[0].hasPrefix("--"), !arguments[1].hasPrefix("--") else {
        fail("usage: sillage-render event <batch folder> <kind> [--scene id] [--field value]...")
    }
    let batch = URL(fileURLWithPath: arguments[0], isDirectory: true)
    do {
        let event = try RunEvent(arguments[1], options: Array(arguments.dropFirst(2)))
        try RunStatusFiles.append(event, to: RunStatusFiles.events(batch: batch))
        return 0
    } catch {
        fail("event: \(error)")
    }
}
