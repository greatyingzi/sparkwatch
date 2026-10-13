import Foundation
import Testing

@testable import SparkWatchCore

// These cases are ports of the Rust probe's unit tests (~/work/dgx-menubar),
// which were written against real captures from both boxes. Keeping both
// implementations honest about the same traps is the point.

@Suite("遥测解析（单位双吃）")
struct TelemetryParserTests {
    /// Real frames, same binary on both boxes, different unit suffixes.
    /// Both describe 130,660,913,152 bytes.
    @Test func kibAndMBFramesNormalizeToTheSameBytes() throws {
        let kib = """
        {"TelemetryForGPUs":[{"percentage_utilization":0,"memory_available_in_kib":20430700,\
        "memory_total_in_kib":127598548,"temperature_in_c":42,"power_draw_in_w":11.08}]}
        """
        let mb = """
        {"TelemetryForGPUs":[{"percentage_utilization":0,"memory_available_in_mb":127608,\
        "memory_total_in_mb":130661,"temperature_in_c":55,"power_draw_in_w":3.7}]}
        """
        let a = try #require(TelemetryParser.parseGpu(kib))
        let b = try #require(TelemetryParser.parseGpu(mb))

        #expect(a.memTotalBytes == 127_598_548 * 1024)
        #expect(b.memTotalBytes == 130_661_000_000)
        let delta = abs(Double(a.memTotalBytes!) - Double(b.memTotalBytes!))
        #expect(delta / 1.3e11 < 1e-5)
        #expect(a.memUsedBytes == a.memTotalBytes! - 20_430_700 * 1024)
        #expect(a.tempC == 42)
        #expect(b.powerW == 3.7)
    }

    /// Absent fields must stay nil so the UI hides the row instead of printing 0.
    @Test func missingFieldsStayNil() throws {
        let sample = try #require(TelemetryParser.parseGpu(#"{"TelemetryForGPUs":[{"percentage_utilization":0}]}"#))
        #expect(sample.utilPct == 0)
        #expect(sample.memTotalBytes == nil)
        #expect(sample.tempC == nil)
        #expect(sample.memUsedPct == nil)
    }

    @Test func rejectsGarbage() {
        #expect(TelemetryParser.parseGpu("not json") == nil)
        #expect(TelemetryParser.parseGpu(#"{"TelemetryForGPUs":[]}"#) == nil)
    }

    @Test func readsJWTExpiry() throws {
        // {"exp":1791941281,"iat":1790731681,"sub":"operator"}
        let token = "h.eyJleHAiOjE3OTE5NDEyODEsImlhdCI6MTc5MDczMTY4MSwic3ViIjoibGVvbiJ9.s"
        let expiry = try #require(TelemetryParser.jwtExpiry(token))
        #expect(Int(expiry.timeIntervalSince1970) == 1_791_941_281)
    }
}

@Suite("Prometheus 解析")
struct PrometheusParserTests {
    /// Shape taken from the real endpoint (labels abridged).
    static let sample = """
    # HELP vllm:num_requests_running
    vllm:num_requests_running{engine="0",model_name="qwen3.8-flash-next"} 2.0
    vllm:num_requests_waiting{engine="0",model_name="qwen3.8-flash-next"} 1.0
    vllm:prompt_tokens_total{engine="0",model_name="qwen3.8-flash-next"} 931377.0
    vllm:generation_tokens_total{engine="0",model_name="qwen3.8-flash-next"} 97624.0
    vllm:request_success_total{engine="0",finished_reason="stop",model_name="qwen3.8-flash-next"} 9.0
    vllm:request_success_total{engine="0",finished_reason="length",model_name="qwen3.8-flash-next"} 140.0
    """

    @Test func sumsSeriesAcrossLabels() throws {
        let snapshot = try #require(PrometheusParser.parse(Self.sample))
        // 9 + 140; taking only the first series would report 9.
        #expect(snapshot.processedRequests == 149)
        #expect(snapshot.modelNames == ["qwen3.8-flash-next"])
        #expect(snapshot.engine == "vLLM")
        #expect(snapshot.generationTokens == 97624)
        #expect(snapshot.activeRequests == 2)
        #expect(snapshot.queuedRequests == 1)
    }

    @Test func detectsSGLang() throws {
        let text = "sglang:generation_tokens_total{model_name=\"m\"} 10\nsglang:gen_throughput{model_name=\"m\"} 55.5\n"
        let snapshot = try #require(PrometheusParser.parse(text))
        #expect(snapshot.engine == "SGLang")
        #expect(snapshot.nativeGenerationTPS == 55.5)
    }

