import Foundation

// Prometheus `/metrics` parsing for the inference half — the part the official
// DGX Dashboard does not expose at all.
//
// Adapted from btoro/SparkTPS `Sources/SparkTPSCore/PrometheusParser.swift`
// (MIT, © 2026 SparkTPS contributors), extended for engines SparkTPS does not
// cover. Every family below was read off a live server, not from docs:
//
//   vLLM      vllm:generation_tokens_total, prompt_tokens_total,
//             num_requests_running/waiting, request_success_total,
//             gpu_cache_usage_perc            [live: spark-a :18300]
//   SGLang    sglang:generation_tokens_total, prompt_tokens_total,
//             num_running_reqs, num_queue_reqs, num_requests_total,
//             gen_throughput, token_usage     [same family as vLLM]
//   llama.cpp llamacpp:tokens_predicted_total, prompt_tokens_total,
//             prompt_tokens_cached_total, requests_processing,
//             requests_deferred, predicted_tokens_seconds,
//             spec_decode_num_accepted_tokens_total / _num_draft_tokens_total
//                                             [live: llama-server 0.4.1]
//   TGI       tgi_request_generated_tokens_sum, tgi_request_input_length_sum,
//             tgi_batch_current_size, tgi_queue_size, tgi_request_success
//                                             [from TGI's metric registry —
//                                              NOT validated against a live TGI]
//
// The summation rule is the one that bites in practice (first learned on the
// SGLang side of an x86 two-GPU box): a metric family can be split across several series
// (engine / finished_reason / is_streaming). Sum every matching series, or the
// totals silently lose half the traffic.

public struct PrometheusSnapshot: Sendable, Equatable {
    public var engine: String?
    public var modelNames: [String] = []
    public var generationTokens: Double = 0
    /// Cumulative *decode* seconds, when the engine counts them separately from
    /// wall time (TensorFold's `decode_seconds_total`, vLLM's
    /// `request_decode_time_seconds_sum`). This is the honest denominator for a
    /// decode rate: it excludes prefill and idle, so a reading taken across a gap
    /// is not diluted by the time nothing was decoding.
    public var decodeSeconds: Double = 0
    public var promptTokens: Double = 0
    public var processedRequests: Double = 0
    public var activeRequests: Double = 0
    public var queuedRequests: Double = 0
    public var nativeGenerationTPS: Double?
    public var kvUsagePct: Double?
    /// Speculative-decode acceptance, where the engine exposes the counters.
    public var specAcceptance: Double?
    /// The engine reports it has raised (TensorFold's `*_engine_fatal`). Kept on
    /// the snapshot because it is not a number that belongs in a rate.
    public var engineFatal: Bool = false
    /// Requests stuck past the engine's own stall threshold.
    public var stalledRequests: Double?
    /// Latency histograms, when the engine exports them.
    ///
    /// These are the numbers that separate "it is fast" from "it is fast *and*
    /// nothing is queueing behind a 300-second prefill": a mean hides the tail, and
    /// the engine's own buckets are the only honest source for it. All optional —
    /// an engine that does not export histograms (llama.cpp, EXL3) simply has none.
    public var ttftMeanSeconds: Double?
    public var ttftP95Seconds: Double?
    public var e2eP95Seconds: Double?
    public var itlP95Seconds: Double?
}

