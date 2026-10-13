import Foundation
import Testing
@testable import SparkWatchCore

/// Regression tests for the sampling store, written after an end-to-end render
/// caught what the unit tests had missed: a 30-second live run made 58 calls into
/// `record` and the curve still held **4 points**.
///
/// The lesson worth keeping: a per-call assertion ("a new value within minGap
/// replaces the previous one") can pass while the *cumulative* behaviour is wrong,
/// because the bug only shows up over a sequence. Any buffer whose value is
/// "how many samples do I end up with" needs a test that feeds a sequence.
@Suite("GPU 历史缓冲（累积行为）")
struct GpuHistoryRegressionTests {
    private let node = UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!

    @Test func frequentSamplesStillAccumulatePoints() {
        var history = GpuHistory(maxAge: 3600, minGap: 1.5)
        let start = Date(timeIntervalSinceReferenceDate: 100_000)
        // 30 seconds at twice the minGap rate: the old implementation collapsed this
        // into a single moving point (it kept "replacing the last point" because the
        // timestamp moved forward with every replace).
        for step in 0..<60 {
            history.record(
                GpuHistory.Point(
                    at: start.addingTimeInterval(Double(step) * 0.5),
                    utilPct: Double(step),
                    powerW: 50,
                    tempC: 70
                ),
                nodeID: node
            )
        }
        let points = history.points(nodeID: node, window: 3600, now: start.addingTimeInterval(30))
        // 30 s ÷ 1.5 s = 20 slots; allow one either way for slot boundaries.
        #expect(points.count >= 19 && points.count <= 21)
        // The newest sample wins inside its slot — that is the whole point of
        // bucketing rather than dropping.
        #expect(points.last?.utilPct == 59)
    }

    @Test func slowerThanMinGapKeepsEverySample() {
        var history = GpuHistory(maxAge: 3600, minGap: 1.5)
        let start = Date(timeIntervalSinceReferenceDate: 200_000)
        for step in 0..<10 {
            history.record(
                GpuHistory.Point(at: start.addingTimeInterval(Double(step) * 2), utilPct: 10, powerW: 50, tempC: 70),
                nodeID: node
            )
        }
        let points = history.points(nodeID: node, window: 3600, now: start.addingTimeInterval(20))
        #expect(points.count == 10)
    }

    @Test func pointsOlderThanTheWindowAreDropped() {
        var history = GpuHistory(maxAge: 60, minGap: 1)
        let start = Date(timeIntervalSinceReferenceDate: 300_000)
        for step in 0..<30 {
            history.record(
                GpuHistory.Point(at: start.addingTimeInterval(Double(step) * 3), utilPct: 10, powerW: 50, tempC: 70),
                nodeID: node
            )
        }
        // 30 samples × 3 s = 90 s of history, maxAge 60 s → the first ~10 are gone.
        let points = history.points(nodeID: node, window: 3600, now: start.addingTimeInterval(87))
        #expect(points.count <= 21)
        #expect(points.count >= 19)
        #expect(points.allSatisfy { $0.at >= start.addingTimeInterval(87 - 60) })
    }

    @Test func aDifferentNodeIsATrackedSeparately() {
        var history = GpuHistory(maxAge: 3600, minGap: 1)
        let other = UUID()
        let start = Date(timeIntervalSinceReferenceDate: 400_000)
        history.record(GpuHistory.Point(at: start, utilPct: 11, powerW: 5, tempC: 60), nodeID: node)
        history.record(GpuHistory.Point(at: start, utilPct: 22, powerW: 6, tempC: 61), nodeID: other)
        #expect(history.points(nodeID: node, window: 60, now: start).first?.utilPct == 11)
        #expect(history.points(nodeID: other, window: 60, now: start).first?.utilPct == 22)
    }

    @Test func roundTripThroughJSONKeepsTheSeries() throws {
        var history = GpuHistory(maxAge: 3600, minGap: 1)
        let start = Date(timeIntervalSinceReferenceDate: 500_000)
        for step in 0..<5 {
            history.record(
                GpuHistory.Point(at: start.addingTimeInterval(Double(step) * 2), utilPct: Double(step) * 10,
                                 powerW: 40, tempC: 65),
                nodeID: node
            )
        }
        let restored = try GpuHistory.decode(try history.encoded())
        let points = restored.points(nodeID: node, window: 600, now: start.addingTimeInterval(8))
        #expect(points.count == 5)
        #expect(points.map(\.utilPct) == [0, 10, 20, 30, 40])
    }