    @Test func rejectsNonInferenceMetrics() {
        #expect(PrometheusParser.parse("# just comments\nnode_cpu_seconds_total 1\n") == nil)
    }

    @Test func rateOnlyOnGrowth() {
        var tracker = TokenRateTracker()
        let t0 = Date()
        #expect(tracker.update(generationTokens: 100, at: t0) == nil)
        #expect(tracker.update(generationTokens: 100, at: t0.addingTimeInterval(2)) == nil)
        let rate = tracker.update(generationTokens: 120, at: t0.addingTimeInterval(4))
        #expect(rate != nil && rate! > 0)
    }

    /// A counter is only comparable with itself. Swapping the engine or the model
    /// rebases the totals, and subtracting across that boundary invents a rate that
    /// never happened — measured 2026-10-03: a stand-in engine switching from a
    /// vLLM-shaped counter (500) to a TensorFold one (50 000) was displayed as
    /// 1451 tok/s out of an idle box.
    @Test func aCounterFromADifferentEngineIsNotARate() {
        var tracker = TokenRateTracker()
        let t0 = Date()
        #expect(tracker.update(generationTokens: 500, engine: "vLLM", model: "m1", at: t0) == nil)
        // Same engine: a normal reading.
        #expect(tracker.update(generationTokens: 700, engine: "vLLM", model: "m1", at: t0.addingTimeInterval(2)) != nil)
        // Engine swapped, counter base changed by 50 000: re-baseline, no rate.
        #expect(tracker.update(generationTokens: 50_000, engine: "TensorFold", model: "m2", at: t0.addingTimeInterval(4)) == nil)
        #expect(tracker.didResetCounters)
        // …and the stale reading from the *previous* engine is gone too.
        #expect(tracker.lastRate == nil)
        // Growth within the new engine counts again.
        #expect(tracker.update(generationTokens: 50_800, engine: "TensorFold", model: "m2", at: t0.addingTimeInterval(6)) != nil)
    }

    /// A model name that is *missing* this cycle is not a model swap.
    ///
    /// The name arrives from `/health` on one probe and `/v1/models` on the next
    /// (whichever call won), so treating "unknown" as "different" reset the baseline
    /// every other tick: the engine was visibly busy and the bar still never showed a
    /// speed. That is the exact live complaint this guards against.
    @Test func aMissingModelNameDoesNotResetTheBaseline() {
        var tracker = TokenRateTracker()
        let t0 = Date()
        #expect(tracker.update(generationTokens: 1_000, engine: "TensorFold", model: "dgx-spark", at: t0) == nil)
        // Next probe could not read the name in time: same counters, no reset.
        #expect(tracker.update(generationTokens: 1_200, engine: "TensorFold", model: nil, at: t0.addingTimeInterval(2)) != nil)
        #expect(!tracker.didResetCounters)
        // …and the name coming back is not a swap either.
        #expect(tracker.update(generationTokens: 1_400, engine: "TensorFold", model: "dgx-spark", at: t0.addingTimeInterval(4)) != nil)
        #expect(!tracker.didResetCounters)
        // A genuinely different model still re-baselines.
        #expect(tracker.update(generationTokens: 60_000, engine: "TensorFold", model: "qwen-32b", at: t0.addingTimeInterval(6)) == nil)
        #expect(tracker.didResetCounters)
    }
}

@Suite("SSH 解析")
struct SshProbeTests {
    /// Real values from spark-a. meminfo's "kB" is KiB: 127,598,548 must
    /// land as 130,660,913,152 bytes — the number `free -b` prints and the
    /// dashboard streams.
    @Test func parsesMeminfoInKiB() {
        let raw = """
        ##meminfo
        MemTotal:       127598548 kB
        MemAvailable:    20455184 kB
        MemFree:         9111776 kB
        Cached:          12345678 kB
        Buffers:           123456 kB
        SwapTotal:       16777216 kB
        SwapFree:        16777216 kB
        ##pressure
        full avg10=4.74 avg60=1.02 avg300=0.21 total=123
        ##load
        0.19 0.19 0.27 1/1234 5678
        ##uptime
        45960.12 1234.00
        ##disk
        /dev/nvme0n1p2 4000000000000 488000000000 3200000000000 13% /
        ##docker
        qwen38-flash|qwen38-b12x:local|0.0.0.0:18300->8000/tcp
        ##gpu
        0, 42, 11.08, N/A, 2405, 3003, Not Active, Not Active, Not Active, Not Active
        """
        let result = SshProbe.parse(raw)
        #expect(result.system.memTotalBytes == 130_660_913_152)
        #expect(result.system.memAvailableBytes == 20_946_108_416)
        #expect(result.system.memCacheBytes == (12_345_678 + 123_456) * 1024)
        #expect(result.system.swapUsedBytes == 0)
        #expect(result.system.memPressureAvg10 == 4.74)
        #expect(result.system.load1 == 0.19)
        #expect(result.system.diskUsedBytes == 488_000_000_000)
        #expect(result.system.containers.count == 1)
        #expect(result.system.containers.first?.name == "qwen38-flash")
        #expect(result.gpu.tempC == 42)
        #expect(result.smClockMHz == 2405)
    }

