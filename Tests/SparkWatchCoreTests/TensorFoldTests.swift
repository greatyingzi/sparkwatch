import Foundation
import Testing

@testable import SparkWatchCore

// Real command lines and payloads, copied verbatim from the two DGX Sparks
// (2026-09-30) while they served GLM-5.3-Flash under TensorFold. Nothing in this
// file is from documentation: the flags, the metric names and the /health shape
// were read off the running deployment, because a parser written from a README
// is a parser that has never seen the real thing.
private let tensorFoldRank0Line = """
/usr/bin/python3 /usr/local/bin/tensorfold serve /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-tr3-4bpw/snapshots/a5fee929cf4888b1824323e33e8a19b60129e025 --tp 2 --rank 0 --master 10.0.0.1 --master-port 29551 --no-update-check --drafter /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-DFlash2/snapshots/7d74cdd881ed7e32c31175984a67823127b66cfe --context 1048576
"""

private let tensorFoldRank1Line = """
/usr/bin/python3 /usr/local/bin/tensorfold serve /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-tr3-4bpw/snapshots/a5fee929cf4888b1824323e33e8a19b60129e025 --tp 2 --rank 1 --master 10.0.0.1 --master-port 29551 --no-update-check --drafter /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-DFlash2/snapshots/7d74cdd881ed7e32c31175984a67823127b66cfe --context 1048576 --name dgx-spark --max-tokens 32768
"""

/// `curl http://spark-a:1235/metrics` (auth proxy → TensorFold :18000).
private let tensorFoldMetrics = """
# HELP tensorfold_requests_total completions finished (errors included)
# TYPE tensorfold_requests_total counter
tensorfold_requests_total{model="dgx-spark"} 111
# HELP tensorfold_request_errors_total completions that raised
# TYPE tensorfold_request_errors_total counter
tensorfold_request_errors_total{model="dgx-spark"} 0
# HELP tensorfold_prompt_tokens_total prompt tokens of finished completions
# TYPE tensorfold_prompt_tokens_total counter
tensorfold_prompt_tokens_total{model="dgx-spark"} 6376989
# HELP tensorfold_cached_tokens_total prompt tokens resumed instead of prefilled
# TYPE tensorfold_cached_tokens_total counter
tensorfold_cached_tokens_total{model="dgx-spark"} 5894016
# HELP tensorfold_completion_tokens_total generated tokens
# TYPE tensorfold_completion_tokens_total counter
tensorfold_completion_tokens_total{model="dgx-spark"} 37081
# HELP tensorfold_requests_inflight completions running now
# TYPE tensorfold_requests_inflight gauge
tensorfold_requests_inflight{model="dgx-spark"} 4
# HELP tensorfold_requests_stalled running completions past GLM53_TF_STALL_S
# TYPE tensorfold_requests_stalled gauge
tensorfold_requests_stalled{model="dgx-spark"} 0
# HELP tensorfold_engine_fatal 1 once the engine raised (restart both ranks)
# TYPE tensorfold_engine_fatal gauge
tensorfold_engine_fatal{model="dgx-spark"} 0
"""

/// `curl http://spark-a:1235/health` — the live half of the picture.
private let tensorFoldHealth = """
{"ok": true, "mode": "basic", "uptime_s": 3962.8, "inflight": 4, "oldest_s": 58.5,
 "idle_s": null, "requests": 111, "errors": 0, "backend": "tensorfold", "busy": true,
 "requests_running": 4, "requests_total": 111, "prompt_tokens_total": 6376989,
 "completion_tokens_total": 37081, "prefill_seconds_total": 408.0197,
 "decode_seconds_total": 737.1105, "cached_tokens_total": 5894016, "rounds_total": 11766,
 "drafted_total": 34531, "accepted_total": 25219,
 "streams": {"decoding": 0, "prefilling": 4, "max": 4}, "context_length": 1048576}
"""

