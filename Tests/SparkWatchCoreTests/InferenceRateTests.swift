import Foundation
import Testing

@testable import SparkWatchCore

// Every payload and number in this file was copied off the live deployment
// (dgx-spark-00, `wu@192.168.1.7`, TensorFold serving Qwen3.8-Flash-Next) on
// 2026-10-30 while a real request ran. The bug they guard against:
//
//   *an 11.2 s request in which `tensorfold:generation_tokens_total` never moved
//   (29 polls, 1 saw growth) and then jumped by the full 400 tokens.*
//
// The old pipeline divided that jump by the sample window — 0 tok/s for the whole
// request, ~200 tok/s at the end — and read nothing at all for prefill, because
// `/health` had changed shape underneath the parser.

/// The current `/health` (new build), idle, right after a request finished.
private let healthNewIdle = """
{"status": "ok", "model": "dgx-spark", "model_ids": ["dgx-spark"], "max_batch_size": 8,
 "warming": false, "memory": {},
 "live": {"connections": 0, "waiting": 0, "decode_tokens_per_second": 25.5,
          "prefill_tokens_per_second": 0.0}}
"""

/// Mid-prefill, 0.4 s into a request (sampled live).
private let healthNewPrefilling = """
{"status": "ok", "model": "dgx-spark", "model_ids": ["dgx-spark"], "max_batch_size": 8,
 "warming": false, "memory": {},
 "live": {"connections": 1, "waiting": 0, "decode_tokens_per_second": 3.0,
          "prefill_tokens_per_second": 1006.3}}
"""

/// The 2026-09 shape, kept so an older engine build keeps working.
private let healthOld = """
{"ok": true, "mode": "basic", "uptime_s": 3962.8, "inflight": 4, "oldest_s": 58.5,
 "idle_s": null, "requests": 111, "errors": 0, "backend": "tensorfold", "busy": true,
 "requests_running": 4, "requests_total": 111, "prompt_tokens_total": 6376989,
 "completion_tokens_total": 37081, "prefill_seconds_total": 408.0197,
 "decode_seconds_total": 737.1105, "cached_tokens_total": 5894016, "rounds_total": 11766,
 "drafted_total": 34531, "accepted_total": 25219,
 "streams": {"decoding": 0, "prefilling": 4, "max": 4}, "context_length": 1048576}
"""

/// `curl :18000/metrics` mid-request (sampled live at t=6.1 s).
private let metricsLive = """
# TYPE tensorfold:generation_tokens_total counter
tensorfold:generation_tokens_total 2363261
# TYPE tensorfold:generation_tokens_running gauge
tensorfold:generation_tokens_running 225
# TYPE tensorfold:num_requests_running gauge
tensorfold:num_requests_running 1
# TYPE tensorfold:prompt_tokens_total counter
tensorfold:prompt_tokens_total 186795426
# TYPE tensorfold:request_decode_time_seconds histogram
tensorfold:request_decode_time_seconds_sum 49807.396074
tensorfold:request_decode_time_seconds_count 2717
# TYPE tensorfold:kv_cache_usage_ratio gauge
tensorfold:kv_cache_usage_ratio 0.42
"""

@Suite("TensorFold /health 的两个 schema")
struct TensorFoldHealthShapeTests {
    @Test func readsTheCurrentLiveOnlyShape() {
        var sample = InferenceSample()
        // Through the same entry the engine adapter uses.
        InferenceProbe.mergeTensorFoldHealth(try! json(healthNewIdle), into: &sample)

        #expect(sample.decodeTPSNative == 25.5)
        #expect(sample.prefillTPSNative == 0.0)
        #expect(sample.running == 0)
        #expect(sample.capabilities.hasSpeed)
        // The counters are gone from /health in this build: they must stay nil
        // rather than being invented as 0, or the rate would read "0 tokens" for a
        // box that is working.
        #expect(sample.generationTokens == nil)
        #expect(sample.prefillSeconds == nil)
    }

    @Test func readsLiveStateDuringAPrefill() {
        var sample = InferenceSample()
        InferenceProbe.mergeTensorFoldHealth(try! json(healthNewPrefilling), into: &sample)

        #expect(sample.prefillTPSNative == 1006.3)
        #expect(sample.running == 1)
    }

    @Test func stillReadsTheOlderCounterShape() {
        var sample = InferenceSample()
        InferenceProbe.mergeTensorFoldHealth(try! json(healthOld), into: &sample)

        #expect(sample.generationTokens == 37081)
        #expect(sample.promptTokens == 6376989)
        #expect(sample.cachedTokens == 5894016)
        #expect(sample.prefillSeconds == 408.0197)
        #expect(sample.running == 4)
        #expect(sample.prefilling == 4)
        // No live rates in that build.
        #expect(sample.decodeTPSNative == nil)
    }

    @Test func parsesTheInFlightGaugeAndTheDecodeClock() {
        let snapshot = PrometheusParser.parse(metricsLive)
        #expect(snapshot?.generationTokensRunning == 225)
        #expect(snapshot?.generationTokens == 2363261)
        #expect(snapshot?.activeRequests == 1)
        // The decode clock now comes from the histogram sum on this build.
        #expect(snapshot?.decodeSeconds == 49807.396074)
    }
}

