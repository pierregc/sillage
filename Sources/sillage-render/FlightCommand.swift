import CoreGraphics
import Foundation
import SillageCore
import SillageRender
import simd

/// `story <scene folder | batch folder>`: the story judged again on curves already written,
/// one line a scene: the first collision, and where the story starts and ends or what still goes
/// on when the curves stop.
/// `flight <scene folder> --at <myr,...>`: `FlightReport`, shared with sillage-cuda (#467).
func flightCommand(_ arguments: [String]) -> Int32 {
    do {
        for line in try FlightReport.lines(arguments, catalogue: catalogueLooks()) { print(line) }
    } catch {
        fail("flight: \(error)")
    }
    return 0
}
