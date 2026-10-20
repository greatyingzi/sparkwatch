import AppKit
import Foundation
import SparkWatchCore

/// Owns the four time-series stores and turns each refresh into history.
///
/// Split out of `AppModel` on purpose: the model is the MainActor bridge that
/// SwiftUI reads, while this is bookkeeping — diffing counters, integrating energy,
/// deriving events, persisting on a slow cadence. Keeping them apart means the UI
/// can be reasoned about without the arithmetic, and the arithmetic can be unit
/// tested without a window.
///
/// Everything here is **derived from what the collector already samples**: no extra
/// network or SSH traffic. A monitor that doubles the load it measures is worse than
/// no monitor.
@MainActor
final class LedgerStore {
    private(set) var history = GpuHistory()
    private(set) var energy = EnergyLedger()
    private(set) var tokens = TokenLedger()
    private(set) var events = EventLog()

    /// Last thing said about each machine, for transition-only events. A dashboard
    /// that logs "GPU hot" every two seconds is a log nobody reads; only the
    /// *change* is news.
    private struct LastState {
        var source: DataSource
        var level: HealthLevel
        var taskModel: String?
        var throttled: Bool
        var incident: Bool
    }
    private var last: [UUID: LastState] = [:]
    private var lastSave = Date.distantPast
    private let saveInterval: TimeInterval = 30

    private let directory: URL = SettingsStore.directory

    private var historyURL: URL { directory.appendingPathComponent("gpu-history.json") }
    private var energyURL: URL { directory.appendingPathComponent("energy.json") }
    private var tokensURL: URL { directory.appendingPathComponent("token-ledger.json") }
    private var eventsURL: URL { directory.appendingPathComponent("events.json") }

    /// Preview/CLI instances may **read** the ledgers but must never write them.
    ///
    /// Writing is what hurt: a render run loaded the shared file, added the couple of
    /// seconds it had collected and saved that back — leaving the real machine's
    /// persisted history threadbare. Reading, on the other hand, is exactly what makes
    /// a diagnostic render or `--print-chart` dump show the *real* series instead of the
    /// two seconds it just collected.
    private let readOnly: Bool

    init(readOnly: Bool = false) {
        self.readOnly = readOnly
        load()
    }

    // MARK: - Recording

    func record(
        nodes: [NodeSnapshot],
        tasks: [ClusterTask],
        power: PowerEstimate = PowerEstimate(),
        at now: Date = Date()
    ) {
        for node in nodes {
            let role = node.inference?.taskRole ?? ""
            // A headless rank of a distributed deployment answers no HTTP and
            // shares one GPU with its peer: counting its energy would bill the same
            // watt twice, and it has no token counters to read at all.
            let isWorker = role.contains("worker")
            let isServing = node.inference != nil && !isWorker

            // The zone temperature and the SM clock go into the same ring as
            // utilisation and power: after a hard power-off this Mac holds the only
            // surviving copy of the last two minutes, and "it was climbing" is a
            // claim that needs those two columns.
            history.record(
                GpuHistory.Point(
                    at: now,
                    utilPct: node.gpu.utilPct,
                    powerW: node.gpu.powerW,
                    tempC: node.gpu.tempC,
                    acpitzC: node.system.cpuTempC,
                    smClockMHz: node.gpu.smClockMHz
                ),
                nodeID: node.id
            )

            // The pre-computed reading is the one every surface shows; recomputing
            // here would let the ledger and the card drift apart again.
            let watts = node.power?.wallW
                ?? EnergyLedger.estimateWatts(
                    gpuW: node.gpu.powerW,
                    cpuUsagePct: node.system.cpuUsagePct,
                    model: power
                )
            energy.record(
                nodeID: node.id,
                at: now,
                watts: watts,
                outputTokens: isServing ? node.inference?.generationTokens : nil,
                countEnergy: !isWorker,
                countTokens: isServing
            )

            if isServing {
                tokens.observe(
                    nodeID: node.id,
                    port: Self.port(from: node.inference?.endpoint),
                    model: node.inference?.model,
                    prompt: node.inference?.promptTokens,
                    completion: node.inference?.generationTokens,
                    cached: node.inference?.cachedTokens,
                    at: now
                )
            }

            emitTransitionEvents(for: node, task: tasks.first { $0.nodes.contains(node.name) }, at: now)
        }

        // **`save()` owns the interval; do not pre-set `lastSave` here.**
        //
        // This used to read `lastSave = now; save()`, which made `save()`'s own
        // `now - lastSave >= saveInterval` check fail by construction — so the ledgers
        // were never written on the interval at all, only when an event forced a save
        // or on quit. Measured 2026-10-10: 75 s with the app running and not a single
        // byte written.
        save()
    }

