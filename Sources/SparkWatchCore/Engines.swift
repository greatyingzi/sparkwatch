import Foundation

// Multi-engine inference adapter.
//
// Every payload shape below was captured from a running server, not guessed:
//
//   vLLM        : vllm:generation_tokens_total / num_requests_running / gpu_cache_usage_perc
//                 (live: spark-a :18300, Qwen3.8-Flash-Next)
//   SGLang      : sglang:generation_tokens_total / num_running_reqs / gen_throughput
//                 (shape from the an x86 two-GPU box SGLang deployment, same family as vLLM)
//   llama.cpp   : llamacpp:tokens_predicted_total / prompt_tokens_total /
//                 requests_processing / requests_deferred / predicted_tokens_seconds,
//                 plus /v1/models `meta` {n_ctx, n_params, ftype}.
//                 `/metrics` only exists with `--metrics`, otherwise HTTP 501.
//                 (live: local llama-server 0.4.1, Qwen2.5-0.5B-Q4_K_M)
//   LM Studio   : /api/v0/models [{id, arch, quantization, state, max_context_length}].
//                 ⚠ `/metrics` answers **HTTP 200 with an error JSON body** —
//                 `{"error":"Unexpected endpoint or method. (GET /metrics)"}`,
//                 so the status code proves nothing; the body must be validated.
//   Ollama      : /api/ps [{name, size, size_vram, expires_at}] — no counters at all.
//   Generic     : /v1/models (OpenAI-compatible) — model name + reachability only.
//
// The UI keys off `capabilities`, so a node backed by an engine without counters
// shows "no rate metrics" instead of an empty speed readout that looks broken.

public enum EngineKind: String, Sendable, CaseIterable {
    case vllm, sglang, llamaCpp = "llama.cpp", tensorFold = "TensorFold", tgi
    case ollama = "Ollama", lmStudio = "LM Studio"
    case openAICompatible = "OpenAI 兼容"

    public var label: String { rawValue }
}

public struct EngineCapabilities: Sendable, Equatable {
    public var hasTokenCounters = false
    public var hasRequestCounters = false
    public var hasSpeed = false
    public var hasModelDetail = false

    public init(
        hasTokenCounters: Bool = false,
        hasRequestCounters: Bool = false,
        hasSpeed: Bool = false,
        hasModelDetail: Bool = false
    ) {
        self.hasTokenCounters = hasTokenCounters
        self.hasRequestCounters = hasRequestCounters
        self.hasSpeed = hasSpeed
        self.hasModelDetail = hasModelDetail
    }
}

/// Where a probe's HTTP actually goes. Two implementations, so the same probe
/// logic serves both paths: straight over the network, or — when macOS blocks an
/// unsigned app from reaching a LAN/tailnet address — through the SSH channel we
/// already own, running `curl` on the box against its own loopback.
public protocol MetricsTransport: Sendable {
    func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int)
}

/// Internal reasons the collector short-circuits a probe. Never surfaced to the
/// person watching: they exist so a known-dead path is not retried every cycle.
public enum InferenceProbeError: Error {
    /// The direct transport is known not to work for this endpoint (a box-local
    /// port, or macOS Local Network permission): go straight to the SSH channel
    /// instead of burning another timeout first.
    case directKnownBlocked
}

public struct DirectTransport: MetricsTransport {
    private let session: URLSession

    public init(timeout: TimeInterval = 8) {
        self.session = HTTP.noProxySession(timeout: timeout)
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int) {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (data, status)
    }
}

public struct SshCurlTransport: MetricsTransport {
    public let user: String
    public let host: String

    public init(user: String, host: String) {
        self.user = user
        self.host = host
    }

    public func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int) {
        // The URL is only used for its path and port; the request itself runs on
        // the remote box against its own loopback.
        let path = url.path.isEmpty ? "/" : url.path
        let port = url.port ?? 80
        let script = """
        curl -s -m \(Int(timeout)) -o /tmp/.sw_probe.$$ -w '%{http_code}' http://127.0.0.1:\(port)\(path); \
        echo; cat /tmp/.sw_probe.$$ 2>/dev/null; rm -f /tmp/.sw_probe.$$
        """
        let output = try await SshRunner.run(user: user, host: host, script: script, timeout: timeout + 6)
        // First line is the status code, the rest is the body.
        guard let newline = output.firstIndex(of: "\n") else { return (Data(), -1) }
        let status = Int(output[..<newline].trimmingCharacters(in: .whitespaces)) ?? -1
        let body = String(output[output.index(after: newline)...])
        return (Data(body.utf8), status)
    }
}

