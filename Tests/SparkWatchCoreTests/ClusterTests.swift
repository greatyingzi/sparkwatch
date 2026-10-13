import Foundation
import Testing
@testable import SparkWatchCore

/// Real command lines, copied verbatim from `ps -eo args` on the two boxes.
/// They run one distributed vLLM deployment: `--nnodes 2 --tensor-parallel-size
/// 2`, rank 0 serving the API and rank 1 running `--headless`.
private let rank0Line = "/usr/bin/python3 /usr/local/bin/vllm serve /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-tr3-4bpw/snapshots/a5fee929cf4888b1824323e33e8a19b60129e025 --served-model-name GLM-5.3-Flash-EXL3 --host 0.0.0.0 --port 8888 --tensor-parallel-size 2 --nnodes 2 --node-rank 0 --master-addr 10.0.0.1 --master-port 29521 --distributed-executor-backend mp --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 --enable-prefix-caching --no-enable-flashinfer-autotune --quantization exl3 --max-model-len 850000 --gpu-memory-utilization 0.85 --max-num-seqs 4 --max-num-batched-tokens 7168"

private let rank1Line = "/usr/bin/python3 /usr/local/bin/vllm serve /root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-tr3-4bpw/snapshots/a5fee929cf4888b1824323e33e8a19b60129e025 --served-model-name GLM-5.3-Flash-EXL3 --host 0.0.0.0 --port 8888 --tensor-parallel-size 2 --nnodes 2 --node-rank 1 --master-addr 10.0.0.1 --master-port 29521 --distributed-executor-backend mp --headless --tool-call-parser glm47 --enable-auto-tool-choice --reasoning-parser glm45 --enable-prefix-caching --no-enable-flashinfer-autotune --quantization exl3 --max-model-len 850000 --gpu-memory-utilization 0.85 --max-num-seqs 4"

@Suite("跨机并行任务识别")
struct ClusterTests {
    @Test func parsesTheApiRank() {
        let infos = InferenceProcessParser.parse(lines: [rank0Line, "VLLM::EngineCore", "VLLM::Worker_TP0"])
        #expect(infos.count == 1)
        let info = infos[0]
        #expect(info.kind == "vllm")
        #expect(info.headless == false)
        #expect(info.nodeRank == 0)
        #expect(info.workerRank == 0)
        #expect(info.nodeCount == 2)
        #expect(info.tensorParallel == 2)
        #expect(info.port == 8888)
        #expect(info.masterAddr == "10.0.0.1:29521")
        #expect(info.servedModelName == "GLM-5.3-Flash-EXL3")
        #expect(info.quantization == "exl3")
        #expect(info.maxModelLen == 850_000)
        #expect(info.modelKey?.hasSuffix("/models--example-org--GLM-5.3-Flash-tr3-4bpw") == true)
        #expect(info.isDistributed)
    }

    @Test func parsesTheHeadlessWorker() {
        let infos = InferenceProcessParser.parse(lines: [rank1Line, "VLLM::Worker_TP1", "ollama serve"])
        let vllm = infos.first { $0.kind == "vllm" }
        #expect(vllm?.headless == true)
        #expect(vllm?.nodeRank == 1)
        #expect(vllm?.workerRank == 1)
        #expect(vllm?.servedModelName == "GLM-5.3-Flash-EXL3")
        // An idle Ollama is reported but never mistaken for the served model.
        #expect(infos.contains { $0.kind == "ollama" })
    }

