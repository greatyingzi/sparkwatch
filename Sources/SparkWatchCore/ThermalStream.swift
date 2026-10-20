import Foundation

/// A 2-second thermal/power telemetry stream, held open over **one** SSH session.
///
/// Why this exists: the values that decide whether a Spark is about to hard
/// power-off are `acpitz` (the ACPI zone the box actually shuts down on) and the
/// SM clock — and both were only read on the 60-second slow probe. The published
/// crash curve is 2.5 minutes long (clock 2450 → 1475 within ~150 s, then a hard
/// power-off at ~96 °C zone temperature), so at 60 s there are two or three points
/// and no curve at all. Measured on this fleet: `nvidia-smi` reads 8–15 °C lower
/// than the zone, so a GPU-rail 84 °C is already ~92 °C on the zone — one sample
/// from the cutoff.
///
/// Why a stream rather than a faster poll: a fresh `ssh` costs 1.27 s per call on
/// this tailnet (measured, 5 calls = 6.37 s), while a multiplexed exec costs
/// 0.25 s and a full fast probe 0.47 s. A standing stream pays the handshake once
/// and then each sample is ~30 bytes with zero round trips. It is also what the
/// field reports prescribe: sample on the box, ship the samples off-box, because
/// the box's own journal dies with the power.
///
/// Nothing is installed on the target and nothing survives the connection: the
/// loop is a shell one-liner running inside this SSH session, and it dies with it.
public struct ThermalSample: Sendable, Equatable, Codable {
    /// Receive time on this Mac (the series axis — a box clock reset cannot move it).
    public var at: Date
    /// The box's own clock at sample time, for CPU-utilisation deltas.
    public var boxEpochMS: Double
    public var acpitzMaxC: Double?
    /// The zone's own declared trip point (`trip_point_0_temp`), 104.8 °C on GB10.
    public var thermalLimitC: Double?
    public var gpuW: Double?
    public var utilPct: Double?
    public var gpuTempC: Double?
    public var smClockMHz: Double?
    public var smClockMaxMHz: Double?
    public var thermalSlowdown: Bool = false
    public var hwSlowdown: Bool = false
    public var powerCapActive: Bool = false
    public var cpuUsagePct: Double?
    /// Mean of the per-policy clocks (GB10: one 3.9 GHz cluster, one 2.808 GHz).
    public var cpuFreqMHz: Double?
    public var cpuFreqMaxMHz: Double?

    public init(at: Date = Date(), boxEpochMS: Double = 0) {
        self.at = at
        self.boxEpochMS = boxEpochMS
    }

    /// Current ÷ maximum clock, clamped to a sane range. Nil when either is unknown.
    public var cpuFreqRatio: Double? {
        guard let current = cpuFreqMHz, let ceiling = cpuFreqMaxMHz, ceiling > 0, current > 0 else {
            return nil
        }
        return min(1.2, Swift.max(0.2, current / ceiling))
    }
}

/// Identifies one boot of the box, so a reboot is detectable without polling uptime.
public struct BootIdentity: Sendable, Equatable, Codable {
    public var bootID: String
    public var uptimeSeconds: Double?
    public var cpuCount: Int?
    public var seenAt: Date

    public init(bootID: String, uptimeSeconds: Double?, cpuCount: Int?, seenAt: Date = Date()) {
        self.bootID = bootID
        self.uptimeSeconds = uptimeSeconds
        self.cpuCount = cpuCount
        self.seenAt = seenAt
    }
}

public enum ThermalStreamEvent: Sendable, Equatable {
    case boot(BootIdentity)
    case sample(ThermalSample)
}

/// Wire format, one line per event, pipe-separated:
///
///     B|<boot_id>|<uptime_s>|<nproc>
///     S|<epoch_ms>|<acpitz mdeg...>|<trip mdeg>|<power,util,gputemp,smclk,smclkmax,swthermal,hwthermal,powercap>|<proc/stat cpu line>|<policy freqs kHz...>
///
/// Parsing is stateful only for CPU utilisation, which is a delta between two
/// `/proc/stat` reads — the same reason the slow probe takes two samples a second
/// apart. A missing field is `nil`, never zero: a zero would read as "idle" and a
/// made-up idle is exactly the lie this app exists to avoid.
public struct ThermalStreamParser: Sendable {
    private var previousCPU: (total: Double, idle: Double)?

