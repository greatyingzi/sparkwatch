import Foundation
import Testing
@testable import SparkWatchCore

// 全部用假时间（固定 Date），不依赖真实 Date() 的流动——否则测试会与机器负载、
// 时钟精度纠缠，跑两遍结果就不一样。

private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!
private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!
private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// MARK: - GpuHistory

@Suite("GPU 历史环形缓冲")
struct GpuHistoryTests {
    private func point(_ t: TimeInterval, _ util: Double?) -> GpuHistory.Point {
        GpuHistory.Point(at: t0.addingTimeInterval(t), utilPct: util, powerW: util, tempC: util)
    }

    /// 超过 maxAge 的点被丢弃（以新点时间为基准）。
    @Test func dropsPointsBeyondMaxAge() {
        var history = GpuHistory(maxAge: 100, minGap: 0)
        for index in 0...15 { history.record(point(Double(index) * 10, 50), nodeID: nodeA) }
        let kept = history.points(nodeID: nodeA, window: 1000, now: t0.addingTimeInterval(150))
        // maxAge=100，只剩 [50,150]，即 50,60,…,150 共 11 个。
        #expect(kept.count == 11)
        #expect(kept.first?.at == t0.addingTimeInterval(50))
        #expect(kept.last?.at == t0.addingTimeInterval(150))
    }

    /// minGap 内新值替换旧值：点数不涨，但值更新（而不是丢弃新值让曲线变稀疏）。
    @Test func minGapReplacesInsteadOfDropping() {
        var history = GpuHistory(maxAge: 1000, minGap: 5)
        history.record(point(0, 10), nodeID: nodeA)
        history.record(point(2, 99), nodeID: nodeA)   // 2 < 5 → 替换
        var kept = history.points(nodeID: nodeA, window: 1000, now: t0.addingTimeInterval(2))
        #expect(kept.count == 1)
        #expect(kept.last?.utilPct == 99)
        #expect(kept.last?.at == t0.addingTimeInterval(2))
        history.record(point(10, 50), nodeID: nodeA)  // 10−2 = 8 ≥ 5 → 追加
        kept = history.points(nodeID: nodeA, window: 1000, now: t0.addingTimeInterval(10))
        #expect(kept.count == 2)
    }

    /// 窗口内的点数量正确。
    @Test func countsPointsInWindow() {
        var history = GpuHistory(maxAge: 10_000, minGap: 0)
        for index in 0...10 { history.record(point(Double(index) * 10, 50), nodeID: nodeA) }
        let kept = history.points(nodeID: nodeA, window: 30, now: t0.addingTimeInterval(100))
        #expect(kept.count == 4)   // 70,80,90,100
        #expect(kept.first?.at == t0.addingTimeInterval(70))
    }

    /// binned 跨断口变 nil 且不跨断口连线。
    @Test func binnedPreservesGaps() {
        // 窗口 [0,100]，10 个桶各 10 s。0–30 密采，30→60 一个 30 s 大洞，60–90 再密采。
        var points: [GpuHistory.Point] = []
        for t in stride(from: 0.0, through: 30.0, by: 5) { points.append(point(t, 50)) }
        for t in stride(from: 60.0, through: 90.0, by: 5) { points.append(point(t, 50)) }
        let result = GpuHistory.binned(
            points, into: 10, window: 100, now: t0.addingTimeInterval(100), gapThreshold: 20
        )
        #expect(result.util.count == 10)
        #expect(result.util[3] == 50)     // 断口前的桶有值
        #expect(result.util[4] == nil)    // 空桶
        #expect(result.util[5] == nil)    // 空桶
        #expect(result.util[6] == nil)    // 断口后第一个桶：必须 nil，不得跨洞连回去
        #expect(result.util[7] == 50)     // 新一段有值
        #expect(result.maxUtil == 50)
    }

    /// encode→decode 往返相等。
    @Test func encodeDecodeRoundTrip() throws {
        var history = GpuHistory(maxAge: 500, minGap: 1.5)
        for index in 0...20 {
            history.record(
                GpuHistory.Point(
                    at: t0.addingTimeInterval(Double(index) * 5),
                    utilPct: Double(index), powerW: Double(index) * 2, tempC: Double(index) + 40
                ),
                nodeID: nodeA
            )
        }
        history.record(point(0, 99), nodeID: nodeB)
        let restored = try GpuHistory.decode(try history.encoded())
        let now = t0.addingTimeInterval(200)
        #expect(restored.points(nodeID: nodeA, window: 10_000, now: now)
            == history.points(nodeID: nodeA, window: 10_000, now: now))
        #expect(restored.points(nodeID: nodeB, window: 10_000, now: now)
            == history.points(nodeID: nodeB, window: 10_000, now: now))
    }

    /// pointBudget 与 maxAge/minGap 一致（约 1.2 倍余量）。
    @Test func pointBudgetIsReasonable() {
        let history = GpuHistory()   // 8h / 1.5s
        #expect(history.pointBudget >= 19_200)   // maxAge / minGap
        #expect(history.pointBudget <= 24_000)   // 再留 20% 余量
    }
}

