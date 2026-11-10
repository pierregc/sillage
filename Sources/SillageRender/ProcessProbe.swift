import Foundation

#if canImport(Darwin)
    /// What the system says about a process: when it started, which tells a live process from
    /// another that was given the same pid since.
    public enum ProcessProbe {
        /// Nil when there is no such process, or only its zombie.
        public static func started(_ pid: Int32) -> Date? {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
            var info = kinfo_proc()
            var size = MemoryLayout<kinfo_proc>.stride
            guard pid > 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0,
                info.kp_proc.p_stat != SZOMB
            else { return nil }
            let start = info.kp_proc.p_un.__p_starttime
            return Date(timeIntervalSince1970: Double(start.tv_sec) + Double(start.tv_usec) / 1e6)
        }

        /// Whether `pid` is still the process that started at `started`; with no start to compare,
        /// a reused pid cannot be told apart, so it is not. The dates go through JSON with
        /// millisecond precision.
        public static func isAlive(pid: Int32?, started expected: Date?) -> Bool {
            guard let pid, let expected, let started = started(pid) else { return false }
            return abs(started.timeIntervalSince(expected)) < 0.01
        }
    }

    extension ProcessProbe {
        /// This user's processes called `name`, this one left out, each with its arguments.
        public static func others(named name: String) -> [(pid: Int32, arguments: [String])] {
            var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_UID, Int32(bitPattern: getuid())]
            var size = 0
            guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
            let stride = MemoryLayout<kinfo_proc>.stride
            var table = [kinfo_proc](repeating: kinfo_proc(), count: size / stride + 32)
            size = table.count * stride
            guard sysctl(&mib, 4, &table, &size, nil, 0) == 0 else { return [] }
            let me = getpid()
            return table.prefix(size / stride).compactMap { info in
                let pid = info.kp_proc.p_pid
                let command = withUnsafeBytes(of: info.kp_proc.p_comm) { raw in
                    String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
                }
                guard pid != me, info.kp_proc.p_stat != SZOMB, command == name else { return nil }
                return (pid, arguments(of: pid))
            }
        }

        /// A process's command line, empty when it cannot be read.
        public static func arguments(of pid: Int32) -> [String] {
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
            var buffer = [UInt8](repeating: 0, count: size)
            guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return [] }
            // argc, the executable's path, padding, then argc strings, each ended by a zero.
            let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
            var index = 4
            while index < size, buffer[index] != 0 { index += 1 }
            while index < size, buffer[index] == 0 { index += 1 }
            var arguments: [String] = []
            while arguments.count < count, index < size {
                let end = buffer[index..<size].firstIndex(of: 0) ?? size
                arguments.append(String(decoding: buffer[index..<end], as: UTF8.self))
                index = end + 1
            }
            return arguments
        }
    }

    /// Starting processes with `posix_spawn`: no descriptor of the parent leaks into them (a runner's
    /// lock held open by a child would outlive the runner), input from /dev/null, output to a log.
    public enum Spawn {
        /// This process's own executable. Not `Bundle.main`, which names the app for a tool
        /// bundled inside one.
        public static var currentExecutable: URL {
            var size: UInt32 = 0
            _NSGetExecutablePath(nil, &size)
            var path = [CChar](repeating: 0, count: Int(size) + 1)
            guard _NSGetExecutablePath(&path, &size) == 0 else {
                return URL(fileURLWithPath: CommandLine.arguments[0])
            }
            let bytes = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
            return URL(fileURLWithPath: String(decoding: bytes, as: UTF8.self)).standardizedFileURL
        }

        static let standardPath = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]

        /// In a session of its own: nothing that ends the parent's session or process group reaches
        /// it. Reaped on a thread of its own, so a parent that lives on keeps no zombie.
        public static func detached(_ executable: String, _ arguments: [String], log: URL) throws
            -> Int32
        {
            let pid = try spawn(executable, arguments, log: log, flags: POSIX_SPAWN_SETSID)
            Thread.detachNewThread {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
            }
            return pid
        }

        /// In a process group of its own, so one signal to the group reaches every process it
        /// starts. The caller waits for it.
        public static func child(_ executable: String, _ arguments: [String], log: URL) throws -> Int32 {
            try spawn(executable, arguments, log: log, flags: POSIX_SPAWN_SETPGROUP)
        }

        /// In the caller's own process group, so whatever suspends or stops the group, the queue's
        /// pause and cancel, reaches it too. The caller waits for it.
        public static func member(_ executable: String, _ arguments: [String], log: URL) throws
            -> Int32
        {
            try spawn(executable, arguments, log: log, flags: 0)
        }

        private static func spawn(
            _ executable: String, _ arguments: [String], log: URL, flags: Int32
        ) throws -> Int32 {
            try FileManager.default.createDirectory(
                at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            var attributes = posix_spawnattr_t(bitPattern: 0)
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            // Signals blocked or ignored where the parent spawns from would carry over, and a job
            // that ignores SIGTERM cannot be cancelled.
            posix_spawnattr_setflags(
                &attributes,
                Int16(flags | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF))
            posix_spawnattr_setpgroup(&attributes, 0)
            var none = sigset_t(0)
            var every = ~sigset_t(0)
            posix_spawnattr_setsigmask(&attributes, &none)
            posix_spawnattr_setsigdefault(&attributes, &every)
            var actions = posix_spawn_file_actions_t(bitPattern: 0)
            posix_spawn_file_actions_init(&actions)
            defer { posix_spawn_file_actions_destroy(&actions) }
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&actions, 1, log.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_adddup2(&actions, 1, 2)

            var environment = ProcessInfo.processInfo.environment
            // An app started from the Finder has a bare PATH, and the stages call python3 and
            // Homebrew's tools.
            let path = environment["PATH"].map { $0.split(separator: ":").map(String.init) } ?? []
            environment["PATH"] = (path + standardPath.filter { !path.contains($0) })
                .joined(separator: ":")
            let argv = ([executable] + arguments).map { strdup($0) } + [nil]
            let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
            defer { for pointer in argv + envp { free(pointer) } }
            var pid: Int32 = 0
            let code = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
            guard code == 0 else { throw QueueStore.Failure.system("posix_spawn \(executable)", code) }
            return pid
        }
    }
#else
    /// The queue's process calls rest on macOS's own, so on Linux nothing is probed and nothing
    /// is started.
    public enum ProcessProbe {
        public static func started(_ pid: Int32) -> Date? { nil }

        public static func isAlive(pid: Int32?, started expected: Date?) -> Bool { false }

        public static func others(named name: String) -> [(pid: Int32, arguments: [String])] { [] }

        public static func arguments(of pid: Int32) -> [String] { [] }
    }

    public enum Spawn {
        public static var currentExecutable: URL {
            URL(fileURLWithPath: "/proc/self/exe").resolvingSymlinksInPath()
        }

        public static func detached(_ executable: String, _ arguments: [String], log: URL) throws
            -> Int32
        {
            throw QueueStore.Failure.system("posix_spawn \(executable)", ENOSYS)
        }

        public static func child(_ executable: String, _ arguments: [String], log: URL) throws -> Int32 {
            throw QueueStore.Failure.system("posix_spawn \(executable)", ENOSYS)
        }

        public static func member(_ executable: String, _ arguments: [String], log: URL) throws
            -> Int32
        {
            throw QueueStore.Failure.system("posix_spawn \(executable)", ENOSYS)
        }
    }
#endif
