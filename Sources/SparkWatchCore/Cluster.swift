import Foundation

/// What a node is actually running, read from the process table rather than
/// guessed from a port.
///
/// Why this exists: a distributed deployment gives each node a different role.
/// In a vLLM tensor-parallel pair, rank 0 runs the API server and rank 1 runs
/// with `--headless` — it serves no HTTP at all. A per-node "probe this URL"
/// model cannot describe that: it will happily keep asking rank 1's stale port
/// (an old Ollama, long since idle on loopback) and report whatever it finds as
/// if it were the served model. Reading `--nnodes / --node-rank / --headless /
/// --master-addr` off the command line tells the truth instead.
public struct InferenceProcessInfo: Sendable, Equatable {
    /// "vllm" | "sglang" | "ollama" | "llama.cpp" | ""
    public var kind: String = ""
    /// Rank of the local worker as reported by the process title
    /// (`VLLM::Worker_TP3` -> 3), when the engine exposes one.
    public var workerRank: Int?
    public var servedModelName: String?
    /// Model snapshot path with the commit hash stripped — stable across the
    /// nodes of one deployment and identical for every node in the same task.
    public var modelKey: String?
    public var port: Int?
    /// `--headless`: this node participates but exposes no API.
    public var headless: Bool = false
    public var nodeRank: Int?
    public var nodeCount: Int?
    public var tensorParallel: Int?
    /// "host:port" rendezvous address, shared by every node of one deployment.
    public var masterAddr: String?
    public var quantization: String?
    public var maxModelLen: Int?
    /// Speculative-decoding draft model (`--drafter`). Worth surfacing: it is the
    /// difference between 20 and 50 tokens/s on the same weights, and nothing in
    /// the model name says whether it is on.
    public var drafter: String?

    public init() {}

    public var isDistributed: Bool { (nodeCount ?? 1) > 1 || (tensorParallel ?? 1) > 1 }
}

/// One inference deployment, possibly spread over several machines.
public struct ClusterTask: Sendable, Equatable, Identifiable {
    public var id: String
    public var model: String
    /// Node names, ordered by node rank.
    public var nodes: [String]
    /// node name -> node rank
    public var ranks: [String: Int]
    public var tensorParallel: Int
    public var nodeCount: Int
    /// The node that actually answers HTTP, and where.
    public var apiNode: String?
    public var apiURL: String?
    public var quantization: String?
    public var contextLength: Int?
    /// Speculative-decoding drafter, when the deployment uses one (TensorFold's
    /// `--drafter`). Shown as a chip: on the same weights it is a 2-3× difference.
    public var drafter: String?

    public var isParallel: Bool { nodes.count > 1 || tensorParallel > 1 }

    /// Explicit, because the implicit memberwise initialiser of a public struct
    /// is internal — the app and the tests need to build tasks (the demo fleet
    /// renders a synthetic deployment to verify multi-machine layouts).
    public init(
        id: String,
        model: String,
        nodes: [String],
        ranks: [String: Int],
        tensorParallel: Int,
        nodeCount: Int,
        apiNode: String?,
        apiURL: String?,
        quantization: String?,
        contextLength: Int?,
        drafter: String? = nil
    ) {
        self.id = id
        self.model = model
        self.nodes = nodes
        self.ranks = ranks
        self.tensorParallel = tensorParallel
        self.nodeCount = nodeCount
        self.apiNode = apiNode
        self.apiURL = apiURL
        self.quantization = quantization
        self.contextLength = contextLength
        self.drafter = drafter
    }

    /// "TP2 · 2 机" style summary.
    public var topologyLabel: String {
        var parts: [String] = []
        if tensorParallel > 1 { parts.append("TP\(tensorParallel)") }
        if nodes.count > 1 { parts.append("\(nodes.count) 机") }
        return parts.isEmpty ? "单机" : parts.joined(separator: " · ")
    }

    public func roleLabel(for node: String) -> String {
        let rank = ranks[node].map { "rank \($0)" } ?? "参与"
        if node == apiNode { return "\(rank) · API" }
        return "\(rank) · headless worker"
    }
}

