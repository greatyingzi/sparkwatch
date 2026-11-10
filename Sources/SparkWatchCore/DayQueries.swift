import Foundation

// 按天查询：把 UTC 小时/分钟桶在**查询侧**重新聚合成本地时区的“一天”。
//
// 为什么在查询侧换算时区而不是改记账桶：账本一切以 UTC 日/小时分桶（见
// TokenLedger 头注释——跨机对账、重启基线都依赖 UTC 口径），那是**存储口径**；
// 而“看看 11 月 9 日用了多少”是**展示口径**，用户所处的时区里“那天”从本地
// 零点开始。存储不动、查询重分组：两个口径各自正确，也无需迁移任何历史数据。
//
// 诚实性规矩（与 DailyBars“空桶画小竖条”一脉相承）：
//   * hasData == false / nil 表示“那天/那小时没有任何记录”，**不是**“用量为零”。
//     引擎关机一天和真的一天没流量，在图上必须是两种样子。
//   * 数值为 0 且 hasData == true，才是真“测得为零”。
//
// 性能规矩：daily()/dayDetail() 每次 UI 刷新都会被调（AppModel.mirrorLedgers），
// 必须**单遍**扫桶聚合；禁止“每个小时把全字典排一遍”的写法（hourlyWatts 的老
// 毛病，新代码不许再犯）。最坏规模 ~200 series × 100 模型 × 840 个小时桶。
//
// ⚠ 本文件是数据层/UI 层两个实现方并行开发的**契约**。public 签名不得改动；
//   标注 TODO(飞轮A) 的实现体由数据层实现方做实。

// MARK: - Token：某一天

/// 某一个本地日的 token 账明细。
public struct TokenDayDetail: Sendable, Equatable {
    /// 本地日里的一小时。completion 是该小时所有 series 的生成增量之和；
    /// hasData == false 表示该小时**任何 series 都没有桶**（引擎没跑/没上报），
    /// 不是“生成为零”。
    public struct Hour: Sendable, Equatable {
        public var completion: Double
        public var hasData: Bool

        public init(completion: Double, hasData: Bool) {
            self.completion = completion
            self.hasData = hasData
        }
    }

    /// 本地日，格式 yyyy-MM-dd（按查询时区）。
    public var day: String
    /// 查询时区标识，UI 拿它标注“UTC+8”之类。
    public var timeZoneIdentifier: String
    /// 当天三分量合计。
    public var totals: TokenLedger.Totals
    /// 当天按模型聚合，completion 降序（与 TokenLedger.byModel 同构，UI 表格直接复用）。
    public var byModel: [TokenLedger.ModelRow]
    /// 本地日 0 点起的逐小时生成量；长度 = 该日真实小时数（平年 24，DST 日 23/25）。
    public var hourly: [Hour]
    /// 当天出现过增量的 (nodeID, port) series 数：“那天有几条 series 在记账”。
    public var seriesCount: Int

    public init(
        day: String,
        timeZoneIdentifier: String,
        totals: TokenLedger.Totals,
        byModel: [TokenLedger.ModelRow],
        hourly: [Hour],
        seriesCount: Int
    ) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.totals = totals
        self.byModel = byModel
        self.hourly = hourly
        self.seriesCount = seriesCount
    }
}

extension TokenLedger {
    /// 按本地日聚合的 token 分量。缺日 hasData == false、数值为 0；索引 0 = 最早一天。
    public struct DailyEntry: Sendable, Equatable {
        public var day: String
        public var prompt: Double
        public var completion: Double
        public var cached: Double
        public var hasData: Bool

        public init(day: String, prompt: Double, completion: Double, cached: Double, hasData: Bool) {
            self.day = day
            self.prompt = prompt
            self.completion = completion
            self.cached = cached
            self.hasData = hasData
        }
    }