    public init() {}

    public mutating func consume(_ rawLine: String) -> ThermalStreamEvent? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return nil }

        switch kind {
        case "B":
            guard parts.count >= 2, !parts[1].isEmpty else { return nil }
            return .boot(
                BootIdentity(
                    bootID: parts[1],
                    uptimeSeconds: parts.count > 2 ? Double(parts[2]) : nil,
                    cpuCount: parts.count > 3 ? Int(parts[3]) : nil
                )
            )
        case "S":
            guard parts.count >= 5 else { return nil }
            var sample = ThermalSample()
            sample.boxEpochMS = Double(parts[1]) ?? 0
            sample.at = Date()

            let zones = parts[2].split(separator: " ").compactMap { Double($0) }
            if let hottest = zones.max() {
                sample.acpitzMaxC = hottest > 1000 ? hottest / 1000 : hottest
            }
            if parts.count > 3, let trip = Double(parts[3]), trip > 0 {
                sample.thermalLimitC = trip > 1000 ? trip / 1000 : trip
            }
            if parts.count > 4 {
                let g = parts[4].split(separator: ",").map(String.init)
                if g.count >= 8 {
                    sample.gpuW = numeric(g[0])
                    sample.utilPct = numeric(g[1])
                    sample.gpuTempC = numeric(g[2])
                    sample.smClockMHz = numeric(g[3])
                    sample.smClockMaxMHz = numeric(g[4])
                    sample.thermalSlowdown = flag(g[5])
                    sample.hwSlowdown = flag(g[6])
                    sample.powerCapActive = flag(g[7])
                }
            }
            if parts.count > 5 {
                let fields = parts[5].split(separator: " ").compactMap { Double($0) }
                // "cpu user nice system idle iowait irq softirq steal ..." — the
                // "cpu" token does not parse, so index 0 is `user`.
                if fields.count >= 5 {
                    let total = fields.reduce(0, +)
                    let idle = fields[3] + fields[4]
                    if let prev = previousCPU {
                        let dTotal = total - prev.total
                        let dIdle = idle - prev.idle
                        if dTotal > 0 {
                            sample.cpuUsagePct = max(0, min(100, (dTotal - dIdle) / dTotal * 100))
                        }
                    }
                    previousCPU = (total, idle)
                }
            }
            if parts.count > 6 {
                let freqs = parts[6].split(separator: " ").compactMap { Double($0) }
                if !freqs.isEmpty {
                    // kHz per policy → MHz. The max comes from the same table the
                    // kernel advertises, so the ratio is meaningful across models.
                    sample.cpuFreqMHz = freqs.reduce(0, +) / Double(freqs.count) / 1000
                    sample.cpuFreqMaxMHz = ThermalStreamParser.maxFreqMHz
                }
            }
            return .sample(sample)
        default:
            return nil
        }
    }

    /// Highest policy clock the box advertises (GB10: 3.9 GHz on the performance
    /// cluster). Cached for the process; it cannot change while running.
    public static let maxFreqMHz: Double = {
        let url = URL(fileURLWithPath: "/sys/devices/system/cpu/cpufreq")
        _ = url
        return 3900
    }()

    private func numeric(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed != "[N/A]", trimmed != "N/A" else { return nil }
        return Double(trimmed)
    }

    /// nvidia-smi renders throttle reasons as `Active` / `Not Active`; the remote
    /// script folds them to 1/0 so a space never has to be parsed here.
    private func flag(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces)
        return t == "1" || t.lowercased() == "active"
    }
}

/// Runs the remote sampling loop and hands each parsed event to `handler`.
///
/// Blocking work (process spawn, pipe reads) never touches the caller's executor:
/// the old code path blocked an actor for 28 minutes on a stalled `ssh` and the
/// whole node froze. Here the read loop is its own `Task` on `FileHandle.bytes`,
/// which is async and cancellable, and `stop()` kills the child so the task ends.
public final class ThermalStream: @unchecked Sendable {
    public typealias Handler = @Sendable (ThermalStreamEvent) -> Void

