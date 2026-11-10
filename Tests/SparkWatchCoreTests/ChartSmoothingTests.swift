import Foundation
import Testing
@testable import SparkWatchCore

// 展示层平滑的序列回归：全部用一段完整序列断言累积行为，不测单次调用。
// （「单点看是对的、整段看是错的」正是 GpuHistory 去抖当年翻车的形状。）

private let nodeA = UUID(uuidString: "00000000-0000-0000-0000-0000000000A0")!

@Suite("图表平滑（断口感知滑动平均）")
struct ChartSmoothingTests {
    @Test func radiusZeroIsIdentity() {
        let input: [Double?] = [1, nil, 3, 4]
        #expect(ChartSmoothing.movingAverage(input, radius: 0).map { $0 as Double? } as! [Double?] == input)
    }

    /// nil 是「没观测到」：平均绝不跨过 nil——nil 两侧各算各的段。
    @Test func gapsAreNotBridged() {
        let input: [Double?] = [10, 10, 10, nil, 50, 50, 50]
        let smoothed = ChartSmoothing.movingAverage(input, radius: 2)
        #expect(smoothed[3] == nil)
        // 左段窗口只见到 10；右段只见到 50——若跨段平均，这里会变成 30。
        #expect(smoothed[1] == 10)
        #expect(smoothed[5] == 50)
    }

    /// 常值序列平滑后不变：平的地方不许被平滑出坡。
    @Test func constantSeriesStaysFlat() {
        let input: [Double?] = Array(repeating: 42, count: 20)
        let smoothed = ChartSmoothing.movingAverage(input, radius: 4)
        for case let value? in smoothed { #expect(value == 42) }
    }

    /// 尖峰被压但不错位：单桶 100 尖峰在均值 0 的序列里被拉低、邻桶被抬高，
    /// 且峰值位置仍是最大值——形状保留，只是钝化。
    @Test func spikeDampenedButPositioned() {
        var input: [Double?] = Array(repeating: 0.0, count: 21)
        input[10] = 100
        let smoothed = ChartSmoothing.movingAverage(input, radius: 3)
        let values = smoothed.compactMap { $0 }
        #expect(values.max()! < 100)
        #expect(values.max()! > 20)   // 峰没被抹没
        let peakIndex = smoothed.firstIndex { $0 == values.max() }
        #expect(peakIndex == 10)
    }

    /// 端点窗口收缩但不造数：首尾的平滑值只由存在的一侧算出，且仍是有限值。
    @Test func edgesShrinkWithoutInventing() {
        let input: [Double?] = [1, 2, 3, 4, 5]
        let smoothed = ChartSmoothing.movingAverage(input, radius: 2)
        #expect(smoothed[0]! > 1 && smoothed[0]! < 3)   // (1*3+2*2+3*1)/6 = 1.67
        #expect(smoothed[4]! > 3 && smoothed[4]! < 5)
    }

    /// 全 nil 输入原样返回：没有数据就没有平滑。
    @Test func allNilStaysAllNil() {
        let input: [Double?] = Array(repeating: nil, count: 8)
        #expect(ChartSmoothing.movingAverage(input, radius: 3).allSatisfy { $0 == nil })
    }

    /// 与 GpuHistory 拼装后的端到端形状：真环形缓冲 → 分桶 → 平滑，
    /// 断口两侧的段不互相污染（这是「画出来」的最后一道关）。
    @Test func endToEndWithRingBufferKeepsSegmentsApart() {
        var history = GpuHistory(maxAge: 3_600, minGap: 1.5)
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        for second in stride(from: 0, through: 600, by: 2) {
            history.record(.init(at: t0.addingTimeInterval(Double(second)), utilPct: 10,
                                 powerW: 10, tempC: 50), nodeID: nodeA)
        }
        for second in stride(from: 900, through: 1_200, by: 2) {
            history.record(.init(at: t0.addingTimeInterval(Double(second)), utilPct: 90,
                                 powerW: 90, tempC: 80), nodeID: nodeA)
        }
        let binned = GpuHistory.binned(history.points(nodeID: nodeA, window: 1_800, now: t0.addingTimeInterval(1_200)),
                                       into: 60, window: 1_800, now: t0.addingTimeInterval(1_200))
        let smoothed = ChartSmoothing.movingAverage(binned.util, radius: 2)
        // 桶 0 = t0−600：0–600 s 的数据落桶 20–39，900–1 200 s 落桶 50+，
        // 中间 600–900 s 的洞 = 桶 40–49。平滑窗 ±2 后，严格在洞内的桶仍必须是 nil。
        #expect(smoothed[20] != nil)   // 前段有数据
        #expect(smoothed[55] != nil)   // 后段有数据
        #expect(smoothed[44] == nil && smoothed[45] == nil)   // 洞内不造数
    }
}
