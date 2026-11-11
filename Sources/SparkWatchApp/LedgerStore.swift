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

    private let directory: URL

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

    /// 只读标记的对外读法：demo 播种只应发生在只读实例上——预览/CLI 的 save()
    /// 是 no-op，种子只活在内存；可写实例会把种子随 save() 写进真实账本文件。
    var isReadOnly: Bool { readOnly }

    /// 回放/诊断：账本里出现过的全部节点 id（并集升序）。
    /// --data-dir 预览用它把 demo 节点重映射到真实 id，机器页才取得到历史。
    func knownNodeIDs() -> [UUID] {
        var ids = Set(history.nodeIDs)
        ids.formUnion(energy.nodeIDs)
        ids.formUnion(tokens.nodeIDs)
        return ids.sorted()
    }

    init(readOnly: Bool = false, directory: URL? = nil) {
        self.readOnly = readOnly
        self.directory = directory ?? SettingsStore.directory
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

    // MARK: - Demo seeding（预览/演示专用）
    //
    // --demo-devices 的机队是合成的，但 token/能耗两张按天图需要**跨天**的账本
    // 才有东西可画：demo 模式不跑 record()，预览进程里也没有几天可攒的历史。
    // 这里按真实口径倒灌——token 走 observe() 的差分计数器（计数器沿时间单调
    // 递增，满足「只记增量」的前提），能耗走 seedBucket() 的分钟桶（契约注明
    // **seedBucket 不 prune，调用方收尾**）。
    //
    // 随机数用固定种子的 LCG 而不是 Double.random：demo 渲染必须可复现，
    // 否则每次截图数字都不一样，「表格合计与柱值一致」这类验收没法比对。
    //
    // 只动内存；调用方保证只在 readOnly 实例上调。
    func seedDemoHistory(now: Date) {
        var tokens = TokenLedger()
        var energy = EnergyLedger()
        let calendar = Calendar.current

        var rng: UInt64 = 0x5DEECE66D
        func next01() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((rng >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }

        // --- token：3 条 series / 2 个模型，沿 30 个本地天铺差分计数器 ---
        //
        // 模型 A 在两台机器各一条 series（当日表里出 ×2），模型 B 一条；
        // 中间留一天整机没跑——「没有记录的那天」必须在 demo 里看得见。
        let series: [(nodeID: UUID, port: Int, model: String)] = [
            (UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, 8888, "GLM-5.3-Flash-EXL3"),
            (UUID(uuidString: "00000000-0000-4000-8000-000000000001")!, 8889, "GLM-5.3-Flash-EXL3"),
            (UUID(uuidString: "00000000-0000-4000-8000-000000000000")!, 8000, "Qwen3-Coder-30B"),
        ]
        let tokenGapDay = 12
        var counters = [(prompt: Double, completion: Double, cached: Double)](
            repeating: (0, 0, 0), count: series.count
        )
        // observe() 首见只取基线不记账：先在窗口外埋一次 0 基线，之后的每次调用
        // 才有增量可记。
        let baselineAt = calendar.date(
            byAdding: .day, value: -31, to: calendar.startOfDay(for: now)
        ) ?? now.addingTimeInterval(-31 * 86400)
        for entry in series {
            tokens.observe(
                nodeID: entry.nodeID, port: entry.port, model: entry.model,
                prompt: 0, completion: 0, cached: 0, at: baselineAt
            )
        }
        for dayOffset in stride(from: 29, through: 0, by: -1) {
            if dayOffset == tokenGapDay { continue }
            let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-Double(dayOffset) * 86400))
            // 「今天」只铺已过去的整点：未来小时没有记录，最后一根柱是半天的。
            let lastHour = dayOffset == 0 ? calendar.component(.hour, from: now) : 24
            let span = max(1, lastHour)
            let targetHours = min(8 + Int(next01() * 13), span)   // 每天 8…20 个小时
            var hours = Set<Int>()
            for hour in 0..<span where next01() < 0.62 { hours.insert(hour) }
            while hours.count < targetHours {
                hours.insert(Int(next01() * Double(span)) % span)
            }
            for (index, entry) in series.enumerated() {
                // 模型 B 的 series 不是天天醒着——真实机队也不是。
                if index == 2, next01() < 0.2 { continue }
                for hour in hours.sorted() {
                    let minute = Int(next01() * 60)
                    guard let at = calendar.date(
                        bySettingHour: hour, minute: minute, second: 0, of: dayStart
                    ) else { continue }
                    // 计数器只增不减：observe() 的差分才有增量可记（倒退=重新取基线）。
                    counters[index].prompt += 1_000 + next01() * 60_000
                    counters[index].completion += 400 + next01() * 12_000
                    counters[index].cached += 800 + next01() * 40_000
                    tokens.observe(
                        nodeID: entry.nodeID, port: entry.port, model: entry.model,
                        prompt: counters[index].prompt,
                        completion: counters[index].completion,
                        cached: counters[index].cached,
                        at: at
                    )
                }
            }
        }

        // --- 能耗：31 天 × 5 分钟粒度（≈9k 桶）---
        //
        // 曲线：白天重、夜里轻；0–6 点引擎停机（整段无覆盖 → 详情里是缺口时段，
        // 不是 0 W）；gapDay 整天没开机。240 W 上限与 PowerEstimate 的 cap 一致。
        let energyGapDay = 9
        for dayOffset in stride(from: 30, through: 0, by: -1) {
            if dayOffset == energyGapDay { continue }
            let dayStart = calendar.startOfDay(for: now.addingTimeInterval(-Double(dayOffset) * 86400))
            let lastMinute = dayOffset == 0
                ? calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now)
                : 1440
            for slot in 0..<288 {
                let minute = slot * 5
                if minute >= lastMinute { break }
                guard let at = calendar.date(byAdding: .minute, value: minute, to: dayStart) else { continue }
                let hour = calendar.component(.hour, from: at)
                if hour < 6 { continue }   // 夜里停机：无覆盖，不是「0 W」
                let weekday = calendar.component(.weekday, from: at)
                let weekendFactor = (weekday == 1 || weekday == 7) ? 0.72 : 1.0
                let shape = 0.45 + 0.55 * max(0, sin((Double(hour) - 5) / 24 * 2 * .pi))
                let watts = min(240, (38 + 118 * shape * (0.75 + 0.5 * next01())) * weekendFactor)
                let outputTokens = watts > 70 ? next01() * 900 : 0
                energy.seedBucket(
                    minuteKey: Int(floor(at.timeIntervalSince1970 / 60)),
                    wh: watts * 300 / 3_600,   // 300 s 的 Wh = W ÷ 12
                    coveredMs: 300_000,
                    outputTokens: outputTokens
                )
            }
        }

        // 契约：seedBucket 之后要 prune 收尾。EnergyLedger 没有公开 prune，而
        // record() 末尾必调——用一次不写桶的 record 触发它；顺带 pushRecent 让
        // 24h 图的「当前 W」有一个读数（demo 模式没有真实采样）。
        energy.record(
            nodeID: series[0].nodeID, at: now, watts: 84,
            outputTokens: nil, countEnergy: true, countTokens: false
        )

        // --- GPU 历史：8 小时 × 5 秒网格的真实占空比形状 ---
        //
        // 没有 GPU 历史，机器详情页那张图在 demo 里是空网格（预览输出 history=0
        // 点），图表的任何设计验收都无从谈起。形状按这台机队的实测画像倒灌：
        // 突发段 util 在 35–97 % 之间以 4–10 s 周期振荡（这就是占空比本体），
        // GPU 轨 55–95 W、温度向 84 °C 渐近；空闲段 util 0、轨 21–27 W、回落
        // 47 °C。另有两类「不完美」必须能画出来：整段时间洞（探测没跑/SSH 断）
        // 和零星单点 nil（采样丢失）——分层图的断口规矩要在假数据上看得见。
        var historySeed = GpuHistory()
        var rngH: UInt64 = 0x9E37_79B9_7F4A_7C15
        func nextH01() -> Double {
            rngH = rngH &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((rngH >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
        }
        let step = 5.0
        // 与上面 token 播种同一组固定节点 ID（demo 机队的 spark-00/01）。
        for nodeID in [
            UUID(uuidString: "00000000-0000-4000-8000-000000000000")!,
            UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        ] {
            var t = now.addingTimeInterval(-8 * 3600)
            var burstLeft = 0.0
            var burstPeriod = 6.0
            var burstBase = 70.0
            var gapLeft = 0.0
            var temp = 46.0
            while t < now {
                if gapLeft > 0 {
                    gapLeft -= step
                    t = t.addingTimeInterval(step)
                    continue   // 时间洞：整段不记点，图上必须是断口而不是连线
                }
                let roll = nextH01()
                if burstLeft <= 0, roll < 0.02 {
                    burstLeft = 60 + nextH01() * 420
                    burstPeriod = 4 + nextH01() * 6
                    burstBase = 62 + nextH01() * 33
                }
                if burstLeft <= 0, roll > 0.995 { gapLeft = 60 + nextH01() * 300 }
                let util: Double?
                let power: Double
                let clock: Double
                if burstLeft > 0 {
                    burstLeft -= step
                    let wobble = 0.5 + 0.5 * sin(2 * .pi * t.timeIntervalSince1970 / burstPeriod)
                    let u = min(97, max(35, burstBase * (0.55 + 0.45 * wobble)))
                    util = u
                    power = 22 + u / 100 * 68 + nextH01() * 4
                    temp += (72 + u / 100 * 12 - temp) * 0.01
                    clock = 2380 + nextH01() * 90
                } else {
                    util = nextH01() < 0.02 ? nil : 0
                    power = 21 + nextH01() * 6
                    temp += (47 - temp) * 0.01
                    clock = 1500 + nextH01() * 60
                }
                historySeed.record(
                    .init(at: t, utilPct: util, powerW: power, tempC: temp,
                          acpitzC: temp + 8, smClockMHz: clock),
                    nodeID: nodeID
                )
                t = t.addingTimeInterval(step)
            }
        }
        self.history = historySeed

        self.tokens = tokens
        self.energy = energy
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
