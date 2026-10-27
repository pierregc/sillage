import Foundation

/// `sillage-render status`: the lines the app shows, from the terminal.
public enum StatusCommand {
    public static let usage = """
        usage: sillage-render status [--library DIR]
        Prints what runs, what waits and what ended last. DIR is by default $SILLAGE_LIBRARY or
        the repository's library/. For fixtures: --now ISO8601, --timezone ID, --fixture N, which takes
        N sillage-render processes as running and a running job as alive.
        """

    public static func main(_ arguments: [String], say: (String) -> Void = { print($0) }) -> Int32 {
        var library = QueueCommand.defaultLibrary()
        var now = Date()
        var timeZone = TimeZone.current
        var processes: [QueueStatus.ProcessInfo]?
        var fixture = false
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else {
                say(usage)
                return 2
            }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--library": library = URL(fileURLWithPath: value, isDirectory: true)
            case "--now":
                guard let date = RunStatus.date(value) else {
                    say("status: \(value) is not an ISO 8601 date")
                    return 2
                }
                now = date
            case "--timezone":
                guard let zone = TimeZone(identifier: value) else {
                    say("status: no time zone \(value)")
                    return 2
                }
                timeZone = zone
            case "--fixture":
                guard let count = Int(value), count >= 0 else {
                    say("status: \(value) is not a number of processes")
                    return 2
                }
                fixture = true
                processes = (0..<count).map {
                    .init(pid: Int32(1_000 + $0), arguments: ["sillage-render", "render"])
                }
            default:
                say(usage)
                return 2
            }
            index += 2
        }
        let real = !fixture
        let alive: @Sendable (QueueJob) -> Bool = { job in
            !real || ProcessProbe.isAlive(pid: job.pid, started: job.pidStarted)
        }
        let status = QueueStatus.read(
            library: library, now: now, timeZone: timeZone, processes: processes,
            isAlive: alive)
        for line in status.lines { say(line) }
        return 0
    }
}