public struct InferenceProbe: Sendable {
    private let transport: any MetricsTransport

    public init(transport: any MetricsTransport = DirectTransport()) {
        self.transport = transport
    }

    /// Probe one endpoint in an engine-agnostic order and return whatever the
    /// engine actually exposes. Never throws for "engine has no metrics" — that
    /// is a normal answer, reported through the sample's capabilities.
    ///
    /// The rate tracker stays with the caller: it is actor-isolated state, and
    /// Swift refuses to pass that as `inout` into an async call.
    public func probe(baseURL rawBase: String) async throws -> InferenceSample {
        guard let base = URL(string: rawBase.trimmingCharacters(in: .whitespaces)),
            base.scheme != nil, base.host != nil
        else {
            throw DashboardError.transport("推理端点 URL 不合法: \(rawBase)")
        }

        // Reachability first, with a short leash. Probing every candidate path on
        // a dead endpoint used to burn ~44 s (five 8-second timeouts) before
        // reporting anything, during which the UI believed nothing was configured.
        guard await reachable(base: base, path: "") else {
            throw DashboardError.transport("端点无响应: \(rawBase)")
        }

        // 1. Prometheus metrics — richest source when it exists.
        if let text = try await fetchMetrics(base: base),
            let snapshot = PrometheusParser.parse(text)
        {
            var sample = sample(from: snapshot, base: base)
            // Prefer the engine's own rate; a counter delta overrides it in the
            // collector when the engine has one.
            sample.decodeTPS = snapshot.nativeGenerationTPS
            sample.capabilities = .init(
                hasTokenCounters: true,
                hasRequestCounters: true,
                hasSpeed: snapshot.nativeGenerationTPS != nil || snapshot.generationTokens > 0,
                hasModelDetail: true
            )
            if sample.model == nil {
                sample.model = await modelName(base: base)
            }
            // TensorFold keeps its live state in /health, not in the counters.
            // Merged here so the sample can say "prefilling 4" instead of nothing.
            if sample.engine == EngineKind.tensorFold.label,
                let health = try await fetchJSON(base: base, path: "health")
            {
                Self.mergeTensorFoldHealth(health, into: &sample)
            }
            return sample
        }

        // 2. Ollama.
        if let ollama = try await fetchJSON(base: base, path: "api/ps"),
            let models = ollama["models"] as? [[String: Any]]
        {
            var sample = InferenceSample()
            sample.engine = EngineKind.ollama.label
            sample.endpoint = base.absoluteString
            if let first = models.first {
                sample.model = first["name"] as? String ?? first["model"] as? String
                if let vram = (first["size_vram"] as? NSNumber)?.doubleValue {
                    sample.vramBytes = UInt64(max(vram, 0))
                }
                // `/api/ps` carries the model facts too — quantisation and
                // parameter size, quoted as strings ("494.03M").
                if let details = first["details"] as? [String: Any] {
                    sample.quantization = details["quantization_level"] as? String
                    if let size = details["parameter_size"] as? String {
                        sample.parameterCount = Self.parseParameterSize(size)
                    }
                    sample.architecture = details["family"] as? String
                }
                sample.loadedModels = models.count
            } else {
                sample.loadedModels = 0
            }
            sample.capabilities = .init(hasModelDetail: true)
            return sample
        }

        // 3. LM Studio.
        if let lmstudio = try await fetchJSON(base: base, path: "api/v0/models"),
            let models = lmstudio["data"] as? [[String: Any]]
        {
            var sample = InferenceSample()
            sample.engine = EngineKind.lmStudio.label
            sample.endpoint = base.absoluteString
            let loaded = models.first { ($0["state"] as? String) == "loaded" }
            let chosen = loaded ?? models.first
            sample.model = chosen?["id"] as? String
            sample.quantization = chosen?["quantization"] as? String
            sample.architecture = chosen?["arch"] as? String
            sample.contextLength = (chosen?["max_context_length"] as? NSNumber)?.intValue
            sample.loadedModels = loaded == nil ? 0 : 1
            sample.capabilities = .init(hasModelDetail: true)
            return sample
        }

        // 4. Generic OpenAI-compatible model list (llama.cpp included: its
        //    /v1/models carries a `meta` block with real model facts).
        if let listed = try await fetchJSON(base: base, path: "v1/models") {
            let entries = (listed["data"] as? [[String: Any]]) ?? (listed["models"] as? [[String: Any]])
            guard let first = entries?.first else { throw DashboardError.malformedTelemetry }
            var sample = InferenceSample()
            sample.engine = (first["owned_by"] as? String) == "llamacpp" ? EngineKind.llamaCpp.label : EngineKind.openAICompatible.label
            sample.endpoint = base.absoluteString
            sample.model = first["id"] as? String ?? first["name"] as? String
            if let meta = first["meta"] as? [String: Any] {
                sample.contextLength = (meta["n_ctx"] as? NSNumber)?.intValue
                sample.quantization = meta["ftype"] as? String
                sample.parameterCount = (meta["n_params"] as? NSNumber)?.doubleValue
            }
            sample.capabilities = .init(hasModelDetail: true)
            return sample
        }

        // 5. Last resort: is anything alive there at all?
        for path in ["health", "props", ""] {
            if await reachable(base: base, path: path) {
                var sample = InferenceSample()
                sample.engine = EngineKind.openAICompatible.label
                sample.endpoint = base.absoluteString
                sample.capabilities = .init()
                return sample
            }
        }
        throw DashboardError.transport("端点无响应: \(rawBase)")
    }

