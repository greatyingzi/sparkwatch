import Foundation

/// One SSH round trip per node, sectioned so a single failing command cannot
/// take the whole scrape down. This is the slow channel (default 60 s): it
/// carries what the dashboard API does not expose — PSI memory pressure, swap,
/// page cache, disk, containers and a raw `nvidia-smi` line used for
/// reconciliation.
///
/// All values are read-only. Nothing is installed on the boxes; the app only
/// needs key-based SSH (already working with `BatchMode=yes`).
public enum SshProbe {
    static let script = """
    echo '##meminfo'; grep -E '^(MemTotal|MemAvailable|MemFree|Cached|Buffers|SReclaimable|SwapTotal|SwapFree):' /proc/meminfo
    echo '##pressure'; grep -E '^full' /proc/pressure/memory || true
    echo '##load'; cat /proc/loadavg
    echo '##uptime'; cat /proc/uptime
    echo '##cores'; nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo
    echo '##cputemp'; for z in /sys/class/thermal/thermal_zone*; do t=$(cat $z/temp 2>/dev/null); [ -n "$t" ] && echo "$t $(cat $z/trip_point_0_temp 2>/dev/null || echo '')"; done
    echo '##rootdev'; findmnt -no SOURCE / 2>/dev/null | sed 's|/dev/||' || true
    echo '##disk'; df -B1 / | tail -1
    echo '##docker'; docker ps --format '{{.Names}}|{{.Image}}|{{.Ports}}' 2>/dev/null || true
    echo '##gpu'; nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,power.draw,power.limit,clocks.current.sm,clocks.max.sm,clocks_throttle_reasons.hw_thermal_slowdown,clocks_throttle_reasons.sw_thermal_slowdown,clocks_throttle_reasons.hw_slowdown,clocks_throttle_reasons.sw_power_cap --format=csv,noheader,nounits 2>/dev/null || true
    echo '##gpuapps'; nvidia-smi --query-compute-apps=pid,process_name,used_gpu_memory --format=csv,noheader,nounits 2>/dev/null || true
    echo '##kernel'
    k=""
    if dmesg >/dev/null 2>&1; then k=$(dmesg 2>/dev/null)
    elif journalctl -k -b --no-pager >/dev/null 2>&1; then k=$(journalctl -k -b --no-pager 2>/dev/null)
    else echo 'unavailable 1'; fi
    if [ -n "$k" ]; then
      echo "xid $(printf '%s\\n' "$k" | grep -cE 'Xid' || true)"
      echo "oom $(printf '%s\\n' "$k" | grep -cE 'Out of memory: Killed process|oom-kill:' || true)"
      echo "nverr $(printf '%s\\n' "$k" | grep -c 'NV_ERR_NO_MEMORY' || true)"
    fi
    echo '##netmeta'; for i in /sys/class/net/*; do n=$(basename $i); case $n in lo|docker*|veth*|br-*|virbr*|tailscale*|zt*|tun*|wg*) continue;; esac; echo "$n|$(cat $i/operstate 2>/dev/null)|$(cat $i/speed 2>/dev/null)|$(ip -4 -o addr show dev $n 2>/dev/null | awk '{print $4}' | head -1)"; done
    echo '##route'; ip -4 route show default 2>/dev/null | head -1 || true
    echo '##diskstat1'; for d in /sys/block/*; do n=$(basename $d); case $n in loop*|ram*|sr*|zram*) continue;; esac; echo "$n $(cat $d/stat 2>/dev/null)"; done
    echo '##netdev1'; cat /proc/net/dev
    echo '##cpu1'; grep '^cpu ' /proc/stat
    sleep 1
    echo '##cpu2'; grep '^cpu ' /proc/stat
    echo '##netdev2'; cat /proc/net/dev
    echo '##diskstat2'; for d in /sys/block/*; do n=$(basename $d); case $n in loop*|ram*|sr*|zram*) continue;; esac; echo "$n $(cat $d/stat 2>/dev/null)"; done
    echo '##tailscale'; if command -v tailscale >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then tailscale status --json 2>/dev/null | python3 -c "import json,sys;d=json.load(sys.stdin);s=d.get('Self') or {};print(json.dumps({'Version':d.get('Version'),'BackendState':d.get('BackendState'),'Self':{k:s.get(k) for k in ('Online','Relay','KeyExpiry','TailscaleIPs','HostName','Expired')}}))" 2>/dev/null || echo 'unavailable'; else echo 'unavailable'; fi
    echo '##infer'; ps -eo args 2>/dev/null | grep -E 'vllm serve|VLLM::Worker|tensorfold serve|sglang|ollama serve|llama-server' | grep -v grep | head -10 || true
    echo '##ports'; ss -tlnH 2>/dev/null | awk '{print $4}' | head -40 || true
    echo '##done'
    """