    /// 最近 days 个**本地日**的分量账，最旧在前、今天在最后（今天未结束）。
    /// days 可大于保留期（35 天）：超出的日 hasData == false。
    public func daily(days: Int, now: Date, timeZone: TimeZone = .current) -> [DailyEntry] {
        guard days > 0 else { return [] }
        let calendar = dayCalendar(timeZone)
        let formatter = dayFormatter(timeZone)
        // 「今天」与 totals(.today, timeZone:) 同一口径：查询时区的本地零点起。
        let todayStart = calendar.startOfDay(for: now)

        // 单遍扫桶（series × model × hour 一圈到底，不排序、不二次遍历）。
        // hourKey → 本地日串按 key 缓存：Formatter 只跑「出现过的不同小时」次
        // （≤ 保留期 × 24），而不是每只桶跑一次。
        var byDay: [String: (prompt: Double, completion: Double, cached: Double)] = [:]
        var dayOfHour: [Int: String] = [:]
        for state in series.values {
            for hours in state.models.values {
                for (hourKey, counts) in hours {
                    let day: String
                    if let cachedDay = dayOfHour[hourKey] {
                        day = cachedDay
                    } else {
                        // 桶按 UTC 整点对齐：hourKey × 3600 即桶起点，取它落在的本地日。
                        // （偏移非整小时的时区，压在日界上的桶按起点归属——契约口径
                        // 就是起点映射；上海/纽约/UTC 这类整小时偏移不受影响。）
                        day = formatter.string(from: Date(timeIntervalSince1970: Double(hourKey) * 3600))
                        dayOfHour[hourKey] = day
                    }
                    var entry = byDay[day] ?? (0, 0, 0)
                    entry.prompt += counts.prompt
                    entry.completion += counts.completion
                    entry.cached += counts.cached
                    byDay[day] = entry
                }
            }
        }

        var out: [DailyEntry] = []
        out.reserveCapacity(days)
        for offset in stride(from: days - 1, through: 0, by: -1) {
            // 用日历加法而不是秒数直加：本地日长有 23/24/25 小时三种，直加 86400 s
            // 会在 25 小时日把「明天」算成今天 23 点。
            guard let dayDate = calendar.date(byAdding: .day, value: -offset, to: todayStart) else { continue }
            let key = formatter.string(from: dayDate)
            if let found = byDay[key] {
                out.append(DailyEntry(day: key, prompt: found.prompt, completion: found.completion, cached: found.cached, hasData: true))
            } else {
                // 没有任何桶的日：hasData == false 是「无记录」，不是「用量为零」。
                out.append(DailyEntry(day: key, prompt: 0, completion: 0, cached: 0, hasData: false))
            }
        }
        return out
    }

    /// 某本地日的完整明细。day 无法解析（非法格式）返回 nil；
    /// 合法但无记录的日返回全空 detail（UI 据此渲染“那天没有记录”）。
    public func dayDetail(day: String, timeZone: TimeZone = .current) -> TokenDayDetail? {
        let calendar = dayCalendar(timeZone)
        let formatter = dayFormatter(timeZone)
        // 严格解析：DateFormatter 对「2026-11-9」这类松散输入也肯给日期，
        // 格式化回去比对一遍，保证 day 一定是规范 yyyy-MM-dd 才继续。
        guard let parsed = formatter.date(from: day),
              formatter.string(from: parsed) == day,
              let interval = calendar.dateInterval(of: .day, for: parsed)
        else { return nil }
        // 该日真实小时数：平年 24，春跳 23、秋跳 25。duration 取整而不是截断，
        // 防浮点尾差把 23.999… 吃成 22。
        let hourCount = Int((interval.duration / 3600).rounded())
        let dayStart = interval.start.timeIntervalSince1970

        var totals = TokenLedger.Totals(prompt: 0, completion: 0, cached: 0)
        var hourCompletion = [Double](repeating: 0, count: hourCount)
        var hourHasData = [Bool](repeating: false, count: hourCount)
        var byModelAggregate: [String: (prompt: Double, completion: Double, cached: Double, series: Set<SeriesKey>)] = [:]
        // hourKey → 日内小时序号，同样按 key 缓存（绝大多数桶不在这一天，
        // 缓存让越界桶只付一次除法的代价）。
        var indexOfHour: [Int: Int] = [:]
        var seriesInDay = Set<SeriesKey>()

        for (key, state) in series {
            for (model, hours) in state.models {
                for (hourKey, counts) in hours {
                    let index: Int
                    if let cachedIndex = indexOfHour[hourKey] {
                        index = cachedIndex
                    } else {
                        // 桶起点相对本地零点偏移几个整点；floor 保证日界之前的桶
                        // 得到负数（随后被 guard 挡掉），而不是被截断成 0 混进第 0 小时。
                        index = Int(floor((Double(hourKey) * 3600 - dayStart) / 3600))
                        indexOfHour[hourKey] = index
                    }
                    guard index >= 0, index < hourCount else { continue }
                    totals.prompt += counts.prompt
                    totals.completion += counts.completion
                    totals.cached += counts.cached
                    hourCompletion[index] += counts.completion
                    hourHasData[index] = true
                    var entry = byModelAggregate[model] ?? (0, 0, 0, [])
                    entry.prompt += counts.prompt
                    entry.completion += counts.completion
                    entry.cached += counts.cached
                    entry.series.insert(key)
                    byModelAggregate[model] = entry
                    seriesInDay.insert(key)
                }
            }
        }

        return TokenDayDetail(
            day: day,
            timeZoneIdentifier: timeZone.identifier,
            totals: totals,
            byModel: byModelAggregate
                .map {
                    ModelRow(
                        model: $0.key,
                        prompt: $0.value.prompt,
                        completion: $0.value.completion,
                        cached: $0.value.cached,
                        seriesCount: $0.value.series.count
                    )
                }
                .sorted { $0.completion > $1.completion },
            hourly: (0..<hourCount).map { TokenDayDetail.Hour(completion: hourCompletion[$0], hasData: hourHasData[$0]) },
            seriesCount: seriesInDay.count
        )
    }
}