// MARK: - EnergyLedger

@Suite("机队能耗账本")
struct EnergyLedgerTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    /// 账本与卡片必须是同一个公式：这里只验它委派给了 `PowerEstimate`。
    @Test func estimateWattsDelegatesToTheSingleModel() {
        let model = PowerEstimate()
        for gpu in [0.0, 11.0, 47.7, 87.0] {
            for cpu in [0.0, 33.0, 100.0] {
                #expect(
                    EnergyLedger.estimateWatts(gpuW: gpu, cpuUsagePct: cpu)
                        == model.estimate(gpuW: gpu, cpuUsagePct: cpu)?.wallW
                )
            }
        }
        // 锚点复核：空载落在 2026 固件的 22–25W 区间，而不是旧公式的 38W。
        let idle = EnergyLedger.estimateWatts(gpuW: 11, cpuUsagePct: 3)!
        #expect(idle >= 20 && idle <= 26)
        // CPU 满载不再被低估（旧公式给 38W，实测 120–130W）。
        let cpuHeavy = EnergyLedger.estimateWatts(gpuW: 12, cpuUsagePct: 100)!
        #expect(cpuHeavy >= 100 && cpuHeavy <= 130)
    }

    /// GPU 轨未知 → nil（不造数）。CPU 未知不再是 nil：整机仍然要记账，
    /// 只是按 20% 的载入先验并标低置信。
    @Test func estimateWattsWithoutInputs() {
        #expect(EnergyLedger.estimateWatts(gpuW: nil, cpuUsagePct: 50) == nil)
        let reading = PowerEstimate().estimate(gpuW: 10, cpuUsagePct: nil)
        #expect(reading != nil)
        #expect(reading?.cpuAssumed == true)
        #expect(reading?.confidence == .low)
    }

    /// 100 W 跑 60 分钟 = 100 Wh = 0.1 kWh。
    @Test func integratesHundredWattsForAnHour() {
        var ledger = EnergyLedger()
        for step in 0...720 {   // 每 5 s，共 3600 s；间隔 5 s < maxGap 10 s
            ledger.record(nodeID: nodeA, at: base.addingTimeInterval(Double(step) * 5), watts: 100,
                          outputTokens: nil, countEnergy: true, countTokens: false)
        }
        let snapshot = ledger.snapshot(now: base.addingTimeInterval(3600))
        #expect(abs(snapshot.energy24hKWh - 0.1) < 0.001)
        #expect(abs(snapshot.energy31dKWh - 0.1) < 0.001)
        // 3600 s 覆盖 / 24 h = 1/24。
        #expect(abs(snapshot.coverage24h - 1.0 / 24.0) < 1e-6)
    }

    /// 间隔 > maxGap → 不积分（断口不计）。
    @Test func gapIsNotIntegrated() {
        var ledger = EnergyLedger()
        ledger.record(nodeID: nodeA, at: base, watts: 100, outputTokens: nil)
        ledger.record(nodeID: nodeA, at: base.addingTimeInterval(100), watts: 100, outputTokens: nil)
        let snapshot = ledger.snapshot(now: base.addingTimeInterval(100))
        #expect(snapshot.energy24hKWh == 0)
        #expect(snapshot.coverage24h == 0)
    }

    /// 计数器倒退不报负，只重新取基线。
    @Test func counterRollbackDoesNotGoNegative() {
        var ledger = EnergyLedger()
        ledger.record(nodeID: nodeA, at: base, watts: 100, outputTokens: 1000)
        ledger.record(nodeID: nodeA, at: base.addingTimeInterval(5), watts: 100, outputTokens: 500)
        var snapshot = ledger.snapshot(now: base.addingTimeInterval(5))
        #expect(snapshot.coveredOutputTokens24h == 0)
        // 基线已重置到 500：下一次 1500 应差分出 1000。
        ledger.record(nodeID: nodeA, at: base.addingTimeInterval(10), watts: 100, outputTokens: 1500)
        snapshot = ledger.snapshot(now: base.addingTimeInterval(10))
        #expect(snapshot.coveredOutputTokens24h == 1000)
    }

    /// worker 不重复计算：两台机器同样 100 W/5 s 一小时，只有计能的一台进账。
    @Test func workerNotDoubleCounted() {
        var ledger = EnergyLedger()
        for step in 0...720 {
            let at = base.addingTimeInterval(Double(step) * 5)
            ledger.record(nodeID: nodeA, at: at, watts: 100, outputTokens: nil, countEnergy: true, countTokens: false)
            ledger.record(nodeID: nodeB, at: at, watts: 100, outputTokens: nil, countEnergy: false, countTokens: false)
        }
        let snapshot = ledger.snapshot(now: base.addingTimeInterval(3600))
        #expect(abs(snapshot.energy24hKWh - 0.1) < 0.001)
    }

    /// hourlyWatts 长度正确，缺数据的小时为 nil。
    @Test func hourlyWattsLengthAndNilPositions() {
        var ledger = EnergyLedger()
        let now = base
        let hourStart = floor(now.timeIntervalSince1970 / 3600) * 3600
        // 只在前两个小时（索引 0）里采样。
        let windowStart = hourStart - 2 * 3600
        for step in 0..<700 {   // 5 s 一步，稳稳待在那个小时内
            ledger.record(nodeID: nodeA, at: Date(timeIntervalSince1970: windowStart + Double(step) * 5),
                          watts: 100, outputTokens: nil, countEnergy: true, countTokens: false)
        }
        let bars = ledger.hourlyWatts(hours: 3, now: now)
        #expect(bars.count == 3)
        #expect(bars[0] != nil)
        #expect(abs((bars[0] ?? 0) - 100) < 1)
        #expect(bars[1] == nil)
        #expect(bars[2] == nil)
    }

    /// encode→decode 往返。
    @Test func encodeDecodeRoundTrip() throws {
        var ledger = EnergyLedger()
        for step in 0...100 {
            ledger.record(nodeID: nodeA, at: base.addingTimeInterval(Double(step) * 5), watts: 80,
                          outputTokens: Double(step) * 100, countEnergy: true, countTokens: true)
        }
        let restored = try EnergyLedger.decode(try ledger.encoded())
        let now = base.addingTimeInterval(500)
        #expect(restored.snapshot(now: now) == ledger.snapshot(now: now))
    }
}

