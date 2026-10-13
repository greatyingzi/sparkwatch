import Foundation
import SparkWatchCore

// Headless acceptance probe — the Swift twin of the Rust probe in
// ~/work/dgx-menubar (kept as an independent implementation so the two can be
// cross-checked). It runs the real pipeline and reconciles the official
// dashboard numbers against independently read ones:
//
//   dashboard mem_total/in_use   vs  /proc/meminfo MemTotal / (MemTotal - MemAvailable)
//   dashboard util/temp/power    vs  nvidia-smi on the same box
//
// Exit code is non-zero if any check blows its tolerance, so this doubles as a
// regression gate for the undocumented API.
//
//   DGX_PW_00=... DGX_PW_01=... swift run sparkwatch-probe -- --seconds 20
//
// Passwords come from the environment only — never from disk, never logged.

struct Recon {
    var util: Double?
    var temp: Double?
    var power: Double?
    var memTotal: UInt64?
    var memAvailable: UInt64?
}

struct Check {
    var what: String
    var delta: Double
    var isPercent: Bool
    var tolerance: Double
    var detail: String
    var passed: Bool { delta <= tolerance }
}

func value(_ args: [String], _ flag: String, default fallback: Double) -> Double {
    guard let index = args.firstIndex(of: flag), index + 1 < args.count,
        let parsed = Double(args[index + 1])
    else { return fallback }
    return parsed
}

let arguments = Array(CommandLine.arguments.dropFirst())

// ── Diagnostics subcommands ──────────────────────────────────────────────
// These are what a user runs when wiring up a machine they have never
// monitored before: find the endpoint, test the endpoint, check the whole node.
if let index = arguments.firstIndex(of: "--engine"), index + 1 < arguments.count {
    let url = arguments[index + 1]
    print("探测推理端点: \(url)")
    do {
        let sample = try await InferenceProbe().probe(baseURL: url)
        print("  引擎     \(sample.engine ?? "未知")")
        print("  模型     \(sample.model ?? "—")")
        if let quant = sample.quantization { print("  量化     \(quant)") }
        if let arch = sample.architecture { print("  架构     \(arch)") }
        if let ctx = sample.contextLength { print("  上下文   \(ctx)") }
        if let params = sample.parameterCount { print("  参数量   \(String(format: "%.0fM", params / 1e6))") }
        if let running = sample.running { print("  运行中   \(Int(running))") }
        if let waiting = sample.waiting { print("  排队     \(Int(waiting))") }
        if let gen = sample.generationTokens { print("  累计生成 \(Int(gen)) tokens") }
        if let vram = sample.vramBytes { print("  显存占用 \(String(format: "%.1f GiB", Double(vram) / 1_073_741_824))") }
        print("  可提供   计数=\(sample.capabilities.hasTokenCounters) 速率=\(sample.capabilities.hasSpeed) 详情=\(sample.capabilities.hasModelDetail)")
        exit(0)
    } catch {
        print("  失败: \(error)")
        exit(1)
    }
}

