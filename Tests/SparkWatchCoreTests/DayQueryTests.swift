import Foundation
import Testing
@testable import SparkWatchCore

// 按天查询（DayQueries 契约）的测试。全部固定 Date：时区/DST/日界的断言最忌
// 「现在几点」漂移，绝不依赖 Date()；时区一律显式传参，不测机器时区。

private let utc = TimeZone(identifier: "UTC")!
private let shanghai = TimeZone(identifier: "Asia/Shanghai")!
private let newYork = TimeZone(identifier: "America/New_York")!

private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000B0")!
private let nodeB = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

/// 在指定时区下构造时刻：date(utc, 2026, 11, 9, 16, 30) = UTC 16:30。
private func date(
    _ timeZone: TimeZone, _ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0
) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

/// token 便捷铺数：同一时刻先拍基线再拍增量，让 observe() 差分出 amount。
/// 同一 series 连续 bump 也成立：先 0 再 amount，0 那拍只重立基线不建桶。
private func bumpToken(
    _ ledger: inout TokenLedger, at: Date, completion amount: Double,
    nodeID: UUID = nodeA, port: Int = 8888, model: String = "m"
) {
    ledger.observe(nodeID: nodeID, port: port, model: model, prompt: 0, completion: 0, cached: 0, at: at)
    ledger.observe(nodeID: nodeID, port: port, model: model, prompt: 0, completion: amount, cached: 0, at: at.addingTimeInterval(60))
}

// MARK: - 日界与时区口径