// MARK: - TokenLedger

@Suite("按模型 token 账本")
struct TokenLedgerTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func utcMidnight(year: Int, month: Int, day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 0))!
    }

    /// 两次 observe 的差分正确。
    @Test func differencesTwoObservations() {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 100, completion: 50, cached: 20, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 150, completion: 80, cached: 30, at: base.addingTimeInterval(10))
        let totals = ledger.totals(.all, now: base.addingTimeInterval(10))
        #expect(totals.prompt == 50)
        #expect(totals.completion == 30)
        #expect(totals.cached == 10)
    }

    /// 倒退不记账。
    @Test func rollbackNotCounted() {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 1000, completion: 0, cached: 0, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 500, completion: 0, cached: 0, at: base.addingTimeInterval(10))
        #expect(ledger.totals(.all, now: base.addingTimeInterval(10)).prompt == 0)
    }

    /// 跳变过大（> 1e9）视为换引擎，不记账。
    @Test func hugeJumpNotCounted() {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 100, completion: 0, cached: 0, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 100 + 2e9, completion: 0, cached: 0, at: base.addingTimeInterval(10))
        #expect(ledger.totals(.all, now: base.addingTimeInterval(10)).prompt == 0)
    }

    /// cached > prompt 被纠正：超出部分并进 prompt，且 cached ≤ prompt 恒成立。
    @Test func cachedExceedingPromptIsCorrected() {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 100, completion: 0, cached: 20, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 150, completion: 0, cached: 200, at: base.addingTimeInterval(10))
        let totals = ledger.totals(.all, now: base.addingTimeInterval(10))
        #expect(totals.prompt == 180)     // 50 的基础上吸收 130 的超出
        #expect(totals.cached == 180)
        #expect(totals.cached <= totals.prompt)
    }

    /// byModel 按 completion 降序。
    @Test func byModelDescending() {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "a", prompt: 0, completion: 0, cached: 0, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "a", prompt: 0, completion: 30, cached: 0, at: base.addingTimeInterval(10))
        ledger.observe(nodeID: nodeA, port: 8889, model: "b", prompt: 0, completion: 0, cached: 0, at: base)
        ledger.observe(nodeID: nodeA, port: 8889, model: "b", prompt: 0, completion: 100, cached: 0, at: base.addingTimeInterval(10))
        let rows = ledger.byModel(.all, now: base.addingTimeInterval(10))
        #expect(rows.count == 2)
        #expect(rows[0].model == "b")
        #expect(rows[1].model == "a")
        #expect(rows[0].seriesCount == 1)
    }

    /// dailyCompletion 缺日为 0，按 UTC 日 yyyy-MM-dd。
    @Test func dailyCompletionFillsMissingDaysWithZero() {
        var ledger = TokenLedger()
        let midnight = utcMidnight(year: 2026, month: 1, day: 15)
        // 3 天前一个增量 50。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0, at: midnight.addingTimeInterval(-3 * 86400 + 3600))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 50, cached: 0, at: midnight.addingTimeInterval(-3 * 86400 + 7200))
        // 今天一个增量 40。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 50, cached: 0, at: midnight.addingTimeInterval(3600))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 90, cached: 0, at: midnight.addingTimeInterval(7200))

        let days = ledger.dailyCompletion(days: 5, now: midnight.addingTimeInterval(12 * 3600))
        #expect(days.count == 5)
        #expect(days[4].day == "2026-01-15")
        #expect(days[4].completion == 40)
        #expect(days[1].day == "2026-01-12")
        #expect(days[1].completion == 50)
        #expect(days[2].completion == 0)   // 缺日为 0
    }

    /// Range 边界：今天只算今天。
    @Test func rangeTodayOnlyCountsToday() {
        var ledger = TokenLedger()
        let midnight = utcMidnight(year: 2026, month: 1, day: 15)
        let now = midnight.addingTimeInterval(12 * 3600)
        // 昨天 23:59 前一拍建立基线，23:59 记 +100（属于昨天）。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0, at: midnight.addingTimeInterval(-3600))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 100, cached: 0, at: midnight.addingTimeInterval(-60))
        // 今天 +150。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 100, cached: 0, at: midnight.addingTimeInterval(60))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 250, cached: 0, at: midnight.addingTimeInterval(120))

        #expect(ledger.totals(.today, now: now).completion == 150)
        #expect(ledger.totals(.all, now: now).completion == 250)
    }

    /// encode→decode 往返。
    @Test func encodeDecodeRoundTrip() throws {
        var ledger = TokenLedger()
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 100, completion: 50, cached: 10, at: base)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 400, completion: 250, cached: 60, at: base.addingTimeInterval(600))
        let restored = try TokenLedger.decode(try ledger.encoded())
        let now = base.addingTimeInterval(600)
        #expect(restored.totals(.all, now: now) == ledger.totals(.all, now: now))
        #expect(restored.byModel(.all, now: now) == ledger.byModel(.all, now: now))
    }
}

