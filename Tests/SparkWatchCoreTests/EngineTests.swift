import Foundation
import Testing

@testable import SparkWatchCore

// The payloads used here were captured from live servers (llama-server 0.4.1,
// LM Studio, spark-a vLLM) — not written from documentation. The adapter
// chain is exercised end to end through a fake transport, so no network is
// needed but the real response shapes are.

/// Serves canned responses by request path. A missing path answers like a dead
/// connection (status -1), which is what curl reports when nothing is listening.
struct FakeTransport: MetricsTransport {
    var responses: [String: (body: String, status: Int)]

    func get(_ url: URL, timeout: TimeInterval) async throws -> (body: Data, status: Int) {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let hit = responses[path] else { return (Data(), -1) }
        return (Data(hit.body.utf8), hit.status)
    }
}

@Suite("引擎适配：llama.cpp")
struct LlamaCppEngineTests {
    /// Real capture: `llama-server --metrics`, Qwen2.5-0.5B-Q4_K_M.
    static let metrics = """
    # HELP llamacpp:prompt_tokens_total Number of prompt tokens processed.
    llamacpp:prompt_tokens_total 128
    llamacpp:prompt_tokens_cached_total 64
    llamacpp:prompt_seconds_total 0.5
    llamacpp:tokens_predicted_total 96
    llamacpp:tokens_predicted_seconds_total 3.2
    llamacpp:n_decode_total 12
    llamacpp:n_tokens_max 4096
    llamacpp:spec_decode_num_draft_tokens_total 50
    llamacpp:spec_decode_num_accepted_tokens_total 35
    llamacpp:prompt_tokens_seconds 256.0
    llamacpp:predicted_tokens_seconds 30.0
    llamacpp:requests_processing 1
    llamacpp:requests_deferred 2
    llamacpp:n_busy_slots_per_decode 1
    """

    @Test func parsesLlamaCppFamilies() throws {
        let snapshot = try #require(PrometheusParser.parse(Self.metrics))
        #expect(snapshot.engine == "llama.cpp")
        // llama.cpp calls generation "tokens_predicted", not "generation_tokens".
        #expect(snapshot.generationTokens == 96)
        #expect(snapshot.promptTokens == 128)
        #expect(snapshot.activeRequests == 1)
        #expect(snapshot.queuedRequests == 2)
        #expect(snapshot.nativeGenerationTPS == 30.0)
        #expect(snapshot.specAcceptance == 70.0)
    }

    /// Without `--metrics` llama.cpp answers 501 — must not be mistaken for data.
    @Test func metricsDisabledIsNotData() {
        let body = #"{"error":{"code":501,"message":"This server does not support metrics endpoint. Start it with `--metrics`"}}"#
        #expect(PrometheusParser.looksLikeMetrics(body) == false)
    }

    /// LM Studio answers **HTTP 200** with an error body — the status code is a
    /// lie, so the body decides. This is why `looksLikeMetrics` exists.
    @Test func lmStudioErrorBodyIsNotMetrics() {
        let body = #"{"error":"Unexpected endpoint or method. (GET /metrics)"}"#
        #expect(PrometheusParser.looksLikeMetrics(body) == false)
    }

    @Test func vllmMetricsStillParse() throws {
        let text = "vllm:num_requests_running{model_name=\"m\"} 2\nvllm:generation_tokens_total{model_name=\"m\"} 100\nvllm:prompt_tokens_total{model_name=\"m\"} 10\n"
        let snapshot = try #require(PrometheusParser.parse(text))
        #expect(snapshot.engine == "vLLM")
        #expect(snapshot.activeRequests == 2)
    }
}

@Suite("引擎适配：探测链")
struct EngineProbeTests {
    @Test func detectsVllmMetrics() async throws {
        let transport = FakeTransport(responses: [
            "": ("ok", 200),
            "metrics": (
                "vllm:num_requests_running{model_name=\"qwen3.8-flash-next\"} 3\nvllm:generation_tokens_total{model_name=\"qwen3.8-flash-next\"} 500\nvllm:prompt_tokens_total{model_name=\"qwen3.8-flash-next\"} 900\nvllm:predicted_tokens_seconds 1\n",
                200
            )
        ])
        let sample = try await InferenceProbe(transport: transport).probe(baseURL: "http://box:18300")
        #expect(sample.engine == "vLLM")
        #expect(sample.model == "qwen3.8-flash-next")
        #expect(sample.running == 3)
        #expect(sample.capabilities.hasTokenCounters)
    }