// ── Mock/interface render mode ───────────────────────────────────────────
// `--render <url> [--samples N] [--interval S]`: probe the endpoint N times,
// feed the counters through the *same* rate trackers and display functions the
// app uses, then print exactly what each surface would show. This is what makes
// a mocked engine testable: the deliverable is the rendered state, not the JSON.
if let index = arguments.firstIndex(of: "--render"), index + 1 < arguments.count {
    let url = arguments[index + 1]
    let samples = arguments.firstIndex(of: "--samples").flatMap { $0 + 1 < arguments.count ? Int(arguments[$0 + 1]) : nil } ?? 3
    let interval = arguments.firstIndex(of: "--interval").flatMap { $0 + 1 < arguments.count ? Double(arguments[$0 + 1]) : nil } ?? 1.5
    let probe = InferenceProbe()
    var decodeTracker = TokenRateTracker()
    var prefillTracker = PrefillRateTracker()
    var last: InferenceSample?
    var transportNote: String?

    for step in 0..<max(1, samples) {
        if step > 0 { try? await Task.sleep(for: .seconds(interval)) }
        do {
            var sample = try await probe.probe(baseURL: url)
            let engineName = sample.engine
            let modelName = sample.model
            let gap = decodeTracker.lastProbeAt.map { Date().timeIntervalSince($0) }
            if let generation = sample.generationTokens,
                let rate = decodeTracker.update(
                    generationTokens: generation, engine: engineName, model: modelName
                ),
                SpeedDisplay.rateIsTrustworthy(intervalSeconds: gap, activeCadence: 2)
            {
                sample.decodeTPS = rate
                sample.decodeTPSAge = 0
            } else if let kept = decodeTracker.lastRate {
                sample.decodeTPS = kept
                sample.decodeTPSAge = decodeTracker.age()
            }
            if let delta = prefillTracker.update(
                promptTokens: sample.promptTokens,
                cachedTokens: sample.cachedTokens,
                prefillSeconds: sample.prefillSeconds
            ) {
                sample.prefillTPS = delta
            }
            transportNote = sample.transportNote
            last = sample
        } catch {
            print("RENDER probe_failed=true error=\(String(describing: error).prefix(120))")
            exit(3)
        }
    }

    guard let sample = last else { exit(3) }
    // A node snapshot as the UI would receive it (hardware fields come from the
    // box, so they stay unset here — the point is the inference half).
    var node = NodeSnapshot(id: UUID(), name: "spark-00", host: "mock", source: .dashboard)
    // Health is evaluated from the same rules the app uses, so engine-reported
    // faults (fatal / stalled) show up here exactly as they would on screen.
    var evaluator = HealthEvaluator()
    node.health = evaluator.evaluate(
        gpu: GpuSample(utilPct: 0, tempC: 45, powerW: 12),
        system: SystemSample(),
        source: .dashboard,
        error: nil,
        inference: sample
    )
    node.inference = sample
    let task = ClusterTask(
        id: "mock", model: sample.model ?? "mock", nodes: ["spark-00"],
        ranks: ["spark-00": 0], tensorParallel: 1, nodeCount: 1,
        apiNode: "spark-00", apiURL: url, quantization: sample.quantization,
        contextLength: sample.contextLength
    )
    let barText = StatusBarText.text(
        for: [node], settings: StatusBarSettings(), powerEstimate: PowerEstimate()
    )
    let tones = StatusBarText.segments(for: [node], settings: StatusBarSettings())
        .map { "\($0.text):\($0.tone)" }.joined(separator: ",")
    let activity = TaskSummary.activity(for: task, in: [node])
    let state = SpeedDisplay.state(rate: sample.decodeTPS, age: sample.decodeTPSAge, running: sample.running)

    print("RENDER engine=\(sample.engine ?? "-")")
    print("RENDER model=\(sample.model ?? "-")")
    print("RENDER bar=\(barText)")
    print("RENDER tones=\(tones)")
    print("RENDER health=\(node.health.level)/\(node.health.alert ? "alert" : "-")/\(node.health.causes.map(\.rawValue).joined(separator: "+"))")
    print("RENDER banner=\(activity.map { "\($0.kind):\($0.text)" } ?? "-")")
    print("RENDER rate=\(state)")
    print("RENDER tps=\(sample.decodeTPS.map { String(format: "%.1f", $0) } ?? "-")")
    print("RENDER age=\(sample.decodeTPSAge.map { String(format: "%.0f", $0) } ?? "-")")
    print("RENDER inflight=\(sample.running.map { String(format: "%.0f", $0) } ?? "-") prefilling=\(sample.prefilling.map { String(format: "%.0f", $0) } ?? "-") decoding=\(sample.decoding.map { String(format: "%.0f", $0) } ?? "-")")
    print("RENDER gen=\(sample.generationTokens.map { String(format: "%.0f", $0) } ?? "-") prefillTps=\(sample.prefillTPS.map { String(format: "%.0f", $0) } ?? "-") ctx=\(sample.contextLength.map(String.init) ?? "-")")
    print("RENDER cacheHit=\(sample.cacheHitPct.map { String(format: "%.0f", $0) } ?? "-") accept=\(sample.acceptancePct.map { String(format: "%.0f", $0) } ?? "-") fatal=\(sample.engineFatal) stalled=\(sample.stalledRequests.map { String(format: "%.0f", $0) } ?? "-")")
    print("RENDER via=\(transportNote == nil ? "direct" : "ssh")")
    exit(0)
}

if let index = arguments.firstIndex(of: "--scan"), index + 1 < arguments.count {
    let host = arguments[index + 1]
    let user = arguments.firstIndex(of: "--user").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil } ?? "user"
    print("扫描 \(user)@\(host) 上的常见推理端口…")
    let hits = await Diagnostics.scanInferencePorts(user: user, host: host)
    if hits.isEmpty {
        print("  没有发现推理服务（试过的端口: \(Diagnostics.candidatePorts.map(String.init).joined(separator: ", "))）")
    }
    for hit in hits {
        print("  :\(hit.port)  \(hit.engine ?? "未知引擎")  \(hit.model ?? "")   [\(hit.note)]")
    }
    exit(0)
}

