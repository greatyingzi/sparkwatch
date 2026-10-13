import Foundation

/// Onboarding helpers: find the inference endpoint for us, and verify a node
/// before the user commits to it. Both exist so configuring a new machine does
/// not require knowing which port its engine happens to listen on.
public enum Diagnostics {
    public struct ScanHit: Sendable, Equatable {
        public var port: Int
        public var engine: String?
        public var model: String?
        public var note: String
        /// How much this looks like a real inference endpoint: 30 = engine-specific
        /// metrics, 25 = engine-native model API, 20 = generic Prometheus, 10 = bare
        /// OpenAI model list. Used to auto-pick one endpoint without asking.
        public var confidence: Int = 0

        public var url: String { "http://127.0.0.1:\(port)" }

        public func url(forHost host: String) -> String { "http://\(host):\(port)" }
    }

    public struct CheckResult: Sendable, Equatable {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    /// Ports commonly used by local inference servers — used as a fallback when
    /// the box cannot enumerate its own listeners.
    public static let candidatePorts = [8000, 18300, 8080, 30000, 11434, 1234, 5000, 8081, 9000]

    /// Ports that are never an inference server, so probing them is just noise:
    /// ssh / dns / nfs / cups / https / the DGX Dashboard / Tailscale.
    static let ignoredPorts: Set<Int> = [22, 53, 111, 631, 443, 80, 11000, 41641]

    /// Enumerate the box's own listening TCP ports. This is what makes the scan
    /// automatic: the fixed list above only catches engines on their default
    /// port, while a real box docks vLLM on 18300, SGLang on 30000, Ollama on
    /// 11434 — or on whatever port its container felt like mapping.
    public static func listeningPorts(user: String, host: String) async -> [Int] {
        let script = """
        (ss -Htln 2>/dev/null || netstat -tln 2>/dev/null) | awk '{print $4}' | sed 's/.*://'
        """
        guard let output = try? await SshRunner.run(user: user, host: host, script: script, timeout: 20)
        else { return [] }
        return parseListeningPorts(output)
    }

    /// `ss -Htln | awk '{print $4}' | sed 's/.*://'` output → candidate ports.
    /// Kept pure so it can be tested against real capture.
    static func parseListeningPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            guard let port = Int(line.trimmingCharacters(in: .whitespaces)) else { continue }
            guard port >= 1024, port <= 65535, !ignoredPorts.contains(port) else { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    /// Which discovered port, if any, is worth adopting automatically.
    /// An engine-specific endpoint is convincing on its own; with several
    /// candidates only a strong one wins; a lone weak hit is still taken (a bare
    /// OpenAI-compatible server is all some boxes expose).
    public static func chooseEndpoint(from hits: [ScanHit]) -> ScanHit? {
        if let strong = hits.filter({ $0.confidence >= 20 }).first { return strong }
        return hits.count == 1 ? hits.first : nil
    }

    /// Probe one box for inference servers: enumerate its listeners, then check
    /// each in a single SSH round trip. Returns hits ordered by confidence
    /// (a real metrics endpoint beats a bare model list).
    public static func discoverInferenceEndpoints(
        user: String,
        host: String,
        extraPorts: [Int] = []
    ) async -> [ScanHit] {
        let discovered = await listeningPorts(user: user, host: host)
        let ports = Array(Set(discovered + extraPorts + candidatePorts).filter {
            !ignoredPorts.contains($0)
        }).sorted()
        guard !ports.isEmpty else { return [] }
        // Bound the work: a busy box can listen on dozens of ports, and each
        // probe costs a localhost curl.
        let probe = Array(ports.prefix(60))
        let hits = await probePorts(user: user, host: host, ports: probe)
        return hits.sorted { lhs, rhs in
            if lhs.confidence != rhs.confidence { return lhs.confidence > rhs.confidence }
            return lhs.port < rhs.port
        }
    }

    /// Ask the box itself which local ports answer like an inference server.
    /// Runs over SSH so it works without any inbound reachability.
    public static func scanInferencePorts(
        user: String,
        host: String,
        ports: [Int] = candidatePorts
    ) async -> [ScanHit] {
        await probePorts(user: user, host: host, ports: ports)
    }

    private static func probePorts(user: String, host: String, ports: [Int]) async -> [ScanHit] {
        guard !ports.isEmpty else { return [] }
        // All ports in ONE ssh call: 60 separate round trips over a tailnet would
        // take longer than the scan is worth.
        let probes = ports.map { port in
            """
            code=$(curl -s -m 1 -o /tmp/.sw_scan.$$ -w '%{http_code}' http://127.0.0.1:\(port)/metrics)
            if [ "$code" = "200" ]; then echo "\(port)|metrics|$(head -c 200 /tmp/.sw_scan.$$ | tr -d '\\n')"; fi
            code=$(curl -s -m 1 -o /tmp/.sw_scan.$$ -w '%{http_code}' http://127.0.0.1:\(port)/api/ps)
            if [ "$code" = "200" ]; then echo "\(port)|ps|$(head -c 300 /tmp/.sw_scan.$$ | tr -d '\\n')"; fi
            code=$(curl -s -m 1 -o /tmp/.sw_scan.$$ -w '%{http_code}' http://127.0.0.1:\(port)/api/v0/models)
            if [ "$code" = "200" ]; then echo "\(port)|lmstudio|$(head -c 300 /tmp/.sw_scan.$$ | tr -d '\\n')"; fi
            code=$(curl -s -m 1 -o /tmp/.sw_scan.$$ -w '%{http_code}' http://127.0.0.1:\(port)/v1/models)
            if [ "$code" = "200" ]; then echo "\(port)|v1|$(head -c 300 /tmp/.sw_scan.$$ | tr -d '\\n')"; fi
            rm -f /tmp/.sw_scan.$$
            """
        }.joined(separator: "\n")
        let script = probes

        guard let output = try? await SshRunner.run(user: user, host: host, script: script, timeout: 60)
        else { return [] }

        var hits: [Int: ScanHit] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count >= 3, let port = Int(parts[0]) else { continue }
            let kind = String(parts[1])
            let body = String(parts[2])
            var hit = hits[port] ?? ScanHit(port: port, engine: nil, model: nil, note: "", confidence: 0)
            hit.note += hit.note.isEmpty ? kind : ",\(kind)"
            switch kind {
            case "metrics":
                // Only real Prometheus text counts; a JSON error body on 200 does
                // not (LM Studio answers exactly that).
                if body.contains("vllm:") { hit.engine = "vLLM"; hit.confidence = 30 }
                else if body.contains("sglang:") { hit.engine = "SGLang"; hit.confidence = 30 }
                else if body.contains("llamacpp:") { hit.engine = "llama.cpp"; hit.confidence = 30 }
                else if body.contains("tgi_") { hit.engine = "TGI"; hit.confidence = 30 }
                else if PrometheusParser.looksLikeMetrics(body) { hit.engine = "Prometheus"; hit.confidence = 20 }
            case "ps":
                if body.contains("\"models\"") { hit.engine = "Ollama"; hit.confidence = 25 }
            case "lmstudio":
                if body.contains("\"data\"") { hit.engine = "LM Studio"; hit.confidence = 25 }
            case "v1":
                if body.contains("\"owned_by\":\"llamacpp\"") { hit.engine = "llama.cpp" }
                if hit.engine == nil { hit.engine = "OpenAI 兼容" }
                hit.confidence = max(hit.confidence, 10)
                if let idRange = body.range(of: "\"id\":\"") {
                    let rest = body[idRange.upperBound...]
                    hit.model = String(rest.prefix { $0 != "\"" })
                }
            default:
                break
            }
            hits[port] = hit
        }
        return hits.values.sorted { $0.port < $1.port }
    }

