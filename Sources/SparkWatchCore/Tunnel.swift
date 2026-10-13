import Foundation

/// One SSH forward per node: `-L 127.0.0.1:<localPort>:localhost:11000`.
///
/// Why we own the tunnel instead of relying on NVIDIA Sync: the dashboard binds
/// loopback only, and Sync maps *one* device at a time (and sometimes picks a
/// random local port after sleep). Owning the forward ourselves is what makes
/// several boxes watchable at once, and it removes the Sync dependency entirely
/// — plain key-based SSH is already set up on both boxes (`BatchMode=yes` works).
///
/// `ExitOnForwardFailure=yes` is load-bearing: without it ssh stays alive after
/// failing to bind, and every request then lands on whatever else owns the port.
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

    public init(host: String, user: String, remotePort: Int = 11000, localPort: Int) {
        self.host = host
        self.user = user
        self.remotePort = remotePort
        self.localPort = localPort
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return process?.isRunning ?? false
    }

    public func start() throws {
        stop()
        try? FileManager.default.createDirectory(
            at: SettingsStore.directory, withIntermediateDirectories: true
        )
        reclaimAbandonedForward()

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
            "-L", "127.0.0.1:\(localPort):localhost:\(remotePort)",
            "\(user)@\(host)",
        ]
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try task.run()
        lock.lock()
        process = task
        lock.unlock()
        try? String(task.processIdentifier).write(to: pidFileURL, atomically: true, encoding: .utf8)
    }

    private var pidFileURL: URL {
        SettingsStore.directory.appending(path: "tunnel-\(localPort).pid")
    }

    /// Kill a forward we started earlier but never cleaned up.
    ///
    /// Without this, an abandoned tunnel keeps the local port bound: the next
    /// process's `ssh -L` dies on `ExitOnForwardFailure`, yet the port still
    /// answers (through the orphan), so everything *looks* healthy while nobody
    /// owns the forward. Verified exactly that while developing this.
    private func reclaimAbandonedForward() {
        guard let text = try? String(contentsOf: pidFileURL, encoding: .utf8),
            let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0
        else { return }
        if let existing = Self.commandLine(for: pid),
            existing.contains(":\(localPort):localhost:\(remotePort)")
        {
            kill(pid, SIGTERM)
            // ssh exits promptly; give it a moment before rebinding.
            usleep(200_000)
        }
        try? FileManager.default.removeItem(at: pidFileURL)
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
        return String(decoding: data ?? Data(), as: UTF8.self)
    }

    public func stop() {
        lock.lock()
        let existing = process
        process = nil
        lock.unlock()
        if let existing, existing.isRunning {
            existing.terminate()
            existing.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: pidFileURL)
    }

    deinit { stop() }
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
