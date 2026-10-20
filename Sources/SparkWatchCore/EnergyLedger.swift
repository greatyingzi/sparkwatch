import Foundation

/// 机队能耗账本：瓦数模型 + 分钟桶积分 + 31 天保留。
///
/// 为什么整机瓦数必须建模：GB10 没有整机功率计。已实测——没有 RAPL
/// （`/sys/class/powercap` 为空）、没有 hwmon 功率传感器、没有 IMC/RAPL、
/// 没有 BMC，连 `nvidia-smi` 的 module power 都恒定返回 0。所以整机瓦数只能
/// 由唯一的那套拟合模型（`PowerEstimate`：GPU 轨 + CPU 占用×频率）给出。
///
/// 为什么按分钟桶积分而不是累计一个总 Wh：24 小时 / 31 天两个窗口都要能「滑窗」
/// 查询，只存一个累计值就无法扣除过期部分。分钟桶（最多 44640 个）内存可忽略，
/// 而 `hourlyWatts` 直接按桶聚合就能算。
///
/// 为什么不记账「计数器倒退」：引擎重启后 token 计数归零，若直接相减就是巨大的
/// 负数——电还在照用，但 token 账目会被一次重启永久污染。规矩与 TokenLedger 一致：
/// 倒退/重启一律只重新取基线。
public struct EnergyLedger: Sendable, Codable {
    public struct Snapshot: Sendable, Equatable {
        /// 最近 30 秒瓦数均值。无采样则 nil。
        public var currentWatts: Double?
        public var energy24hKWh: Double
        public var energy31dKWh: Double
        /// 24h 内 Wh ÷ 该窗口内确实被覆盖的输出 token。没有覆盖 token → nil。
        public var whPerOutputToken: Double?
        public var coveredOutputTokens24h: Double
        /// 0…1：24h 窗口里有多少比例的时间真的有覆盖。
        public var coverage24h: Double
        public var coverage31d: Double

        public init(
            currentWatts: Double? = nil,
            energy24hKWh: Double = 0,
            energy31dKWh: Double = 0,
            whPerOutputToken: Double? = nil,
            coveredOutputTokens24h: Double = 0,
            coverage24h: Double = 0,
            coverage31d: Double = 0
        ) {
            self.currentWatts = currentWatts
            self.energy24hKWh = energy24hKWh
            self.energy31dKWh = energy31dKWh
            self.whPerOutputToken = whPerOutputToken
            self.coveredOutputTokens24h = coveredOutputTokens24h
            self.coverage24h = coverage24h
            self.coverage31d = coverage31d
        }
    }

    private struct Bucket: Codable {
        var wh: Double = 0            // 这一分钟内积出的电（Wh）
        var coveredMs: Double = 0     // 这一分钟内被采样连续覆盖的毫秒
        var outputTokens: Double = 0  // 这一分钟内（被覆盖的）输出 token 增量
    }

    private struct NodeState: Codable {
        var at: Date
        var watts: Double?
        var outputTokens: Double?
    }

    private struct RecentSample: Codable {
        var at: Date
        var value: Double
    }

    /// 保留窗口（秒），默认 31 天。
    public var retention: TimeInterval
    /// 相邻采样间隔超过它即视为断口：不积分、也不计覆盖。默认 10 s——采集周期 2 s，
    /// 容忍四五次丢包，而不把真正的空洞当成连续。
    public var maxGap: TimeInterval

    private var buckets: [Int: Bucket] = [:]
    private var nodes: [UUID: NodeState] = [:]
    private var recent: [RecentSample] = []

    /// 31 天 × 1440 = 44640 个分钟桶，再留一天余量防边界抖动。
    private static let maxBuckets = 46_080
    /// `currentWatts` 的均值窗口。
    private static let recentWindow: TimeInterval = 30

    public init(retention: TimeInterval = 31 * 24 * 3600, maxGap: TimeInterval = 10) {
        self.retention = retention
        self.maxGap = maxGap
    }

