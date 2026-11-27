import Foundation

/// The commands of `sillage-render` and the options each reads. `scripts/explore-batch.sh`, the
/// queue and the nights all end up here, so a name that is read in `Sources/sillage-render` and
/// is not in a table below is a name the command refuses (RenderCommandsTests holds the two
/// together).
public enum RenderCommands {
    public enum Outcome: Equatable {
        case run
        case help(String)
        case refused(String)
    }

    private static func options(
        flags: String = "", text: String = "", whole: String = "", number: String = "",
        about: [String: String] = [:], group: String? = nil
    ) -> [CommandSpec.Option] {
        CommandSpec.options(
            flags: flags, text: text, whole: whole, number: number, about: about, group: group)
    }

    /// What a render, an `explore` and a `hires` read between them: `hires` and `explore` hand
    /// their options on to the render that does the work.
    static let render =
        options(
            flags: "calm check check-only no-check",
            text: "preset scene solver pair-share sticky-gas",
            whole: "seed index galaxies look-seed",
            number: "archetypes spacing haste halo theta softening dt dt-scale dissipation",
            group: "The scene")
        + options(
            flags: "resume no-video profile",
            text: "pass export speed dt-schedule",
            whole: "particles steps frames width height fps settle take-interval take-memory "
                + "key-frames-span tracer-sort tracer-sort-chunk",
            number: "massive span story-cap story-after checkpoint-every",
            group: "The run")
        + options(
            text: "key-frames-at draw-stills draw-stills-dir", whole: "draw-divisor",
            group: "The full pass of a hires")
        + options(
            flags: "plain director immersed",
            text: "look camera center",
            whole: "stars supersample bloom-levels",
            number: "zoom percentile radius elevation elevation-end azimuth azimuth-end orbit arms "
                + "brightness dust dust-web star-size smoothing min-kernel max-kernel column "
                + "bloom bloom-threshold bloom-knee stretch saturation white-point tint glint "
                + "spikes spike-length spike-intensity sky noise fov old-width bulge-width "
                + "young-width knot-width",
            group: "The camera and the look")
        + options(
            flags: "no-sidecars",
            text: "out video curves thumbnail take scene-out look-out state-out summary",
            whole: "thumbnail-frame", group: "Files written")
        + options(
            text: "density dump-walk dump-walk-frames dump-targets dump-targets-frames take-v6 "
                + "take-massive sf-leaves",
            whole: "density-frames", number: "density-extent", group: "Measuring")
        + options(
            flags: "massive-only stop-after-key-frames",
            text: "massive-set dt-switches checkpoint draw draw-out draw-take key-frames "
                + "key-frame-list key-frame-curves",
            whole: "checkpoint-frames checkpoint-steps", number: "theta-tracers dt-judge",
            group: "Set by hires and explore, or for tests")

    static let plain = CommandSpec(
        "",
        summary: "Draws a scene: a PNG sequence, or a video with --video. Without any argument it "
            + "renders 1 000 000 particles of the merger preset.",
        usage: ["usage: sillage-render [options]"], options: render)

    static let explore = CommandSpec(
        "explore",
        summary: "Runs a scene and writes its preview into the scene folder. Alone it takes the "
            + "batch's defaults: 960x540, 900 frames at 30 fps, 700 Myr, a step scale of 7.",
        usage: ["usage: sillage-render explore <scene folder> [options]"], words: ["scene folder"],
        options: render)

    static let hires = CommandSpec(
        "hires",
        summary: "Runs an explored scene again at a larger size; a batch folder runs every scene "
            + "marked yes.",
        usage: ["usage: sillage-render hires <scene folder | batch folder> [options]"],
        words: ["scene folder"], options: render)

    static let look = CommandSpec(
        "look",
        summary: "Chooses a scene's style: --style auto, --palette, --promote, or --grid against "
            + "key frames of the take; any .look.json given is a row of the grid.",
        usage: [
            "usage: sillage-render look <scene folder> [--style auto | --palette <name|auto> | "
                + "--promote <name> | --grid] [options]"
        ],
        words: ["scene folder"], extraWords: true,
        options: options(
            flags: "grid single generated no-catalogue no-variants keep",
            text: "style palette promote camera world base take frames times stills",
            number: "width", about: OptionHelp.look))