    static func port(from endpoint: String?) -> Int {
        guard let endpoint, let colon = endpoint.lastIndex(of: ":") else { return 0 }
        return Int(endpoint[endpoint.index(after: colon)...].prefix { $0.isNumber }) ?? 0
    }

    // MARK: - Transitions → events

    private func emitTransitionEvents(for node: NodeSnapshot, task: ClusterTask?, at now: Date) {
        let throttled = node.gpu.throttle?.active ?? false
        let current = LastState(
            source: node.source,
            level: node.health.level,
            taskModel: task?.model,
            throttled: throttled,
            incident: node.system.incidentActive
        )
        defer { last[node.id] = current }
        guard let previous = last[node.id] else { return }  // first sight is a baseline, not news

        if previous.source != .down, node.source == .down {
            events.record(WatchEvent(
                at: now, severity: .error, kind: "node.offline", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) 失去响应（SSH 与面板通道都不通）"
            ))
        } else if previous.source == .down, node.source != .down {
            events.record(WatchEvent(
                at: now, severity: .success, kind: "node.online", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) 恢复在线（数据源 \(node.source.label)）"
            ))
        }

        if node.health.level > previous.level, node.health.level != .ok {
            let reason = node.health.reasons.first ?? Theme.levelLabel(node.health.level)
            events.record(WatchEvent(
                at: now,
                severity: node.health.level == .critical ? .error : .warn,
                kind: "health.\(node.health.level == .critical ? "critical" : "warning")",
                nodeID: node.id, nodeName: node.name,
                message: "\(node.name) \(reason)"
            ))
        } else if node.health.level < previous.level, node.health.level == .ok {
            events.record(WatchEvent(
                at: now, severity: .success, kind: "health.cleared", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) 恢复正常（之前：\(previous.level.label)）"
            ))
        }

        if !previous.throttled, throttled {
            events.record(WatchEvent(
                at: now, severity: .warn, kind: "gpu.throttle", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) GPU 降频：\(node.gpu.throttle?.label ?? "")"
            ))
        } else if previous.throttled, !throttled {
            events.record(WatchEvent(
                at: now, severity: .success, kind: "gpu.throttle.cleared", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) 降频解除"
            ))
        }

        if !previous.incident, node.system.incidentActive {
            let kernel = node.system.kernelErrors
            events.record(WatchEvent(
                at: now, severity: .error, kind: "health.incident", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) 内核事件上升：Xid \(kernel.xid) · OOM \(kernel.oomKills) · 显存分配失败 \(kernel.nvErrNoMemory)"
            ))
        }

        if let model = task?.model, model != previous.taskModel {
            let verb = previous.taskModel == nil ? "开始服务" : "切换模型到"
            events.record(WatchEvent(
                at: now, severity: .info, kind: "task.model", nodeID: node.id, nodeName: node.name,
                message: "\(node.name) \(verb) \(model)"
            ))
        }
    }

    /// A user-visible action or app-level note (benchmark finished, settings saved).
    func note(_ message: String, severity: WatchEvent.Severity = .info, kind: String, node: NodeSnapshot? = nil, at now: Date = Date()) {
        events.record(WatchEvent(
            at: now, severity: severity, kind: kind,
            nodeID: node?.id, nodeName: node?.name, message: message
        ))
        save(force: true)
    }

    // MARK: - Persistence

    private func load() {
        if let data = try? Data(contentsOf: historyURL), let decoded = try? GpuHistory.decode(data) {
            history = decoded
        }
        if let data = try? Data(contentsOf: energyURL), let decoded = try? EnergyLedger.decode(data) {
            energy = decoded
        }
        if let data = try? Data(contentsOf: tokensURL), let decoded = try? TokenLedger.decode(data) {
            tokens = decoded
        }
        if let data = try? Data(contentsOf: eventsURL), let decoded = try? EventLog.decode(data) {
            events = decoded
        }
    }

    func save(force: Bool = false) {
        guard !readOnly else { return }
        guard force || Date().timeIntervalSince(lastSave) >= saveInterval else { return }
        lastSave = Date()
        write(history, to: historyURL)
        write(energy, to: energyURL)
        write(tokens, to: tokensURL)
        write(events, to: eventsURL)
    }

    private func write<T>(_ value: T, to url: URL) where T: Encodable {
        guard let data = try? JSONEncoder.sparkwatch.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

extension JSONEncoder {
    /// One date strategy for every ledger file: the same one the plumbing already
    /// uses for sessions, so a file written by one component can be read by another.
    static var sparkwatch: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