// MARK: - 能耗：某一天

/// 某一个本地日的能耗明细。整台机队口径（与 EnergyLedger 一致：worker 不重复计电）。
public struct EnergyDayDetail: Sendable, Equatable {
    /// 本地日，格式 yyyy-MM-dd。
    public var day: String
    public var timeZoneIdentifier: String
    /// 当天 kWh；nil = 当天没有任何覆盖分钟（不是 0 kWh）。
    public var kwh: Double?
    /// 0…1：该日被采样覆盖的比例（coveredMs ÷ 当日毫秒数）。
    public var coverage: Double
    /// 覆盖时间加权的平均瓦数；无覆盖为 nil。
    public var avgWatts: Double?
    /// 各小时均值里的最大值（“那天最猛的一小时”）；无覆盖为 nil。
    public var peakWatts: Double?
    /// 本地日 0 点起的逐小时均值瓦数；长度 = 该日真实小时数（23/24/25），nil = 无覆盖。
    public var hourly: [Double?]

    public init(
        day: String,
        timeZoneIdentifier: String,
        kwh: Double?,
        coverage: Double,
        avgWatts: Double?,
        peakWatts: Double?,
        hourly: [Double?]
    ) {
        self.day = day
        self.timeZoneIdentifier = timeZoneIdentifier
        self.kwh = kwh
        self.coverage = coverage
        self.avgWatts = avgWatts
        self.peakWatts = peakWatts
        self.hourly = hourly
    }
}

extension EnergyLedger {
    /// 按本地日聚合的能耗。kwh == nil ⇔ coverage == 0（该日无覆盖）。
    public struct DailyEntry: Sendable, Equatable {
        public var day: String
        public var kwh: Double?
        public var coverage: Double
        public var avgWatts: Double?

        public init(day: String, kwh: Double?, coverage: Double, avgWatts: Double?) {
            self.day = day
            self.kwh = kwh
            self.coverage = coverage
            self.avgWatts = avgWatts
        }
    }

    /// 最近 days 个**本地日**的 kWh，最旧在前。days 可大于 31 天保留期。
    public func daily(days: Int, now: Date, timeZone: TimeZone = .current) -> [DailyEntry] {
        guard days > 0 else { return [] }
        let calendar = dayCalendar(timeZone)
        let formatter = dayFormatter(timeZone)
        let todayStart = calendar.startOfDay(for: now)

        // 单遍扫分钟桶（≤ 44640 只）：分钟 → 本地日串按 key 缓存。
        var byDay: [String: (wh: Double, coveredMs: Double)] = [:]
        var dayOfMinute: [Int: String] = [:]
        for (minuteKey, bucket) in buckets {
            let day: String
            if let cachedDay = dayOfMinute[minuteKey] {
                day = cachedDay
            } else {
                day = formatter.string(from: Date(timeIntervalSince1970: Double(minuteKey) * 60))
                dayOfMinute[minuteKey] = day
            }
            var entry = byDay[day] ?? (0, 0)
            entry.wh += bucket.wh
            entry.coveredMs += bucket.coveredMs
            byDay[day] = entry
        }

        var out: [DailyEntry] = []
        out.reserveCapacity(days)
        for offset in stride(from: days - 1, through: 0, by: -1) {
            // 日历加法跨 DST 才稳（本地日长 23/24/25 小时三种）。
            guard let dayDate = calendar.date(byAdding: .day, value: -offset, to: todayStart),
                  let interval = calendar.dateInterval(of: .day, for: dayDate)
            else { continue }
            let key = formatter.string(from: dayDate)
            guard let found = byDay[key] else {
                // 无覆盖日：kwh == nil（不是 0 kWh）、coverage 0、avgWatts nil。
                out.append(DailyEntry(day: key, kwh: nil, coverage: 0, avgWatts: nil))
                continue
            }
            // 覆盖率分母用该日真实毫秒数（DST 日 23/25 小时），与 dayDetail 同口径。
            let dayMs = interval.duration * 1000
            let hasCoverage = found.coveredMs > 0
            out.append(DailyEntry(
                day: key,
                kwh: hasCoverage ? found.wh / 1000 : nil,
                coverage: min(max(found.coveredMs / dayMs, 0), 1),
                avgWatts: hasCoverage ? found.wh * 3_600_000 / found.coveredMs : nil
            ))
        }
        return out
    }