public enum ClusterTaskBuilder {
    /// Groups per-node processes into deployments.
    ///
    /// Grouping key is the rendezvous address (`--master-addr:--master-port`):
    /// that is what makes two processes one task. Nodes without one are kept
    /// separate even when they serve the same model, because two independent
    /// replicas of one model are two tasks, not one.
    public static func build(
        nodes: [(name: String, host: String, processes: [InferenceProcessInfo])]
    ) -> [ClusterTask] {
        var groups: [String: [(node: String, host: String, info: InferenceProcessInfo)]] = [:]
        var order: [String] = []

        for node in nodes {
            for info in node.processes where info.kind != "ollama" {
                guard let master = info.masterAddr, !master.isEmpty else { continue }
                let key = "\(master)|\(info.modelKey ?? info.servedModelName ?? "?")"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append((node.name, node.host, info))
            }
        }

        return order.compactMap { key -> ClusterTask? in
            guard let members = groups[key], let first = members.first?.info else { return nil }
            let sorted = members.sorted { ($0.info.nodeRank ?? 0) < ($1.info.nodeRank ?? 0) }
            let api = sorted.first { !$0.info.headless && $0.info.port != nil }
            var ranks: [String: Int] = [:]
            for member in sorted where member.info.nodeRank != nil {
                ranks[member.node] = member.info.nodeRank
            }
            let model = first.servedModelName
                ?? first.modelKey.map { shortModelName($0) }
                ?? "未知模型"
            return ClusterTask(
                id: key,
                model: model,
                nodes: sorted.map { $0.node },
                ranks: ranks,
                tensorParallel: first.tensorParallel ?? 1,
                nodeCount: first.nodeCount ?? sorted.count,
                apiNode: api?.node,
                apiURL: api.flatMap { member in
                    member.info.port.map { "http://\(member.host):\($0)" }
                },
                quantization: first.quantization,
                contextLength: first.maxModelLen,
                drafter: first.drafter.map {
                    shortDrafter(shortModelName($0), model: model)
                }
            )
        }
    }

    /// "models--example-org--GLM-5.3-Flash-tr3-4bpw" -> "GLM-5.3-Flash-tr3-4bpw"
    public static func shortModelName(_ key: String) -> String {
        var name = key
        if let range = name.range(of: "/snapshots/") { name = String(name[..<range.lowerBound]) }
        // An absolute path ends in the repo directory, e.g.
        // ".../hub/models--example-org--GLM-5.3-Flash-tr3-4bpw"
        if let slash = name.lastIndex(of: "/") { name = String(name[name.index(after: slash)...]) }
        if name.hasPrefix("models--") { name = String(name.dropFirst("models--".count)) }
        // "org--repo" -> "repo"
        if let range = name.range(of: "--") { name = String(name[range.upperBound...]) }
        return name
    }

    /// The drafter chip should say *which* drafter, not repeat the model name:
    /// model "GLM-5.3-Flash-tr3-4bpw" + drafter "GLM-5.3-Flash-DFlash2" -> "DFlash2".
    ///
    /// Stripping the model's last path component is not enough ("GLM-5.3-Flash-tr3"
    /// is not a prefix of the drafter); the shared prefix is what has to go.
    public static func shortDrafter(_ drafter: String, model: String) -> String {
        let modelChars = Array(model)
        let drafterChars = Array(drafter)
        var shared = 0
        while shared < modelChars.count, shared < drafterChars.count,
            modelChars[shared] == drafterChars[shared]
        {
            shared += 1
        }
        // Too little in common means these are unrelated names; keep the whole
        // thing rather than amputating it.
        guard shared >= 4 else { return drafter }
        var rest = String(drafterChars[shared...])
        while rest.hasPrefix("-") { rest.removeFirst() }
        return rest.isEmpty ? drafter : rest
    }
}

/// Turns "what is listening" + "what is running" into the list of services a
/// user can choose from.
///
/// Both halves matter: a port alone cannot say whether it is vLLM or a leftover
/// Ollama, and a process alone cannot say which port it answers on. The join is
/// keyed on the ports the processes declare.
public enum InferenceCandidates {
    /// Ports that plausibly speak to an inference engine. Deliberately narrow:
    /// showing every listening socket as a "choice" is noise, and the point of
    /// this list is to make a decision easy.
    public static let knownPorts: Set<Int> = [
        11434, 1234, 8000, 8080, 8081, 8888, 18300, 30000, 5000, 9000,
    ]