    /// The whole point: two boxes, one task, and the right node owns the API.
    @Test func groupsTheTwoNodesIntoOneParallelTask() {
        let nodes: [(name: String, host: String, processes: [InferenceProcessInfo])] = [
            ("spark-00", "spark-a", InferenceProcessParser.parse(lines: [rank0Line, "VLLM::Worker_TP0"])),
            ("spark-01", "spark-b", InferenceProcessParser.parse(lines: [rank1Line, "VLLM::Worker_TP1", "ollama serve"])),
        ]
        let tasks = ClusterTaskBuilder.build(nodes: nodes)
        #expect(tasks.count == 1)
        let task = tasks[0]
        #expect(task.model == "GLM-5.3-Flash-EXL3")
        #expect(task.nodes == ["spark-00", "spark-01"])
        #expect(task.ranks["spark-00"] == 0)
        #expect(task.ranks["spark-01"] == 1)
        #expect(task.tensorParallel == 2)
        #expect(task.nodeCount == 2)
        #expect(task.isParallel)
        #expect(task.topologyLabel == "TP2 · 2 机")
        // Only rank 0 answers HTTP, and the URL comes from its own --port.
        #expect(task.apiNode == "spark-00")
        #expect(task.apiURL == "http://spark-a:8888")
        #expect(task.roleLabel(for: "spark-00") == "rank 0 · API")
        #expect(task.roleLabel(for: "spark-01") == "rank 1 · headless worker")
        #expect(task.quantization == "exl3")
        #expect(task.contextLength == 850_000)
    }

    /// Two independent single-box servers of the same model are two tasks, not
    /// one: without a rendezvous address there is nothing tying them together.
    @Test func independentReplicasAreNotOneTask() {
        let solo = rank0Line
            .replacingOccurrences(of: "--nnodes 2", with: "")
            .replacingOccurrences(of: "--node-rank 0", with: "")
            .replacingOccurrences(of: "--master-addr 10.0.0.1", with: "")
            .replacingOccurrences(of: "--master-port 29521", with: "")
        let processes = InferenceProcessParser.parse(lines: [solo])
        let tasks = ClusterTaskBuilder.build(nodes: [
            ("a", "host-a", processes),
            ("b", "host-b", processes),
        ])
        #expect(tasks.isEmpty)
    }

    @Test func shortensSnapshotNames() {
        #expect(
            ClusterTaskBuilder.shortModelName(
                "/root/.cache/huggingface/hub/models--example-org--GLM-5.3-Flash-tr3-4bpw/snapshots/a5fee929"
            ) == "GLM-5.3-Flash-tr3-4bpw"
        )
    }
}

@Suite("推理服务候选（用户可选）")
struct InferenceCandidateTests {
    /// The live case: one real vLLM on :8888 and a stale Ollama on :11434 that
    /// only answers on loopback. Both are offered, named, so the user can tell
    /// them apart instead of the app guessing.
    @Test func offersBothTheRealServiceAndTheStaleLeftover() {
        let processes = InferenceProcessParser.parse(lines: [rank0Line, "VLLM::Worker_TP0"])
        let listeners: [(bind: String, port: Int)] = [
            ("0.0.0.0", 8888),
            ("127.0.0.1", 11434),
            ("0.0.0.0", 22),
        ]
        let candidates = InferenceCandidates.build(listeners: listeners, processes: processes)
        #expect(candidates.count == 2)
        #expect(candidates[0].port == 8888)
        #expect(candidates[0].engine == "vllm")
        #expect(candidates[0].model == "GLM-5.3-Flash-EXL3")
        #expect(candidates[0].isLoopbackOnly == false)
        #expect(candidates[1].port == 11434)
        #expect(candidates[1].engine == "ollama")
        #expect(candidates[1].isLoopbackOnly)
        // Port 22 is not an inference service and must not clutter the choice.
        #expect(!candidates.contains { $0.port == 22 })
    }

    /// A headless TP rank passes a `--port` it never serves on. Offering that as
    /// a selectable endpoint would hand the user a dead option.
    @Test func doesNotOfferADeadWorkerPort() {
        let processes = InferenceProcessParser.parse(lines: [rank1Line, "VLLM::Worker_TP1"])
        // The rank declares --port 8888 but serves nothing on it; the machine's
        // only listener is ssh. Nothing to offer is the correct answer.
        let candidates = InferenceCandidates.build(
            listeners: [("0.0.0.0", 22)],
            processes: processes
        )
        #expect(candidates.isEmpty)
    }