    /// How long the probe's own deltas span (the `sleep 1` between the paired
    /// sections). Rates are computed against this, so it is one constant rather
    /// than a magic number in two places.
    static let sampleWindowSeconds: Double = 1

    public struct Result: Sendable {
        public var system: SystemSample
        public var gpu: GpuSample
        public var smClockMHz: Double?
        public var processes: [InferenceProcessInfo] = []
        /// Listening sockets, as "bind:port" — the raw material for the
        /// inference-service picker.
        public var listeners: [(bind: String, port: Int)] = []
    }

    public static func collect(
        user: String,
        host: String,
        timeout: TimeInterval = 20
    ) async throws -> Result {
        let output = try await SshRunner.run(user: user, host: host, script: script, timeout: timeout)
        return parse(output)
    }

    public static func parse(_ text: String) -> Result {
        var system = SystemSample()
        var gpu = GpuSample()
        var clock: Double?
        var section = ""
        var firstCPUSample: (total: Double, idle: Double)?
        var processLines: [String] = []
        var listeners: [(bind: String, port: Int)] = []
        // Paired sections (…1 / …2) exist because rates need a delta, and the
        // probe is stateless: the 1 s interval has to come from the box, not
        // from two separate SSH calls that may be minutes apart.
        var networkCounters1: [String: (rx: Double, tx: Double)] = [:]
        var diskSectors1: [String: (read: Double, write: Double)] = [:]
        var networkMeta: [String: (operstate: String, speed: Double?, ip: String?)] = [:]
        var rootDevice: String?
        // tailscale's JSON is pretty-printed over many lines, so the section is
        // accumulated and parsed once at the end. (Parsing line by line silently
        // produced "no tailnet" for every real node — caught by the fixture test.)
        var tailnetLines: [String] = []

        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line)
            if line.hasPrefix("##") {
                section = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            switch section {
            case "meminfo":
                // "MemTotal:       127598548 kB"
                //
                // The kernel's "kB" is really KiB — proven byte-exact on
                // spark-a: 127,598,548 x 1024 == 130,660,913,152 == `free -b`
                // total. Multiplying by 1000 produces a phantom 2.3 % delta
                // against the dashboard, which streams the very same number.
                let parts = line.split(separator: " ", omittingEmptySubsequences: true)
                guard parts.count >= 2, let kib = UInt64(parts[1]) else { continue }
                let bytes = kib * 1024
                switch parts[0] {
                case "MemTotal:": system.memTotalBytes = bytes
                case "MemAvailable:": system.memAvailableBytes = bytes
                case "MemFree:": system.memFreeBytes = bytes
                case "Cached:", "Buffers:", "SReclaimable:":
                    system.memCacheBytes = (system.memCacheBytes ?? 0) + bytes
                case "SwapTotal:": system.swapTotalBytes = bytes
                case "SwapFree:": system.swapFreeBytes = bytes
                default: break
                }
            case "pressure":
                // "full avg10=4.74 avg60=1.02 avg300=0.21 total=..."
                if let range = line.range(of: "avg10=") {
                    let tail = line[range.upperBound...]
                    let value = tail.prefix { $0 != " " }
                    system.memPressureAvg10 = Double(value)
                }
            case "cores":
                system.cpuCores = Int(line.trimmingCharacters(in: .whitespaces))
            case "cpu1":
                let fields = line.split(separator: " ").compactMap { Double($0) }
                // user nice system idle iowait irq softirq steal
                guard fields.count >= 5 else { continue }
                firstCPUSample = (total: fields.reduce(0, +), idle: fields[3] + fields[4])
            case "cpu2":
                // Two `/proc/stat` reads, one second apart, inside the same SSH
                // call: CPU usage needs a delta, and the probe is stateless
                // (60 s cadence), so the interval has to come from the box.
                let fields = line.split(separator: " ").compactMap { Double($0) }
                guard fields.count >= 5, let first = firstCPUSample else { continue }
                let total = fields.reduce(0, +)
                let idle = fields[3] + fields[4]
                let totalDelta = total - first.total
                let idleDelta = idle - first.idle
                if totalDelta > 0 {
                    system.cpuUsagePct = max(0, min(100, (totalDelta - idleDelta) / totalDelta * 100))
                }
            case "cputemp":
                // "<temp_millidegrees> <trip_millidegrees>" per thermal zone.
                // Millidegrees; the hottest zone is the one worth showing, and it
                // arrives with the platform's own limit for that zone.
                let fields = line.split(separator: " ").map(String.init)
                guard let rawTemp = fields.first.flatMap(Double.init) else { continue }
                let temp = rawTemp > 1000 ? rawTemp / 1000 : rawTemp
                if system.cpuTempC == nil || temp > (system.cpuTempC ?? 0) {
                    system.cpuTempC = temp
                    if fields.count > 1, let rawTrip = Double(fields[1]) {
                        system.thermalLimitC = rawTrip > 1000 ? rawTrip / 1000 : rawTrip
                    }
                }
            case "load":
                system.load1 = line.split(separator: " ").first.flatMap { Double($0) }
            case "uptime":
                system.uptimeSeconds = line.split(separator: " ").first.flatMap { Double($0) }
            case "rootdev":
                rootDevice = line.trimmingCharacters(in: .whitespacesAndNewlines)
            case "disk":
                let fields = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
                if fields.count >= 3 {
                    system.diskTotalBytes = UInt64(fields[1])
                    system.diskUsedBytes = UInt64(fields[2])
                }
            case "docker":
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                if fields.count == 3, !fields[0].isEmpty {
                    system.containers.append(
                        ContainerInfo(name: fields[0], image: fields[1], ports: fields[2])
                    )
                }
            case "gpuapps":
                // "3763152, /usr/bin/python3, 99429" — MiB per process.
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 3,
                    let pid = Int(fields[0]),
                    let mib = Double(fields[2])
                else { continue }
                system.gpuAllocBytes = (system.gpuAllocBytes ?? 0) + UInt64(mib) * 1_048_576
                system.gpuProcesses.append(
                    GpuProcessInfo(
                        pid: pid,
                        name: fields[1].split(separator: "/").last.map(String.init) ?? fields[1],
                        memoryBytes: UInt64(mib) * 1_048_576
                    )
                )
            case "kernel":
                // Counters only: the log bodies never leave the box.
                let fields = line.split(separator: " ").map { $0.trimmingCharacters(in: .whitespaces) }
                if fields.first == "unavailable" {
                    system.kernelErrors = KernelErrors(available: false)
                    continue
                }
                guard fields.count >= 2, let value = Int(fields[1]) else { continue }
                var errors = system.kernelErrors
                errors.available = true
                switch fields[0] {
                case "xid": errors.xid = value
                case "oom": errors.oomKills = value
                case "nverr": errors.nvErrNoMemory = value
                default: break
                }
                system.kernelErrors = errors
            case "netmeta":
                // "enP7s7|up|1000|192.168.1.60/24"
                let fields = line.split(separator: "|", omittingEmptySubsequences: false).map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                guard fields.count >= 4, !fields[0].isEmpty else { continue }
                networkMeta[fields[0]] = (
                    operstate: fields[1],
                    speed: Double(fields[2]),
                    ip: fields[3].split(separator: "/").first.map(String.init)
                )
            case "route":
                // "default via 192.168.1.1 dev enP7s7 proto dhcp …"
                let parts = line.split(separator: " ").map(String.init)
                if let index = parts.firstIndex(of: "dev"), index + 1 < parts.count {
                    system.network.primary = parts[index + 1]
                }
            case "netdev1":
                if let pair = Self.procNetDev(line) { networkCounters1[pair.name] = (pair.rx, pair.tx) }
            case "netdev2":
                guard let pair = Self.procNetDev(line),
                    let first = networkCounters1[pair.name]
                else { continue }
                let meta = networkMeta[pair.name]
                system.network.interfaces.append(
                    NetworkInterface(
                        name: pair.name,
                        rxBytesPerSec: max(0, (pair.rx - first.rx) / sampleWindowSeconds),
                        txBytesPerSec: max(0, (pair.tx - first.tx) / sampleWindowSeconds),
                        ip: meta?.ip,
                        linkSpeedMbps: meta?.speed,
                        operstate: meta?.operstate
                    )
                )
            case "diskstat1":
                if let pair = Self.blockStat(line) { diskSectors1[pair.device] = (pair.read, pair.write) }
            case "diskstat2":
                guard let pair = Self.blockStat(line), let first = diskSectors1[pair.device] else { continue }
                // 512-byte sectors, and /sys/block/<dev>/stat counts in sectors
                // for both directions (fields 3 and 7).
                let read = max(0, (pair.read - first.read) * 512 / sampleWindowSeconds)
                let write = max(0, (pair.write - first.write) * 512 / sampleWindowSeconds)
                if Self.matchesRoot(pair.device, root: rootDevice) {
                    system.diskReadBytesPerSec = read
                    system.diskWriteBytesPerSec = write
                }
            case "tailscale":
                tailnetLines.append(line)
            case "infer":
                processLines.append(line)
            case "ports":
                // "0.0.0.0:8888" / "127.0.0.1:11434" / "[::]:22"
                guard let colon = line.lastIndex(of: ":") else { continue }
                let bind = String(line[..<colon])
                guard let port = Int(line[line.index(after: colon)...]) else { continue }
                listeners.append((bind: bind, port: port))
            case "gpu":
                // "0, 42, 11.08, N/A, 2405, 3003, Not Active, Not Active, Not Active, Not Active"
                // With `--format=csv,noheader,nounits`; "[N/A]" stays nil, which
                // is exactly what unified memory and power limits return on GB10.
                let fields = line.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                guard fields.count >= 2 else { continue }
                gpu.utilPct = numeric(fields[0])
                gpu.tempC = numeric(fields[1])
                if fields.count > 2 { gpu.powerW = numeric(fields[2]) }
                if fields.count > 3 { gpu.powerLimitW = numeric(fields[3]) }
                if fields.count > 4 { clock = numeric(fields[4]) }
                var throttle = ThrottleInfo()
                throttle.smClockMHz = clock
                if fields.count > 5 { throttle.smClockMaxMHz = numeric(fields[5]) }
                if fields.count > 6 { throttle.thermal = active(fields[6]) }
                if fields.count > 7 { throttle.thermal = throttle.thermal || active(fields[7]) }
                if fields.count > 8 { throttle.hardware = active(fields[8]) }
                if fields.count > 9 { throttle.powerCap = active(fields[9]) }
                gpu.throttle = throttle
            default:
                break
            }
        }
        system.gpuProcesses = Array(
            system.gpuProcesses.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(5)
        )
        if !tailnetLines.isEmpty {
            system.tailnet = TailnetParser.parse(tailnetLines.joined(separator: "\n"))
        }
        gpu.smClockMHz = gpu.smClockMHz ?? clock
        return Result(
            system: system,
            gpu: gpu,
            smClockMHz: clock,
            processes: InferenceProcessParser.parse(lines: processLines),
            listeners: listeners
        )
    }

    /// `/proc/net/dev` row → name + cumulative byte counters.
    /// `  enP7s7: 1234567  8901  0  0 …  7654321  1098  0  0 …`
    static func procNetDev(_ line: String) -> (name: String, rx: Double, tx: Double)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != "Inter-|" , name != "face" else { return nil }
        let fields = line[line.index(after: colon)...]
            .split(separator: " ", omittingEmptySubsequences: true)
            .compactMap { Double($0) }
        // rx: bytes packets errs drop fifo frame compressed multicast, then tx: bytes …
        guard fields.count >= 9 else { return nil }
        return (name, fields[0], fields[8])
    }

    /// `/sys/block/<dev>/stat` row → sectors read and written.
    ///
    /// The field numbering is the classic off-by-one: this file lists *read
    /// I/Os, read merges, sectors read, ms reading, write I/Os, write merges,
    /// sectors written…*, so with the device name occupying index 0 the sectors
    /// live at 3 and 7 — not 2 and 6. Taking 2 and 6 reads the merge counters
    /// instead, which returns 0 almost always and looks exactly like "this disk
    /// is idle" (it did, until the fixture test above caught it).
    static func blockStat(_ line: String) -> (device: String, read: Double, write: Double)? {
        let parts = line.split(separator: " ").map(String.init)
        guard parts.count >= 8, !parts[0].isEmpty else { return nil }
        guard let read = Double(parts[3]), let write = Double(parts[7]) else { return nil }
        return (parts[0], read, write)
    }

    /// Partitions carry their parent's counters (`nvme0n1p2` is a slice of
    /// `nvme0n1`), and only the parent appears under `/sys/block`.
    static func matchesRoot(_ device: String, root: String?) -> Bool {
        guard let root, !root.isEmpty else { return false }
        if device == root { return true }
        var base = root
        while let last = base.last, last.isNumber { base.removeLast() }
        if base.hasSuffix("p") { base.removeLast() }
        return device == base
    }

    /// nvidia-smi's throttle-reason fields, which are spelled differently
    /// depending on driver version: "Active" / "Not Active", a `0x…` bitmask, an
    /// integer, or `[N/A]` (meaning "this reason does not apply here").
    static func active(_ text: String) -> Bool {
        let value = text.trimmingCharacters(in: .whitespaces).lowercased()
        if value.isEmpty || value.contains("n/a") { return false }
        if value == "active" { return true }
        if value.hasPrefix("0x") { return (UInt64(value.dropFirst(2), radix: 16) ?? 0) != 0 }
        if let number = Int(value) { return number != 0 }
        return false
    }

    /// Tolerant numeric parse: drops unit suffixes ("%", " W", " MiB") that some
    /// nvidia-smi formats append, and returns nil for "[N/A]".
    static func numeric(_ text: String) -> Double? {
        var digits = ""
        for character in text {
            if character.isNumber || character == "." || character == "-" || character == "+" {
                digits.append(character)
            } else if !digits.isEmpty {
                break
            }
        }
        return digits.isEmpty ? nil : Double(digits)
    }
}