// MARK: - EventLog

@Suite("事件日志")
struct EventLogTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    private func event(_ t: TimeInterval, kind: String, message: String) -> WatchEvent {
        WatchEvent(
            at: base.addingTimeInterval(t), severity: .warn, kind: kind,
            nodeID: nodeA, nodeName: "spark-00", message: message
        )
    }

    /// 去重窗口内重复被吃掉。
    @Test func dedupeWithinWindow() {
        var log = EventLog(dedupeWindow: 5)
        log.record(event(0, kind: "node.offline", message: "节点离线"))
        log.record(event(3, kind: "node.offline", message: "节点离线"))   // 3 < 5 → 吃
        log.record(event(4, kind: "node.offline", message: "节点离线"))   // 仍从 0 起算 → 吃
        #expect(log.all().count == 1)
    }

    /// 窗口外不被吃。
    @Test func notDedupedOutsideWindow() {
        var log = EventLog(dedupeWindow: 5)
        log.record(event(0, kind: "node.offline", message: "节点离线"))
        log.record(event(6, kind: "node.offline", message: "节点离线"))   // 6 ≥ 5 → 记
        #expect(log.all().count == 2)
        // 不同 message 不受影响。
        log.record(event(7, kind: "node.offline", message: "换了句话"))
        #expect(log.all().count == 3)
    }

    /// limit 截断保留最新。
    @Test func limitKeepsNewest() {
        var log = EventLog(limit: 3)
        for index in 0..<5 { log.record(event(Double(index), kind: "k", message: "m\(index)")) }
        let all = log.all()
        #expect(all.count == 3)
        #expect(all.map(\.message) == ["m2", "m3", "m4"])
    }

    /// recent 降序。
    @Test func recentIsDescending() {
        var log = EventLog()
        for index in 0..<3 { log.record(event(Double(index), kind: "k", message: "m\(index)")) }
        let recent = log.recent(limit: 10)
        #expect(recent.map(\.message) == ["m2", "m1", "m0"])
    }

    /// encode→decode 往返。
    @Test func encodeDecodeRoundTrip() throws {
        var log = EventLog()
        log.record(event(0, kind: "node.offline", message: "节点离线"))
        log.record(event(10, kind: "gpu.throttle", message: "GPU 降频"))
        let restored = try EventLog.decode(try log.encoded())
        #expect(restored.all() == log.all())
        #expect(restored.recent(limit: 10) == log.recent(limit: 10))
    }
}
