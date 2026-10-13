import Foundation

// The official DGX Dashboard speaks an undocumented internal API. Reverse
// engineered from `/opt/nvidia/dgx-dashboard-service/dashboard-service` (Go,
// not stripped) and its bundled Remix frontend, then verified end to end from
// this Mac against both boxes:
//
//   POST /api/login                     {"username","password"} -> {"token"}
//   GET  /api/v1/gpu_telemetry/stream   SSE, event `gpu_telemetry`, ~1 Hz
//   GET  /api/v1/hostname               -> {"hostname": "..."}
//   GET  /api/v1/telemetry              ⚠ anonymous-telemetry *consent* setting,
//                                        NOT system telemetry. Never a data source.
//
// Token is an RS256 JWT, 14 days of validity (measured: iat 2026-09-30 09:28:01
// -> exp 2026-10-14 09:28:01), sent as `Authorization: Bearer <jwt>`; 401 means
// re-login. The dashboard binds 127.0.0.1:11000 only, hence the per-node SSH
// forward (see Tunnel.swift).
//
// Login/session handling is adapted from AdrianBinDC/DGXPulse (MIT,
// © 2026 Adrian Bolinger): store the token, never the password.
// SSE framing is adapted from the same project (byte-level CR/LF handling plus
// an idle watchdog, because a tunnel can die without closing the stream).

public enum DashboardError: Error, Sendable {
    case unauthorized
    case http(Int, String)
    case malformedTelemetry
    case transport(String)

    public var message: String {
        switch self {
        case .unauthorized: "登录已过期，需要重新输入密码"
        case let .http(code, body): "HTTP \(code): \(body.prefix(80))"
        case .malformedTelemetry: "遥测数据格式不认识"
        case let .transport(text): text
        }
    }
}