public enum PrometheusParser {
    public static func parse(_ text: String) -> PrometheusSnapshot? {
        var values: [String: Double] = [:]
        var models = Set<String>()
        var families: Set<String> = []
        // Histograms are summed per `le` across label sets (a metric split by
        // `engine`/`tp_rank` has several bucket series per boundary, and taking only
        // the first would compute a quantile over a fraction of the requests).
        var buckets: [String: [Double: Double]] = [:]
        var histSum: [String: Double] = [:]
        var histCount: [String: Double] = [:]

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            guard let space = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let descriptor = String(line[..<space])
            let valueText = line[line.index(after: space)...]
            guard let value = Double(valueText), value.isFinite else { continue }

            let metricName = descriptor.split(separator: "{", maxSplits: 1).first.map(String.init)
                ?? descriptor
            guard let family = family(of: metricName) else { continue }

            families.insert(family)
            values[metricName, default: 0] += value

            if metricName.hasSuffix("_bucket"),
                let raw = label(named: "le", in: descriptor)
            {
                let base = String(metricName.dropLast("_bucket".count))
                let le = raw == "+Inf" ? Double.infinity : Double(raw)
                if let le { buckets[base, default: [:]][le, default: 0] += value }
            } else if metricName.hasSuffix("_sum") {
                histSum[String(metricName.dropLast("_sum".count)), default: 0] += value
            } else if metricName.hasSuffix("_count") {
                histCount[String(metricName.dropLast("_count".count)), default: 0] += value
            }

            if let model = label(named: "model_name", in: descriptor)
                ?? label(named: "model", in: descriptor), !model.isEmpty
            {
                models.insert(model)
            }
        }

        guard let engineFamily = preferredFamily(in: families) else { return nil }

        var snapshot = PrometheusSnapshot()
        snapshot.modelNames = models.sorted()
        snapshot.engine = engineLabel(for: engineFamily)

        switch engineFamily {
        case "vllm", "sglang":
            let prefix = engineFamily + ":"
            snapshot.generationTokens = values[prefix + "generation_tokens_total"]
                ?? values[prefix + "generation_tokens"] ?? 0
            snapshot.decodeSeconds = values[prefix + "request_decode_time_seconds_sum"] ?? 0
            snapshot.promptTokens = values[prefix + "prompt_tokens_total"]
                ?? values[prefix + "prompt_tokens"] ?? 0
            if engineFamily == "sglang" {
                snapshot.processedRequests = values["sglang:num_requests_total"] ?? 0
                snapshot.activeRequests = values["sglang:num_running_reqs"] ?? 0
                snapshot.queuedRequests = values["sglang:num_queue_reqs"] ?? 0
                snapshot.nativeGenerationTPS = values["sglang:gen_throughput"]
                snapshot.kvUsagePct = values["sglang:token_usage"].map { $0 <= 1 ? $0 * 100 : $0 }
            } else {
                snapshot.processedRequests = values["vllm:request_success_total"] ?? 0
                snapshot.activeRequests = values["vllm:num_requests_running"] ?? 0
                snapshot.queuedRequests = values["vllm:num_requests_waiting"] ?? 0
                snapshot.kvUsagePct = values["vllm:gpu_cache_usage_perc"].map { $0 <= 1 ? $0 * 100 : $0 }
            }

        case "llamacpp":
            // Every counter sits at a different name than vLLM's.
            snapshot.generationTokens = values["llamacpp:tokens_predicted_total"] ?? 0
            snapshot.promptTokens = values["llamacpp:prompt_tokens_total"] ?? 0
            snapshot.processedRequests = values["llamacpp:n_decode_total"] ?? 0
            snapshot.activeRequests = values["llamacpp:requests_processing"] ?? 0
            snapshot.queuedRequests = values["llamacpp:requests_deferred"] ?? 0
            snapshot.nativeGenerationTPS = values["llamacpp:predicted_tokens_seconds"]
            if let accepted = values["llamacpp:spec_decode_num_accepted_tokens_total"],
                let drafted = values["llamacpp:spec_decode_num_draft_tokens_total"], drafted > 0
            {
                snapshot.specAcceptance = accepted / drafted * 100
            }

        case "tgi":
            snapshot.generationTokens = values["tgi_request_generated_tokens_sum"] ?? 0
            snapshot.promptTokens = values["tgi_request_input_length_sum"] ?? 0
            snapshot.processedRequests = values["tgi_request_success"]
                ?? values["tgi_request_count"] ?? 0
            snapshot.activeRequests = values["tgi_batch_current_size"] ?? 0
            snapshot.queuedRequests = values["tgi_queue_size"] ?? 0
            if let sum = values["tgi_request_mean_time_per_token_duration_sum"],
                let count = values["tgi_request_mean_time_per_token_duration_count"], count > 0
            {
                let secondsPerToken = sum / count
                if secondsPerToken > 0 { snapshot.nativeGenerationTPS = 1 / secondsPerToken }
            }

        case "tensorfold":
            // Three spellings are live across two engine builds, and an engine
            // upgrade must not turn every counter into a zero — so read them all:
            //   new build (2026-10+): `tensorfold:` (vLLM-style, no model label)
            //                         `tensorfold_health:` (the /health export)
            //   old build (2026-09):  `tensorfold_*` (flat, underscored)
            // [live: spark-a :1235 (auth proxy) → :18000, and :18000 direct]
            snapshot.generationTokens = values["tensorfold:generation_tokens_total"]
                ?? values["tensorfold_health:completion_tokens_total"]
                ?? values["tensorfold_completion_tokens_total"] ?? 0
            snapshot.decodeSeconds = values["tensorfold_health:decode_seconds_total"]
                ?? values["tensorfold_decode_seconds_total"] ?? 0
            snapshot.promptTokens = values["tensorfold:prompt_tokens_total"]
                ?? values["tensorfold_health:prompt_tokens_total"]
                ?? values["tensorfold_prompt_tokens_total"] ?? 0
            snapshot.processedRequests = values["tensorfold_health:requests_total"]
                ?? values["tensorfold_requests_total"] ?? 0
            snapshot.activeRequests = values["tensorfold:requests_running"]
                ?? values["tensorfold_requests_inflight"] ?? 0
            snapshot.queuedRequests = values["tensorfold:requests_waiting"] ?? 0
            // Ratio with a `pool` label (summed across pools by the accumulator).
            snapshot.kvUsagePct = values["tensorfold:kv_cache_usage_ratio"]
                .map { $0 <= 1 ? $0 * 100 : $0 }
            // The new build names spec-decode acceptance after MTP.
            if let accepted = values["tensorfold:mtp_accepted_total"],
                let drafted = values["tensorfold:mtp_drafted_total"], drafted > 0
            {
                snapshot.specAcceptance = accepted / drafted * 100
            }
            // Old-build-only health flags; the new build reports fatal state
            // through /health instead.
            snapshot.stalledRequests = values["tensorfold_requests_stalled"]
            snapshot.engineFatal = (values["tensorfold_engine_fatal"] ?? 0) >= 1

        default:
            return nil
        }