    static let palettes = CommandSpec(
        "palettes",
        summary: "Draws palettes for a scene against a frame of its take, with their swatches.",
        usage: ["usage: sillage-render palettes <scene folder> [options]"], words: ["scene folder"],
        options: options(
            flags: "single", text: "world harmony family base",
            whole: "count seed best frame width", about: OptionHelp.palettes))

    static let export = CommandSpec(
        "export",
        summary: "Draws a scene's take as a video, or as stills with --stills.",
        usage: [
            "usage: sillage-render export <scene folder> [--preset 1080p|4k|vertical|square|"
                + "whatsapp] [options]"
        ],
        words: ["scene folder"],
        options: options(
            flags: "no-overlay single drawings-only",
            text: "preset codec format look palette world take out overlay framing speed slow summary "
                + "flight flight-at flight-keys flight-stills stills still-frames dump-targets "
                + "dump-targets-frames csv "
                + "drawings drawings-myr",
            number: "bitrate quality duration fps start width height from to seconds max-size",
            about: OptionHelp.export))

    static let pace = CommandSpec(
        "pace",
        summary: "Writes a time track for a scene: the pace a video plays the take at.",
        usage: [
            "usage: sillage-render pace <scene folder> --speed <story[:pace[:top]]|"
                + "visual[:top[:busiest]]> [--slow from:to:speed] [--take <file>] [--look <look>] "
                + "[--out <file>] [--csv <file>] [--drawings <dir> --drawings-myr <from>:<to>]"
        ],
        words: ["scene folder"],
        options: options(
            flags: "drawings-only", text: "speed slow take look out csv drawings drawings-myr",
            about: OptionHelp.pace))

    static let flight = CommandSpec(
        "flight",
        summary: "Prints the keys of a flight from a take, at the moments given.",
        usage: [
            "usage: sillage-render flight <scene folder> --at <myr,...> [--look <name>] "
                + "[--take <file>] [--arms <kpc,...>]"
        ],
        words: ["scene folder"], options: options(text: "at look take arms", about: OptionHelp.flight))

    static let match = CommandSpec(
        "match",
        summary: "Finds the moment and the view where a take overlaps a real picture best.",
        usage: [
            "usage: sillage-render match <scene folder> <picture.map.json> [--take <file>] [--at <myr>] "
                + "[--within <myr>] [--view <elevation,azimuth,roll>] [--span <degrees>] "
                + "[--kpc-across <kpc>] [--stars N] [--ceiling <decades>] [--measure <name>] [--fresh]"
        ],
        words: ["scene folder", "picture map"],
        options: options(
            flags: "fresh", text: "take view measure", whole: "stars",
            number: "at within span kpc-across ceiling", about: OptionHelp.match))

    static let take = CommandSpec(
        "take",
        summary: "Works on a take file: extract writes the frames around chosen moments as a take "
            + "of their own (#379).",
        usage: [
            "usage: sillage-render take extract <take> --at <myr,...> [--span <frames>] <out.sillage>"
        ],
        words: ["action", "take", "out"], options: options(text: "at", whole: "span", about: OptionHelp.take))

    static let story = CommandSpec(
        "story",
        summary: "Judges the story of a scene, or of every scene of a batch, from its curves.",
        usage: ["usage: sillage-render story <scene folder | batch folder>"], words: ["folder"])

    static let costs = CommandSpec(
        "costs",
        summary: "Refreshes the cost model of a library; --check <batch> sets it against a batch.",
        usage: ["usage: sillage-render costs [library] [--check <batch>]"], words: [],
        extraWords: true,
        options: options(text: "check", about: ["check": "sets the cost model against this batch"]))

    static let probeDisk = CommandSpec(
        "probe-disk",
        summary: "Runs one galaxy's disk alone and writes what it did.",
        usage: [
            "usage: sillage-render probe-disk <scene.json | scene folder> <galaxy index> "
                + "[--particles N] [--myr T] [--frame-myr T] [--seed S] [--out DIR] [--width W] "
                + "[--height H] [--no-clip] [--painted] [--lag-myr T] [--stills 0,300,...] "
                + "[--dt-scale X] [--softening KPC] ..."
        ],
        words: ["scene", "galaxy index"],
        options: options(
            flags: "no-clip painted calm", text: "out stills sf-leaves",
            whole: "particles seed width height arm-count",
            number: "myr frame-myr lag-myr dt-scale clumpiness toomre-q arm-strength "
                + "arm-irregularity disk-mass-fraction disk-thickness dissipation mass-contrast "
                + "streaming young-clumpiness dust-fraction dust-mass softening effective-q",
            about: OptionHelp.probeDisk))