@Suite("在途 token gauge 转速率")
struct GaugeTokensRateTests {
    @Test func turnsGrowthIntoARate() {
        var tracker = GaugeTokensRateTracker()
        let t0 = Date(timeIntervalSince1970: 1000)
        #expect(tracker.update(tokens: 6, at: t0) == nil)          // first sample: baseline
        #expect(tracker.update(tokens: 56, at: t0.addingTimeInterval(2)) == 25)
        #expect(tracker.update(tokens: 106, at: t0.addingTimeInterval(4)) == 25)
        #expect(tracker.lastRate == 25)
    }

    @Test func aResetIsNotANegativeRate() {
        var tracker = GaugeTokensRateTracker()
        let t0 = Date(timeIntervalSince1970: 2000)
        _ = tracker.update(tokens: 395, at: t0)
        // The stream finished and the gauge went to 0: skipping the interval is the
        // only honest answer, and it must not poison the next one either.
        #expect(tracker.update(tokens: 0, at: t0.addingTimeInterval(2)) == nil)
        #expect(tracker.update(tokens: 40, at: t0.addingTimeInterval(4)) == 20)
    }

    @Test func frozenGaugeProducesNothing() {
        var tracker = GaugeTokensRateTracker()
        let t0 = Date(timeIntervalSince1970: 3000)
        _ = tracker.update(tokens: 0, at: t0)
        #expect(tracker.update(tokens: 0, at: t0.addingTimeInterval(2)) == nil)
        #expect(tracker.lastRate == nil)
    }
}

@Suite("速率来源的优先顺序")
struct InferenceRateResolverTests {
    @Test func nativeRateWinsWhileTheEngineReportsWork() {
        let r = InferenceRateResolver.resolve(
            nativeRate: 33.5, nativeBusy: true,
            gaugeRate: 34.2, wallRate: 0, engineRate: nil,
            justFinished: false, hasLiveSource: true
        )
        #expect(r.tps == 33.5)
        #expect(r.source == "health")
        #expect(r.counterStale == false)
    }

    @Test func aCoastingNativeRateIsNotLive() {
        // The engine's own EMA lingers for a second or two after the last stream
        // (measured: 32.0 with connections == 0). With no work in flight it must
        // not keep claiming to be live.
        let r = InferenceRateResolver.resolve(
            nativeRate: 32.0, nativeBusy: false,
            gaugeRate: nil, wallRate: nil, engineRate: nil,
            justFinished: false, hasLiveSource: true
        )
        #expect(r.tps == nil)
        #expect(r.counterStale == false)
    }

    @Test func gaugeIsUsedWhenThereIsNoNativeRate() {
        let r = InferenceRateResolver.resolve(
            nativeRate: nil, nativeBusy: true,
            gaugeRate: 25.4, wallRate: 0, engineRate: nil,
            justFinished: false, hasLiveSource: true
        )
        #expect(r.tps == 25.4)
        #expect(r.source == "gauge")
    }

    @Test func counterJumpAtCompletionIsNotDividedByTheSampleWindow() {
        // This is the 200 tok/s spike: 400 tokens arrived in one step because the
        // request ended. With engine-accounted decode time available the honest
        // answer is 36.4 tok/s.
        let r = InferenceRateResolver.resolve(
            nativeRate: 0, nativeBusy: false,
            gaugeRate: nil, wallRate: 200, engineRate: 36.4,
            justFinished: true, hasLiveSource: true
        )
        #expect(r.tps == 36.4)
        #expect(r.source == "engine")
    }

    @Test func boundaryJumpWithNoClockIsDropped() {
        let r = InferenceRateResolver.resolve(
            nativeRate: 0, nativeBusy: false,
            gaugeRate: nil, wallRate: 200, engineRate: nil,
            justFinished: true, hasLiveSource: true
        )
        #expect(r.tps == nil)
        #expect(r.source == "boundary")
    }

    @Test func enginesWithLiveCountersKeepUsingThem() {
        // vLLM/SGLang: the counter really does move during a request, so the wall
        // clock is a legitimate denominator and must not be suppressed.
        let r = InferenceRateResolver.resolve(
            nativeRate: nil, nativeBusy: false,
            gaugeRate: nil, wallRate: 47.2, engineRate: nil,
            justFinished: false, hasLiveSource: false
        )
        #expect(r.tps == 47.2)
        #expect(r.source == "counter")
    }

    @Test func busyButNothingMovedIsReportedAsStale() {
        let r = InferenceRateResolver.resolve(
            nativeRate: nil, nativeBusy: true,
            gaugeRate: nil, wallRate: 0, engineRate: nil,
            justFinished: false, hasLiveSource: true
        )
        #expect(r.tps == nil)
        #expect(r.counterStale)
    }

    @Test func prefillPrefersTheLiveFigure() {
        #expect(InferenceRateResolver.prefill(native: 1006.3, tracked: 408) == 1006.3)
        #expect(InferenceRateResolver.prefill(native: 0, tracked: 917) == 917)
        #expect(InferenceRateResolver.prefill(native: nil, tracked: nil) == nil)
    }
}

private func json(_ text: String) throws -> [String: Any] {
    let data = Data(text.utf8)
    return try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
}