/// Runs a command over SSH with a hard timeout (Process has none of its own).
///
/// The deadline is enforced by a **GCD timer**, deliberately not by a Swift `Task`
/// watchdog: the read side of this call blocks, and a watchdog scheduled on the
/// cooperative pool can be starved exactly when it is needed. Measured live
/// (2026-10-03): the inference loop sat inside this function for 28 minutes —
/// every later probe simply never happened, so the rate readout froze on screen
/// while the node looked healthy. The old `Task`-based watchdog never got to run.
public enum SshRunner {
    /// - Important: Everything here is blocking (`Process`, pipes, `waitpid`), so it
    ///   runs on a detached thread and **never on the caller's executor**. The old
    ///   version ran inline from the actor, and `sample` on the live fleet parked
    ///   2264/2264 frames in `-[NSConcreteTask waitUntilExit]` under this very
    ///   function: the whole `NodeRuntime` actor was frozen, so the inference loop
    ///   produced no samples while the engine kept decoding at 38 tok/s (2026-10-03).
    ///   It also waited *unbounded* — a child that refuses to die could hold the
    ///   caller forever. Both are fixed by construction here.
    public static func run(
        user: String,
        host: String,
        script: String,
        timeout: TimeInterval
    ) async throws -> String {
        let outcome = try await Task.detached(priority: .utility) {
            try runBlocking(user: user, host: host, script: script, timeout: timeout)
        }.value
        switch outcome {
        case .expired:
            throw DashboardError.transport("ssh \(host) 超时 \(Int(timeout))s，已终止")
        case .failed(let status, let message):
            throw DashboardError.transport("ssh \(host) 失败(\(status)): \(message.prefix(160))")
        case .ok(let output):
            return output
        }
    }