    // MARK: - Transports

    /// Fetch `/metrics`, treating "HTTP 200 with an error body" as no metrics —
    /// LM Studio does exactly that, so the body is the only trustworthy signal.
    private func fetchMetrics(base: URL) async throws -> String? {
        guard let (data, status) = try? await transport.get(
            base.appending(path: "metrics"), timeout: 8
        ), status == 200
        else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard PrometheusParser.looksLikeMetrics(text) else { return nil }
        return text
    }

    private func fetchJSON(base: URL, path: String) async throws -> [String: Any]? {
        guard let (data, status) = try? await transport.get(base.appending(path: path), timeout: 8),
            status == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object
    }

    private func reachable(base: URL, path: String) async -> Bool {
        let url = path.isEmpty ? base : base.appending(path: path)
        // 3 s: enough for a local or tailnet box, short enough that a dead
        // endpoint is reported quickly instead of stalling the UI.
        guard let (_, status) = try? await transport.get(url, timeout: 3) else { return false }
        // Any HTTP answer counts as alive, including 404: vLLM answers 404 on `/`
        // while serving fine, and one engine's root path says nothing about
        // whether its own model endpoint exists. Only "no response at all"
        // (status <= 0) means dead.
        return status > 0
    }

    /// The model name when the metrics text has none (llama.cpp keeps it in
    /// /v1/models, not in the metric labels).
    private func modelName(base: URL) async -> String? {
        guard let object = (try? await fetchJSON(base: base, path: "v1/models")) ?? nil else {
            return nil
        }
        let entries = (object["data"] as? [[String: Any]]) ?? (object["models"] as? [[String: Any]])
        return entries?.first?["id"] as? String
    }

