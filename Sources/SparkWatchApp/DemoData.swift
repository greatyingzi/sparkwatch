import Foundation
import SparkWatchCore

/// Synthetic machines, for verifying layouts at fleet sizes we do not own.
///
/// The app is built for a pair but ships to people watching a dozen, and "it
/// looked fine with two" is not a verification. This generates plausible nodes
/// across every state the UI must render (healthy, loaded, warning, critical,
/// unreachable, still connecting, headless TP rank, no inference endpoint), so a
/// layout can be rendered and checked at N = 1, 2, 5, 12 before anyone runs it.
enum DemoData {
    static func snapshots(count: Int) -> [NodeSnapshot] {
        (0..<max(1, count)).map { index in
            var node = NodeSnapshot(
                id: deterministicUUID(index),
                name: String(format: "spark-%02d", index),
                host: String(format: "dgx-spark-%02d", index)
            )
            // Eight states, cycling: the two halves of a real TP pair, an idle box
            // holding a model, one with a stale leftover next to a live service, a
            // critical machine, a down one, one whose dashboard session has
            // expired (healthy-looking SSH numbers, no official channel), and one
            // still connecting. (The leftover state used to be a second `case 2`,
            // which Swift treated as unreachable — that state never rendered.)
            switch index % 8 {
            case 0:
                node.source = .dashboard
                node.system = system(availableGB: 7.6, usedPct: 94, pressure: 0.0, cpu: 24, load: 3.2, uptime: 6.2)
                node.gpu = gpu(util: 96, temp: 61, powerW: 47.7, usedPct: 94)
                node.inference = inference(model: "GLM-5.3-Flash-EXL3", tps: 27.5, role: "rank 0 · API")
                node.inferenceConfigured = true
                node.inferenceNote = "自动发现 → 自动选中 :8888 vLLM"
                node.health = HealthReport(
                    level: .warning,
                    reasons: ["可用内存 7.6 GB < 8（PSI 0.00，无人等内存）"],
                    causes: [.memoryLow]
                )
            case 1:
                node.source = .dashboard
                node.system = system(availableGB: 8.7, usedPct: 93, pressure: 0.02, cpu: 31, load: 2.1, uptime: 6.2)
                node.gpu = gpu(util: 95, temp: 59, powerW: 41.0, usedPct: 93)
                node.inference = inference(model: "GLM-5.3-Flash-EXL3", tps: 0, role: "rank 1 · headless worker")
                node.health = HealthReport(
                    level: .warning, reasons: ["可用内存 8.7 GB < 16"], causes: [.memoryLow]
                )
            case 2:
                node.source = .dashboard
                node.system = system(availableGB: 61, usedPct: 52, pressure: 0.0, cpu: 8, load: 0.6, uptime: 1.4)
                node.gpu = gpu(util: 4, temp: 38, powerW: 12.1, usedPct: 52)
                node.inference = inference(model: "Qwen3-Coder-30B", tps: 0, role: nil)
                node.inferenceConfigured = true
                node.health = .ok
            case 3:
                // The live case this feature exists for: a box running one real
                // service and one stale leftover, both answering a port scan.
                node.source = .dashboard
                node.system = system(availableGB: 61, usedPct: 52, pressure: 0.0, cpu: 8, load: 0.6, uptime: 1.4)
                node.gpu = gpu(util: 4, temp: 38, powerW: 12.1, usedPct: 52)
                node.inferenceCandidates = [
                    InferenceCandidate(port: 8888, engine: "vllm", model: "GLM-5.3-Flash-EXL3",
                                       note: "进程 vllm"),
                    InferenceCandidate(port: 11434, engine: "ollama", bind: "127.0.0.1",
                                       note: "监听端口"),
                ]
                node.inference = inference(model: "Qwen3-Coder-30B", tps: 0, role: nil)
                node.inferenceConfigured = true
                node.health = .ok
            case 4:
                node.source = .dashboard
                node.system = system(availableGB: 22, usedPct: 79, pressure: 0.31, cpu: 64, load: 12.4, uptime: 21.9)
                node.gpu = gpu(util: 88, temp: 92, powerW: 18.0, usedPct: 79)
                node.inference = inference(model: "llama-3-70b", tps: 4.1, role: nil)
                node.health = HealthReport(
                    level: .critical,
                    reasons: ["GPU 温度 92°C ≥ 90", "内存压力 PSI full avg10 0.31 > 0.25"],
                    causes: [.gpuThermal, .memoryPressure],
                    alert: true
                )
            case 5:
                node.source = .down
                node.error = "ssh spark-c 失败(255): connect timeout"
                node.health = HealthReport(
                    level: .critical, reasons: ["无响应"], causes: [.unreachable], alert: true
                )
            case 6:
                // 2026-10-16, as it actually looked: the session expired, the
                // official channel is off, and the SSH fallback supplies every
                // number — so the only honest signal is the credential state
                // itself. This state exists so that signal gets rendered and
                // reviewed instead of being discovered in production.
                node.source = .sshFallback
                node.system = system(availableGB: 62, usedPct: 52, pressure: 0.0, cpu: 12, load: 2.9, uptime: 10.5)
                node.gpu = gpu(util: 96, temp: 84, powerW: 77.1, usedPct: 52)
                node.inferenceConfigured = true
                node.awaitingCredentials = true
                node.error = CredentialGate.needsLoginReason
                node.health = HealthReport(
                    level: .warning,
                    reasons: [CredentialGate.needsLoginReason],
                    causes: [.needsLogin]
                )
            default:
                node.source = .sshFallback
                node.connecting = true
                node.system = system(availableGB: 110, usedPct: 8, pressure: 0.0, cpu: 3, load: 0.1, uptime: 0.3)
                node.gpu = gpu(util: 0, temp: 34, powerW: 11.0, usedPct: 8)
                node.health = HealthReport(level: .unknown, reasons: [])
            }

            // The derived layer production fills in `NodeRuntime.snapshot()`. Doing
            // it here too keeps previews honest: a layout that shows a thermal trend
            // or a fault chip must be reviewable without a real incident.
            let model = PowerEstimate()
            node.power = model.estimate(gpuW: node.gpu.powerW, cpuUsagePct: node.system.cpuUsagePct)
            node.faultMode = node.health.faultMode
            node.collective = index % 8 < 2
            switch index % 8 {
            case 0, 1:
                node.clockLock = .unlocked
                node.thermalTrend = ThermalTrend.Reading(
                    slopePerMinute: 0.3 + Double(index) * 0.2, spanSeconds: 180, deltaC: 1.1
                )
                node.forensics = BootForensics(
                    verdict: .powerLossSuspected, confident: true,
                    summary: "上次启动的日志停在「systemd-journald: Under memory pressure」，随后没有干净关机标记且 pstore 为空 → 疑似硬断电或被强杀。"
                )
                node.forensics?.previousBootTail = ["Oct 06 05:17:24 dgx-spark-00 systemd-journald[606]: Under memory pressure, flushing caches."]
                node.fastSampleAge = 1.6
            case 4:
                // The documented power-off recipe: 92 → 96 °C while climbing.
                node.clockLock = .unknown
                node.thermalTrend = ThermalTrend.Reading(slopePerMinute: 1.5, spanSeconds: 150, deltaC: 3.8)
                node.system.cpuTempC = 95
                node.faultMode = .clockCollapse
                node.fastSampleAge = 2.1
                node.forensics = BootForensics(
                    verdict: .powerLossSuspected, confident: false,
                    summary: "上次启动的日志在行中间中断，pstore 不可读（需要 root）→ 疑似硬断电，证据不完整。"
                )
            case 5:
                node.fastSampleAge = nil
            default:
                node.clockLock = .unknown
                node.fastSampleAge = 2.0
                node.forensics = BootForensics(
                    verdict: .cleanShutdown, confident: true, summary: "上次关机写了干净关机标记（3 条），不是断电。"
                )
            }
            return node
        }
    }