    private enum Outcome: Sendable {
        case ok(String)
        case failed(Int32, String)
        case expired
    }

    private static func runBlocking(
        user: String,
        host: String,
        script: String,
        timeout: TimeInterval
    ) throws -> Outcome {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        task.arguments = [
            "-o", "BatchMode=yes",
            "-o", "ConnectTimeout=\(min(Int(timeout), 15))",
            "-o", "StrictHostKeyChecking=accept-new",
            // A half-open TCP connection is the usual way this hangs: without
            // keepalives, ssh waits forever for a peer that will never answer.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=2",
            "\(user)@\(host)",
            script,
        ]
        let stdout = Pipe()
        let stderr = Pipe()
        task.standardOutput = stdout
        task.standardError = stderr
        task.standardInput = FileHandle.nullDevice

        try task.run()
        let pid = task.processIdentifier

        // Drain both pipes on their own queues while the child runs; they end at EOF.
        let outBox = DataBox()
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outBox.set((try? stdout.fileHandleForReading.readToEnd()) ?? Data())
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errBox.set((try? stderr.fileHandleForReading.readToEnd()) ?? Data())
            group.leave()
        }

        // Poll instead of `waitUntilExit()`: polling is interrupted by the deadline,
        // blocking `waitpid` is not.
        let deadline = Date().addingTimeInterval(timeout)
        var expired = false
        while task.isRunning {
            if Date() >= deadline {
                expired = true
                // ssh can ignore a polite signal mid-handshake, and a deadline is a
                // deadline. Kill it and stop caring: a corpse is not worth waiting for.
                kill(pid, SIGKILL)
                break
            }
            usleep(50_000)
        }
        // Give the readers a moment to see EOF, never longer: whatever is missing is
        // missing, and the caller has a loop to get back to.
        _ = group.wait(timeout: .now() + 2)

        if expired { return .expired }
        let status = task.terminationStatus
        if status != 0 {
            let message = String(decoding: errBox.value, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failed(status, message)
        }
        return .ok(String(decoding: outBox.value, as: UTF8.self))
    }
}

/// Mutable box with a lock, for the pipe readers → blocking body handoff.
private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    func set(_ data: Data) { lock.lock(); storage = data; lock.unlock() }
    var value: Data { lock.lock(); defer { lock.unlock() }; return storage }
}

/// Set-once flag with a memory barrier, for the timer → async-task handoff.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}
