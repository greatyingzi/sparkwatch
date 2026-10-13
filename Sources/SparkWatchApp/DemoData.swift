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
            // Seven states, cycling: the two halves of a real TP pair, an idle box
            // holding a model, one with a stale leftover next to a live service,
            // a critical machine, a down one, and one still connecting. (The
            // leftover state used to be a second `case 2`, which Swift treated as
            // unreachable — that state never rendered.)
            switch index % 7 {
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
            default:
                node.source = .sshFallback
                node.connecting = true
                node.system = system(availableGB: 110, usedPct: 8, pressure: 0.0, cpu: 3, load: 0.1, uptime: 0.3)
                node.gpu = gpu(util: 0, temp: 34, powerW: 11.0, usedPct: 8)
                node.health = HealthReport(level: .unknown, reasons: [])
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