@Suite("按天查询：日界与时区")
struct DayBoundaryTests {
    /// 上海 +8：UTC 2026-11-09 16:00 = 本地 11-10 00:00。压着本地零点的桶必须记到
    /// 11-10，23:30 的桶留在 11-09——「那天」按用户时区切，不按 UTC 切。
    @Test func localDayBoundaryFollowsQueryTimeZone() {
        var ledger = TokenLedger()
        // 本地 11-09 23:30（UTC 15:30）+10；本地 11-10 00:30（UTC 16:30）+60。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0,
                       at: date(utc, 2026, 11, 9, 15, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 10, cached: 0,
                       at: date(utc, 2026, 11, 9, 15, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 70, cached: 0,
                       at: date(utc, 2026, 11, 9, 16, 30))

        let now = date(utc, 2026, 11, 10, 12)   // 本地 11-10 20:00，今天未结束
        let days = ledger.daily(days: 3, now: now, timeZone: shanghai)
        #expect(days.map(\.day) == ["2026-11-08", "2026-11-09", "2026-11-10"])
        #expect(!days[0].hasData && days[0].completion == 0)   // 无记录日 ≠ 用量为零
        #expect(days[1].hasData && days[1].completion == 10)   // 本地 23:30 的桶
        #expect(days[2].hasData && days[2].completion == 60)   // 跨过本地零点的桶
    }

    /// 显式传 UTC 时，daily() 必须与旧 dailyCompletion 完全同口径
    /// （回归：查询侧改本地日分组，不许动 UTC 对账语义）。
    @Test func utcTimeZoneMatchesLegacyDailyCompletion() {
        var ledger = TokenLedger()
        let midnight = date(utc, 2026, 1, 15)
        // 01-12 +50、01-13 +20、01-15 +40；01-10/11/14 留空当缺日。
        for (offset, amount) in [(3, 50.0), (2, 20.0), (0, 40.0)] {
            let at = midnight.addingTimeInterval(TimeInterval(-offset) * 86_400 + 3_600)
            ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0, at: at)
            ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: amount, cached: 0, at: at.addingTimeInterval(600))
        }
        let now = midnight.addingTimeInterval(12 * 3_600)
        let legacy = ledger.dailyCompletion(days: 6, now: now)
        let daily = ledger.daily(days: 6, now: now, timeZone: utc)
        #expect(daily.map(\.day) == legacy.map { $0.day })
        #expect(daily.map(\.completion) == legacy.map { $0.completion })
        // 本数据每只桶都带 completion > 0，hasData 应与「completion > 0」一一对应。
        #expect(daily.map(\.hasData) == legacy.map { $0.completion > 0 })
        #expect(daily[0].day == "2026-01-10" && !daily[0].hasData)
        #expect(daily[2].day == "2026-01-12" && daily[2].completion == 50)
        #expect(daily[5].day == "2026-01-15" && daily[5].completion == 40)
    }

    /// 「今天」区间从查询时区的本地零点起算（上海比 UTC 零点晚 8 小时）：
    /// 本地昨天 23:30 的增量不算今天；显式传 UTC 时按 UTC 零点算——两个口径各算各的。
    @Test func todayRangeStartsAtLocalMidnight() {
        var ledger = TokenLedger()
        // UTC 15:30 = 本地 11-09 23:30 → +100（本地昨天）
        // UTC 16:30 = 本地 11-10 00:30 → +200（本地今天）
        // UTC 11-10 05:00 → +50（两个口径都算「今天」）
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0, at: date(utc, 2026, 11, 9, 15, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 100, cached: 0, at: date(utc, 2026, 11, 9, 15, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 100, cached: 0, at: date(utc, 2026, 11, 9, 16, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 300, cached: 0, at: date(utc, 2026, 11, 9, 16, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 300, cached: 0, at: date(utc, 2026, 11, 10, 5, 0))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 350, cached: 0, at: date(utc, 2026, 11, 10, 5, 0).addingTimeInterval(60))

        let now = date(utc, 2026, 11, 10, 12)   // 本地 20:00
        #expect(ledger.totals(.today, now: now, timeZone: shanghai).completion == 250)
        #expect(ledger.totals(.today, now: now, timeZone: utc).completion == 50)
        #expect(ledger.totals(.all, now: now).completion == 350)   // .all 不受时区影响
        let rows = ledger.byModel(.today, now: now, timeZone: shanghai)
        #expect(rows.count == 1 && rows[0].model == "m" && rows[0].completion == 250)
    }
}

// MARK: - dayDetail 结构

@Suite("按天查询：dayDetail")
struct DayDetailTests {
    /// token 版：hourly 长度 = 当日真实小时数（上海无 DST → 24）；hasData 只标
    /// 「有桶的小时」；byModel 复用 ModelRow 且 completion 降序；seriesCount 数当天
    /// 记过账的 series。非法 day 串一律 nil，绝不猜日期。
    @Test func tokenDayDetailHourlyLayout() {
        var ledger = TokenLedger()
        // 本地 11-10（上海）= UTC [11-09 16:00, 11-10 16:00)。本地第 h 小时（h<8）
        // 在 UTC 11-09 (16+h) 点，h≥8 在 UTC 11-10 (h−8) 点。只铺第 0/5/23 小时；
        // 第 23 小时换一条 series（port 8889, 模型 n）。
        bumpToken(&ledger, at: date(utc, 2026, 11, 9, 16, 10), completion: 30)
        bumpToken(&ledger, at: date(utc, 2026, 11, 9, 21, 10), completion: 50)
        bumpToken(&ledger, at: date(utc, 2026, 11, 10, 15, 10), completion: 20, port: 8889, model: "n")

        let detail = ledger.dayDetail(day: "2026-11-10", timeZone: shanghai)
        #expect(detail != nil)
        guard let detail else { return }
        #expect(detail.day == "2026-11-10")
        #expect(detail.timeZoneIdentifier == "Asia/Shanghai")
        #expect(detail.hourly.count == 24)
        #expect(detail.hourly[0].hasData && detail.hourly[0].completion == 30)
        #expect(!detail.hourly[1].hasData && detail.hourly[1].completion == 0)
        #expect(detail.hourly[5].hasData && detail.hourly[5].completion == 50)
        #expect(detail.hourly[23].hasData && detail.hourly[23].completion == 20)
        #expect(detail.totals.completion == 100)
        #expect(detail.seriesCount == 2)
        #expect(detail.byModel.map(\.model) == ["m", "n"])   // 80 > 20，completion 降序
        #expect(detail.byModel[0].seriesCount == 1)

        #expect(ledger.dayDetail(day: "2026-13-99", timeZone: shanghai) == nil)
        #expect(ledger.dayDetail(day: "不是日期", timeZone: shanghai) == nil)
    }

    /// 能耗版：分钟桶 → 本地小时均值瓦；kwh/coverage/avgWatts/peakWatts 同契约；
    /// nil = 无覆盖，绝不当 0。压着日界前一只桶（本地 11-09 23:30）不许混进 11-10。
    @Test func energyDayDetailHourlyLayout() {
        var ledger = EnergyLedger()
        func minuteKey(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int) -> Int {
            Int(date(utc, y, mo, d, h, mi).timeIntervalSince1970 / 60)
        }
        // 本地 00:30（UTC 11-09 16:30）：50 Wh / 600 s → 300 W。
        ledger.seedBucket(minuteKey: minuteKey(2026, 11, 9, 16, 30), wh: 50, coveredMs: 600_000, outputTokens: 0)
        // 本地 23:30（UTC 11-10 15:30）：10 Wh / 300 s → 120 W。
        ledger.seedBucket(minuteKey: minuteKey(2026, 11, 10, 15, 30), wh: 10, coveredMs: 300_000, outputTokens: 0)
        // 本地 11-09 23:30（UTC 11-09 15:30）：属于前一天。
        ledger.seedBucket(minuteKey: minuteKey(2026, 11, 9, 15, 30), wh: 999, coveredMs: 60_000, outputTokens: 0)

        #expect(ledger.dayDetail(day: "2026-13-99", timeZone: shanghai) == nil)
        let detail = ledger.dayDetail(day: "2026-11-10", timeZone: shanghai)
        #expect(detail != nil)
        guard let detail else { return }
        #expect(detail.hourly.count == 24)
        #expect(abs((detail.hourly[0] ?? -1) - 300) < 1e-9)
        #expect(detail.hourly[1] == nil)
        #expect(abs((detail.hourly[23] ?? -1) - 120) < 1e-9)
        #expect(abs((detail.kwh ?? -1) - 0.06) < 1e-9)              // (50+10)/1000
        #expect(abs(detail.coverage - 1.0 / 96.0) < 1e-12)           // 900 s / 86400 s
        #expect(abs((detail.avgWatts ?? -1) - 240) < 1e-9)           // 60 Wh×3.6e6 / 9e5 ms
        #expect(abs((detail.peakWatts ?? -1) - 300) < 1e-9)
    }

    /// 2026 年美国 DST：3-08（3 月第二个周日）春跳少一小时、11-01（11 月第一个周日）
    /// 秋跳多一小时。先用日历断言这两天确实 23/25 小时（年份抄错当场就红），
    /// 再要求 dayDetail 的 hourly 同长，且桶落对格子：春跳的 03:00 是第 2 格
    /// （02:xx 不存在）；秋跳的两个 01:00（EDT/EST）必须各占一格。
    @Test func dstDayLengthsAndHourMapping() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        let springDay = date(newYork, 2026, 3, 8)
        let fallDay = date(newYork, 2026, 11, 1)
        #expect(calendar.dateInterval(of: .day, for: springDay)!.duration == 23 * 3_600)
        #expect(calendar.dateInterval(of: .day, for: fallDay)!.duration == 25 * 3_600)

        var ledger = TokenLedger()
        // 春跳日：本地 03:00 EDT = UTC 07:00 → 第 2 格（00、01 各一格，02 被跳过）。
        bumpToken(&ledger, at: date(utc, 2026, 3, 8, 7, 10), completion: 30)
        let spring = ledger.dayDetail(day: "2026-03-08", timeZone: newYork)
        #expect(spring != nil)
        guard let spring else { return }
        #expect(spring.hourly.count == 23)
        #expect(spring.hourly[2].hasData && spring.hourly[2].completion == 30)
        #expect(!spring.hourly[3].hasData)

        // 秋跳日：01:10 EDT = UTC 05:10 → 第 1 格；01:10 EST = UTC 06:10 → 第 2 格。
        bumpToken(&ledger, at: date(utc, 2026, 11, 1, 5, 10), completion: 11)
        bumpToken(&ledger, at: date(utc, 2026, 11, 1, 6, 10), completion: 13)
        let fall = ledger.dayDetail(day: "2026-11-01", timeZone: newYork)
        #expect(fall != nil)
        guard let fall else { return }
        #expect(fall.hourly.count == 25)
        #expect(fall.hourly[1].completion == 11)
        #expect(fall.hourly[2].completion == 13)
        #expect(!fall.hourly[24].hasData)   // 本地 23:00 EST 那格没铺数据
        #expect(fall.totals.completion == 24)
    }

    /// 能耗 dayDetail 在秋跳日同样是 25 格。
    @Test func energyDayDetailDSTHourCount() {
        var ledger = EnergyLedger()
        // 本地 01:00 EST（UTC 06:10）播一只桶：10 Wh / 60 s → 600 W。
        ledger.seedBucket(
            minuteKey: Int(date(utc, 2026, 11, 1, 6, 10).timeIntervalSince1970 / 60),
            wh: 10, coveredMs: 60_000, outputTokens: 0
        )
        let detail = ledger.dayDetail(day: "2026-11-01", timeZone: newYork)
        #expect(detail != nil)
        guard let detail else { return }
        #expect(detail.hourly.count == 25)
        #expect(abs((detail.hourly[2] ?? -1) - 600) < 1e-9)
        #expect(abs((detail.kwh ?? -1) - 0.01) < 1e-9)
    }

    /// daily() 与 dayDetail() 对同一份桶必须对得上账：日合计 == 明细 totals。
    @Test func dailyEntryAgreesWithDayDetail() {
        var ledger = TokenLedger()
        // 本地（上海）11-10 的 00:30 与 08:30（UTC 11-09 16:30 / 11-10 00:30）。
        // 第三拍三个计数全没动 → 差分 0，不建桶（顺带钉住「0 增量不建桶」）。
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 10, completion: 0, cached: 0, at: date(utc, 2026, 11, 9, 16, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 110, completion: 30, cached: 10, at: date(utc, 2026, 11, 9, 16, 30).addingTimeInterval(60))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 110, completion: 30, cached: 10, at: date(utc, 2026, 11, 10, 0, 30))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 210, completion: 80, cached: 10, at: date(utc, 2026, 11, 10, 0, 30).addingTimeInterval(60))

        let now = date(utc, 2026, 11, 10, 12)
        let entries = ledger.daily(days: 1, now: now, timeZone: shanghai)
        #expect(entries.count == 1 && entries[0].day == "2026-11-10" && entries[0].hasData)
        #expect(entries[0].prompt == 200 && entries[0].completion == 80 && entries[0].cached == 10)
        let detail = ledger.dayDetail(day: entries[0].day, timeZone: shanghai)
        #expect(detail != nil)
        guard let detail else { return }
        #expect(detail.totals == TokenLedger.Totals(prompt: 200, completion: 80, cached: 10))
        #expect(detail.hourly.count == 24)
        #expect(detail.hourly[0].completion == 30)   // 本地 00:30 那格
        #expect(detail.hourly[8].completion == 50)   // 本地 08:30 那格
        #expect(detail.seriesCount == 1)
    }
}

