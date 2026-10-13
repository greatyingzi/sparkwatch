import Foundation

/// 按模型记 token 账：只记**增量**，且倒退/重启一律重新取基线。
///
/// 为什么一切以 UTC 日/小时分桶：引擎重启、时区切换、跨机汇总对账时，本地时区
/// 会把「今天」切在同一个 UTC 瞬间的不同偏移上，摘要对不上账。参考实现也用 UTC，
/// 这里保持一致。
///
/// 为什么同一 (nodeID, port) 是一条独立 series：跨机部署里同一个模型会在多台
/// 机器、多个端口各跑一份，各自的累计计数器互不相干；只有按 series 分别差分，
/// 才不会把 A 机的累计值减到 B 机的基线上，算出一个凭空的负增量。
public struct TokenLedger: Sendable, Codable {
    public struct Totals: Sendable, Equatable {
        public var prompt: Double
        public var completion: Double
        public var cached: Double

        public init(prompt: Double, completion: Double, cached: Double) {
            self.prompt = prompt
            self.completion = completion
            self.cached = cached
        }
    }

    public struct ModelRow: Sendable, Equatable {
        public var model: String
        public var prompt: Double
        public var completion: Double
        public var cached: Double
        public var seriesCount: Int

        public init(
            model: String, prompt: Double, completion: Double, cached: Double, seriesCount: Int
        ) {
            self.model = model
            self.prompt = prompt
            self.completion = completion
            self.cached = cached
            self.seriesCount = seriesCount
        }
    }

    public enum Range: String, CaseIterable, Sendable {
        case today, week, twoWeeks, month, all

        public var label: String {
            switch self {
            case .today: "今天"
            case .week: "最近 7 天"
            case .twoWeeks: "最近 14 天"
            case .month: "最近 30 天"
            case .all: "全部"
            }
        }
    }

    /// 一条 series = 一个 (nodeID, port)。
    private struct SeriesKey: Codable, Hashable {
        var nodeID: UUID
        var port: Int
    }

    private struct Counts: Codable, Equatable {
        var prompt: Double = 0
        var completion: Double = 0
        var cached: Double = 0
    }

    private struct SeriesState: Codable {
        var lastPrompt: Double?
        var lastCompletion: Double?
        var lastCached: Double?
        var lastModel: String?
        var lastAt: Date?
        /// 模型 → UTC 小时索引 → 该小时内的 token 增量。
        var models: [String: [Int: Counts]] = [:]
    }

    public var retentionDays: Int
    public var maxSeries: Int
    public var maxModelsPerSeries: Int

    private var series: [SeriesKey: SeriesState] = [:]

    public init(retentionDays: Int = 35, maxSeries: Int = 200, maxModelsPerSeries: Int = 100) {
        self.retentionDays = retentionDays
        self.maxSeries = maxSeries
        self.maxModelsPerSeries = maxModelsPerSeries
    }

    /// 观察**累计**计数器。同一 (nodeID, port) 是一条 series。
    public mutating func observe(
        nodeID: UUID,
        port: Int,
        model: String?,
        prompt: Double?,
        completion: Double?,
        cached: Double?,
        at now: Date
    ) {
        let key = SeriesKey(nodeID: nodeID, port: port)
        var state = series[key]
            ?? SeriesState(
                lastPrompt: nil, lastCompletion: nil, lastCached: nil, lastModel: nil, lastAt: nil
            )

        let label: String = {
            if let model, !model.isEmpty { return model }
            return "unknown"
        }()

        let (rawPrompt, nextPrompt) = Self.delta(new: prompt, old: state.lastPrompt)
        let (deltaCompletion, nextCompletion) = Self.delta(new: completion, old: state.lastCompletion)
        let (rawCached, nextCached) = Self.delta(new: cached, old: state.lastCached)

        var deltaPrompt = rawPrompt
        let deltaCached = rawCached
        // cached 不可能多于 prompt：超出的部分一律并进 prompt，免得出现
        // 「命中的缓存比总 prompt 还多」这种自相矛盾的账。
        if deltaCached > deltaPrompt {
            deltaPrompt += (deltaCached - deltaPrompt)
        }

        state.lastPrompt = nextPrompt
        state.lastCompletion = nextCompletion
        state.lastCached = nextCached
        state.lastModel = label
        state.lastAt = now

        if deltaPrompt != 0 || deltaCompletion != 0 || deltaCached != 0 {
            let hourKey = Int(floor(now.timeIntervalSince1970 / 3600))
            var hours = state.models[label] ?? [:]
            var counts = hours[hourKey] ?? Counts()
            counts.prompt += deltaPrompt
            counts.completion += deltaCompletion
            counts.cached += deltaCached
            hours[hourKey] = counts
            state.models[label] = hours
        }

        // 保留天数：砍掉过旧的小时桶。
        let minHour = Int(
            floor(now.addingTimeInterval(-Double(retentionDays) * 86400).timeIntervalSince1970 / 3600)
        )
        for (model, hours) in state.models {
            let kept = hours.filter { $0.key >= minHour }
            if kept.isEmpty { state.models.removeValue(forKey: model) } else { state.models[model] = kept }
        }
        // 每 series 模型数上限：超出丢「最近一次出现最旧」的模型。
        if state.models.count > maxModelsPerSeries {
            let byRecency = state.models.sorted {
                ($0.value.keys.max() ?? Int.min) < ($1.value.keys.max() ?? Int.min)
            }
            for (model, _) in byRecency.prefix(state.models.count - maxModelsPerSeries) {
                state.models.removeValue(forKey: model)
            }
        }

        series[key] = state

        // series 数上限：超出丢最久没更新的一条。
        if series.count > maxSeries {
            let byRecency = series.sorted {
                ($0.value.lastAt ?? .distantPast) < ($1.value.lastAt ?? .distantPast)
            }
            for (key, _) in byRecency.prefix(series.count - maxSeries) {
                series.removeValue(forKey: key)
            }
        }
    }