    /// nvidia-smi prints "[N/A]" for unified memory; we never ask it for memory,
    /// and a partial line must not crash the parse.
    @Test func toleratesPartialOutput() {
        let result = SshProbe.parse("##gpu\n0 %, [N/A], [N/A]\n##docker\n")
        #expect(result.gpu.utilPct == 0)
        #expect(result.gpu.tempC == nil)
        #expect(result.system.containers.isEmpty)
    }
}

@Suite("GB10 判据")
struct HealthTests {
    func system(availableGB: Double, totalGB: Double = 130, pressure: Double? = nil, swapGB: Double = 0) -> SystemSample {
        var sample = SystemSample()
        sample.memTotalBytes = UInt64(totalGB * 1e9)
        sample.memAvailableBytes = UInt64(availableGB * 1e9)
        sample.memPressureAvg10 = pressure
        sample.swapTotalBytes = UInt64(swapGB * 1e9)
        sample.swapFreeBytes = 0
        return sample
    }

    @Test func thermalThresholds() {
        var evaluator = HealthEvaluator()
        var gpu = GpuSample(); gpu.tempC = 84
        #expect(evaluator.evaluate(gpu: gpu, system: system(availableGB: 60), source: .dashboard, error: nil).level == .ok)
        gpu.tempC = 86
        #expect(evaluator.evaluate(gpu: gpu, system: system(availableGB: 60), source: .dashboard, error: nil).level == .warning)
        gpu.tempC = 90
        #expect(evaluator.evaluate(gpu: gpu, system: system(availableGB: 60), source: .dashboard, error: nil).level == .critical)
    }

    /// The ACPI zone is judged against the platform's own declared limit, not a
    /// fixed line. The live false positive this replaces: GB10 declares 104 °C,
    /// sits at 90-91 °C under sustained inference, and a hard-coded 90 °C
    /// threshold therefore produced a standing ⚠ on a healthy machine.
    @Test func thermalZoneIsJudgedAgainstThePlatformLimit() {
        var evaluator = HealthEvaluator()
        var system = SystemSample()
        system.thermalLimitC = 104

        // The range this machine actually lives in under load stays quiet.
        for reading in [78.0, 85.0, 91.0] {
            system.cpuTempC = reading
            let quiet = evaluator.evaluate(gpu: GpuSample(), system: system, source: .dashboard, error: nil)
            #expect(quiet.level == .ok, "zone at \(reading) °C should be quiet")
            #expect(quiet.alert == false)
        }

        system.cpuTempC = 93                     // within 12 °C of the ceiling
        var report = evaluator.evaluate(gpu: GpuSample(), system: system, source: .dashboard, error: nil)
        #expect(report.level == .warning)        // hot, worth watching, not a fault
        #expect(report.alert == false)           // and definitely not a standing ⚠

        system.cpuTempC = 99                     // within 6 °C
        report = evaluator.evaluate(gpu: GpuSample(), system: system, source: .dashboard, error: nil)
        #expect(report.level == .critical)
        #expect(report.alert)
    }