    public static func build(
        listeners: [(bind: String, port: Int)],
        processes: [InferenceProcessInfo]
    ) -> [InferenceCandidate] {
        var byPort: [Int: InferenceCandidate] = [:]

        // 1. Ports the running processes declare — the strongest evidence.
        for info in processes where info.kind != "" && info.kind != "vllm-worker" {
            // A vLLM headless rank declares a --port it never serves on; skip it
            // so the picker does not offer a dead endpoint as a choice.
            guard let port = info.port, !(info.headless && info.kind == "vllm") else { continue }
            // TensorFold's own API binds loopback (its public face is a separate
            // auth proxy the deployment runs alongside), so the picker must not
            // claim it is reachable at the machine's address.
            let loopbackOnly = info.headless || info.kind == "tensorfold"
            byPort[port] = InferenceCandidate(
                port: port,
                engine: info.kind,
                model: info.servedModelName ?? info.modelKey.map { ClusterTaskBuilder.shortModelName($0) },
                bind: loopbackOnly ? "127.0.0.1" : "0.0.0.0",
                note: info.servedModelName == nil ? "进程 \(info.kind)" : "进程 \(info.kind)（\(info.servedModelName!)）"
            )
        }

        // 2. Listening sockets on ports we recognise as inference servers.
        for listener in listeners where knownPorts.contains(listener.port) {
            let port = listener.port
            if var existing = byPort[port] {
                existing.bind = listener.bind
                byPort[port] = existing
                continue
            }
            // Port 11434 is Ollama's default and the most common stale service on
            // a box that moved on to vLLM, so name it rather than calling it a
            // generic listener.
            let engine: String? = port == 11434 ? "ollama" : (port == 1234 ? "lmstudio" : nil)
            byPort[port] = InferenceCandidate(port: port, engine: engine, bind: listener.bind)
        }

        return byPort.values.sorted { $0.port < $1.port }
    }
}

public enum InferenceProcessParser {
    /// Parses the `##infer` section: one `ps -eo args` line per process.
    public static func parse(lines: [String]) -> [InferenceProcessInfo] {
        var results: [InferenceProcessInfo] = []
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }

            // Worker titles are their own line (`VLLM::Worker_TP1`); the launcher
            // command line is another. Both describe the same node, so merge by
            // keeping the richer record and folding the rank in.
            if let rank = workerRank(in: line) {
                if var existing = results.first(where: { $0.kind == "vllm" }) {
                    existing.workerRank = rank
                    if existing.nodeRank == nil { existing.nodeRank = rank }
                    if let index = results.firstIndex(where: { $0.kind == "vllm" }) {
                        results[index] = existing
                    }
                } else {
                    var info = InferenceProcessInfo()
                    info.kind = "vllm"
                    info.workerRank = rank
                    info.nodeRank = rank
                    results.append(info)
                }
                continue
            }