    /// A listener on a known port with no process to explain it is still worth
    /// offering: that is what a service started by docker (or one whose process
    /// line moved) looks like.
    @Test func offersAnUnexplainedKnownPort() {
        let candidates = InferenceCandidates.build(
            listeners: [("0.0.0.0", 8000)],
            processes: []
        )
        #expect(candidates.count == 1)
        #expect(candidates[0].port == 8000)
        #expect(candidates[0].engine == nil)
        #expect(candidates[0].note == "监听端口")
    }

    @Test func labelsCandidatesForThePicker() {
        let candidate = InferenceCandidate(
            port: 11434, engine: "ollama", model: nil, bind: "127.0.0.1"
        )
        #expect(candidate.label == ":11434 · ollama · 仅本机")
        // Loopback-only: only the box itself can reach it.
        #expect(candidate.url(forHost: "spark-b") == "http://127.0.0.1:11434")
        // Bound to 0.0.0.0: address the machine, so it works over LAN/tailnet.
        let open = InferenceCandidate(port: 8888, engine: "vllm", bind: "0.0.0.0")
        #expect(open.url(forHost: "spark-a") == "http://spark-a:8888")
    }

    /// The source choice round-trips through JSON, and an older config without
    /// the field still decodes (defaulting to auto).
    @Test func inferenceSourceSurvivesConfigRoundTrip() throws {
        var settings = AppSettings()
        settings.nodes = [NodeConfig(name: "a", sshHost: "h", dashboardLocalPort: 19100)]
        settings.nodes[0].inferenceSource = .pinned("http://127.0.0.1:8888")
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        #expect(decoded.nodes[0].inferenceSource == .pinned("http://127.0.0.1:8888"))

        let legacy = #"{"nodes":[{"name":"x","sshHost":"h","dashboardLocalPort":19100}]}"#
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(legacy.utf8))
        #expect(old.nodes[0].inferenceSource == .auto)
    }

    /// The leftover Ollama on rank 1 is a real service, but it is not what the
    /// box serves. Its discovery note and its capability profile must not survive
    /// the moment the topology identifies the box as a headless rank: that is
    /// what made the detail card read "GLM-5.3-Flash-EXL3 · rank 1 · headless
    /// worker" on one line and "自动选中 :11434 Ollama · qwen2.5:0.5b" on the next.
    @Test func headlessRankDoesNotLeakTheLeftoverEnginesNote() async {
        let runtime = NodeRuntime(config: NodeConfig(
            name: "spark-01", sshHost: "spark-b", autoDiscover: true
        ))
        // The auto-discovery pass adopts the leftover engine on loopback.
        await runtime.setInferenceEndpoint(
            "http://127.0.0.1:11434",
            note: "未配置端点，自动发现 → 自动选中 :11434 ollama · qwen2.5:0.5b"
        )
        #expect(await runtime.snapshot().inferenceNote != nil)

        // Then the topology lands: this box is rank 1 of a two-node TP pair.
        await runtime.setSuppressInferenceProbe(true)
        await runtime.adoptTaskModel("GLM-5.3-Flash-EXL3", role: "rank 1 · headless worker")

        let snapshot = await runtime.snapshot()
        #expect(snapshot.inferenceNote == nil)
        #expect(snapshot.inference?.model == "GLM-5.3-Flash-EXL3")
        #expect(snapshot.inference?.taskRole == "rank 1 · headless worker")
        #expect(snapshot.inference?.engine == "cluster")
        // A rank with no endpoint has no in-flight requests to report; claiming
        // one turns into a phantom "×1" in the menu bar.
        #expect(snapshot.inference?.running == nil)
        // Nothing may be inherited from the suppressed probe: those fields
        // describe the stranger, not this deployment.
        #expect(snapshot.inference?.capabilities.hasTokenCounters == false)
        #expect(snapshot.inference?.capabilities.hasRequestCounters == false)
        #expect(snapshot.inference?.capabilities.hasSpeed == false)
        #expect(snapshot.inference?.vramBytes == nil)
        #expect(snapshot.inference?.generationTokens == nil)
    }
}
