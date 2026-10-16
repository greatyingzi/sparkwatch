import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// One SSH forward per node: `-L 127.0.0.1:<localPort>:localhost:<remotePort>`.
///
/// Why we own the tunnel instead of relying on NVIDIA Sync: the dashboard binds
/// loopback only, and Sync maps *one* device at a time (and sometimes picks a
/// random local port after sleep). Owning the forward ourselves is what makes
/// several boxes watchable at once, and it removes the Sync dependency entirely
/// — plain key-based SSH is already set up on both boxes (`BatchMode=yes` works).
///
/// `ExitOnForwardFailure=yes` is load-bearing: without it ssh stays alive after
/// failing to bind, and every request then lands on whatever else owns the port.
///
/// The other half of that story (measured 2026-10-16): ssh connects *first* and
/// binds the forward afterwards, so a spawn that is going to fail still leaves a
/// live process for a second or two. Recording the pid right after `run()`
/// therefore wrote down a process that was about to die, overwriting the pid of
/// the orphan that really held the port — and once that record was gone, every
/// later launch spawned a fresh ssh that died on `ExitOnForwardFailure` while the
/// orphan kept answering, so 19100/19101 stayed bound for hours with nobody
/// owning them. Hence the two rules below: record a pid only for a forward that
/// is *provably up*, and treat the process table (not the pid file) as the
/// authority on who owns our port.
public final class SshTunnel: @unchecked Sendable {
    public let host: String
    public let user: String
    /// The port on the far side. 11000 is the dashboard; an engine's own HTTP port
    /// is forwarded the same way, so reading it is a loopback call instead of a
    /// fresh SSH handshake per probe.
    public let remotePort: Int
    public let localPort: Int

    private let lock = NSLock()
    private var process: Process?
    /// Where the pid record lives. Injectable so a test can exercise the record
    /// policy without touching — or reclaiming from — the user's real tunnels.
    private let pidDirectory: URL

    public init(
        host: String,
        user: String,
        remotePort: Int = 11000,
        localPort: Int,
        pidDirectory: URL? = nil
    ) {
        self.host = host
        self.user = user
        self.remotePort = remotePort
        self.localPort = localPort
        self.pidDirectory = pidDirectory ?? SettingsStore.directory
    }

    /// How long a forward gets to appear before it counts as failed. ssh connects
    /// first (`ConnectTimeout=8`) and binds after, so this has to be comfortably
    /// longer than that.
    public static let readinessTimeout: TimeInterval = 12

    /// How long a child gets to exit after SIGTERM before it is SIGKILLed. Bounded
    /// because the callers are actors: waiting on a wedged ssh is unbounded, and
    /// doing it from an actor's executor has frozen this app before.
    static let retireTimeout: TimeInterval = 0.4

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public func start() throws {
        stop()
        try? FileManager.default.createDirectory(
            at: pidDirectory, withIntermediateDirectories: true
        )
        reclaimAbandonedForward()

        // A port we could not free belongs to somebody else: our `ssh -L` is
        // guaranteed to die on `ExitOnForwardFailure`, so fail now — with a reason
        // the caller can surface — instead of spawning a process that only lingers.
        if TcpProbe.isOpen(port: localPort) {
            throw TunnelError.forwardFailed(host: host, localPort: localPort)
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-N",
            "-o", "BatchMode=yes",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=8",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-o", "StrictHostKeyChecking=accept-new",
            "-L", Self.forwardSpec(localPort: localPort, remotePort: remotePort),
            "\(user)@\(host)",
        ]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        lock.lock()
        process = task
        lock.unlock()

        // Waiting for the forward to come up means waiting out ssh's connect
        // phase (up to `ConnectTimeout`), and this is called from a node runtime —
        // i.e. from an actor. Blocking there would freeze snapshots for seconds,
        // so the wait happens off to the side:
        //
        //   * the pid record is written only once the forward is *provably* up
        //     (that is the 2026-10-16 fix — a record written at spawn time named a
        //     process that was about to die and buried the real orphan);
        //   * a spawn that bound nothing is retired instead of left to linger;
        //   * callers keep their own non-blocking readiness check
        //     (`DashboardClient.isDashboard`), and recovery no longer trusts this
        //     file at all — `reclaimAbandonedForward` reads the process table.
        Task.detached { [weak self] in
            guard let self else { return }
            let up = TunnelReadiness.verify(
                process: task, localPort: self.localPort, timeout: Self.readinessTimeout
            )
            guard self.isCurrent(task) else { return }
            if up {
                try? String(task.processIdentifier)
                    .write(to: self.pidFileURL, atomically: true, encoding: .utf8)
            } else {
                TunnelReadiness.retire(task)
                self.forget(task)
            }
        }
    }

    private func isCurrent(_ task: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return process === task
    }

    private func forget(_ task: Process) {
        lock.lock()
        if process === task { process = nil }
        lock.unlock()
    }

    /// The one spelling of our forward, shared by the ssh arguments and the
    /// process-table matcher so the two can never drift apart.
    public static func forwardSpec(localPort: Int, remotePort: Int) -> String {
        "127.0.0.1:\(localPort):localhost:\(remotePort)"
    }

    /// Is this command line one of *our* forwards for this pair of ports?
    ///
    /// Deliberately strict: the reclaim step kills what matches, so it must not
    /// be able to match "some other app's ssh on some other port" — a substring
    /// test on the port alone would. This machine legitimately runs unrelated
    /// forwards (a memory-hub tunnel, for one).
    public static func isOurForward(_ command: String, localPort: Int, remotePort: Int) -> Bool {
        let isSSH = command.contains("/ssh ") || command.hasPrefix("ssh ")
        guard isSSH else { return false }
        return command.contains("-L \(forwardSpec(localPort: localPort, remotePort: remotePort))")
    }