public struct DashboardClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, timeout: TimeInterval = 12) {
        self.baseURL = baseURL
        self.session = HTTP.noProxySession(timeout: timeout)
    }

    // MARK: Auth

    public func login(username: String, password: String) async throws -> String {
        var request = URLRequest(url: baseURL.appending(path: "api/login"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: ["username": username, "password": password]
        )
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw DashboardError.transport("无 HTTP 响应")
        }
        guard http.statusCode == 200 else {
            throw DashboardError.http(
                http.statusCode,
                String(data: data, encoding: .utf8) ?? ""
            )
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = object["token"] as? String, !token.isEmpty
        else {
            throw DashboardError.http(200, "响应里没有 token")
        }
        return token
    }

    /// Dashboard identity check — used to tell "our tunnel is up" from
    /// "something else took that local port".
    public func isDashboard() async -> Bool {
        var request = URLRequest(url: baseURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 1.5
        guard let (data, response) = try? await send(request),
            let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode),
            let body = String(data: data, encoding: .utf8)
        else { return false }
        return body.localizedCaseInsensitiveContains("DGX Dashboard")
    }

    public func hostname(token: String) async -> String? {
        var request = URLRequest(url: baseURL.appending(path: "api/v1/hostname"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await send(request),
            let http = response as? HTTPURLResponse, http.statusCode == 200,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return object["hostname"] as? String
    }

    // MARK: Streaming

    public enum TelemetryEvent: Sendable {
        case connected
        case sample(GpuSample)
        case failure(DashboardError)
    }

    /// Long-lived GPU telemetry stream. The caller owns reconnection; an idle
    /// stream (no bytes for `idleTimeout`) is treated as a dead tunnel.
    public func telemetry(
        token: String,
        idleTimeout: Duration = .seconds(20)
    ) -> AsyncStream<TelemetryEvent> {
        AsyncStream { continuation in
            let task = Task {
                var request = URLRequest(
                    url: baseURL.appending(path: "api/v1/gpu_telemetry/stream")
                )
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                request.timeoutInterval = 60

                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard let http = response as? HTTPURLResponse else {
                        continuation.yield(.failure(.transport("无 HTTP 响应")))
                        continuation.finish()
                        return
                    }
                    if http.statusCode == 401 {
                        continuation.yield(.failure(.unauthorized))
                        continuation.finish()
                        return
                    }
                    guard http.statusCode == 200 else {
                        continuation.yield(.failure(.http(http.statusCode, "")))
                        continuation.finish()
                        return
                    }
                    continuation.yield(.connected)
                    try await Self.consume(bytes: bytes, idleTimeout: idleTimeout, continuation: continuation)
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.yield(.failure(.transport(String(describing: error))))
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func consume(
        bytes: URLSession.AsyncBytes,
        idleTimeout: Duration,
        continuation: AsyncStream<TelemetryEvent>.Continuation
    ) async throws {
        let limit = TimeInterval(idleTimeout.components.seconds)
        // Shared with the watchdog only; every other piece of parser state stays
        // local to the byte loop so nothing is mutated across tasks.
        let clock = ActivityClock()

        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                var eventName = ""
                var dataLines: [String] = []
                var line: [UInt8] = []
                var previousWasCR = false

                for try await byte in bytes {
                    try Task.checkCancellation()
                    clock.touch()

                    if byte == 0x0A || byte == 0x0D {
                        if byte == 0x0A, previousWasCR {
                            previousWasCR = false
                            continue
                        }
                        previousWasCR = (byte == 0x0D)
                        var text = String(decoding: line, as: UTF8.self)
                        if text.hasSuffix("\r") { text.removeLast() }
                        line.removeAll(keepingCapacity: true)
                        if text.isEmpty {
                            if !dataLines.isEmpty {
                                emit(eventName: eventName, data: dataLines, to: continuation)
                            }
                            eventName = ""
                            dataLines.removeAll(keepingCapacity: true)
                        } else if text.hasPrefix(":") {
                            // comment / keep-alive
                        } else if let separator = text.firstIndex(of: ":") {
                            let field = String(text[..<separator])
                            var value = String(text[text.index(after: separator)...])
                            if value.hasPrefix(" ") { value.removeFirst() }
                            switch field {
                            case "event": eventName = value
                            case "data": dataLines.append(value)
                            default: break
                            }
                        }
                    } else {
                        previousWasCR = false
                        line.append(byte)
                    }
                }
            }
            group.addTask {
                while !Task.isCancelled {
                    try await Task.sleep(for: .seconds(3))
                    if clock.idleSeconds() > limit {
                        throw DashboardError.transport("遥测流静默超过 \(Int(limit))s（隧道可能已死）")
                    }
                }
            }
            _ = try await group.next()
            group.cancelAll()
        }
    }

    private static func emit(
        eventName: String,
        data: [String],
        to continuation: AsyncStream<TelemetryEvent>.Continuation
    ) {
        switch eventName {
        case "gpu_telemetry", "":
            if let sample = TelemetryParser.parseGpu(data.joined(separator: "\n")) {
                continuation.yield(.sample(sample))
            } else {
                continuation.yield(.failure(.malformedTelemetry))
            }
        case "error":
            continuation.yield(.failure(.transport("服务端 error 事件: \(data.joined().prefix(120))")))
        default:
            break
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw DashboardError.transport(String(describing: error))
        }
    }
}

// MARK: - Telemetry parsing (the unit trap)

public enum TelemetryParser {
    /// Parse one `gpu_telemetry` frame.
    ///
    /// The field names are unit-dependent *per host*, verified on two machines
    /// running the byte-identical binary
    /// (`md5 292142e5b76cc2a649df55c47cdb143b`):
    ///
    ///   spark-a -> "memory_total_in_kib":127598548
    ///   spark-b -> "memory_total_in_mb":130661
    ///
    /// Both describe 130,660,913,152 bytes. Every upstream app we reviewed only
    /// understands `_in_mb`, so they show nothing for memory on the box that
    /// streams KiB. Accept both; hide the row when neither is present rather
    /// than rendering a fake zero.
    public static func parseGpu(_ json: String) -> GpuSample? {
        guard let data = json.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let gpus = root["TelemetryForGPUs"] as? [[String: Any]],
            let first = gpus.first
        else { return nil }

        func number(_ key: String) -> Double? { (first[key] as? NSNumber)?.doubleValue }
        // `_in_kib` is true KiB (x1024); `_in_mb` is decimal MB (x1e6). Both
        // equal the byte count `free -b` prints on the same box.
        func bytes(kib: String, mb: String) -> UInt64? {
            if let value = (first[kib] as? NSNumber)?.uint64Value { return value * 1024 }
            if let value = (first[mb] as? NSNumber)?.uint64Value { return value * 1_000_000 }
            return nil
        }

        let total = bytes(kib: "memory_total_in_kib", mb: "memory_total_in_mb")
        let available = bytes(kib: "memory_available_in_kib", mb: "memory_available_in_mb")
        let used: UInt64? = {
            guard let total, let available, available <= total else { return nil }
            return total - available
        }()

        return GpuSample(
            utilPct: number("percentage_utilization"),
            tempC: number("temperature_in_c"),
            powerW: number("power_draw_in_w"),
            memTotalBytes: total,
            memUsedBytes: used
        )
    }

    /// JWT expiry (`exp` of the payload segment, base64url).
    public static func jwtExpiry(_ token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2,
            let data = base64URLDecode(String(parts[1])),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = (object["exp"] as? NSNumber)?.doubleValue
        else { return nil }
        return Date(timeIntervalSince1970: exp)
    }

    static func base64URLDecode(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value.append("=") }
        return Data(base64Encoded: value)
    }
}

// MARK: - Shared session bits

/// Lock-protected last-activity stamp; the only state shared between the SSE
/// byte loop and its watchdog.
final class ActivityClock: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()

    func touch() {
        lock.lock()
        last = Date()
        lock.unlock()
    }

    func idleSeconds() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(last)
    }
}

public enum HTTP {
    /// System proxies are the classic silent killer here: FlClash routes
    /// `100.x` tailnet addresses into the proxy while the CLI tools (which
    /// honour NO_PROXY) keep working, so requests fail in the app while `curl`
    /// succeeds. Always talk to the boxes with proxies off.
    public static func noProxySession(timeout: TimeInterval) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            "HTTPEnable": false,
            "HTTPSEnable": false,
            "ProxyAutoConfigEnable": false,
            "SOCKSEnable": false,
        ]
        configuration.timeoutIntervalForRequest = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}