    /// "494.03M" / "7.6B" → parameters.
    static func parseParameterSize(_ text: String) -> Double? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard let last = trimmed.last, let value = Double(trimmed.dropLast()) else { return nil }
        switch last {
        case "B", "b": return value * 1_000_000_000
        case "M", "m": return value * 1_000_000
        case "K", "k": return value * 1_000
        default: return nil
        }
    }

    private func sample(from snapshot: PrometheusSnapshot, base: URL) -> InferenceSample {
        var sample = InferenceSample()
        sample.engine = snapshot.engine
        sample.endpoint = base.absoluteString
        sample.model = snapshot.modelNames.first
        sample.running = snapshot.activeRequests
        sample.waiting = snapshot.queuedRequests
        sample.promptTokens = snapshot.promptTokens
        sample.generationTokens = snapshot.generationTokens
        // The engine's own decode clock — the denominator that cannot be diluted
        // by idle time. Without this copy the field existed but was always nil,
        // and every rate fell back to the wall clock.
        sample.decodeSeconds = snapshot.decodeSeconds > 0 ? snapshot.decodeSeconds : nil
        sample.requestsProcessed = snapshot.processedRequests
        sample.kvUsagePct = snapshot.kvUsagePct
        sample.acceptancePct = snapshot.specAcceptance
        sample.engineFatal = snapshot.engineFatal
        sample.stalledRequests = snapshot.stalledRequests
        // Latency percentiles, when the engine exports histograms. Copied as-is
        // (nil stays nil) so the panel can tell "no data" from "zero latency".
        sample.ttftMeanSeconds = snapshot.ttftMeanSeconds
        sample.ttftP95Seconds = snapshot.ttftP95Seconds
        sample.e2eP95Seconds = snapshot.e2eP95Seconds
        sample.itlP95Seconds = snapshot.itlP95Seconds
        return sample
    }

    /// TensorFold splits its state in two: `/metrics` counts *finished* work, and
    /// `/health` says what is happening *now* (`streams.prefilling` / `decoding`).
    ///
    /// That split is the whole reason this merge exists. Through a decode-token
    /// counter alone, a box chewing a 300K-token prefill and a box sitting idle
    /// look identical — both report no tokens/s — and the first one is also the
    /// box at 96 % utilisation and 80 °C that reads as "nothing is wrong here".
    ///
    /// Live shape (spark-a, 2026-09-30):
    /// `{"ok":true,"busy":true,"inflight":4,"requests":111,"errors":0,
    ///   "prompt_tokens_total":6376989,"completion_tokens_total":37081,
    ///   "cached_tokens_total":5894016,"drafted_total":34531,
    ///   "accepted_total":25219,"streams":{"decoding":0,"prefilling":4,"max":4},
    ///   "context_length":1048576}`
    static func mergeTensorFoldHealth(_ health: [String: Any], into sample: inout InferenceSample) {
        // The counters MUST come from here, not from `/metrics`.
        //
        // Measured on the live deployment (2026-10-01): with two requests
        // decoding, `tensorfold_completion_tokens_total` sat frozen at 82549 for
        // 6+ s per scrape while `/health` reported 83333 → 83705 over the same
        // window. The engine republishes the Prometheus snapshot on its own slower
        // schedule, so a delta taken from it is zero most of the time — which is
        // exactly why the menu bar showed no speed at all while the box was
        // decoding at ~45 tok/s.
        if let completion = number(health["completion_tokens_total"]) {
            sample.generationTokens = completion
        }
        if let prompts = number(health["prompt_tokens_total"]) {
            sample.promptTokens = prompts
        }
        if let inflight = number(health["inflight"]) {
            sample.running = inflight
        } else if let running = number(health["requests_running"]) {
            sample.running = running
        }
        if let streams = health["streams"] as? [String: Any] {
            sample.decoding = number(streams["decoding"])
            sample.prefilling = number(streams["prefilling"])
        }
        if let total = number(health["requests_total"]) {
            sample.requestsProcessed = total
        }
        if let oldest = number(health["oldest_s"]) {
            sample.oldestSeconds = oldest
        }
        if let prefillSeconds = number(health["prefill_seconds_total"]) {
            sample.prefillSeconds = prefillSeconds
        }
        if let cached = number(health["cached_tokens_total"]) {
            sample.cachedTokens = cached
        }
        if let prompts = sample.promptTokens, prompts > 0, let cached = sample.cachedTokens {
            sample.cacheHitPct = min(cached / prompts * 100, 100)
        }
        if let accepted = number(health["accepted_total"]),
            let drafted = number(health["drafted_total"]), drafted > 0
        {
            sample.acceptancePct = accepted / drafted * 100
        }
        if let context = number(health["context_length"]) {
            sample.contextLength = Int(context)
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