    /// Every live process that owns this forward, from the process table.
    public static func matchingForwards(localPort: Int, remotePort: Int) -> [Int32] {
        guard let listing = processTable() else { return [] }
        var out: [Int32] = []
        for line in listing.split(separator: "\n") {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2, let pid = Int32(parts[0]) else { continue }
            if isOurForward(String(parts[1]), localPort: localPort, remotePort: remotePort) {
                out.append(pid)
            }
        }
        return out
    }

    private var pidFileURL: URL {
        pidDirectory.appending(path: "tunnel-\(localPort).pid")
    }

    /// Kill every forward that holds a port we need to own. Returns true when
    /// something was actually killed.
    ///
    /// Two sources on purpose: the pid file is the fast path, but it is a *claim*,
    /// not evidence — it can be stale, or (before the readiness fix above) it can
    /// name a spawn that never bound anything. The process table is the evidence,
    /// and using it is what makes recovery possible without a restart.
    @discardableResult
    private func reclaimAbandonedForward() -> Bool {
        var killed = false
        if let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0,
            let command = Self.commandLine(for: pid),
            Self.isOurForward(command, localPort: localPort, remotePort: remotePort)
        {
            kill(pid, SIGTERM)
            Self.awaitExit(pid, timeout: 0.5)
            killed = true
        }
        try? FileManager.default.removeItem(at: pidFileURL)

        for pid in Self.matchingForwards(localPort: localPort, remotePort: remotePort)
        where pid != getpid() {
            kill(pid, SIGTERM)
            killed = true
        }
        // Only wait for the socket when we actually retired something: ssh exits
        // promptly on SIGTERM, but a port held by an unrelated process will never
        // come free by waiting, and the pre-flight check below reports that case.
        guard killed else { return false }
        let deadline = Date().addingTimeInterval(1.5)
        while Date() < deadline, TcpProbe.isOpen(port: localPort) {
            usleep(100_000)
        }
        return true
    }

    private static func commandLine(for pid: Int32) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "command=", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private static func processTable() -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-Ao", "pid=,command="]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// SIGTERM, then SIGKILL if it is still there. Bounded on purpose:
    /// `waitUntilExit()` on a wedged ssh is unbounded, and doing that from an
    /// actor's executor has frozen this app before. A monitor must never block on
    /// a child it can do without.
    static func awaitExit(_ pid: Int32, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if kill(pid, 0) != 0 { return }
            usleep(50_000)
        }
        kill(pid, SIGKILL)
    }

    public func stop() {
        lock.lock()
        let existing = process
        process = nil
        lock.unlock()
        if let existing, existing.isRunning {
            TunnelReadiness.retire(existing)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    deinit { stop() }
}

public enum TunnelError: Error, CustomStringConvertible {
    case forwardFailed(host: String, localPort: Int)

    public var description: String {
        switch self {
        case let .forwardFailed(host, localPort):
            "SSH 隧道建立失败（\(host) → 127.0.0.1:\(localPort)；端口被占或对端不可达）"
        }
    }
}

/// A TCP connect test against a loopback port: it answers "is the forward really
/// up?", which is not the same question as "did ssh start?" — the two differ for
/// a second or two, and that window is what produced the orphaned forwards.
public enum TcpProbe {
    public static func isOpen(port: Int, timeout: TimeInterval = 0.2) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(truncatingIfNeeded: port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var tv = timeval(
            tv_sec: Int(timeout),
            tv_usec: suseconds_t((timeout - Double(Int(timeout))) * 1_000_000)
        )
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        return withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}

/// When a freshly spawned forward may be written down as "ours".
public enum TunnelReadiness {
    /// Both halves are required, and neither alone is enough: the process must
    /// still be alive (a bind that failed exits within about a second of
    /// connecting — `ExitOnForwardFailure`), *and* the port must answer (an ssh
    /// that is still connecting has not bound anything yet).
    public static func shouldRecord(processAlive: Bool, portOpen: Bool) -> Bool {
        processAlive && portOpen
    }

    /// Polls until the forward is up, the process dies, or the budget runs out.
    public static func verify(process: Process, localPort: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if TcpProbe.isOpen(port: localPort) {
                // Settle once: a doomed bind is rejected by the far side right
                // after it succeeds locally, so require the process to still be
                // there a moment later before taking ownership of the record.
                usleep(300_000)
                return shouldRecord(processAlive: process.isRunning, portOpen: true)
            }
            usleep(100_000)
        }
        return false
    }

    /// Ask a child to go away without waiting on it for ever.
    static func retire(_ process: Process) {
        let pid = process.processIdentifier
        process.terminate()
        SshTunnel.awaitExit(pid, timeout: SshTunnel.retireTimeout)
    }
}

/// Exponential backoff shared by reconnection paths.
/// Adapted from AdrianBinDC/DGXPulse (MIT, © 2026 Adrian Bolinger).
public enum ReconnectBackoff {
    public static func delay(
        forAttempt attempt: Int,
        base: Duration = .milliseconds(500),
        cap: Duration = .seconds(30)
    ) -> Duration {
        let clamped = max(0, min(attempt, 16))
        let multiplier = pow(2.0, Double(clamped))
        let baseNanos = Double(base.components.seconds) * 1_000_000_000
            + Double(base.components.attoseconds) / 1_000_000_000
        let capNanos = Double(cap.components.seconds) * 1_000_000_000
            + Double(cap.components.attoseconds) / 1_000_000_000
        return .nanoseconds(Int64(min(baseNanos * multiplier, capNanos)))
    }
}

/// Never log a session token.
public enum TokenRedactor {
    public static func redact(_ token: String) -> String {
        token.count > 4 ? "…" + token.suffix(4) : "…****"
    }
}