        // Latency histograms — optional, and each engine spells them differently, so
        // every candidate name is tried. Absent means absent: the tiles that show
        // these simply do not render, rather than printing a zero.
        let ttft = histogram(["\(prefixFor(engineFamily))time_to_first_token_seconds",
                              "\(prefixFor(engineFamily))ttft_seconds"], buckets: buckets, count: histCount, sum: histSum)
        snapshot.ttftP95Seconds = quantile(0.95, buckets: ttft.buckets, count: ttft.count)
        if let sum = ttft.sum, let count = ttft.count, count > 0, sum > 0 {
            snapshot.ttftMeanSeconds = sum / count
        }
        let e2e = histogram(["\(prefixFor(engineFamily))request_latency_seconds",
                             "\(prefixFor(engineFamily))e2e_request_latency_seconds"], buckets: buckets, count: histCount, sum: histSum)
        snapshot.e2eP95Seconds = quantile(0.95, buckets: e2e.buckets, count: e2e.count)
        let itl = histogram(["\(prefixFor(engineFamily))inter_token_latency_seconds",
                             "\(prefixFor(engineFamily))itl_seconds"], buckets: buckets, count: histCount, sum: histSum)
        snapshot.itlP95Seconds = quantile(0.95, buckets: itl.buckets, count: itl.count)
        return snapshot
    }

    /// The metric-name prefix each family uses (`vllm:` / `sglang:` / `tensorfold:`),
    /// so the histogram lookups above stay readable.
    static func prefixFor(_ family: String) -> String {
        switch family {
        case "vllm", "sglang": family + ":"
        case "tensorfold": "tensorfold:"
        default: family + ":"
        }
    }

    static func histogram(
        _ names: [String],
        buckets: [String: [Double: Double]],
        count: [String: Double],
        sum: [String: Double]
    ) -> (buckets: [Double: Double]?, count: Double?, sum: Double?) {
        for name in names where buckets[name] != nil {
            return (buckets[name], count[name], sum[name])
        }
        return (nil, nil, nil)
    }

    /// Linear-interpolated quantile from a Prometheus histogram.
    ///
    /// Returns **nil** rather than guessing in the three cases where the answer is
    /// not in the data — the honesty rule this whole file follows:
    ///   * no buckets at all (the engine does not export this histogram);
    ///   * the buckets and `_count` disagree, i.e. a partially scraped histogram —
    ///     the reference implementation refuses the quantile in exactly this case;
    ///   * the target lies in the `+Inf` bucket, where the exported boundaries do
    ///     not bound it. Reporting the last finite boundary there would be a
    ///     fabricated number (measured live: request-latency p95 for this fleet falls
    ///     in that tail, while TTFT p95 lands cleanly at ≈31 s).
    static func quantile(_ q: Double, buckets: [Double: Double]?, count: Double?) -> Double? {
        guard let buckets, !buckets.isEmpty else { return nil }
        let sorted = buckets.sorted { $0.key < $1.key }
        let infinite = buckets[.infinity]
        guard let total = infinite ?? sorted.last?.value, total > 0 else { return nil }
        if let count, let infinite, abs(infinite - count) > 0.5 { return nil }

        let target = q * total
        var lowerLe = 0.0
        var lowerCum = 0.0
        for (le, cum) in sorted where le.isFinite {
            if cum >= target {
                let span = cum - lowerCum
                guard span > 0 else { return le }
                let fraction = (target - lowerCum) / span
                return lowerLe + fraction * (le - lowerLe)
            }
            lowerLe = le
            lowerCum = cum
        }
        // Everything finite is below the target → it lives in the +Inf tail.
        return nil
    }

    private static func family(of metricName: String) -> String? {
        if metricName.hasPrefix("vllm:") { return "vllm" }
        if metricName.hasPrefix("sglang:") { return "sglang" }
        if metricName.hasPrefix("llamacpp:") { return "llamacpp" }
        if metricName.hasPrefix("tensorfold:") { return "tensorfold" }
        if metricName.hasPrefix("tensorfold_") { return "tensorfold" }
        if metricName.hasPrefix("tgi_") { return "tgi" }
        return nil
    }

    private static func engineLabel(for family: String) -> String {
        switch family {
        case "vllm": "vLLM"
        case "sglang": "SGLang"
        case "llamacpp": "llama.cpp"
        case "tensorfold": "TensorFold"
        case "tgi": "TGI"
        default: family
        }
    }

    /// One engine per endpoint normally; if several families appear, prefer the
    /// one with the real counters.
    private static func preferredFamily(in families: Set<String>) -> String? {
        for candidate in ["vllm", "sglang", "tensorfold", "llamacpp", "tgi"]
        where families.contains(candidate) {
            return candidate
        }
        return nil
    }

    /// Does this body actually contain Prometheus inference metrics?
    ///
    /// Status codes lie here: LM Studio answers `GET /metrics` with **HTTP 200**
    /// plus `{"error":"Unexpected endpoint or method..."}`, and llama.cpp answers
    /// 501 unless started with `--metrics`. Validate the body, not the code.
    public static func looksLikeMetrics(_ text: String) -> Bool {
        var sampleLines = 0
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let space = line.lastIndex(where: { $0 == " " || $0 == "\t" }) else { continue }
            let value = line[line.index(after: space)...]
            guard Double(value) != nil else { continue }
            sampleLines += 1
            if sampleLines >= 3 { return true }
        }
        return false
    }

    private static func label(named name: String, in descriptor: String) -> String? {
        let marker = name + "=\""
        guard let start = descriptor.range(of: marker)?.upperBound else { return nil }
        var result = ""
        var escaped = false
        var index = start
        while index < descriptor.endIndex {
            let character = descriptor[index]
            if escaped {
                result.append(character)
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "\"" {
                return result
            } else {
                result.append(character)
            }
            index = descriptor.index(after: index)
        }
        return nil
    }
}