    @Test func thermalZoneFallsBackWhenNoLimitIsDeclared() {
        var evaluator = HealthEvaluator()
        var system = SystemSample()
        system.thermalLimitC = nil
        system.cpuTempC = 95                     // within 6 °C of the 100 °C fallback
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system, source: .dashboard, error: nil).level
            == .critical)
    }

    @Test func memoryThresholds() {
        var evaluator = HealthEvaluator()
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system(availableGB: 20), source: .dashboard, error: nil).level == .ok)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system(availableGB: 12), source: .dashboard, error: nil).level == .warning)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system(availableGB: 60, pressure: 0.15), source: .dashboard, error: nil).level == .warning)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system(availableGB: 60, pressure: 0.30), source: .dashboard, error: nil).level == .critical)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: system(availableGB: 60, swapGB: 10), source: .dashboard, error: nil).level == .warning)
    }

    /// The live false positive this rule was rewritten for: 7.6 GB available on a
    /// 121 GiB box holding a 284B model, PSI 0.00 (nobody is waiting on memory).
    /// That is the box doing its job — 注意, not 异常.
    @Test func lowAvailableWithNoStallsIsNotCritical() {
        var evaluator = HealthEvaluator()
        let residentModel = system(availableGB: 7.6, totalGB: 130, pressure: 0.00)
        let report = evaluator.evaluate(gpu: GpuSample(), system: residentModel, source: .dashboard, error: nil)
        #expect(report.level == .warning)
        #expect(report.alert == false)
        #expect(report.reasons.contains { $0.contains("7.6") })
    }

    @Test func lowAvailableWithRealStallsIsCritical() {
        var evaluator = HealthEvaluator()
        let thrashing = system(availableGB: 7.6, totalGB: 130, pressure: 0.30)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: thrashing, source: .dashboard, error: nil).level == .critical)
    }

    @Test func imminentOOMIsCriticalWithoutPSI() {
        var evaluator = HealthEvaluator()
        let nearlyOut = system(availableGB: 1.4, totalGB: 130, pressure: 0.00)
        #expect(evaluator.evaluate(gpu: GpuSample(), system: nearlyOut, source: .dashboard, error: nil).level == .critical)
    }

    /// The documented wedge has a signature: busy, sipping power, AND collapsed
    /// clocks. Three consecutive samples escalate.
    @Test func lowDrawStreakEscalatesOnlyWithCollapsedClocks() {
        var evaluator = HealthEvaluator()
        var gpu = GpuSample(); gpu.utilPct = 96; gpu.powerW = 14
        gpu.smClockMHz = 600                     // the wedge: clocks gone
        let sample = system(availableGB: 60)
        #expect(evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil).level == .warning)
        #expect(evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil).level == .warning)
        #expect(evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil).level == .critical)
        // A healthy busy sample resets the streak.
        gpu.powerW = 120
        #expect(evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil).level == .ok)
    }

    /// The live false positive this rule was rewritten for: a tensor-parallel
    /// rank at 96 % utilisation drawing 23 W **at full clock** while the pair was
    /// decoding at 27-65 tok/s. High utilisation with normal clocks is a
    /// collective wait, not a fault, and it must never raise ⚠.
    @Test func busyAtLowPowerWithNormalClocksIsNotAWedge() {
        var evaluator = HealthEvaluator()
        var gpu = GpuSample(); gpu.utilPct = 96; gpu.powerW = 23.4
        gpu.smClockMHz = 2411                   // GB10's idle/boost clock
        let sample = system(availableGB: 60)
        for _ in 0..<6 {
            let report = evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil)
            #expect(report.level == .ok)
            #expect(report.alert == false)
        }
    }

    /// No clock reading: the rule stays silent rather than guessing — an alarm
    /// nobody can act on is worse than a wedge nobody spotted.
    @Test func unknownClockNeverRaisesTheWedgeAlarm() {
        var evaluator = HealthEvaluator()
        var gpu = GpuSample(); gpu.utilPct = 94; gpu.powerW = 18
        gpu.smClockMHz = nil
        let sample = system(availableGB: 60)
        for _ in 0..<5 {
            let report = evaluator.evaluate(gpu: gpu, system: sample, source: .dashboard, error: nil)
            #expect(report.level == .ok)
            #expect(report.alert == false)
        }
    }

    @Test func downNodeIsCritical() {
        var evaluator = HealthEvaluator()
        let report = evaluator.evaluate(gpu: GpuSample(), system: SystemSample(), source: .down, error: "无响应")
        #expect(report.level == .critical)
        #expect(report.reasons.first == "无响应")
    }
}

@Suite("配置")
struct ConfigTests {
    @Test func defaultsCoverBothBoxes() {
        let nodes = NodeConfig.defaults
        #expect(nodes.count == 2)
        #expect(nodes.map(\.dashboardLocalPort) == [19100, 19101])
        #expect(nodes[0].inferenceMetricsURL != nil)
        // IDs must be stable: they key the stored sessions, so a regenerated UUID
        // silently logs every node out.
        #expect(nodes[0].id == NodeConfig.defaults[0].id)
        #expect(nodes[0].id != nodes[1].id)
    }