            if line.contains("vllm serve") || line.contains("/vllm ") {
                results.append(parseVllm(line))
            } else if line.contains("tensorfold serve") || line.contains("/tensorfold ") {
                results.append(parseTensorFold(line))
            } else if line.contains("sglang") {
                var info = InferenceProcessInfo()
                info.kind = "sglang"
                info.modelKey = value(of: "--model-path", in: line)
                info.port = intValue(of: "--port", in: line)
                info.tensorParallel = intValue(of: "--tp-size", in: line)
                    ?? intValue(of: "--tensor-parallel-size", in: line)
                info.masterAddr = rendezvous(in: line, flags: ["--dist-init-addr"])
                results.append(info)
            } else if line.contains("ollama serve") {
                var info = InferenceProcessInfo()
                info.kind = "ollama"
                results.append(info)
            } else if line.contains("llama-server") {
                var info = InferenceProcessInfo()
                info.kind = "llama.cpp"
                info.modelKey = value(of: "--model", in: line) ?? value(of: "-m", in: line)
                info.port = intValue(of: "--port", in: line)
                results.append(info)
            }
        }
        return results
    }

    static func workerRank(in line: String) -> Int? {
        guard let range = line.range(of: "Worker_TP") else { return nil }
        let digits = line[range.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }

    static func parseVllm(_ line: String) -> InferenceProcessInfo {
        var info = InferenceProcessInfo()
        info.kind = "vllm"
        info.headless = line.contains("--headless")
        info.servedModelName = value(of: "--served-model-name", in: line)
        info.nodeRank = intValue(of: "--node-rank", in: line)
        info.nodeCount = intValue(of: "--nnodes", in: line)
        info.tensorParallel = intValue(of: "--tensor-parallel-size", in: line)
        info.port = intValue(of: "--port", in: line)
        info.quantization = value(of: "--quantization", in: line)
        info.maxModelLen = intValue(of: "--max-model-len", in: line)
        info.masterAddr = rendezvous(in: line, flags: ["--master-addr"])
        // The positional argument after `serve` is the snapshot path.
        if let range = line.range(of: "serve ") {
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !tail.hasPrefix("--") {
                var path = String(tail.prefix { $0 != " " })
                // Drop the snapshot commit so the key stays stable when the
                // deployment is restarted onto a newer revision.
                if let snapshots = path.range(of: "/snapshots/") {
                    path = String(path[..<snapshots.lowerBound])
                }
                info.modelKey = path
            }
        }
        return info
    }

    /// TensorFold's own launcher. Its flags are their own dialect — nothing
    /// matches vLLM's names, so a vLLM-shaped parser reads this as "one process,
    /// no topology":
    ///
    ///   tensorfold serve <weights> --tp 2 --rank 1 --master 10.0.0.1 \
    ///       --master-port 29551 --no-update-check --drafter <draft model> \
    ///       --context 1048576 --name dgx-spark --max-tokens 32768
    ///
    ///   * `--tp` is the tensor-parallel width (vLLM: `--tensor-parallel-size`)
    ///   * `--rank` is the node rank (vLLM: `--node-rank`) — rank 0 owns the HTTP
    ///     endpoint, the others are workers
    ///   * `--master` + `--master-port` are the rendezvous (vLLM: `--master-addr`),
    ///     and that pair is what groups the boxes into one task
    ///   * `--context` is the context window (vLLM: `--max-model-len`)
    ///   * the weights directory is the first positional argument, and there is
    ///     no `--headless`: rank alone decides who serves
    ///
    /// `--name` is deliberately *not* used as the task's model name. It is the
    /// API alias clients ask for ("dgx-spark"), while the weights directory says
    /// what is actually loaded and which quantisation it is.
    static func parseTensorFold(_ line: String) -> InferenceProcessInfo {
        var info = InferenceProcessInfo()
        info.kind = "tensorfold"
        info.nodeRank = intValue(of: "--rank", in: line)
        info.tensorParallel = intValue(of: "--tp", in: line)
        info.masterAddr = rendezvous(in: line, flags: ["--master"])
        info.maxModelLen = intValue(of: "--context", in: line)
        info.drafter = value(of: "--drafter", in: line)
        // Rank 0 is the API rank; the rest run without an endpoint. (vLLM says so
        // with `--headless`; TensorFold says it with the rank.)
        let rank = info.nodeRank ?? 0
        info.headless = rank != 0
        // 18000 is TensorFold's own default (the documented auth proxy upstream is
        // 127.0.0.1:18000). Only the API rank answers there.
        if let explicit = intValue(of: "--port", in: line) ?? intValue(of: "--api-port", in: line) {
            info.port = explicit
        } else if rank == 0 {
            info.port = 18000
        }
        // The positional argument after `serve` is the weights directory.
        if let range = line.range(of: "serve ") {
            let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if !tail.hasPrefix("--") {
                var path = String(tail.prefix { $0 != " " })
                // Same rule as vLLM: drop the snapshot commit so the key survives
                // a restart onto a newer revision.
                if let snapshots = path.range(of: "/snapshots/") {
                    path = String(path[..<snapshots.lowerBound])
                }
                info.modelKey = path
            }
        }
        return info
    }

    /// `--master-addr HOST` (+ `--master-port PORT`) or `--dist-init-addr HOST:PORT`.
    static func rendezvous(in line: String, flags: [String]) -> String? {
        for flag in flags {
            guard let host = value(of: flag, in: line) else { continue }
            if host.contains(":") { return host }
            if let port = intValue(of: "--master-port", in: line) {
                return "\(host):\(port)"
            }
            return host
        }
        return nil
    }

    static func value(of flag: String, in line: String) -> String? {
        guard let range = line.range(of: "\(flag) ") else { return nil }
        let tail = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
        let value = tail.prefix { $0 != " " }
        return value.isEmpty ? nil : String(value)
    }

    static func intValue(of flag: String, in line: String) -> Int? {
        value(of: flag, in: line).flatMap { Int($0) }
    }
}