if let index = arguments.firstIndex(of: "--check"), index + 1 < arguments.count {
    let name = arguments[index + 1]
    let password = arguments.firstIndex(of: "--password").flatMap { $0 + 1 < arguments.count ? arguments[$0 + 1] : nil }
    let settings = SettingsStore.load()
    guard let node = settings.nodes.first(where: { $0.name == name || $0.sshHost == name }) else {
        print("settings.json 里没有名为 \(name) 的节点。现有: \(settings.nodes.map(\.name).joined(separator: ", "))")
        exit(2)
    }
    print("体检节点 \(node.name) (\(node.sshHost))")
    for result in await Diagnostics.checkNode(node, password: password) {
        print("  \(result.ok ? "ok  " : "FAIL") \(result.name): \(result.detail)")
    }
    exit(0)
}

let seconds = value(arguments, "--seconds", default: 20)
let interval = value(arguments, "--interval", default: 5)

let settings = SettingsStore.load()
var nodes = settings.nodes.filter { $0.enabled }

// Read passwords from the environment; a missing one skips that node.
var passwords: [UUID: String] = [:]
for node in nodes {
    let key = "DGX_PW_" + node.name.suffix(2)
    if let password = ProcessInfo.processInfo.environment[key], !password.isEmpty {
        passwords[node.id] = password
    }
}

print("sparkwatch-probe: \(nodes.count) 节点, \(Int(seconds))s 窗口, \(Int(interval))s 间隔")
let collector = ClusterCollector(settings: settings)
// Runtimes are created by start(); sign-in attaches to them, so start first.
await collector.start()

for node in nodes where passwords[node.id] == nil {
    print("  \(node.name): 跳过（未设置环境变量 DGX_PW_\(node.name.suffix(2))）")
}
nodes = nodes.filter { passwords[$0.id] != nil }

for node in nodes {
    let result = await collector.login(
        nodeID: node.id,
        username: SessionStore.username(for: node.id) ?? node.sshUser,
        password: passwords[node.id]!
    )
    switch result {
    case .success:
        let expiry = SessionStore.token(for: node.id).flatMap(TelemetryParser.jwtExpiry)
        let days = expiry.map { String(format: "%.1f 天", $0.timeIntervalSinceNow / 86400) } ?? "未知"
        print("  \(node.name) \(node.sshHost): 登录 OK（JWT 剩 \(days)）")
    case let .failure(error):
        print("  \(node.name) \(node.sshHost): 登录失败 — \(error.message)")
    }
}

var checks: [Check] = []
let started = Date()
var cycle = 0

while Date().timeIntervalSince(started) < seconds {
    cycle += 1
    print("\n── cycle \(cycle) (t+\(Int(Date().timeIntervalSince(started)))s) ──")
    for snapshot in await collector.snapshots() {
        printSnapshot(snapshot)

        // Independent measurement, taken right after the snapshot.
        if let node = nodes.first(where: { $0.id == snapshot.id }),
            let recon = try? await SshProbe.collect(user: node.sshUser, host: node.sshHost)
        {
            let parsed = Recon(
                util: recon.gpu.utilPct,
                temp: recon.gpu.tempC,
                power: recon.gpu.powerW,
                memTotal: recon.system.memTotalBytes,
                memAvailable: recon.system.memAvailableBytes
            )
            reconcile(name: snapshot.name, source: snapshot.source, gpu: snapshot.gpu, recon: parsed, into: &checks)
        }
    }
    try? await Task.sleep(for: .seconds(interval))
}

await collector.stop()

print("\n══ 对账结果 ══")
for check in checks.prefix(12) {
    let unit = check.isPercent ? "%" : ""
    print(
        String(
            format: "  %@ %.3f%@ (容差 %.3f%@)  %@",
            check.passed ? "ok  " : "FAIL",
            check.delta, unit, check.tolerance, unit, check.detail
        )
    )
}
if checks.count > 12 { print("  … 其余 \(checks.count - 12) 项同构，省略") }

let failures = checks.filter { !$0.passed }
if failures.isEmpty {
    print("PASS · \(checks.count) 项检查全部在容差内")
} else {
    print("FAIL · \(failures.count) 项超出容差")
    exit(1)
}

// MARK: - helpers

func percentDelta(_ a: Double, _ b: Double) -> Double {
    let scale = max(abs(a), abs(b))
    return scale < 1e-9 ? 0 : abs(a - b) / scale * 100
}