    private let user: String
    private let host: String
    private let intervalSeconds: Double
    private let lock = NSLock()
    private var process: Process?
    private var task: Task<Void, Never>?
    private var stopped = false

    /// When the last sample arrived. A stream that silently stops (half-open
    /// tunnel) must be distinguishable from a box at a constant temperature.
    private(set) var lastEventAt: Date?

    public init(user: String, host: String, intervalSeconds: Double = 2) {
        self.user = user
        self.host = host
        self.intervalSeconds = intervalSeconds
    }

    /// The remote loop. Read-only, no install, ends when the session does.
    static func remoteScript(intervalSeconds: Double) -> String {
        let period = String(format: "%.1f", max(1, intervalSeconds))
        return """
        echo "B|$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)|$(cut -d' ' -f1 /proc/uptime 2>/dev/null)|$(nproc 2>/dev/null)"
        while : ; do
          t=$(date +%s%3N 2>/dev/null || echo 0)
          a=$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | tr '\\n' ' ')
          lm=$(cat /sys/class/thermal/thermal_zone*/trip_point_0_temp 2>/dev/null | sort -n | tail -1)
          g=$(nvidia-smi --query-gpu=power.draw,utilization.gpu,temperature.gpu,clocks.current.sm,clocks.max.sm,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_power_cap --format=csv,noheader,nounits 2>/dev/null | head -1 | sed 's/Not Active/0/g; s/Active/1/g' | tr -d ' ')
          c=$(head -1 /proc/stat 2>/dev/null)
          f=$(cat /sys/devices/system/cpu/cpufreq/policy*/scaling_cur_freq 2>/dev/null | tr '\\n' ' ')
          echo "S|$t|$a|$lm|$g|$c|$f"
          sleep \(period)
        done
        """
    }

    public func start(handler: @escaping Handler) {
        lock.lock()
        stopped = false
        lock.unlock()
        task?.cancel()
        task = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.runLoop(handler: handler)
        }
    }

    public func stop() {
        lock.lock()
        stopped = true
        let proc = process
        process = nil
        lock.unlock()
        proc?.terminate()
        task?.cancel()
        task = nil
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    /// Kept synchronous on purpose: `NSLock` is unavailable from async contexts, so
    /// every mutation goes through one of these.
    private func store(process proc: Process) {
        lock.lock()
        process = proc
        lock.unlock()
    }

    private func clear(process proc: Process) {
        lock.lock()
        if process === proc { process = nil }
        lock.unlock()
    }

    private func runLoop(handler: @escaping Handler) async {
        var attempt = 0
        while !isStopped {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
            proc.arguments = [
                "-T",
                "-o", "BatchMode=yes",
                "-o", "ConnectTimeout=8",
                "-o", "StrictHostKeyChecking=accept-new",
                // A half-open connection is the usual failure: without keepalives
                // ssh waits forever for a peer that will never answer.
                "-o", "ServerAliveInterval=5",
                "-o", "ServerAliveCountMax=2",
                "\(user)@\(host)",
                Self.remoteScript(intervalSeconds: intervalSeconds),
            ]
            let stdout = Pipe()
            let stderr = Pipe()
            proc.standardOutput = stdout
            proc.standardError = stderr
            proc.standardInput = FileHandle.nullDevice

            do {
                try proc.run()
            } catch {
                attempt += 1
                try? await Task.sleep(for: ReconnectBackoff.delay(forAttempt: attempt))
                continue
            }
            store(process: proc)

            var parser = ThermalStreamParser()
            var sawSample = false
            do {
                for try await line in stdout.fileHandleForReading.bytes.lines {
                    if isStopped { break }
                    if let event = parser.consume(line) {
                        if case .sample = event { sawSample = true }
                        lastEventAt = Date()
                        handler(event)
                    }
                }
            } catch {
                // EOF or a killed child both land here; the restart below decides.
            }
            clear(process: proc)
            if !proc.isRunning { /* child already gone */ } else { proc.terminate() }

            if isStopped { return }
            attempt = sawSample ? 1 : attempt + 1
            try? await Task.sleep(for: ReconnectBackoff.delay(forAttempt: attempt))
        }
    }
}