    /// 曲线必须**平移**，不能"呼吸"。
    ///
    /// 用户报的现象：每次刷新所有曲线都在变，而不是平移。根因是窗口写成 `now - window`，
    /// 2 秒一次刷新就把每个桶的边界都推 2 秒，于是所有桶都在重新平均。
    ///
    /// 这条测试按 app 的节奏走时钟（2 秒一刷），验证性质的两半：
    ///   ① 同一桶周期内的刷新，输出逐元素相同；
    ///   ② 跨过一个桶边界，整体正好左移一格。
    /// 用**斜坡 + 周期**序列而不是常量序列：常量序列在边界滑动时也照样"通过"。
    @Test func refreshesWithinABucketAreIdenticalAndBoundariesShiftExactlyOneSlot() {
        let width = 20.0          // 30 分钟窗口 / 90 桶，与图表实际取值一致
        let window = 1800.0
        let count = 90
        // 起点故意不落在 20 秒格上（+3 秒），否则样本会正好压在桶边界上，
        // 让"末桶含右端、其余桶不含"的差别变成假失败。
        let base = Date(timeIntervalSince1970: 1_800_000_003)
        var points: [GpuHistory.Point] = []
        for step in 0..<(30 * 60 / 2) {           // 30 分钟，2 秒一个样本
            let at = base.addingTimeInterval(Double(step) * 2)
            points.append(GpuHistory.Point(
                at: at,
                utilPct: Double(30 + (step * 7) % 60),
                powerW: Double(100 + step % 50),
                tempC: Double(50 + step % 30)
            ))
        }
        guard let last = points.last?.at else {
            Issue.record("测试序列构造失败")
            return
        }
        // 最后一个样本之后的第一个桶边界；B 之后的一个桶周期 = (B, B+20]，故取 B+2 … B+18。
        let boundary = (last.timeIntervalSince1970 / width).rounded(.up) * width

        // ① 同一周期内连续刷新 → 必须完全相同。
        let reference = GpuHistory.binned(
            points, into: count, window: window,
            now: Date(timeIntervalSince1970: boundary + 2)
        )
        var ticks = 2.0
        while ticks <= width - 2 {
            let later = GpuHistory.binned(
                points, into: count, window: window,
                now: Date(timeIntervalSince1970: boundary + ticks)
            )
            #expect(later.util == reference.util, "桶周期内刷新不应改变均值曲线（+\(ticks)s）")
            #expect(later.utilLow == reference.utilLow, "包络下沿不应改变（+\(ticks)s）")
            #expect(later.utilHigh == reference.utilHigh, "包络上沿不应改变（+\(ticks)s）")
            #expect(later.power == reference.power, "功耗曲线不应改变（+\(ticks)s）")
            #expect(later.temp == reference.temp, "温度曲线不应改变（+\(ticks)s）")
            ticks += 2
        }

        // ② 跨过边界 → 整体左移一格：第 i 格应等于原来第 i+1 格。
        let before = GpuHistory.binned(
            points, into: count, window: window,
            now: Date(timeIntervalSince1970: boundary + width - 2)
        )
        let after = GpuHistory.binned(
            points, into: count, window: window,
            now: Date(timeIntervalSince1970: boundary + width + 2)
        )
        #expect(
            Array(after.util.dropLast()) == Array(before.util.dropFirst()),
            "跨桶边界后曲线应整体左移一格（只有最右侧那一格是新的）"
        )
    }

    /// 图表几何必须**只在「又攒满一个桶」时变一次**。
    ///
    /// `available`（已有数据跨度）每个采样周期都在长；如果窗口或桶宽跟着它连续变，
    /// 整张图就会每次刷新重新缩放 —— 这正是「曲线不平移」的另一半原因。
    @Test func chartGeometryOnlyChangesWhenAWholeBucketElapses() {
        let requested = 1800.0                                            // 30 分钟档
        let quantum = GpuChartScale.bucketSeconds(requested: requested)
        #expect(quantum == 20, "30 分钟 / 90 桶应为 20 秒，实际 \(quantum)")

        // 从「已有 17 分钟数据」开始，按 2 秒一步推进一分钟。
        var previous = GpuChartScale.resolve(requested: requested, available: 17 * 60)
        #expect(previous.buckets == 51)
        var changes = 0
        for step in 1...30 {
            let now = GpuChartScale.resolve(
                requested: requested,
                available: 17 * 60 + Double(step) * 2
            )
            if now.window != previous.window {
                changes += 1
                #expect(
                    abs((now.window - previous.window) - quantum) < 1e-9,
                    "窗口一次只应挪一个桶宽（第 \(step) 步）"
                )
                #expect(now.buckets == previous.buckets + 1, "桶数一次只应加一（第 \(step) 步）")
            } else {
                #expect(now.buckets == previous.buckets, "几何不变时桶数也不应变（第 \(step) 步）")
                #expect(now.bucketSeconds == previous.bucketSeconds)
            }
            previous = now
        }
        #expect(changes == 3, "60 秒 / 20 秒桶宽应恰好变 3 次，实际 \(changes)")
    }

    /// 数据攒满后几何必须钉在请求跨度上（不再 zoom）。
    @Test func chartGeometrySettlesAtTheRequestedSpan() {
        let requested = 3600.0
        let full = GpuChartScale.resolve(requested: requested, available: requested)
        #expect(full.window == requested)
        #expect(full.buckets == 90)
        #expect(full.zoomed == false)
        // 更多数据也不会把窗口撑大。
        let more = GpuChartScale.resolve(requested: requested, available: requested * 5)
        #expect(more.window == requested)
        #expect(more.buckets == 90)
    }

    /// The chart draws an envelope, so the extremes have to survive binning. This is
    /// the shape the real boxes produce: two samples inside ONE bucket that swing
    /// 10 → 90 (the engine idles between requests), where a mean-only chart drew a
    /// picket fence.
    @Test func binningKeepsThePerBucketEnvelope() {
        var history = GpuHistory(maxAge: 3600, minGap: 1)
        let start = Date(timeIntervalSinceReferenceDate: 600_000)
        history.record(
            GpuHistory.Point(at: start.addingTimeInterval(1), utilPct: 10, powerW: 20, tempC: 60),
            nodeID: node
        )
        history.record(
            GpuHistory.Point(at: start.addingTimeInterval(9), utilPct: 90, powerW: 80, tempC: 80),
            nodeID: node
        )
        let points = history.points(nodeID: node, window: 60, now: start.addingTimeInterval(10))
        let result = GpuHistory.binned(points, into: 6, window: 60, now: start.addingTimeInterval(60))

        guard let index = result.util.lastIndex(where: { $0 != nil }) else {
            Issue.record("没有桶拿到数据")
            return
        }
        #expect(result.util[index] == 50)       // mean of 10 and 90
        #expect(result.utilLow[index] == 10)
        #expect(result.utilHigh[index] == 90)
        // An envelope needs the same gap discipline as the line: a bucket with no
        // samples is nil in all three arrays, never a zero-height band.
        for bucket in result.util.indices where result.util[bucket] == nil {
            #expect(result.utilLow[bucket] == nil)
            #expect(result.utilHigh[bucket] == nil)
        }
    }

    /// 桶宽决定读出来的是「占空比」还是「锯齿」——这是折线图那次改造的核心判据。
    ///
    /// 同一段信号（忙 8 秒 / 闲 8 秒，各半，2 秒一个采样点），两种桶宽读出来是两个
    /// 完全不同的东西：
    ///   * 9 秒桶（改前：200 桶 / 30 分钟）→ 桶内几乎只有一个相位 → 均值贴着 0 或 95
    ///     → 画出来就是锯齿
    ///   * 20 秒桶（改后：90 桶 / 30 分钟）→ 桶内跨两个相位 → 均值就是那段的占空比
    @Test func bucketWidthDecidesDutyCycleVersusPicketFence() {
        var history = GpuHistory(maxAge: 3600, minGap: 1)
        let start = Date(timeIntervalSinceReferenceDate: 700_000)
        for step in 0..<900 {
            let at = start.addingTimeInterval(Double(step) * 2)
            let busy = (step * 2) % 16 < 8      // 8 秒忙 / 8 秒闲 → 占空比 50%
            history.record(
                GpuHistory.Point(at: at, utilPct: busy ? 95 : 0, powerW: busy ? 80 : 12, tempC: 70),
                nodeID: node
            )
        }
        let now = start.addingTimeInterval(1800)
        let points = history.points(nodeID: node, window: 3600, now: now)

        // 改后的 20 秒桶：读出来是占空比（≈50%），两个极端都不再出现。
        let coarse = GpuHistory.binned(points, into: 90, window: 1800, now: now)
        let coarseMid = coarse.util.compactMap { $0 }
        #expect(coarseMid.count > 80)
        if coarseMid.count > 80 {
            let middle = Array(coarseMid[10..<(coarseMid.count - 10)])
            let average = middle.reduce(0, +) / Double(middle.count)
            #expect(abs(average - 50) < 12)                        // ≈50% 占空比
            #expect(middle.allSatisfy { $0 > 15 && $0 < 85 })      // 不触两个极端
        }

        // 改前的 9 秒桶：同一段数据会给出贴着 0 与 95 的值 —— 这就是锯齿的来源。
        let fine = GpuHistory.binned(points, into: 200, window: 1800, now: now)
        let fineMid = fine.util.compactMap { $0 }
        #expect(fineMid.contains { $0 > 90 })
        #expect(fineMid.contains { $0 < 5 })
    }
}