    /// 记录一次采样。
    ///
    /// - Parameters:
    ///   - watts: 整机瓦数（通常来自 `estimateWatts`）。nil 表示这一刻没有可信瓦数。
    ///   - outputTokens: 该节点的**累计**输出 token 计数（内部差分成增量）。nil 表示不记账。
    ///   - countEnergy: 只对 head/standalone 计数。worker 传 false——否则一台机队的电
    ///     会被 head 和 worker 各算一遍，凭空翻倍。
    ///   - countTokens: 是否记 token。引擎不报 token 的节点传 false。
    public mutating func record(
        nodeID: UUID,
        at now: Date,
        watts: Double?,
        outputTokens: Double?,
        countEnergy: Bool = true,
        countTokens: Bool = true
    ) {
        if let previous = nodes[nodeID] {
            let dtMs = now.timeIntervalSince(previous.at) * 1000
            // 间隔为负（时钟回拨）或超过 maxGap（断口）都不积分。
            if dtMs >= 0, dtMs <= maxGap * 1000 {
                var wh = 0.0
                var coveredMs = 0.0
                var tokens = 0.0
                if countEnergy {
                    coveredMs = dtMs
                    if let watts { wh = watts * dtMs / 3_600_000 }
                }
                if countTokens, let outputTokens {
                    tokens = Self.delta(new: outputTokens, old: previous.outputTokens)
                }
                if wh != 0 || coveredMs != 0 || tokens != 0 {
                    addToBucket(now, wh: wh, coveredMs: coveredMs, tokens: tokens)
                }
            }
        }

        var state = nodes[nodeID] ?? NodeState(at: now, watts: nil, outputTokens: nil)
        state.at = now
        state.watts = watts
        // token 计数为 nil 时保留旧基线（下一次仍从旧基线差分），避免 nil 把基线抹掉。
        if let outputTokens { state.outputTokens = outputTokens }
        nodes[nodeID] = state

        if countEnergy, let watts { pushRecent(at: now, value: watts) }
        prune(now)
    }

    public func snapshot(now: Date) -> Snapshot {
        let cut24 = now.addingTimeInterval(-24 * 3600).timeIntervalSince1970
        let cut31 = now.addingTimeInterval(-retention).timeIntervalSince1970

        var wh24 = 0.0, wh31 = 0.0
        var covered24 = 0.0, covered31 = 0.0
        var tokens24 = 0.0
        // 按 key 排序后再累加：字典的遍历顺序在 encode/decode 之间会变，浮点加法
        // 又不是严格结合的——不排序的话同一个账本序列化再读回来，最后一位会飘。
        for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
            let at = Double(key) * 60
            if at >= cut24 {
                wh24 += bucket.wh
                covered24 += bucket.coveredMs
                tokens24 += bucket.outputTokens
            }
            if at >= cut31 {
                wh31 += bucket.wh
                covered31 += bucket.coveredMs
            }
        }

        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        let inWindow = recent.filter { $0.at >= cutoff }
        let currentWatts = inWindow.isEmpty
            ? nil
            : inWindow.reduce(0) { $0 + $1.value } / Double(inWindow.count)

        let coverage24 = clamp(covered24 / (24 * 3600 * 1000), 0, 1)
        let coverage31 = clamp(covered31 / (retention * 1000), 0, 1)

