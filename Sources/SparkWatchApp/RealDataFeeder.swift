import Foundation
import SparkWatchCore

/// 真实数据**循环投喂**（主人的思路：「真实占用都有记录，找一段反复投喂即可」）。
///
/// 两步语义：
///   1. **重定基**：账本里的点是过去时刻的——直接喂只会在「现在」接一小段尾巴，
///      中间全是洞。先把提取出的整段真实曲线整体平移到 [now−段长−投喂时长,
///      now−投喂时长]，能耗段（分钟桶里的真实整机瓦数）同样平移——窗口从此
///      被**真实形状连续铺满**。
///   2. **循环投喂**：从段末继续按 tick 循环取段内采样喂「现在」端——面板、
///      状态栏、活动边沿都是活的真实节奏。token 计数器沿段的每小时增量保持
///      **单调递增**（observe() 差分记账：倒退即重取基线，直接重放绝对值会
///      被当成重启而记零）。
///
/// 只喂内存（配 readOnly 实例），save() 门保证绝不落盘。能耗账本的分钟桶是
/// **机队聚合**的（record 按 countEnergy 头节点规则累计），所以能耗一律只记
/// primary 节点一份，绝不把机队瓦数按节点翻倍。
@MainActor
final class RealDataFeeder {
    private let ledgers: LedgerStore
    private let tick: TimeInterval
    private var segments: [UUID: [GpuHistory.Point]] = [:]
    private var primaryNodeID: UUID?
    private var segmentStartMinute = 0
    private var segmentMinutes = 1
    private var tokenPlan: [TokenPlan] = []
    private var counters: [String: (prompt: Double, completion: Double, cached: Double)] = [:]
    private var lastWatts: [UUID: Double] = [:]
    private var rebased = false
    private(set) var fedTicks = 0

    private struct TokenPlan {
        var nodeID: UUID
        var port: Int
        var model: String
        var perTickPrompt: Double
        var perTickCompletion: Double
        var perTickCached: Double
        var key: String { "\(nodeID.uuidString)|\(port)|\(model)" }
    }

    /// 从已加载账本提取最近 segmentSeconds 秒。无任何采样点返回 nil。
    init?(ledgers: LedgerStore, segmentSeconds: TimeInterval = 1800, tick: TimeInterval = 2) {
        self.ledgers = ledgers
        self.tick = tick
        let now = Date()
        // 段窗口锚定**数据自身的最新点**而不是墙上时钟：fixture 常比渲染时刻
        // 陈旧几分钟甚至更久，按 now 取段会整段取空（实测覆盖 0/90 桶）。
        var dataNow = Date.distantPast
        var allPoints: [UUID: [GpuHistory.Point]] = [:]
        for nodeID in ledgers.history.nodeIDs {
            let points = ledgers.history.points(nodeID: nodeID, window: 8 * 3600, now: now)
            if let last = points.last { dataNow = max(dataNow, last.at) }
            if !points.isEmpty { allPoints[nodeID] = points }
        }
        guard dataNow > .distantPast else { return nil }
        var segs: [UUID: [GpuHistory.Point]] = [:]
        for (nodeID, points) in allPoints {
            let sliced = points.filter { $0.at >= dataNow.addingTimeInterval(-segmentSeconds) }
            if !sliced.isEmpty { segs[nodeID] = sliced }
        }
        guard let primary = segs.values.first, !primary.isEmpty else { return nil }
        segments = segs
        primaryNodeID = segs.keys.sorted().first
        segmentStartMinute = Int(floor(primary[0].at.timeIntervalSince1970 / 60))
        segmentMinutes = max(1, Int((segmentSeconds / 60).rounded()))

        let segmentStartHour = Int(floor(primary[0].at.timeIntervalSince1970 / 3600))
        let segmentHours = max(1, Int((segmentSeconds / 3600).rounded(.up)))
        for slice in ledgers.tokenFeedSlice(startHour: segmentStartHour, hours: segmentHours) {
            guard slice.segmentPrompt > 0 || slice.segmentCompletion > 0 || slice.segmentCached > 0
            else { continue }
            let ticks = segmentSeconds / tick
            tokenPlan.append(TokenPlan(
                nodeID: slice.nodeID, port: slice.port, model: slice.model,
                perTickPrompt: slice.segmentPrompt / ticks,
                perTickCompletion: slice.segmentCompletion / ticks,
                perTickCached: slice.segmentCached / ticks
            ))
            counters["\(slice.nodeID.uuidString)|\(slice.port)|\(slice.model)"] = (
                slice.lastPrompt, slice.lastCompletion, slice.lastCached
            )
        }
    }

    /// 重定基 + 投喂 count 个 tick。重复调用安全（rebase 只做一次）。
    func feedTicks(_ count: Int) {
        let now = Date()
        if !rebased {
            rebaseSegment(end: now.addingTimeInterval(-Double(max(0, count)) * tick))
            rebased = true
        }
        for index in 0..<max(0, count) {
            feedTick(at: now.addingTimeInterval(Double(index) * tick))
        }
        fedTicks += max(0, count)
    }

    /// 把整段真实曲线（history 逐节点 + energy 机队瓦数）平移到
    /// [end − 段长, end]。段内每分钟无覆盖的能耗跳过——洞还是洞。
    private func rebaseSegment(end: Date) {
        guard let primary = primaryNodeID,
            let first = segments.values.first?.first,
            let last = segments.values.first?.last
        else { return }
        let shift = end.timeIntervalSince(last.at)
        for (nodeID, points) in segments {
            for point in points {
                var shifted = point
                shifted.at = point.at.addingTimeInterval(shift)
                ledgers.feedHistory(shifted, nodeID: nodeID)
            }
        }
        for minute in segmentStartMinute..<(segmentStartMinute + segmentMinutes) {
            guard let watts = ledgers.recordedWatts(atMinute: minute) else { continue }
            let shiftedAt = Date(timeIntervalSince1970: Double(minute) * 60 + shift)
            ledgers.feedEnergy(nodeID: primary, at: shiftedAt, watts: watts)
        }
        _ = first // 段首仅用于文档语义；真正的平移基准是段末。
    }

    private func feedTick(at now: Date) {
        for (nodeID, points) in segments {
            let point = points[fedTicks % points.count]
            ledgers.feedHistory(
                .init(at: now, utilPct: point.utilPct, powerW: point.powerW, tempC: point.tempC,
                      acpitzC: point.acpitzC, smClockMHz: point.smClockMHz),
                nodeID: nodeID
            )
        }
        // 能耗：机队瓦数一份（primary 记账），来源 = 段内循环到的真实分钟桶。
        if let primary = primaryNodeID {
            let minute = segmentStartMinute + (fedTicks % segmentMinutes)
            if let w = ledgers.recordedWatts(atMinute: minute) { lastWatts[primary] = w }
            ledgers.feedEnergy(nodeID: primary, at: now, watts: lastWatts[primary])
        }
        for plan in tokenPlan {
            var counter = counters[plan.key]!
            counter.prompt += plan.perTickPrompt
            counter.completion += plan.perTickCompletion
            counter.cached += plan.perTickCached
            counters[plan.key] = counter
            ledgers.feedTokens(
                nodeID: plan.nodeID, port: plan.port, model: plan.model,
                prompt: counter.prompt, completion: counter.completion, cached: counter.cached,
                at: now
            )
        }
        fedTicks += 1
    }
}