    /// A TP deployment over the first `width` machines, mirroring the real pair
    /// so the banner and role chips render as they do in production.
    static func tasks(for nodes: [NodeSnapshot], width: Int = 2) -> [ClusterTask] {
        let members = Array(nodes.prefix(max(2, width)))
        guard members.count >= 2 else { return [] }
        var ranks: [String: Int] = [:]
        for (index, node) in members.enumerated() { ranks[node.name] = index }
        return [
            ClusterTask(
                id: "demo",
                model: "GLM-5.3-Flash-EXL3",
                nodes: members.map(\.name),
                ranks: ranks,
                tensorParallel: members.count,
                nodeCount: members.count,
                apiNode: members.first?.name,
                apiURL: members.first.map { "http://\($0.host):8888" },
                quantization: "exl3",
                contextLength: 850_000
            )
        ]
    }

    private static func system(
        availableGB: Double,
        usedPct: Double,
        pressure: Double,
        cpu: Double,
        load: Double,
        uptime days: Double
    ) -> SystemSample {
        var sample = SystemSample()
        sample.memTotalBytes = 130_660_913_152
        sample.memAvailableBytes = UInt64(availableGB * 1e9)
        sample.memFreeBytes = UInt64(availableGB * 0.6 * 1e9)
        sample.memCacheBytes = 9_330_458_624
        sample.memPressureAvg10 = pressure
        sample.swapTotalBytes = 16_106_127_360
        sample.swapFreeBytes = 16_106_127_360
        sample.cpuUsagePct = cpu
        sample.cpuCores = 20
        // Real GB10 values, so a preview exercises the same thresholds as production:
        // two cpufreq policies (3.9 GHz + 2.808 GHz), a 104.8 °C trip point, the
        // 580.x driver, and the four boot-time PCIe power lines every box logs.
        sample.cpuFreqMHz = 3_354
        sample.cpuFreqMaxMHz = 3_900
        sample.thermalLimitC = 104.8
        sample.driverVersion = "580.178.04"
        sample.pcieBootPowerEvents = 4
        sample.pcieLatePowerEvents = 0
        sample.cpuTempC = 54
        sample.load1 = load
        sample.uptimeSeconds = days * 86_400
        sample.diskTotalBytes = 1_000_204_886_016
        sample.diskUsedBytes = 412_000_000_000
        return sample
    }

    private static func gpu(util: Double, temp: Double, powerW: Double, usedPct: Double) -> GpuSample {
        var sample = GpuSample()
        sample.utilPct = util
        sample.tempC = temp
        sample.powerW = powerW
        sample.smClockMHz = util > 50 ? 2_463 : 2_411
        sample.powerInstantW = powerW
        sample.memTotalBytes = 130_660_913_152
        sample.memUsedBytes = UInt64(130_660_913_152 * usedPct / 100)
        return sample
    }

    private static func inference(model: String, tps: Double, role: String?) -> InferenceSample {
        var sample = InferenceSample()
        sample.engine = role == nil ? "vLLM" : "cluster"
        sample.model = model
        sample.running = 1
        sample.decodeTPS = tps > 0 ? tps : nil
        sample.taskRole = role
        sample.quantization = "EXL3"
        sample.contextLength = 850_000
        return sample
    }

    /// Stable ids so history and focus survive re-renders.
    private static func deterministicUUID(_ index: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index))!
    }
}
