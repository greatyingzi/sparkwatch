import Foundation

/// 固定时长的 GPU 历史环形缓冲。
///
/// 为什么是 8 小时：官方 Dashboard 的曲线页也只留这一段，而采集周期 2 s、
/// 去抖窗 1.5 s，8 小时约 1.9 万个点——够画「今天发生过什么」，又不至于把
/// 常驻进程的内存撑起来。改窗口只改 `maxAge`，`pointBudget` 会跟着重算。
///
/// 为什么点按节点分开存：一台 Mac 同时看多台 Spark，同一个时刻每台都有自己的
/// util/功率/温度，混在一起就画不出各自的曲线。
public struct GpuHistory: Sendable, Codable {
    public struct Point: Sendable, Equatable, Codable {
        public var at: Date
        public var utilPct: Double?
        public var powerW: Double?
        public var tempC: Double?
        /// Hottest ACPI zone at that moment. This is the number a Spark actually
        /// shuts down on, and it reads 8–15 °C above the GPU rail — the last
        /// sample before a documented hard power-off was 92.2 °C here versus
        /// 84 °C from `nvidia-smi`. Stored so a power-off leaves evidence behind
        /// on this Mac, which is the only place it can survive.
        public var acpitzC: Double?
        /// SM clock. Together with power and utilisation it is what separates a
        /// real wedge from a tensor-parallel rank waiting on its peer.
        public var smClockMHz: Double?

        public init(
            at: Date, utilPct: Double?, powerW: Double?, tempC: Double?,
            acpitzC: Double? = nil, smClockMHz: Double? = nil
        ) {
            self.at = at
            self.utilPct = utilPct
            self.powerW = powerW
            self.tempC = tempC
            self.acpitzC = acpitzC
            self.smClockMHz = smClockMHz
        }
    }

    /// 保留时长（秒）。默认 8 小时。
    public var maxAge: TimeInterval
    /// 去抖下限（秒）。默认 1.5 s：比 2 s 采集周期略小，既压掉同一拍的重复上报，
    /// 又不会把真实的快速变化（周期被 InferenceCadence 调快时）抹平。
    public var minGap: TimeInterval

    private var byNode: [UUID: [Point]] = [:]

    public init(maxAge: TimeInterval = 8 * 3600, minGap: TimeInterval = 1.5) {
        self.maxAge = maxAge
        self.minGap = minGap
    }

    /// 每个节点保留的采样上限。按 maxAge/minGap 推算再留 20% 余量：真实采样
    /// 间隔不会均匀恰好等于 minGap，偶尔会更密，余量就是留给这些毛刺的。
    public var pointBudget: Int {
        guard minGap > 0, maxAge > 0 else { return 0 }
        return Int((maxAge / minGap * 1.2).rounded(.up))
    }

    public mutating func record(_ point: Point, nodeID: UUID) {
        var list = byNode[nodeID] ?? []

        // 先按 maxAge 砍掉过期点（以新点的时间为基准，避免用墙上时钟）。
        let cutoff = point.at.addingTimeInterval(-maxAge)
        if let firstInside = list.firstIndex(where: { $0.at >= cutoff }) {
            list.removeFirst(firstInside)
        } else {
            list.removeAll()
        }

        // 再去抖。这里必须按 **minGap 时间槽** 归并，而不是简单地“和上一个点比太近
        // 就替换它”——后者永远攒不出第二个点：替换会把最后一个点的时间戳一起推
        // 前，于是下一个采样又落在 1.5 秒之内，循环下去整条曲线只剩一个点。
        // （实测：30 秒 58 次采样只留下 4 个点，端到端渲染出来才看见。）
        // 按槽归并才有想要的语义：采得更密 → 同一槽内取最新值，点数仍按 minGap
        // 推进，曲线既不变稀疏、也不无限增长。
        if let last = list.last, minGap > 0 {
            let lastSlot = (last.at.timeIntervalSinceReferenceDate / minGap).rounded(.down)
            let slot = (point.at.timeIntervalSinceReferenceDate / minGap).rounded(.down)
            if slot <= lastSlot {
                list[list.count - 1] = point
                byNode[nodeID] = list
                return
            }
        }
        list.append(point)

        // 双保险：即便去抖失效，也不会无限增长。
        let budget = pointBudget
        if budget > 0, list.count > budget { list.removeFirst(list.count - budget) }

        byNode[nodeID] = list
    }
    /// 窗口内的点，按时间升序。
    public func points(nodeID: UUID, window: TimeInterval, now: Date = Date()) -> [Point] {
        guard let list = byNode[nodeID] else { return [] }
        let cutoff = now.addingTimeInterval(-window)
        return list.filter { $0.at >= cutoff }
    }

