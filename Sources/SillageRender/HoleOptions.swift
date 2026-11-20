import Foundation
import SillageCore

/// The words, `--name value` options and `--flag`s of `sillage-render black-hole` and
/// `sillage-cuda black-hole` (#336).
public struct HoleOptions {
    public var words: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []

    public init(_ arguments: [String]) {
        var index = 0
        while index < arguments.count {
            let word = arguments[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") {
                    values[name] = arguments[index + 1]
                    index += 2
                    continue
                }
                flags.insert(name)
            } else {
                words.append(word)
            }
            index += 1
        }
    }

    public func float(_ name: String) -> Float? { values[name].flatMap(Float.init) }
    public func double(_ name: String) -> Double? { values[name].flatMap(Double.init) }
    public func int(_ name: String) -> Int? { values[name].flatMap(Int.init) }

    /// The look asked, with the view's options over it.
    public func look(folder: SceneFolder) throws -> HoleLookFile {
        var look = try folder.holeLook(values["look"])
        if flags.contains("straight") { look.lensed = false }
        if let value = int("images") { look.images = value }
        if let value = values["temperature"].flatMap(HoleLookFile.Temperature.init) {
            look.temperature = value
        }
        if let value = double("hottest") { look.hottest = value }
        if let value = double("beaming") { look.beaming = value }
        if let value = double("exposure") { look.exposure = value }
        if let value = int("stars") { look.stars = value }
        if let value = double("thinning") { look.thinning = value }
        if let value = double("elevation") { look.camera.elevation = value }
        if let value = double("azimuth") { look.camera.azimuth = value }
        if let value = double("distance") { look.camera.distance = value }
        if let value = double("fov") { look.camera.fieldOfView = value }
        try look.validate()
        return look
    }
}
