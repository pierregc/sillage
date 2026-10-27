import AppKit
import Foundation
import SillageRender

/// `--queuesoak <scene> [hires options]`: puts a hires of the scene in the queue from the app,
/// as the app's own buttons will, and writes a line every five seconds to
/// `/tmp/sillage-queuesoak.log`: frames done, the job's processor time, the GPU's use and
/// whether the window is visible. With the display put to sleep halfway (`pmset
/// displaysleepnow`), it shows whether a job the app started keeps its pace, as `--soak` did for
/// a run inside the app (`docs/notes/app-nap.md`). The app may quit at any point: the job goes on.
@MainActor
enum QueueSoak {
    static func run() {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--queuesoak"), flag + 1 < arguments.count else {
            return
        }
        let path = URL(fileURLWithPath: "/tmp/sillage-queuesoak.log")
        let scene = SceneFolder(path: arguments[flag + 1])
        let model = QueueModel(library: scene.library)
        let job: QueueJob
        do {
            job = try model.submit(
                .hires, path: scene.url.path, options: Array(arguments.dropFirst(flag + 2))
            ).job
        } catch {
            try? "\(error)".write(to: path, atomically: true, encoding: .utf8)
            return
        }

        Task {
            let clock = Date()
            let stamp = DateFormatter()
            stamp.dateFormat = "HH:mm:ss"
            var lines = [
                "travail \(job.id), \(job.summary)",
                "heure     wall s  images  im/min   cpu s  cpu/s  gpu %  fenêtre  état",
            ]
            var last = (wall: 0.0, frames: 0, cpu: 0.0)
            while true {
                try? await Task.sleep(for: .seconds(5))
                model.refresh()
                guard let current = model.queue.job(job.id) else { continue }
                let wall = Date().timeIntervalSince(clock)
                let frames = current.log.map(framesDone) ?? 0
                let cpu = current.pid.flatMap(processorSeconds) ?? last.cpu
                let span = max(wall - last.wall, 1e-6)
                let visible = NSApp.windows.contains { $0.occlusionState.contains(.visible) }
                lines.append(
                    String(
                        format: "%@  %6.0f  %6d  %6.1f  %6.1f  %5.2f  %5.0f  %@  %@",
                        stamp.string(from: Date()), wall, frames,
                        Double(frames - last.frames) / span * 60, cpu, (cpu - last.cpu) / span,
                        GPUUtilisation.read() ?? -1, visible ? "visible" : "cachée ",
                        current.state.rawValue))
                last = (wall, frames, cpu)
                try? lines.joined(separator: "\n").write(to: path, atomically: true, encoding: .utf8)
                if current.isFinished { return }
            }
        }
    }

    /// The frames `sillage-render` has logged so far, one `frame` line each.
    private static func framesDone(_ log: String) -> Int {
        ((try? String(contentsOfFile: log, encoding: .utf8)) ?? "")
            .split(separator: "\n").filter { $0.hasPrefix("frame ") }.count
    }

    /// Another process's processor time, user and system, in seconds.
    private static func processorSeconds(_ pid: Int32) -> Double? {
        var info = rusage_info_v2()
        let found = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
            }
        }
        guard found == 0 else { return nil }
        var base = mach_timebase_info_data_t()
        mach_timebase_info(&base)
        return Double(info.ri_user_time + info.ri_system_time) * Double(base.numer)
            / Double(base.denom) / 1e9
    }
}