    /// Ollama exposes no counters at all, so the sample must simply lack speed
    /// data instead of inventing zeros — the UI shows "该引擎无速率指标".
    @Test func ollamaHasNoCounters() async throws {
        let ps = #"{"models":[{"name":"qwen2.5:0.5b","model":"qwen2.5:0.5b","size":397000000,"size_vram":397000000,"details":{"family":"qwen2"}}]}"#
        let transport = FakeTransport(responses: [
            "": ("ok", 200),
            "metrics": (#"{"error":"not found"}"#, 404),
            "api/ps": (ps, 200),
        ])
        let sample = try await InferenceProbe(transport: transport).probe(baseURL: "http://box:11434")
        #expect(sample.engine == "Ollama")
        #expect(sample.model == "qwen2.5:0.5b")
        #expect(sample.vramBytes == 397_000_000)
        #expect(sample.loadedModels == 1)
        #expect(sample.generationTokens == nil)
        #expect(sample.capabilities.hasTokenCounters == false)
        #expect(sample.decodeTPS == nil)
    }

    @Test func detectsLmStudioModelState() async throws {
        let models = #"{"data":[{"id":"qwen3.5-2b-mlx","object":"model","type":"vlm","arch":"qwen3_5","compatibility_type":"mlx","quantization":"4bit","state":"loaded","max_context_length":262144}]}"#
        let transport = FakeTransport(responses: [
            "": ("ok", 200),
            // Exactly what LM Studio really answers for /metrics: 200 + error body.
            "metrics": (#"{"error":"Unexpected endpoint or method. (GET /metrics)"}"#, 200),
            "api/v0/models": (models, 200),
        ])
        let sample = try await InferenceProbe(transport: transport).probe(baseURL: "http://127.0.0.1:1234")
        #expect(sample.engine == "LM Studio")
        #expect(sample.model == "qwen3.5-2b-mlx")
        #expect(sample.quantization == "4bit")
        #expect(sample.architecture == "qwen3_5")
        #expect(sample.contextLength == 262144)
        #expect(sample.loadedModels == 1)
    }

    @Test func fallsBackToOpenAIModelList() async throws {
        // Real llama.cpp /v1/models shape, including the `meta` block.
        let body = #"{"object":"list","data":[{"id":"test-models/qwen2.5-0.5b-instruct-q4_k_m.gguf","owned_by":"llamacpp","meta":{"n_ctx":2048,"n_params":630167424,"ftype":"Q4_K - Medium"}}]}"#
        let transport = FakeTransport(responses: [
            "": ("ok", 200),
            "metrics": (#"{"error":{"code":501,"message":"no metrics"}}"#, 501),
            "v1/models": (body, 200),
        ])
        let sample = try await InferenceProbe(transport: transport).probe(baseURL: "http://127.0.0.1:18080")
        #expect(sample.engine == "llama.cpp")
        #expect(sample.model?.contains("qwen2.5-0.5b") == true)
        #expect(sample.contextLength == 2048)
        #expect(sample.quantization == "Q4_K - Medium")
        #expect(sample.parameterCount == 630_167_424)
    }

    @Test func deadEndpointThrows() async {
        let transport = FakeTransport(responses: [:])
        await #expect(throws: (any Error).self) {
            _ = try await InferenceProbe(transport: transport).probe(baseURL: "http://box:9999")
        }
    }

    @Test func malformedURLThrows() async {
        await #expect(throws: (any Error).self) {
            _ = try await InferenceProbe(transport: FakeTransport(responses: [:])).probe(baseURL: "not a url")
        }
    }
}


@Suite("端点自动发现")
struct DiscoveryTests {
    /// Real `ss -Htln` output from a DGX box (ports only, as the script prints).
    @Test func parsesListeningPortsAndSkipsInfrastructure() {
        let output = """
        22
        631
        11000
        11434
        18300
        41641
        53
        30000
        """
        let ports = Diagnostics.parseListeningPorts(output)
        #expect(ports == [11434, 18300, 30000])
    }

    @Test func adoptsTheMostConvincingEndpoint() {
        let hits = [
            Diagnostics.ScanHit(port: 8080, engine: "OpenAI 兼容", model: nil, note: "v1", confidence: 10),
            Diagnostics.ScanHit(port: 11434, engine: "Ollama", model: "qwen2.5:0.5b", note: "ps", confidence: 25),
        ]
        #expect(Diagnostics.chooseEndpoint(from: hits)?.port == 11434)
    }

    @Test func adoptsLoneWeakHitButNotAmbiguousOnes() {
        let lone = [Diagnostics.ScanHit(port: 9000, engine: "OpenAI 兼容", model: nil, note: "v1", confidence: 10)]
        #expect(Diagnostics.chooseEndpoint(from: lone)?.port == 9000)
        // Two weak candidates = ambiguous, do not guess.
        let ambiguous = lone + [Diagnostics.ScanHit(port: 9001, engine: "OpenAI 兼容", model: nil, note: "v1", confidence: 10)]
        #expect(Diagnostics.chooseEndpoint(from: ambiguous) == nil)
    }
}
