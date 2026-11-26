import Foundation

/// The commands of `sillage-cuda` and the options each reads (#465), held to them as
/// `RenderCommands` holds `sillage-render`'s: an option nothing reads, a value that does not parse
/// or a stray word is refused before a run starts on a rented GPU. A command that runs as its
/// `sillage-render` namesake shares its table.
public enum CUDACommands {
    private static func options(
        flags: String = "", text: String = "", whole: String = "", number: String = "",
        about: [String: String] = [:]
    ) -> [CommandSpec.Option] {
        CommandSpec.options(flags: flags, text: text, whole: whole, number: number, about: about)
    }

    static let threads = CommandSpec.options(whole: "threads", group: "On CUDA")

    static let explore = CommandSpec(
        "explore",
        summary: "Runs a scene's preview into its folder, as sillage-render explore does.",
        usage: ["usage: sillage-cuda explore <scene folder> [options]"], words: ["scene folder"],
        options: RenderCommands.render + threads)

    static let hires = CommandSpec(
        "hires",
        summary: "Computes an explored scene at a larger size, as sillage-render hires does.",
        usage: [
            "usage: sillage-cuda hires <scene folder> [--particles N] [--massive N] "
                + "[--pass massive|full] [options]"
        ],
        words: ["scene folder"], options: RenderCommands.render + threads)

    static let check = CommandSpec(
        "check",
        summary: "Builds the reference tree and draws the reference frames with this build.",
        usage: ["usage: sillage-cuda check [--fixtures <dir>] [--record <file>]"],
        options: options(text: "fixtures record", whole: "threads"))

    static let status = CommandSpec(
        "status",
        summary: "What the run of a scene's library is doing.",
        usage: ["usage: sillage-cuda status <scene folder>"], words: ["scene folder"])

    static let still = CommandSpec(
        "still",
        summary: "Draws frames of a take as PNGs, or moments of a flight with --flight.",
        usage: [
            "usage: sillage-cuda still <take> --look <look> --frames 0,200,900 --out <dir> [options]",
            "       sillage-cuda still <take> --look <look> --flight <file> --seconds 0,2.5,9 "
                + "--out <dir> [options]",
        ],
        words: ["take"],
        options: options(
            text: "look framing preset frames flight seconds out",
            whole: "width height fps rate threads", about: OptionHelp.cudaStill))

    static let export = CommandSpec(
        "export",
        summary: "Draws a take's video, with the look's camera or along a flight.",
        usage: [
            "usage: sillage-cuda export <scene folder | take> [--flight <name | file>] [--look <look>] "
                + "[--preset 1080p|4k|vertical|square|whatsapp] [options]"
        ],
        words: ["scene folder or take"],
        options: options(
            flags: "no-overlay profile resume whole-squares",
            text: "flight flight-at flight-keys look take framing preset codec speed slow overlay "
                + "out stills still-frames large-splats part summary",
            whole: "width height fps rate threads device segment-frames",
            number: "start duration bitrate", about: OptionHelp.export))

    static let blackHole = CommandSpec(
        "black-hole",
        summary: "Draws one moment of a black hole close up's take.",
        usage: ["usage: sillage-cuda black-hole still <folder> <png> [options]"],
        words: ["action", "folder", "png"],
        options: options(
            flags: "straight",
            text: "look temperature flight",
            whole: "width height images stars",
            number: "at elevation azimuth distance fov hottest beaming exposure thinning second",
            about: OptionHelp.blackHole))

    static let look = CommandSpec(
        "look",
        summary: "Chooses a scene's look: --palette or --promote. --style auto and --grid draw, on the Mac.",
        usage: [
            "usage: sillage-cuda look <scene folder> [--palette <name|auto> | --promote <name>] [options]"
        ],
        words: ["scene folder"],
        options: options(
            flags: "single generated", text: "palette promote camera world base", about: OptionHelp.look))

    static let pace = CommandSpec(
        "pace",
        summary: "Writes the story pace of a scene as a time track. The visual pace draws, on the Mac.",
        usage: [
            "usage: sillage-cuda pace <scene folder> --speed story[:pace[:top]] [--slow from:to:speed] "
                + "[--take <file>] [--out <file>] [--csv <file>]"
        ],
        words: ["scene folder"],
        options: options(text: "speed slow take out csv", about: OptionHelp.pace))

    public static let all: [CommandSpec] = [
        explore, hires, check, status, still, export, RenderCommands.match, RenderCommands.take,
        RenderCommands.flight, look, pace, blackHole,
    ]

    /// Whether `arguments`, the words after `sillage-cuda`, may run. `overview` is what a bare
    /// `sillage-cuda` or `--help` prints.
    public static func check(_ arguments: [String], overview: String) -> RenderCommands.Outcome {
        guard let first = arguments.first else { return .help(overview) }
        if ["--help", "-h", "help"].contains(first) { return .help(overview) }
        guard let spec = all.first(where: { $0.name == first }) else {
            let near = all.map(\.name).min {
                CommandSpec.distance($0, first) < CommandSpec.distance($1, first)
            }
            let hint = near.map { CommandSpec.distance($0, first) <= 2 ? ", did you mean \($0)?" : "" } ?? ""
            return .refused("sillage-cuda: no command \"\(first)\"\(hint)\nsee sillage-cuda help")
        }
        let rest = Array(arguments.dropFirst())
        let label = "sillage-cuda \(spec.name)"
        if rest.contains("--help") || rest.contains("-h") {
            return .help(spec.help.replacingOccurrences(of: "sillage-render", with: "sillage-cuda"))
        }
        do {
            let parsed = try spec.parse(rest)
            if spec.name == "black-hole", parsed.words.first != "still" {
                return .refused("\(label): only still runs here\n\(spec.usage[0])")
            }
            return .run
        } catch {
            return .refused(
                "\(label): \(error)\n\(spec.usage[0].replacingOccurrences(of: "sillage-render", with: "sillage-cuda"))"
            )
        }
    }
}