// MARK: - 缺日与保留期

@Suite("按天查询：缺日与保留期")
struct DailyWindowTests {
    /// 缺日 hasData == false；days 可大于 35 天保留期——超期日全空。
    /// observe 的 prune 以**观测时刻**为基准：先铺 36 天前的数据再铺今天，
    /// 让最后一次 prune（以 now 为基准）把超期桶清掉，对应的日必须回「无记录」。
    @Test func dailyFillsMissingDaysAndBeyondRetention() {
        var ledger = TokenLedger()   // 保留 35 天
        let now = date(utc, 2026, 11, 10, 12)
        let old = now.addingTimeInterval(-36 * 86_400)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 0, cached: 0, at: old)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 90, cached: 0, at: old.addingTimeInterval(60))
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 40, cached: 0, at: now)
        ledger.observe(nodeID: nodeA, port: 8888, model: "m", prompt: 0, completion: 80, cached: 0, at: now.addingTimeInterval(60))   // +40

        let days = ledger.daily(days: 40, now: now, timeZone: utc)
        #expect(days.count == 40)   // 恰好 days 个，最旧在前、今天最后
        #expect(days[0].day == "2026-10-02")
        #expect(days[39].day == "2026-11-10" && days[39].hasData && days[39].completion == 40)
        #expect(days.prefix(39).allSatisfy { !$0.hasData && $0.completion == 0 })
    }

    /// 能耗版：31 天保留期外全空（kwh nil / coverage 0 / avgWatts nil）。
    /// seedBucket 不自己 prune（桶先还在），record() 收尾后超期桶消失。
    @Test func energyDailyBeyondRetentionAllEmpty() {
        var ledger = EnergyLedger()   // 保留 31 天
        let now = date(utc, 2026, 11, 10, 12)
        let staleMinute = Int(now.addingTimeInterval(-32 * 86_400).timeIntervalSince1970 / 60)
        ledger.seedBucket(minuteKey: staleMinute, wh: 100, coveredMs: 60_000, outputTokens: 0)
        ledger.seedBucket(minuteKey: Int(now.timeIntervalSince1970 / 60), wh: 24, coveredMs: 60_000, outputTokens: 0)
        #expect(ledger.buckets[staleMinute] != nil)
        // 收尾：record() 内含 prune，以 now+5 为基准把 32 天前的桶清掉。
        ledger.record(nodeID: nodeA, at: now.addingTimeInterval(5), watts: nil, outputTokens: nil,
                      countEnergy: false, countTokens: false)
        #expect(ledger.buckets[staleMinute] == nil)

        let days = ledger.daily(days: 35, now: now, timeZone: utc)
        #expect(days.count == 35)
        #expect(abs((days[34].kwh ?? -1) - 0.024) < 1e-9)   // 24 Wh / 1000
        #expect(days[34].coverage > 0 && days[34].avgWatts != nil)
        #expect(days.prefix(34).allSatisfy { $0.kwh == nil && $0.coverage == 0 && $0.avgWatts == nil })
    }
}