/// Turns two consecutive *engine-accounted* prefill figures into a speed.
///
/// Different from `TokenRateTracker` on purpose. Prompt tokens and prefill
/// seconds only move when a request **finishes**, so a wall-clock delta over them
/// measures nothing: measured on the live box, a 10 515-token prompt arrived as
/// one jump of `prompt +10515 / cached +10240 / prefill_s +0.3` — dividing 10515
/// by the sampling window would report ~1.7k tok/s for work that actually
/// computed 275 tokens in 0.3 s.
///
/// What is honest is the engine's own accounting: *newly computed* prompt tokens
/// (prompt − cached) per second of prefill work. Same sample: 275 / 0.3 ≈ 917
/// tok/s. It refreshes only when a request completes, which is why the UI labels
/// it as the last finished prompt and keeps a separate live progress indicator
/// (the in-flight count and its age).
public struct PrefillRateTracker: Sendable {
    private var last: (prompt: Double, cached: Double, seconds: Double)?
    /// Same guard as `TokenRateTracker`: prompt counters from two different engines
    /// must never be subtracted from each other. A missing model name does not count
    /// as a change (see `TokenRateTracker.adoptCounters`).
    private var engine: String?
    private var model: String?

    public init() {}

    public mutating func update(
        promptTokens: Double?,
        cachedTokens: Double?,
        prefillSeconds: Double?,
        engine newEngine: String? = nil,
        model newModel: String? = nil
    ) -> Double? {
        let engineChanged = newEngine != nil && engine != nil && newEngine != engine
        let modelChanged = newModel?.isEmpty == false && model?.isEmpty == false && newModel != model
        if engineChanged || modelChanged {
            engine = newEngine ?? engine
            model = newModel ?? model
            last = nil
            if let promptTokens, let cachedTokens, let prefillSeconds {
                last = (promptTokens, cachedTokens, prefillSeconds)
            }
            return nil
        }
        if let newEngine, engine == nil { engine = newEngine }
        if let newModel, !newModel.isEmpty, model?.isEmpty != false { model = newModel }
        defer {
            if let promptTokens, let cachedTokens, let prefillSeconds {
                last = (promptTokens, cachedTokens, prefillSeconds)
            }
        }
        guard let last, let promptTokens, let cachedTokens, let prefillSeconds else { return nil }
        let computed = (promptTokens - last.prompt) - (cachedTokens - last.cached)
        let seconds = prefillSeconds - last.seconds
        guard seconds > 0.001, computed > 0 else { return nil }
        return computed / seconds
    }
}