    public func totals(_ range: Range, now: Date) -> Totals {
        let start = startHour(range, now: now)
        var totals = Totals(prompt: 0, completion: 0, cached: 0)
        for state in series.values {
            for hours in state.models.values {
                for (hour, counts) in hours where start == nil || hour >= start! {
                    totals.prompt += counts.prompt
                    totals.completion += counts.completion
                    totals.cached += counts.cached
                }
            }
        }
        return totals
    }

    /// 按模型汇总，completion 降序。
    public func byModel(_ range: Range, now: Date) -> [ModelRow] {
        let start = startHour(range, now: now)
        var aggregate: [String: (prompt: Double, completion: Double, cached: Double, series: Set<SeriesKey>)] = [:]
        for (key, state) in series {
            for (model, hours) in state.models {
                for (hour, counts) in hours where start == nil || hour >= start! {
                    var entry = aggregate[model] ?? (0, 0, 0, [])
                    entry.prompt += counts.prompt
                    entry.completion += counts.completion
                    entry.cached += counts.cached
                    entry.series.insert(key)
                    aggregate[model] = entry
                }
            }
        }
        return aggregate
            .map {
                ModelRow(
                    model: $0.key,
                    prompt: $0.value.prompt,
                    completion: $0.value.completion,
                    cached: $0.value.cached,
                    seriesCount: $0.value.series.count
                )
            }
            .sorted { $0.completion > $1.completion }
    }

    /// 最近 N 天的 completion，按 UTC 日（yyyy-MM-dd），缺日为 0；索引 0 = 最早一天。
    public func dailyCompletion(days: Int, now: Date) -> [(day: String, completion: Double)] {
        guard days > 0 else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        // hourKey / 24 == UTC 日索引（时间戳为正，整除即是 floor）。
        var byDay: [Int: Double] = [:]
        for state in series.values {
            for hours in state.models.values {
                for (hour, counts) in hours { byDay[hour / 24, default: 0] += counts.completion }
            }
        }

        let todayStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / 86400) * 86400)
        var out: [(day: String, completion: Double)] = []
        for offset in stride(from: days - 1, through: 0, by: -1) {
            let dayStart = todayStart.addingTimeInterval(-Double(offset) * 86400)
            let dayIndex = Int(floor(dayStart.timeIntervalSince1970 / 86400))
            out.append((day: formatter.string(from: dayStart), completion: byDay[dayIndex] ?? 0))
        }
        return out
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> TokenLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(TokenLedger.self, from: data)
    }

    // MARK: - Internals

    /// 该 range 的起始 UTC 小时索引；`.all` 返回 nil（不设下界）。
    private func startHour(_ range: Range, now: Date) -> Int? {
        switch range {
        case .all:
            return nil
        case .today:
            return Int(floor(now.timeIntervalSince1970 / 86400) * 24)
        case .week:
            return Int(floor((now.timeIntervalSince1970 - 7 * 86400) / 3600))
        case .twoWeeks:
            return Int(floor((now.timeIntervalSince1970 - 14 * 86400) / 3600))
        case .month:
            return Int(floor((now.timeIntervalSince1970 - 30 * 86400) / 3600))
        }
    }

    /// 计数器差分。首次观察、倒退（重启/换模型）、跳变过大（换引擎）都返回 0 并重新取基线。
    private static func delta(new value: Double?, old: Double?) -> (Double, Double?) {
        guard let value else { return (0, old) }
        guard let old else { return (0, value) }
        let d = value - old
        if d < 0 { return (0, value) }
        if d > 1e9 { return (0, value) }
        return (d, value)
    }
}