// MARK: - 播种与分钟曲线

@Suite("按天查询：seedBucket / minuteWatts")
struct SeedingTests {
    /// seedBucket 同分钟累加（不覆盖别人的账）、绝不自己 prune；
    /// 调用方收尾（record() 触发 prune）后，超期桶消失、近期桶保留。
    @Test func seedBucketAccumulatesAndDoesNotPrune() {
        var ledger = EnergyLedger()
        let now = date(utc, 2026, 11, 10, 12)
        let staleKey = Int(now.addingTimeInterval(-40 * 86_400).timeIntervalSince1970 / 60)
        let liveKey = Int(now.timeIntervalSince1970 / 60)
        ledger.seedBucket(minuteKey: staleKey, wh: 10, coveredMs: 60_000, outputTokens: 0)
        ledger.seedBucket(minuteKey: liveKey, wh: 10, coveredMs: 60_000, outputTokens: 5)
        ledger.seedBucket(minuteKey: liveKey, wh: 5, coveredMs: 30_000, outputTokens: 0)
        #expect(ledger.buckets[staleKey] != nil)               // 40 天前的桶还活着
        #expect(ledger.buckets[liveKey]?.wh == 15)             // 同分钟累加：10+5
        #expect(ledger.buckets[liveKey]?.coveredMs == 90_000)  // 60 s + 30 s
        #expect(ledger.buckets[liveKey]?.outputTokens == 5)

        ledger.record(nodeID: nodeA, at: now.addingTimeInterval(5), watts: nil, outputTokens: nil,
                      countEnergy: false, countTokens: false)   // 收尾 prune
        #expect(ledger.buckets[staleKey] == nil)
        #expect(ledger.buckets[liveKey]?.wh == 15)             // 近期桶不受影响
    }