    /// Regression: a config file written before `inferenceEngine` existed used to
    /// fail to decode, and SettingsStore silently fell back to built-in defaults
    /// — the app looked configured while monitoring the wrong host.
    @Test func decodesLegacyConfigWithoutNewFields() throws {
        let legacy = """
        {"sampleIntervalSeconds":2,"slowProbeIntervalSeconds":60,"nodes":[
          {"id":"00000000-0000-0000-0000-0000000000A0","name":"box","sshHost":"box.local",
           "sshUser":"operator","dashboardLocalPort":19100,
           "inferenceMetricsURL":"http://box.local:8000","enabled":true}]}
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(settings.nodes.count == 1)
        #expect(settings.nodes[0].inferenceMetricsURL == "http://box.local:8000")
        #expect(settings.nodes[0].inferenceEngine == "auto")
    }

    @Test func decodesMinimalNode() throws {
        let minimal = #"{"nodes":[{"name":"x","sshHost":"h","dashboardLocalPort":19100}]}"#
        var settings = AppSettings()
        settings = try JSONDecoder().decode(AppSettings.self, from: Data(minimal.utf8))
        #expect(settings.nodes[0].enabled)
        #expect(settings.nodes[0].inferenceMetricsURL == nil)
    }

    /// CPU usage needs a delta; the probe gets it from two `/proc/stat` reads
    /// inside one SSH call, so both lines must land in the same parse.
    @Test func parsesCPUUsageFromTwoSamples() {
        let raw = """
        ##cores
        20
        ##cpu1
        cpu  100 0 50 1000 10 0 0 0 0 0
        ##cpu2
        cpu  150 0 70 1500 14 0 0 0 0 0
        ##cputemp
        45000
        ##gpu
        0, 42, 11.08, N/A, 2405, 3003, Not Active, Not Active, Not Active, Not Active
        """
        let result = SshProbe.parse(raw)
        #expect(result.system.cpuCores == 20)
        // busy = (574 - 504) / 574 = 12.2 %
        #expect(abs((result.system.cpuUsagePct ?? 0) - 12.2) < 0.2)
        #expect(result.system.cpuTempC == 45)
    }

    /// A single /proc/stat line (no delta) must leave usage unknown rather than
    /// reporting a meaningless 0 %.
    @Test func singleCPUSampleStaysUnknown() {
        let result = SshProbe.parse("##cpu1\ncpu  100 0 50 1000 10 0 0 0 0 0\n")
        #expect(result.system.cpuUsagePct == nil)
    }

}


@Suite("暂停 / 恢复")
struct PauseTests {
    /// Pause keeps the configuration but tears the runtimes down; resume brings
    /// them back. The status bar relies on this to stop collecting entirely.
    @Test func pauseStopsRuntimesAndResumeRestores() async {
        var settings = AppSettings()
        settings.nodes = [
            NodeConfig(name: "a", sshHost: "127.0.0.1", dashboardLocalPort: 19991),
            NodeConfig(name: "b", sshHost: "127.0.0.1", dashboardLocalPort: 19992),
        ]
        let collector = ClusterCollector(settings: settings)
        await collector.start()
        #expect(await collector.snapshots().count == 2)
        #expect(await collector.isPaused == false)

        await collector.pause()
        #expect(await collector.isPaused)
        // Configuration survives: the node list is still reported (as not running).
        #expect(await collector.snapshots().count == 2)

        await collector.resume()
        #expect(await collector.isPaused == false)
        #expect(await collector.snapshots().count == 2)
        await collector.stop()
    }
}


@Suite("整机功耗预估")
struct PowerEstimateTests {
    /// The two wall-meter anchors the coefficients are solved from.
    @Test func matchesTheWallMeterAnchors() {
        let estimate = PowerEstimate()               // base 12 W, k 2.20
        // idle, no model: GPU 11.8 W -> 38 W at the wall
        #expect(abs((estimate.wholeMachineW(gpuW: 11.8) ?? 0) - 38) < 0.5)
        // generating: GPU 47.7 W -> 117 W per box (two-node Shelly, 234 W / 2)
        #expect(abs((estimate.wholeMachineW(gpuW: 47.7) ?? 0) - 117) < 0.5)
    }

    @Test func neverExceedsTheAdapter() {
        let estimate = PowerEstimate()
        #expect(estimate.wholeMachineW(gpuW: 10_000) == 240)
    }

    @Test func noGpuReadingMeansNoEstimate() {
        let estimate = PowerEstimate()
        #expect(estimate.wholeMachineW(gpuW: nil) == nil)
        var off = estimate
        off.enabled = false
        #expect(off.wholeMachineW(gpuW: 50) == nil)
    }

    @Test func coefficientsAreTunable() {
        var estimate = PowerEstimate()
        estimate.baseW = 30
        estimate.perGpuW = 2
        #expect(estimate.wholeMachineW(gpuW: 50) == 130)
    }
}