/// Turns consecutive cumulative counters into a rate.
/// Decode rate from the engine's own accounting: Δtokens ÷ Δdecode_seconds.
///
/// Preferred over the wall-clock tracker whenever the engine exposes decode time,
/// because the denominator is time actually spent decoding. That matters at the
/// start of a request: the wall-clock delta spans whatever idle time preceded it
/// (measured live: a reading of 7.5 tok/s for work running at 46 tok/s, purely
/// because the probe interval contained 5 s of nothing), and it matters at the
/// end, where a stalled counter reads as a slowdown.
public struct EngineDecodeRateTracker: Sendable {
    private var last: (tokens: Double, seconds: Double)?
    /// Where the last rate came from — surfaced in the trace so a missing rate
    /// can be attributed without guessing.
    public private(set) var lastSource = "none"

    public init() {}

    public mutating func update(generationTokens: Double?, decodeSeconds: Double?) -> Double? {
        defer {
            if let generationTokens, let decodeSeconds {
                last = (generationTokens, decodeSeconds)
            }
        }
        guard let previous = last, let generationTokens, let decodeSeconds else { return nil }
        let tokens = generationTokens - previous.tokens
        let seconds = decodeSeconds - previous.seconds
        // Both must advance: no tokens means nothing was produced, no seconds
        // means the engine's clock did not move (and dividing by it is nonsense).
        guard tokens > 0, seconds > 0.001 else {
            lastSource = tokens > 0 ? "engine(no-clock)" : "engine(idle)"
            return nil
        }
        lastSource = "engine"
        return tokens / seconds
    }
}