    /// 把一段点重采样成 N 个桶（每条序列一个数组，nil = 该桶无数据），供画曲线用。
    /// 桶内取均值；跨桶断口（相邻采样间隔 > gapThreshold）必须保留为 nil，不得跨断口连线。
    ///
    /// 为什么断口要变成 nil：进程重启、SSH 断开、盒子休眠都会在序列里留下一个
    /// 几十秒到几小时的空洞。若两端各有一个值就顺手连一条线，会画出一条根本不
    /// 存在的高原——看上去像「一直满负载」，实际是「中间没人采样」。
    /// 断口后第一个桶判为 nil，就是为了在图上留下一道可见的缺口。
    public static func binned(
        _ points: [Point],
        into count: Int,
        window: TimeInterval,
        now: Date,
        gapThreshold: TimeInterval = 20
    ) -> (
        util: [Double?], power: [Double?], temp: [Double?],
        utilLow: [Double?], utilHigh: [Double?],
        maxUtil: Double?, maxPower: Double?, maxTemp: Double?
    ) {
        guard count > 0, window > 0 else { return ([], [], [], [], [], nil, nil, nil) }

        // **Snap the window to absolute bucket edges.**
        //
        // `now - window` slides with the clock, so a 2-second refresh moved *every*
        // bucket boundary by 2 seconds — every bucket re-averaged whatever it happened
        // to contain at that instant, and the whole curve shimmered in place instead of
        // scrolling (reported as 「每次刷新，所有曲线都在变，而不是平移」).
        //
        // Anchoring the edges to multiples of the bucket width makes bin membership
        // independent of *when* we look: within one bucket period the result is
        // identical, and when the clock crosses an edge every value moves left by
        // exactly one slot. The caller must pass a `window` that is a whole number of
        // buckets (it does), otherwise `start` would land mid-bucket.
        let width = window / Double(count)
        let snappedEnd = (now.timeIntervalSince1970 / width).rounded(.up) * width
        let end = Date(timeIntervalSince1970: snappedEnd)
        let start = end.addingTimeInterval(-window)
        let inWindow = points
            .filter { $0.at >= start && $0.at <= now }
            .sorted { $0.at < $1.at }

        var util = [Double?](repeating: nil, count: count)
        var power = [Double?](repeating: nil, count: count)
        var temp = [Double?](repeating: nil, count: count)
        // Min/max per bucket, not just the mean: on this hardware utilisation swings
        // between ~95 % and ~0 % within seconds (the engine idles between requests)
        // and the GPU rail swings tens of watts. A single mean line through that
        // reads as a picket fence; the envelope is what makes the swing legible
        // *and* keeps it honest (it is measured, not smoothed away).
        var utilLow = [Double?](repeating: nil, count: count)
        var utilHigh = [Double?](repeating: nil, count: count)

        // **单趟扫描。**
        //
        // 原来是「每个桶都对整段历史 filter 一次」：90 个桶 × 8 小时的点（约 1.9 万）
        // ≈ 170 万次比较外加 90 次数组分配，而这段代码跑在**主线程**上（SwiftUI body），
        // 每秒刷新都来一遍 —— 用 `sample` 抓到了它压在 main thread 上。
        // 改成一趟累积后，语义逐条不变：桶内断口、跨桶断口照样作废记 nil，
        // min–max 包络与均值照样只对开了出来到桶里的点算。
        var previous: Point?          // 上一个非空桶的最后一个点（跨桶断口判断）
        var index = -1                // 正在填的桶
        var lastInBucket: Point?
        var broken = false
        var sumUtil = 0.0, sumPower = 0.0, sumTemp = 0.0
        var nUtil = 0, nPower = 0, nTemp = 0
        var low: Double?
        var high: Double?

        func flush() {
            defer {
                if let lastInBucket { previous = lastInBucket }
                index = -1
                lastInBucket = nil
                broken = false
                sumUtil = 0; sumPower = 0; sumTemp = 0
                nUtil = 0; nPower = 0; nTemp = 0
                low = nil; high = nil
            }
            guard index >= 0, !broken else { return }
            if nUtil > 0 { util[index] = sumUtil / Double(nUtil) }
            if nPower > 0 { power[index] = sumPower / Double(nPower) }
            if nTemp > 0 { temp[index] = sumTemp / Double(nTemp) }
            utilLow[index] = low
            utilHigh[index] = high
        }

        for point in inWindow {
            // 末桶含右端（与旧实现 `isLast ? <= hi : < hi` 一致），所以把边界外的
            // 那一点折叠进最后一格，而不是丢掉。
            let slot = min(count - 1, Int(point.at.timeIntervalSince(start) / width))
            guard slot >= 0 else { continue }

            if slot != index {
                flush()
                index = slot
                // 与上一个桶的最后一个点隔得太远 → 这个桶作废。
                if let previous, point.at.timeIntervalSince(previous.at) > gapThreshold {
                    broken = true
                }
            } else if let lastInBucket, point.at.timeIntervalSince(lastInBucket.at) > gapThreshold {
                broken = true      // 桶内断口
            }

            if let value = point.utilPct {
                sumUtil += value; nUtil += 1
                low = min(low ?? value, value)
                high = max(high ?? value, value)
            }
            if let value = point.powerW { sumPower += value; nPower += 1 }
            if let value = point.tempC { sumTemp += value; nTemp += 1 }
            lastInBucket = point
        }
        flush()

        return (
            util, power, temp,
            utilLow, utilHigh,
            inWindow.compactMap(\.utilPct).max(),
            inWindow.compactMap(\.powerW).max(),
            inWindow.compactMap(\.tempC).max()
        )
    }

    /// 只对非 nil 的样本取均值；全是 nil 则返回 nil（而不是当成 0）。
    private static func mean(_ values: [Double?]) -> Double? {
        let present = values.compactMap { $0 }
        guard !present.isEmpty else { return nil }
        return present.reduce(0, +) / Double(present.count)
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> GpuHistory {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GpuHistory.self, from: data)
    }
}