    /// Verify a node end to end: SSH reachable, dashboard reachable + login, and
    /// (if configured) the inference endpoint understood.
    public static func checkNode(
        _ node: NodeConfig,
        password: String?
    ) async -> [CheckResult] {
        var results: [CheckResult] = []

        // 1. SSH
        do {
            let hostname = try await SshRunner.run(
                user: node.sshUser, host: node.sshHost, script: "hostname", timeout: 12
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            results.append(.init(name: "SSH", ok: true, detail: "可达（\(hostname)）"))
        } catch {
            results.append(.init(name: "SSH", ok: false, detail: String(describing: error).prefix(120).description))
            return results
        }

        // 2. Dashboard channel (tunnel + login)
        if let password, !password.isEmpty {
            let tunnel = SshTunnel(
                host: node.sshHost, user: node.sshUser, localPort: node.dashboardLocalPort
            )
            defer { tunnel.stop() }
            try? tunnel.start()
            let client = DashboardClient(
                baseURL: URL(string: "http://127.0.0.1:\(node.dashboardLocalPort)")!
            )
            var ready = false
            for _ in 0..<15 {
                if await client.isDashboard() { ready = true; break }
                try? await Task.sleep(for: .milliseconds(400))
            }
            if !ready {
                results.append(.init(name: "DGX Dashboard", ok: false,
                                     detail: "端口 \(node.dashboardLocalPort) 未转发到面板（该机可能没装 DGX OS）"))
            } else {
                do {
                    let token = try await client.login(username: node.sshUser, password: password)
                    let expiry = TelemetryParser.jwtExpiry(token)
                    let days = expiry.map { String(format: "%.1f 天", $0.timeIntervalSinceNow / 86400) } ?? "未知"
                    results.append(.init(name: "DGX Dashboard", ok: true, detail: "登录成功（令牌剩 \(days)）"))
                } catch {
                    results.append(.init(name: "DGX Dashboard", ok: false,
                                         detail: (error as? DashboardError)?.message ?? String(describing: error)))
                }
            }
        } else {
            results.append(.init(name: "DGX Dashboard", ok: true, detail: "跳过（未提供密码；硬件将走 SSH 通道）"))
        }

        // 3. Inference endpoint
        if let url = node.inferenceMetricsURL, !url.isEmpty {
            do {
                let sample = try await InferenceProbe().probe(baseURL: url)
                let engine = sample.engine ?? "未知引擎"
                var detail = engine
                if let model = sample.model { detail += " · \(model)" }
                if let ctx = sample.contextLength { detail += " · \(ctx) ctx" }
                if !sample.capabilities.hasSpeed { detail += " · 该引擎无速率指标" }
                results.append(.init(name: "推理端点", ok: true, detail: detail))
            } catch {
                results.append(.init(name: "推理端点", ok: false,
                                     detail: String(describing: error).prefix(140).description))
            }
        } else {
            results.append(.init(name: "推理端点", ok: true, detail: "未配置（可点“扫描”自动发现）"))
        }
        return results
    }
}