        return Snapshot(
            currentWatts: currentWatts,
            energy24hKWh: wh24 / 1000,
            energy31dKWh: wh31 / 1000,
            whPerOutputToken: tokens24 > 0 ? wh24 / tokens24 : nil,
            coveredOutputTokens24h: tokens24,
            coverage24h: coverage24,
            coverage31d: coverage31
        )
    }

    /// 最近 N 小时每小时的均值瓦数（缺数据的钟头为 nil），供 24 根直方图用。
    /// 索引 0 = 最早的一小时，索引 hours-1 = 当前小时；均值 = 该小时 Wh × 3.6e6 / 覆盖毫秒。
    public func hourlyWatts(hours: Int, now: Date) -> [Double?] {
        guard hours > 0 else { return [] }
        let currentHourStart = floor(now.timeIntervalSince1970 / 3600) * 3600
        var out = [Double?](repeating: nil, count: hours)
        for index in 0..<hours {
            let start = currentHourStart - Double(hours - 1 - index) * 3600
            let end = start + 3600
            var wh = 0.0
            var coveredMs = 0.0
            for (key, bucket) in buckets.sorted(by: { $0.key < $1.key }) {
                let at = Double(key) * 60
                if at >= start, at < end {
                    wh += bucket.wh
                    coveredMs += bucket.coveredMs
                }
            }
            out[index] = coveredMs > 0 ? wh * 3_600_000 / coveredMs : nil
        }
        return out
    }

    /// GB10 没有整机功率计（已实测：无 RAPL、无 hwmon 功率传感器、无 IMC/RAPL、无 BMC），
    /// 所以整机瓦数必须建模。这个公式就是模型本体，系数可调。
    ///
    /// 口径：
    ///   cpuWatts = cpuIdleW + (cpuTdpW − cpuIdleW) × clamp(cpu%, 0, 100) / 100
    ///   watts    = clamp(gpuW + cpuWatts + peripheralW, 0, capW)
    /// gpuW 或 cpu% 为 nil → 返回 nil（不造数）。`+23 W` 是 CX7/网卡/盘等外设的固定底。
    /// 整机瓦数：**只**走那一套模型（`PowerEstimate`），这里只是薄封装。
    ///
    /// 这里以前是第二套公式（`GPU + 5.2 + 59.8×CPU% + 23`，CPU 按 65W TDP），
    /// 于是同一个时刻卡片上显示 148W、电费账本记 117W —— 两个数都叫"整机功耗"，
    /// 只有一个能在设置里校准。现在两个消费者吃同一个读数。
    public static func estimateWatts(
        gpuW: Double?,
        cpuUsagePct: Double?,
        cpuFreqRatio: Double? = nil,
        model: PowerEstimate = PowerEstimate()
    ) -> Double? {
        model.estimate(gpuW: gpuW, cpuUsagePct: cpuUsagePct, cpuFreqRatio: cpuFreqRatio)?.wallW
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> EnergyLedger {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EnergyLedger.self, from: data)
    }

    // MARK: - Internals

    private mutating func addToBucket(_ now: Date, wh: Double, coveredMs: Double, tokens: Double) {
        let key = Int(floor(now.timeIntervalSince1970 / 60))
        var bucket = buckets[key] ?? Bucket()
        bucket.wh += wh
        bucket.coveredMs += coveredMs
        bucket.outputTokens += tokens
        buckets[key] = bucket
    }

    private mutating func pushRecent(at now: Date, value: Double) {
        recent.append(RecentSample(at: now, value: value))
        let cutoff = now.addingTimeInterval(-Self.recentWindow)
        recent.removeAll { $0.at < cutoff }
        if recent.count > 256 { recent.removeFirst(recent.count - 256) }
    }

    private mutating func prune(_ now: Date) {
        let cutoff = now.addingTimeInterval(-retention).timeIntervalSince1970
        buckets = buckets.filter { Double($0.key) * 60 >= cutoff }
        if buckets.count > Self.maxBuckets {
            for key in buckets.keys.sorted().prefix(buckets.count - Self.maxBuckets) {
                buckets.removeValue(forKey: key)
            }
        }
    }

    /// 计数器差分。首次观察（无基线）、倒退（重启）、跳变过大（换引擎）都返回 0
    /// 并要求重新取基线，绝不产生负数。
    private static func delta(new value: Double, old: Double?) -> Double {
        guard let old else { return 0 }
        let d = value - old
        if d < 0 { return 0 }
        if d > 1e9 { return 0 }
        return d
    }

    private func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