/// Turns consecutive cumulative counters into a rate.
public struct TokenRateTracker: Sendable {
    private var last: (at: Date, generationTokens: Double)?
    /// Which counters these numbers came from (engine + model). A change means the
    /// counter now has a different base, and subtracting across that boundary
    /// invents a rate that never happened — measured 2026-10-03 on the mock matrix:
    /// switching the stand-in from a vLLM-shaped counter (500) to a TensorFold one
    /// (50 000) was reported as 1451 tok/s out of a genuinely idle engine.
    private var engine: String?
    private var model: String?

    /// Set by the last `update` when it threw the baseline away because the counters
    /// underneath had changed. The collector logs it: without this, a reset looks
    /// exactly like "the engine is working but no rate ever appears".
    public private(set) var didResetCounters = false

    public init() {}

    /// Same counters or different ones?
    ///
    /// A *missing* model name must not count as a different model: the name arrives
    /// from `/health` or `/v1/models` depending on which call won this cycle, so a
    /// flaky probe used to flip the identity on every other tick and reset the
    /// baseline each time — which reads on screen as "engine busy, no speed, ever".
    /// Only a *known and different* name, or a different engine, re-baselines.
    private mutating func adoptCounters(engine newEngine: String?, model newModel: String?) -> Bool {
        let engineChanged = newEngine != nil && engine != nil && newEngine != engine
        let modelChanged = newModel?.isEmpty == false && model?.isEmpty == false && newModel != model
        if engineChanged || modelChanged {
            engine = newEngine ?? engine
            model = newModel ?? model
            return true
        }
        if let newEngine, engine == nil { engine = newEngine }
        if let newModel, model?.isEmpty != false, !newModel.isEmpty { model = newModel }
        return false
    }

    /// tok/s when the counter grew; nil on the first sample and while idle, so
    /// the UI can show "—" instead of a decaying average.
    public mutating func update(
        generationTokens: Double,
        engine newEngine: String? = nil,
        model newModel: String? = nil,
        at now: Date = Date()
    ) -> Double? {
        didResetCounters = false
        if adoptCounters(engine: newEngine, model: newModel) {
            // Different counters (engine or model swapped): re-baseline and drop
            // the old reading — one engine's total minus another's is not a rate.
            last = (now, generationTokens)
            lastRateValue = nil
            lastRateAt = nil
            didResetCounters = true
            return nil
        }
        defer { last = (now, generationTokens) }
        guard let previous = last, generationTokens > previous.generationTokens else { return nil }
        let seconds = now.timeIntervalSince(previous.at)
        guard seconds > 0 else { return nil }
        lastRateValue = (generationTokens - previous.generationTokens) / seconds
        lastRateAt = now
        return lastRateValue
    }

    /// Seconds since the counter last *grew* — i.e. how old the last rate is.
    ///
    /// Deliberately not `now - last.at`: `last.at` is refreshed on every probe
    /// (it is the delta's left edge), so measuring age against it always returned
    /// ~0 and the UI could never tell a live rate from a stale one. This is the
    /// whole reason the number used to stay bright after inference stopped.
    public func age(now: Date = Date()) -> Double? {
        guard let lastRateAt else { return nil }
        return now.timeIntervalSince(lastRateAt)
    }

    /// The rate computed most recently, kept so a stopped deployment can still
    /// show what it was doing (greyed) instead of a dash.
    public var lastRate: Double? { lastRateValue }
    private var lastRateValue: Double?
    /// When the counter last grew — the moment `lastRateValue` was measured.
    private var lastRateAt: Date?
    /// When the counter was last *read* (every probe, growth or not). Exposed so
    /// the collector can tell whether the interval behind a rate started before
    /// the work did, which would dilute the first reading of a request.
    public var lastProbeAt: Date? { last?.at }

    public func stale(olderThan seconds: TimeInterval, now: Date = Date()) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last.at) > seconds
    }
}
