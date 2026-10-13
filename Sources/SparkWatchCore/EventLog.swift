import Foundation

/// 一条给人看的监控事件。
///
/// `kind` 是机器用的稳定枚举（"node.offline" / "gpu.throttle" / "bench.decode" …），
/// `message` 是给人看的完整句子——两者分开，UI 才能既按 kind 去重/着色，又原样
/// 显示一句不需要拼装的说明。
public struct WatchEvent: Sendable, Identifiable, Codable, Equatable {
    public enum Severity: String, Codable, Sendable {
        case info, success, warn, error
    }

    public var id: UUID
    public var at: Date
    public var severity: Severity
    public var kind: String
    public var nodeID: UUID?
    public var nodeName: String?
    public var message: String

    public init(
        id: UUID = UUID(),
        at: Date,
        severity: Severity,
        kind: String,
        nodeID: UUID?,
        nodeName: String?,
        message: String
    ) {
        self.id = id
        self.at = at
        self.severity = severity
        self.kind = kind
        self.nodeID = nodeID
        self.nodeName = nodeName
        self.message = message
    }
}

/// 事件环形日志，带去重窗口。
///
/// 为什么要去重：多数事件来自 2 s 一轮的采集循环，一次网络抖动会让「节点离线」
/// 在几秒内被重复判定十几次。不去重的话，日志会被同一条消息刷屏，真正的新事件
/// 被冲掉。
///
/// 去重窗口只从「上一条被真正记下的」事件起算，而不是从「上一条到来的」起算：
/// 否则一条每 3 s 复现一次的持续告警在 5 s 窗口下会被永远吃掉，第一次之后再无记录。
public struct EventLog: Sendable, Codable {
    private struct DedupeKey: Codable, Hashable {
        var kind: String
        var nodeID: UUID?
        var message: String
    }

    public var limit: Int
    public var dedupeWindow: TimeInterval

    private var events: [WatchEvent] = []
    private var lastSeen: [DedupeKey: Date] = [:]

    public init(limit: Int = 2000, dedupeWindow: TimeInterval = 5) {
        self.limit = limit
        self.dedupeWindow = dedupeWindow
    }

    /// 同一 (kind, nodeID, message) 在 dedupeWindow 内重复出现只记一条。
    public mutating func record(_ event: WatchEvent) {
        let key = DedupeKey(kind: event.kind, nodeID: event.nodeID, message: event.message)
        if let last = lastSeen[key], event.at.timeIntervalSince(last) < dedupeWindow {
            return
        }
        lastSeen[key] = event.at
        events.append(event)
        if events.count > limit { events.removeFirst(events.count - limit) }
    }

    /// 新的在前。
    public func recent(limit: Int) -> [WatchEvent] {
        Array(events.sorted { $0.at > $1.at }.prefix(max(0, limit)))
    }

    public func all() -> [WatchEvent] { events }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EventLog {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EventLog.self, from: data)
    }
}