@Suite("SSH 探测的超时")
struct SshRunnerTimeoutTests {
    /// The call must come back within its deadline even when the peer never
    /// answers — that is the whole reason this runner exists.
    ///
    /// Live failure this guards against (2026-10-03): the inference loop sat
    /// inside `SshRunner.run` for 28 minutes. A `Task`-based watchdog never got to
    /// run (the read side blocks the cooperative pool), so the probe stayed wedged
    /// and the rate on screen froze. 10.255.255.1 is non-routable, so the TCP
    /// connect hangs for as long as anyone lets it.
    @Test func returnsWithinItsDeadlineWhenThePeerNeverAnswers() async {
        let started = Date()
        var threw = false
        do {
            _ = try await SshRunner.run(
                user: "nobody", host: "10.255.255.1", script: "true", timeout: 3
            )
        } catch {
            threw = true
        }
        let elapsed = Date().timeIntervalSince(started)
        #expect(threw)
        // 3 s deadline + up to 2 s of grace + scheduling slack.
        #expect(elapsed < 10, "SshRunner 没有在自己的 deadline 内返回（耗时 \(elapsed)s）")
    }
}

@Suite("TensorFold 部署识别")
struct TensorFoldTests {
    // MARK: - Command line

    @Test func parsesTheApiRank() {
        let info = InferenceProcessParser.parse(lines: [tensorFoldRank0Line])[0]
        #expect(info.kind == "tensorfold")
        #expect(info.nodeRank == 0)
        #expect(info.tensorParallel == 2)
        #expect(info.masterAddr == "10.0.0.1:29551")
        #expect(info.maxModelLen == 1_048_576)
        #expect(info.headless == false)
        #expect(info.port == 18000)
        #expect(info.isDistributed)
        #expect(info.modelKey?.hasSuffix("models--example-org--GLM-5.3-Flash-tr3-4bpw") == true)
        #expect(info.drafter?.contains("models--example-org--GLM-5.3-Flash-DFlash2") == true)
    }

    /// The worker rank is what a vLLM-shaped parser gets wrong twice: TensorFold
    /// has no `--headless`, and the API port belongs to rank 0 only.
    @Test func parsesTheWorkerRankWithoutAHeadlessFlag() {
        let info = InferenceProcessParser.parse(lines: [tensorFoldRank1Line])[0]
        #expect(info.kind == "tensorfold")
        #expect(info.nodeRank == 1)
        #expect(info.headless)
        #expect(info.port == nil)
        #expect(info.masterAddr == "10.0.0.1:29551")
    }

    /// `--name` is an API alias ("dgx-spark"), not the model identity: the banner
    /// must say what is loaded, not what the proxy calls it.
    @Test func theApiAliasDoesNotBecomeTheModelName() {
        let info = InferenceProcessParser.parse(lines: [tensorFoldRank1Line])[0]
        #expect(info.servedModelName == nil)
    }

    @Test func groupsTheTwoRanksIntoOneParallelTask() {
        let nodes: [(name: String, host: String, processes: [InferenceProcessInfo])] = [
            ("spark-00", "spark-a", InferenceProcessParser.parse(lines: [tensorFoldRank0Line])),
            ("spark-01", "spark-b", InferenceProcessParser.parse(lines: [tensorFoldRank1Line])),
        ]
        let tasks = ClusterTaskBuilder.build(nodes: nodes)
        #expect(tasks.count == 1)
        let task = tasks[0]
        #expect(task.model == "GLM-5.3-Flash-tr3-4bpw")
        #expect(task.nodes == ["spark-00", "spark-01"])
        #expect(task.ranks["spark-00"] == 0)
        #expect(task.ranks["spark-01"] == 1)
        #expect(task.topologyLabel == "TP2 · 2 机")
        #expect(task.contextLength == 1_048_576)
        // Rank 0 owns the endpoint; the worker serves no HTTP at all.
        #expect(task.apiNode == "spark-00")
        #expect(task.apiURL == "http://spark-a:18000")
        #expect(task.roleLabel(for: "spark-01") == "rank 1 · headless worker")
        // The drafter chip says which drafter, not the model name again.
        #expect(task.drafter == "DFlash2")
    }

    // MARK: - Metrics + health

    @Test func parsesTheMetricsBody() throws {
        let snapshot = try #require(PrometheusParser.parse(tensorFoldMetrics))
        #expect(snapshot.engine == "TensorFold")
        #expect(snapshot.modelNames == ["dgx-spark"])
        #expect(snapshot.generationTokens == 37081)
        #expect(snapshot.promptTokens == 6376989)
        #expect(snapshot.processedRequests == 111)
        #expect(snapshot.activeRequests == 4)
        #expect(snapshot.engineFatal == false)
        #expect(snapshot.stalledRequests == 0)
    }