    /// minuteWatts：窗口与 hourlyWatts 同口径（最后一格 = 当前小时），分钟桶直接
    /// 按键取值；窗口外/无覆盖分钟为 nil；长度恒为 hours×60。
    @Test func minuteWattsWindowAndNil() {
        var ledger = EnergyLedger()
        let now = date(utc, 2026, 11, 10, 5, 30)
        func seed(_ hour: Int, _ minute: Int, wh: Double, coveredMs: Double) {
            ledger.seedBucket(
                minuteKey: Int(date(utc, 2026, 11, 10, hour, minute).timeIntervalSince1970 / 60),
                wh: wh, coveredMs: coveredMs, outputTokens: 0
            )
        }
        seed(4, 45, wh: 20, coveredMs: 30_000)   // 20 Wh/30 s → 2400 W，索引 45
        seed(5, 10, wh: 10, coveredMs: 60_000)   // 10 Wh/60 s → 600 W，索引 70（当前小时）
        seed(3, 10, wh: 999, coveredMs: 60_000)  // 窗口 [04:00, 06:00) 之外

        let watts = ledger.minuteWatts(hours: 2, now: now)
        #expect(watts.count == 120)
        #expect(abs((watts[45] ?? -1) - 2_400) < 1e-9)
        #expect(abs((watts[70] ?? -1) - 600) < 1e-9)
        #expect(watts[44] == nil && watts[46] == nil && watts[0] == nil && watts[119] == nil)
    }
}