func reconcile(name: String, source: DataSource, gpu: GpuSample, recon: Recon, into checks: inout [Check]) {
    // A percentage tolerance is meaningless on a small base: spark-01 keeps ~3 GB
    // used because its page cache counts as available, so 50 MB of rounding is
    // 1.6 %. Treat anything within 150 MB as equal.
    let memoryEpsilon: Double = 150_000_000
    if let a = gpu.memTotalBytes, let b = recon.memTotal {
        let delta = percentDelta(Double(a), Double(b))
        checks.append(Check(
            what: "\(name) 统一内存总量",
            delta: abs(Double(a) - Double(b)) <= memoryEpsilon ? 0 : delta,
            isPercent: true, tolerance: 0.05,
            detail: "[\(source.label)] dash \(String(format: "%.2f", Double(a) / 1e9))GB vs meminfo \(String(format: "%.2f", Double(b) / 1e9))GB"
        ))
    }
    if let used = gpu.memUsedBytes, let total = recon.memTotal, let available = recon.memAvailable {
        let delta = percentDelta(Double(used), Double(total - available))
        checks.append(Check(
            what: "\(name) 统一内存占用",
            delta: abs(Double(used) - Double(total - available)) <= memoryEpsilon ? 0 : delta,
            isPercent: true, tolerance: 0.05,
            detail: "[\(source.label)] dash \(String(format: "%.2f", Double(used) / 1e9))GB vs meminfo \(String(format: "%.2f", Double(total - available) / 1e9))GB"
        ))
    }
    // Sampled seconds apart: absolute tolerances.
    if let a = gpu.tempC, let b = recon.temp {
        checks.append(Check(what: "\(name) 温度", delta: abs(a - b), isPercent: false, tolerance: 2,
                            detail: String(format: "dash %.0f°C vs nvidia-smi %.0f°C", a, b)))
    }
    if let a = gpu.powerW, let b = recon.power {
        checks.append(Check(what: "\(name) 功耗", delta: abs(a - b), isPercent: false, tolerance: 1.5,
                            detail: String(format: "dash %.2fW vs nvidia-smi %.2fW", a, b)))
    }
    if let a = gpu.utilPct, let b = recon.util {
        checks.append(Check(what: "\(name) GPU 利用率", delta: abs(a - b), isPercent: false, tolerance: 2,
                            detail: String(format: "dash %.0f%% vs nvidia-smi %.0f%%", a, b)))
    }
}

func gib(_ bytes: UInt64?) -> String {
    guard let bytes else { return "--" }
    return String(format: "%.1f", Double(bytes) / 1024 / 1024 / 1024)
}

func printSnapshot(_ snapshot: NodeSnapshot) {
    let gpu = snapshot.gpu
    print(
        "  [\(snapshot.name)] \(snapshot.source.label.padding(toLength: 6, withPad: " ", startingAt: 0))"
            + " util \(gpu.utilPct.map { String(format: "%3.0f%%", $0) } ?? "  --")"
            + "  \(gpu.tempC.map { String(format: "%.0f°C", $0) } ?? "--")"
            + "  \(gpu.powerW.map { String(format: "%6.2f W", $0) } ?? "     --")"
            + "  统一内存 \(gib(gpu.memUsedBytes))/\(gib(gpu.memTotalBytes)) GiB"
            + " (\(gpu.memUsedPct.map { String(format: "%.0f%%", $0) } ?? "--"))"
    )
    let system = snapshot.system
    var bits: [String] = []
    if let cpu = system.cpuUsagePct { bits.append(String(format: "CPU %.0f%%", cpu)) }
    if let cpuTemp = system.cpuTempC { bits.append(String(format: "热区 %.0f°C", cpuTemp)) }
    if let cores = system.cpuCores { bits.append("\(cores) 核") }
    if let load = system.load1 { bits.append(String(format: "load %.2f", load)) }
    if let cache = system.memCacheBytes { bits.append(String(format: "cache %.1f GiB", Double(cache) / 1073741824)) }
    if let pressure = system.memPressureAvg10 { bits.append(String(format: "PSI %.2f", pressure)) }
    if let swap = system.swapUsedBytes, swap > 0 { bits.append(String(format: "swap %.1f GiB", Double(swap) / 1073741824)) }
    if let used = system.diskUsedBytes, let total = system.diskTotalBytes, total > 0 {
        bits.append(String(format: "disk %.2f/%.2f TB", Double(used) / 1e12, Double(total) / 1e12))
    }
    if let uptime = system.uptimeSeconds { bits.append(String(format: "up %.1fd", uptime / 86400)) }
    if !system.containers.isEmpty {
        bits.append("容器 " + system.containers.map(\.name).joined(separator: ", "))
    }
    print("        sys   " + bits.joined(separator: "  "))
    if let inference = snapshot.inference {
        print(
            "        infer \(inference.model ?? "?")  run \(Int(inference.running ?? 0)) wait \(Int(inference.waiting ?? 0))"
                + "  tok/s \(inference.decodeTPS.map { String(format: "%.1f", $0) } ?? "--")"
                + "  gen \(Int(inference.generationTokens ?? 0))"
                + "  ok \(Int(inference.requestsProcessed ?? 0))"
        )
    }
    print("        健康  \(snapshot.health.level.label)"
          + (snapshot.health.reasons.isEmpty ? "" : " — " + snapshot.health.reasons.joined(separator: "; ")))
    if let error = snapshot.error { print("        err   \(error)") }
}