    static let event = CommandSpec(
        "event",
        summary: "Appends an event to a batch's events.jsonl; each --field takes a value.",
        usage: ["usage: sillage-render event <batch folder> <kind> [--scene id] [--field value]..."],
        words: ["batch folder", "kind"], freeOptions: true)

    static let fixtures = CommandSpec(
        "fixtures",
        summary: "Writes the reference outputs both engines must give.",
        usage: ["usage: sillage-render fixtures <directory>"], words: ["directory"])

    static let holeFixtures = CommandSpec(
        "hole-fixtures",
        summary: "Writes the black hole close up's reference outputs (#336).",
        usage: ["usage: sillage-render hole-fixtures <directory>"], words: ["directory"])

    static let fields = CommandSpec(
        "fields",
        summary: "Prints the fields of a look file: what each does, its default and the range looks/ use.",
        usage: ["usage: sillage-render fields"])

    /// The commands this table holds to their options. `queue`, `night`, `status` and
    /// `black-hole` read their own.
    public static let all: [CommandSpec] = [
        explore, hires, look, export, palettes, story, probeDisk, costs, event, pace, flight, fixtures,
        holeFixtures, match, take, fields,
    ]

    /// Commands with a parser of their own: asked for help, they answer it.
    static let own = ["queue", "night", "status", "black-hole"]

    public static func spec(named name: String) -> CommandSpec? {
        name.isEmpty ? plain : all.first { $0.name == name }
    }

    /// The text of `sillage-render --help`.
    public static var overview: String {
        var lines = ["usage: sillage-render [options]", "       sillage-render <command> ..."]
        lines.append("")
        lines.append("Without a command it draws a scene: see `sillage-render --help` options below, or")
        lines.append("`sillage-render <command> --help` for one command.")
        lines.append("")
        lines.append("Commands:")
        let summaries: [(String, String)] =
            all.map { ($0.name, $0.summary) } + [
                ("queue", "The queue of heavy jobs: add, list, run, pause."),
                ("night", "Runs a night from a recipe file."),
                ("status", "What the queue and the nights are doing."),
                ("black-hole", "A black hole close up: new, run, still."),
            ]
        for (name, summary) in summaries.sorted(by: { $0.0 < $1.0 }) {
            let padded = name.padding(toLength: 11, withPad: " ", startingAt: 0)
            lines.append("  \(padded) \(summary.split(separator: ".").first.map(String.init) ?? summary)")
        }
        lines.append("")
        lines.append(plain.help)
        return lines.joined(separator: "\n")
    }

    /// Whether `arguments`, the words after `sillage-render`, may run. No argument at all is the
    /// default render.
    public static func check(_ arguments: [String]) -> Outcome {
        guard let first = arguments.first else { return .run }
        if first == "--help" || first == "-h" || first == "help" { return .help(overview) }
        if own.contains(first) { return .run }
        let (spec, rest): (CommandSpec, [String])
        if first.hasPrefix("--") {
            (spec, rest) = (plain, arguments)
        } else if let found = all.first(where: { $0.name == first }) {
            (spec, rest) = (found, Array(arguments.dropFirst()))
        } else {
            let names = all.map(\.name) + own
            let near = names.min { CommandSpec.distance($0, first) < CommandSpec.distance($1, first) }
            let hint =
                near.map { CommandSpec.distance($0, first) <= 2 ? ", did you mean \($0)?" : "" } ?? ""
            return .refused("sillage-render: no command \"\(first)\"\(hint)\nsee sillage-render --help")
        }
        if rest.contains("--help") || rest.contains("-h") { return .help(spec.help) }
        do {
            _ = try spec.parse(rest)
            return .run
        } catch {
            let label = spec.name.isEmpty ? "sillage-render" : "sillage-render \(spec.name)"
            return .refused("\(label): \(error)\n\(spec.usage.first ?? "")")
        }
    }
}