    /// 某本地日的明细。day 无法解析返回 nil；无覆盖日返回 kwh == nil 的 detail。
    public func dayDetail(day: String, timeZone: TimeZone = .current) -> EnergyDayDetail? {
        let calendar = dayCalendar(timeZone)
        let formatter = dayFormatter(timeZone)
        // 与 token 版同一套严格解析：不规范 day 串一律 nil。
        guard let parsed = formatter.date(from: day),
              formatter.string(from: parsed) == day,
              let interval = calendar.dateInterval(of: .day, for: parsed)
        else { return nil }
        let hourCount = Int((interval.duration / 3600).rounded())   // 23/24/25
        let dayStart = interval.start.timeIntervalSince1970

        var whTotal = 0.0
        var coveredTotal = 0.0
        var hourWh = [Double](repeating: 0, count: hourCount)
        var hourCoveredMs = [Double](repeating: 0, count: hourCount)
        var indexOfMinute: [Int: Int] = [:]

        for (minuteKey, bucket) in buckets {
            let index: Int
            if let cachedIndex = indexOfMinute[minuteKey] {
                index = cachedIndex
            } else {
                // floor：日界之前的分钟得负数被 guard 挡掉，不会截断成第 0 小时。
                index = Int(floor((Double(minuteKey) * 60 - dayStart) / 3600))
                indexOfMinute[minuteKey] = index
            }
            guard index >= 0, index < hourCount else { continue }
            whTotal += bucket.wh
            coveredTotal += bucket.coveredMs
            hourWh[index] += bucket.wh
            hourCoveredMs[index] += bucket.coveredMs
        }

        // 每小时均值 = 该小时 Wh × 3.6e6 / 覆盖毫秒；无覆盖为 nil（不造 0 W）。
        let hourly: [Double?] = (0..<hourCount).map { index in
            hourCoveredMs[index] > 0 ? hourWh[index] * 3_600_000 / hourCoveredMs[index] : nil
        }
        return EnergyDayDetail(
            day: day,
            timeZoneIdentifier: timeZone.identifier,
            // kwh == nil ⇔ 全日无覆盖：没有读数的日子不是「0 度电」。
            kwh: coveredTotal > 0 ? whTotal / 1000 : nil,
            coverage: min(max(coveredTotal / (interval.duration * 1000), 0), 1),
            avgWatts: coveredTotal > 0 ? whTotal * 3_600_000 / coveredTotal : nil,
            peakWatts: hourly.compactMap { $0 }.max(),
            hourly: hourly
        )
    }

    /// 最近 hours 小时的逐分钟均值瓦数（长度 hours×60，索引 0 = 最早一分钟），
    /// nil = 该分钟无覆盖。供“点击小时柱看分钟曲线”用。
    public func minuteWatts(hours: Int, now: Date) -> [Double?] {
        guard hours > 0 else { return [] }
        // 与 hourlyWatts 同一窗口口径：最后一格 = 当前小时。
        let currentHourStart = floor(now.timeIntervalSince1970 / 3600) * 3600
        let firstMinuteKey = Int(currentHourStart / 60) - (hours - 1) * 60
        // 分钟桶本身就是分钟粒度：直接按键取，绝不扫全字典（hourlyWatts 的教训）。
        var out = [Double?](repeating: nil, count: hours * 60)
        for index in 0..<(hours * 60) {
            if let bucket = buckets[firstMinuteKey + index], bucket.coveredMs > 0 {
                out[index] = bucket.wh * 3_600_000 / bucket.coveredMs
            }
        }
        return out
    }

    /// 测试/演示播种：直接写一个分钟桶（绕过 record() 的差分与节点状态）。
    /// **不触发 prune**——调用方铺完数据自己收尾 prune 一次，避免 O(n)×调用次数。
    public mutating func seedBucket(minuteKey: Int, wh: Double, coveredMs: Double, outputTokens: Double) {
        // 累加进桶而不是覆盖（与 addToBucket 同一写法）：同一分钟可能已有 record()
        // 记下的账，覆盖会把别人的账抹掉。**刻意不 prune**——契约写明由调用方
        // 铺完数据收尾一次，否则铺 44640 只桶要白跑 44640 次 O(n)。
        var bucket = buckets[minuteKey] ?? Bucket()
        bucket.wh += wh
        bucket.coveredMs += coveredMs
        bucket.outputTokens += outputTokens
        buckets[minuteKey] = bucket
    }
}

// MARK: - 本地日口径工具（两个查询扩展共用；实现内部，非契约）

// 为什么固定公历 + en_US_POSIX：day 串要当 DailyEntry.day / 图表柱的稳定身份用，
// 绝不能随机器区域设置变样；时区一律来自查询参数，而不是机器当前时区。

private func dayCalendar(_ timeZone: TimeZone) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar
}

private func dayFormatter(_ timeZone: TimeZone) -> DateFormatter {
    let formatter = DateFormatter()
    formatter.calendar = dayCalendar(timeZone)
    formatter.timeZone = timeZone
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}