    /// The split that matters: `/metrics` knows finished work, `/health` knows
    /// what is happening now — and "prefilling 4" is the difference between a busy
    /// box and an idle one when no decode tokens are being produced either way.
    @Test func mergesTheLiveHealthBlock() throws {
        let object = try JSONSerialization.jsonObject(with: Data(tensorFoldHealth.utf8))
        let health = try #require(object as? [String: Any])
        var sample = InferenceSample()
        InferenceProbe.mergeTensorFoldHealth(health, into: &sample)

        #expect(sample.running == 4)
        #expect(sample.prefilling == 4)
        #expect(sample.decoding == 0)
        #expect(sample.cachedTokens == 5_894_016)
        #expect(sample.contextLength == 1_048_576)
        // 5894016 / 6376989 = 92.4 % of prompt tokens came from the prefix cache.
        #expect(abs((sample.cacheHitPct ?? 0) - 92.42) < 0.1)
        // 25219 / 34531 = 73.0 % drafter acceptance.
        #expect(abs((sample.acceptancePct ?? 0) - 73.03) < 0.1)
    }

    @Test func activityNamesPrefillRatherThanShowingNothing() {
        var api = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.prefilling = 4
        sample.running = 4
        api.inference = sample
        let worker = NodeSnapshot(id: UUID(), name: "spark-01", host: "spark-b")
        let task = ClusterTask(
            id: "k", model: "GLM-5.3-Flash-tr3-4bpw", nodes: ["spark-00", "spark-01"],
            ranks: ["spark-00": 0, "spark-01": 1], tensorParallel: 2, nodeCount: 2,
            apiNode: "spark-00", apiURL: "http://spark-a:18000",
            quantization: nil, contextLength: 1_048_576
        )
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.kind == .prefilling)
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "prefill ×4")

        // During a prefill no counter moves (measured on a 20K prompt: every
        // figure frozen for the whole 6 s), so the age of the oldest request is
        // the only live evidence that it is working rather than stuck.
        api.inference?.oldestSeconds = 27
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "prefill ×4 · 27s")
        api.inference?.oldestSeconds = 95
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "prefill ×4 · 2m")
        api.inference?.oldestSeconds = nil

        // A measured prefill rate is the engine's own accounting, not a wall-clock
        // delta — so the banner's ladder does not show it (see `activity`).
        api.inference?.prefillTPS = 6200
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "prefill ×4")

        // Decoding is the top of the ladder: the banner shows tokens/s instead.
        api.inference?.decodeTPS = 27
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.kind == .decoding)
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "▶27/s")

        // In flight with no rate yet falls back to the count.
        api.inference = InferenceSample()
        api.inference?.running = 2
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "处理中 ×2")

        // An engine that cannot report in-flight state says nothing at all,
        // rather than inventing "idle".
        api.inference = InferenceSample()
        #expect(TaskSummary.activity(for: task, in: [api, worker]) == nil)
    }

    // MARK: - The engine's second namespace (2026-10 build)

    /// The same engine, rebuilt: metrics moved to a vLLM-style namespace
    /// (`tensorfold:`), with the /health block exported as `tensorfold_health:`.
    /// Captured verbatim from spark-a while the new build was serving.
    private let tensorFoldNewMetrics = """
    tensorfold:requests_running 1
    tensorfold:requests_waiting 0
    tensorfold:prompt_tokens_total 1084251
    tensorfold:generation_tokens_total 15997
    tensorfold:kv_cache_usage_ratio{pool="0"} 0.08392
    tensorfold:mtp_drafted_total 15868
    tensorfold:mtp_accepted_total 9473
    tensorfold_health:cached_tokens_total 292736
    tensorfold_health:completion_tokens_total 7709
    tensorfold_health:context_length 1048576
    tensorfold_health:decode_seconds_total 147.7487
    tensorfold_health:prefill_seconds_total 66.3607
    tensorfold_health:requests_total 33
    tensorfold_health:rounds_total 3034
    tensorfold_health:streams{state="decoding"} 1
    tensorfold_health:streams{state="filling"} 0
    tensorfold_health:streams_max 4
    """

    /// An engine upgrade must not silently zero the counters. The same probe has
    /// to read both namespaces, and the new one carries fields the old one never
    /// had (KV pool ratio, waiting queue, MTP acceptance).
    @Test func readsTheRebuiltEnginesNamespace() throws {
        let snapshot = try #require(PrometheusParser.parse(tensorFoldNewMetrics))
        #expect(snapshot.engine == "TensorFold")
        #expect(snapshot.generationTokens == 15997)
        #expect(snapshot.promptTokens == 1_084_251)
        #expect(snapshot.decodeSeconds == 147.7487)
        #expect(snapshot.processedRequests == 33)
        #expect(snapshot.activeRequests == 1)
        #expect(snapshot.queuedRequests == 0)
        // 0.08392 ratio -> 8.4 %, not 0.08 %.
        #expect(abs((snapshot.kvUsagePct ?? 0) - 8.392) < 0.01)
        // 9473 / 15868 = 59.7 % MTP acceptance.
        #expect(abs((snapshot.specAcceptance ?? 0) - 59.70) < 0.05)
        // No model label in this namespace — the model name comes from
        // /v1/models or /health instead.
        #expect(snapshot.modelNames.isEmpty)
    }

    /// The /health JSON also changed shape: `inflight`/`oldest_s` are gone,
    /// `requests_running` and a KV pool took their place. Nothing may crash or
    /// read as zero because a key disappeared.
    @Test func mergesTheRebuiltHealthShape() throws {
        let json = """
        {"ok": true, "backend": "tensorfold", "busy": true, "requests_running": 1,
         "requests_total": 33, "prompt_tokens_total": 391792,
         "completion_tokens_total": 7709, "prefill_seconds_total": 66.3607,
         "decode_seconds_total": 147.7487, "cached_tokens_total": 292736,
         "rounds_total": 3034, "drafted_total": 7482, "accepted_total": 4619,
         "streams": {"decoding": 1, "prefilling": 0, "max": 4, "filling": 0, "paused": 0},
         "pool_tokens": 2582528, "pool_free_tokens": 2473984, "kept_prompts": 12,
         "context_length": 1048576}
        """
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let health = try #require(object as? [String: Any])
        var sample = InferenceSample()
        InferenceProbe.mergeTensorFoldHealth(health, into: &sample)

        #expect(sample.running == 1)          // via requests_running
        #expect(sample.decoding == 1)
        #expect(sample.prefilling == 0)
        #expect(sample.generationTokens == 7709)
        #expect(sample.contextLength == 1_048_576)
        #expect(abs((sample.acceptancePct ?? 0) - 61.7) < 0.1)
        // No oldest_s in this build: the age suffix simply stays empty.
        #expect(sample.oldestSeconds == nil)
        #expect(TaskSummary.ageSuffix(sample) == "")
    }

    // MARK: - Rate semantics

    /// Prefill speed has to come from the engine's own accounting.
    ///
    /// The live measurements behind this test: a 10 515-token prompt lands as ONE
    /// jump — `prompt +10515, cached +10240, prefill_s +0.3`. A wall-clock delta
    /// would report ~1.7k tok/s (10515 ÷ the sampling window) for work that
    /// actually computed 275 tokens in 0.3 s, i.e. ≈917 tok/s.
    @Test func prefillSpeedUsesComputedTokensPerPrefillSecond() {
        var tracker = PrefillRateTracker()
        // First sample only establishes a baseline (nothing can be divided yet).
        #expect(
            tracker.update(promptTokens: 9_444_826, cachedTokens: 8_337_856, prefillSeconds: 1587.9)
                == nil
        )
        let rate = tracker.update(
            promptTokens: 9_455_341, cachedTokens: 8_348_096, prefillSeconds: 1588.2
        )
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - 916.7) < 1)

        // A fully cached prompt computes nothing: no prefill work, no speed.
        #expect(
            tracker.update(promptTokens: 9_460_000, cachedTokens: 8_352_755, prefillSeconds: 1588.2)
                == nil
        )
    }

    /// Decode speed is the opposite: a live counter over the wall clock, which is
    /// why it can be shown while the box is generating and vanishes when it stops.
    @Test func decodeSpeedIsAWallClockDeltaOfALiveCounter() {
        var tracker = TokenRateTracker()
        let start = Date()
        #expect(tracker.update(generationTokens: 102_046, at: start) == nil)
        let rate = tracker.update(generationTokens: 102_226, at: start.addingTimeInterval(6))
        #expect(abs((rate ?? 0) - 30) < 0.1)
        // Counter did not grow → no rate, rather than a decaying average.
        #expect(tracker.update(generationTokens: 102_226, at: start.addingTimeInterval(12)) == nil)
    }

    // MARK: - Health

    /// `engine_fatal` is the failure a green dashboard hides: every counter it
    /// exposes keeps looking fine while the engine needs both ranks restarted.
    @Test func engineFatalIsAnAlert() {
        var evaluator = HealthEvaluator()
        var inference = InferenceSample()
        inference.model = "dgx-spark"
        inference.engineFatal = true
        let report = evaluator.evaluate(
            gpu: GpuSample(), system: SystemSample(), source: .dashboard,
            error: nil, inference: inference
        )
        #expect(report.level == .critical)
        #expect(report.alert)
        #expect(report.causes.contains(.engineFatal))
    }

    @Test func stalledRequestsAreAWarningNotAnAlarm() {
        var evaluator = HealthEvaluator()
        var inference = InferenceSample()
        inference.stalledRequests = 2
        let report = evaluator.evaluate(
            gpu: GpuSample(), system: SystemSample(), source: .dashboard,
            error: nil, inference: inference
        )
        #expect(report.level == .warning)
        #expect(report.alert == false)
        #expect(report.causes.contains(.engineStalled))
    }
}

    /// The live bug this ordering fix came from: the banner asked the *first*
    /// node's sample, and a headless worker has no rate of its own — so when the
    /// worker happened to come first in the snapshot array, a deployment decoding
    /// at 63 tok/s announced 处理中 ×2 instead. The ladder is asked across nodes.
    @Test func workerOrderDoesNotShadowTheRealRate() {
        var api = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.decodeTPS = 63
        sample.running = 2
        api.inference = sample

        var worker = NodeSnapshot(id: UUID(), name: "spark-01", host: "spark-b")
        var adopted = InferenceSample()
        adopted.engine = "cluster"
        adopted.model = "GLM-5.3-Flash-Uncensored-EXL3"
        adopted.taskRole = "rank 1 · headless worker"
        worker.inference = adopted

        let task = ClusterTask(
            id: "k", model: "GLM-5.3-Flash-Uncensored-EXL3",
            nodes: ["spark-00", "spark-01"], ranks: ["spark-00": 0, "spark-01": 1],
            tensorParallel: 2, nodeCount: 2, apiNode: "spark-00",
            apiURL: "http://spark-a:18000", quantization: nil, contextLength: 1_048_576
        )
        // Worker first in the array — the order that used to break it.
        #expect(TaskSummary.activity(for: task, in: [worker, api])?.text == "▶63/s")
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.text == "▶63/s")
    }

    /// Engine reports it is decoding but the counter delta needs two probes: say
    /// so, rather than dropping to 处理中 (which reads as "no speed available").
    @Test func decodingWithoutARateYetIsLabelled() {
        var api = NodeSnapshot(id: UUID(), name: "spark-00", host: "spark-a")
        var sample = InferenceSample()
        sample.decoding = 2
        sample.prefilling = 0
        sample.running = 2
        api.inference = sample
        let worker = NodeSnapshot(id: UUID(), name: "spark-01", host: "spark-b")
        let task = ClusterTask(
            id: "k", model: "m", nodes: ["spark-00", "spark-01"], ranks: [:],
            tensorParallel: 2, nodeCount: 2, apiNode: "spark-00",
            apiURL: nil, quantization: nil, contextLength: nil
        )
        let activity = TaskSummary.activity(for: task, in: [api, worker])
        #expect(activity?.kind == .decoding)
        #expect(activity?.text == "▶ 测量中…")

        // A prefill is still a prefill: the label is gated on prefilling == 0.
        api.inference?.prefilling = 2
        #expect(TaskSummary.activity(for: task, in: [api, worker])?.kind == .prefilling)
    }
