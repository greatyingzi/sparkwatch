import AppKit
import SparkWatchCore
import SwiftUI

/// The GPU history chart, redesigned as **layered small multiples** with a
/// crosshair readout:
///
///   * 主图 = 利用率（0–100%，唯一有天然量程的序列）：平滑均值线。
///   * 温度、功耗 = 两条**自适应量程**的细带——旧版把三者挤进同一个 0–100 坐标，
///     功率一旦过 100 W 就整段削顶贴顶（这台机队突发就是 50–95 W），温度又被
///     利用率压得看不清。分层后各看各的形状，右侧标注实际量程。
///   * **十字线读数**：纵向线跟随鼠标、x 吸附到最近采样桶，右上浮层给出该桶的
///     **原始**值（利用率均值与 min–max、温度、功耗）——绘制层是平滑过的，
///     精确值只在悬停读数里，两者都可见、互不冒充。曾试过常驻 min–max 色带，
///     主人判了「效果不好」：锯齿边缘 + 平滑失真，占空比信息改由悬停承载。
///
/// 保留的三条老规矩（出处见 git 历史，都是被真数据教出来的）：
///
///  1. **x 轴缩放到数据**：历史不足请求窗口的 60% 时画已有的跨度并明说
///     （「历史起点 N 分钟前」），不留两 third 空白。
///  2. **断口是断口**：没观测到的桶留空不连线；平滑也**断口感知**（ChartSmoothing），
///     绝不把「不知道」平均成「过渡」。
///  3. 展示平滑只动线形；图例峰值、细带端点标注、十字线读数全部取**原始桶值**。
struct GpuHistoryChart: View {
    @ObservedObject var model: AppModel
    var nodeID: UUID
    var palette: Palette

    enum Span: String, CaseIterable, Identifiable {
        case thirtyMinutes, oneHour, eightHours
        var id: String { rawValue }
        var seconds: TimeInterval {
            switch self {
            case .thirtyMinutes: 1800
            case .oneHour: 3600
            case .eightHours: 8 * 3600
            }
        }
        var label: String {
            switch self {
            case .thirtyMinutes: "30 min"
            case .oneHour: "1 h"
            case .eightHours: "8 h"
            }
        }
    }

    @State private var span: Span = .thirtyMinutes
    /// 十字线当前吸附的采样桶。nil = 鼠标不在图上。三层共用同一个状态：
    /// x 轴对齐后，悬停任何一层，线在三层同时动。
    @State private var hoverIndex: Int?

    private var available: TimeInterval { model.historySpan(for: nodeID) }

    /// 几何（窗口 / 桶数 / 是否缩放）来自 Core 的纯函数 GpuChartScale。
    ///
    /// 它必须可测，也必须**只因「又攒满一个桶」才变**：跟着数据连续变的话，
    /// 整张图会在每次刷新时重新缩放（用户报的「而不是平移」就是这么来的）。
    private var scale: (window: TimeInterval, buckets: Int, zoomed: Bool, bucketSeconds: Double) {
        GpuChartScale.resolve(requested: span.seconds, available: available)
    }

    private var effectiveWindow: TimeInterval { scale.window }
    private var bucketCount: Int { scale.buckets }
    private var bucketSeconds: Double { scale.bucketSeconds }
    private var zoomed: Bool { scale.zoomed }

    private var series: (util: [Double?], power: [Double?], temp: [Double?],
        utilLow: [Double?], utilHigh: [Double?],
        maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    {
        model.binnedHistory(for: nodeID, window: effectiveWindow, buckets: bucketCount)
    }

    /// 绘制平滑半径（桶数比例：约 ±2% 跨度，中心权最重）。桶越多半径越大，
    /// 但封顶 8 —— 8h 视图每桶已是 2 分钟均值，再糊就没形状了。
    private var smoothRadius: Int { max(2, min(8, bucketCount / 40)) }

    /// 左侧 44pt 是全图层共用的标签列（主图 y 轴刻度、细带名称），绘图区从
    /// 44pt 起——三层绘图区**逐像素同宽**，十字线在层间才能对得上。
    private let labelColumn: CGFloat = 44

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        let data = series
        let smooth = (
            util: ChartSmoothing.movingAverage(data.util, radius: smoothRadius),
            power: ChartSmoothing.movingAverage(data.power, radius: smoothRadius),
            temp: ChartSmoothing.movingAverage(data.temp, radius: smoothRadius)
        )
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("GPU 历史")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                if zoomed {
                    Chip(text: String(format: "历史起点 %.0f 分钟前", available / 60), tint: palette.accent)
                        .help("这条记录只有这么久；x 轴按实际数据缩放，而不是留一大片空白")
                }
                Spacer(minLength: 0)
                Picker("", selection: $span) {
                    ForEach(Span.allCases) { span in
                        Text(span.label).tag(span)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }

            mainChart(data, smooth)
            layerSeparator
            strip("温度", color: palette.info, values: smooth.temp) { String(format: "%.0f°", $0) }
            layerSeparator
            strip("功耗", color: palette.violet, values: smooth.power) { String(format: "%.0f W", $0) }

            HStack(spacing: 14) {
                legendItem("利用率", value: data.maxUtil.map { String(format: "峰值 %.0f%%", $0) }, color: palette.accent)
                legendItem("温度", value: data.maxTemp.map { String(format: "峰值 %.0f°C", $0) }, color: palette.info)
                legendItem("功耗", value: data.maxPower.map { String(format: "峰值 %.0f W", $0) }, color: palette.violet)
                Spacer(minLength: 0)
                Text(coverageLabel(data))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Text("三层各管各的量程：利用率固定 0–100%，温度/功耗按观测区间自适应（右侧标注）。曲线做了轻度展示平滑（居中加权均值，断口不跨）；把鼠标放到图上，十字线所在时刻的**原始桶值**（利用率均值与波动范围、温度、功耗）在右上读数里。每格约 \(Int(bucketSeconds)) 秒 —— 这台机器几秒内就能从 95% 摆到 0%，悬停读数里的「波动范围」就是占空比本体；没观测到的时段留空，不连线。")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
    }

    // MARK: - 主图（利用率 + 十字线读数）

    private func mainChart(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?),
        _ smooth: (util: [Double?], power: [Double?], temp: [Double?])
    ) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotWidth = width - labelColumn
            let height: CGFloat = 168
            ZStack(alignment: .topLeading) {
                gridlines(width: plotWidth, height: height)
                    .offset(x: labelColumn)

                seriesPath(smooth.util, width: plotWidth, height: height, y: unitY(height))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: palette.accent.opacity(0.30), radius: 2.5)
                    .offset(x: labelColumn)

                axisLabels(plotWidth: plotWidth, height: height)

                if let index = hoverIndex {
                    crosshair(index: index, plotWidth: plotWidth, height: height)
                        .offset(x: labelColumn)
                    if let value = data.util.indices.contains(index) ? data.util[index] : nil {
                        markerDot(color: palette.accent, x: xPosition(index, plotWidth: plotWidth),
                                  y: unitY(height)(value))
                            .offset(x: labelColumn)
                    }
                    readoutBox(data, index: index)
                        .frame(width: plotWidth, height: height, alignment: .topTrailing)
                        .allowsHitTesting(false)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let hover):
                    hoverIndex = Self.bucketIndex(
                        x: hover.x - labelColumn, plotWidth: plotWidth, count: bucketCount
                    )
                case .ended:
                    hoverIndex = nil
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 168)
    }

    /// 层与层之间的发丝分隔：三块绘图区共用 x 轴，视觉上必须是「分层」而不是
    /// 「一张图里三条线」——旧版把三者挤进同一量程正是这条没立住。
    private var layerSeparator: some View {
        Rectangle()
            .fill(palette.border.opacity(0.35))
            .frame(height: 1)
    }

    /// 0–100 的统一 y 映射（主图专用）。
    private func unitY(_ height: CGFloat) -> (Double) -> CGFloat {
        { value in height - height * CGFloat(min(max(value, 0), 100)) / 100 }
    }

    /// 悬停 x → 采样桶序号（**吸附**：读数永远对应一个真实存在的桶，
    /// 而不是鼠标位置上的插值——插值值是编造的测量）。
    static func bucketIndex(x: CGFloat, plotWidth: CGFloat, count: Int) -> Int? {
        guard count > 1, plotWidth > 0 else { return nil }
        let step = plotWidth / CGFloat(count - 1)
        let index = Int((x / step).rounded())
        return indices0(count).contains(index) ? index : nil
    }

    private static func indices0(_ count: Int) -> Range<Int> { 0..<max(count, 0) }

    private func xPosition(_ index: Int, plotWidth: CGFloat) -> CGFloat {
        guard bucketCount > 1 else { return 0 }
        return CGFloat(index) * plotWidth / CGFloat(bucketCount - 1)
    }

    /// 十字线：一条 1pt 纵线贯穿该层绘图区。
    private func crosshair(index: Int, plotWidth: CGFloat, height: CGFloat) -> some View {
        Rectangle()
            .fill(palette.mutedStrong.opacity(0.45))
            .frame(width: 1, height: height)
            .offset(x: xPosition(index, plotWidth: plotWidth))
    }

    private func markerDot(color: Color, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .position(x: x, y: y)
    }

    /// 悬停读数浮层：固定右上（跟随式会抖、还会盖住线）。全部取**原始桶值**——
    /// 绘制层是平滑过的，精确值只在这里，两条信息链互不冒充。
    private func readoutBox(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?),
        index: Int
    ) -> some View {
        let util = data.util.indices.contains(index) ? data.util[index] : nil
        let low = data.utilLow.indices.contains(index) ? data.utilLow[index] : nil
        let high = data.utilHigh.indices.contains(index) ? data.utilHigh[index] : nil
        let temp = data.temp.indices.contains(index) ? data.temp[index] : nil
        let power = data.power.indices.contains(index) ? data.power[index] : nil
        // 桶中心时刻：最新桶 ≈ 现在，往前每桶退 bucketSeconds。
        let offset = effectiveWindow - (Double(index) + 0.5) * bucketSeconds
        let at = Date().addingTimeInterval(-offset)
        return VStack(alignment: .leading, spacing: 4) {
            Text(Self.clockFormatter.string(from: at))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(palette.textStrong)
            readoutRow(color: palette.accent, label: "利用率",
                       value: util.map { String(format: "%.0f%%", $0) } ?? "—",
                       // 波动范围只在真的有摆动时才有信息量：0–0% 这种
                       // 「平稳」不需要第二行数字去重复均值。
                       sub: util != nil && low != nil && high != nil && high! - low! >= 1
                           ? String(format: "%.0f–%.0f%%", low!, high!) : nil)
            readoutRow(color: palette.info, label: "温度",
                       value: temp.map { String(format: "%.0f°", $0) } ?? "—", sub: nil)
            readoutRow(color: palette.violet, label: "功耗",
                       value: power.map { String(format: "%.0f W", $0) } ?? "—", sub: nil)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(palette.surface))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(palette.border, lineWidth: 1))
    }

    private func readoutRow(color: Color, label: String, value: String, sub: String?) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 10, design: .rounded)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.textStrong)
            if let sub {
                Text(sub)
                    .font(.system(size: 9.5, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func gridlines(width: CGFloat, height: CGFloat) -> some View {
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
            let y = height - height * CGFloat(level) / 100
            Path { path in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
            .stroke(palette.grid.opacity(level == 0 || level == 100 ? 0.9 : 0.55),
                    style: StrokeStyle(lineWidth: 1))
        }
    }

    /// The y scale is written on the left, the actual span on the bottom: without
    /// the span label a zoomed chart silently claims to be the requested window.
    private func axisLabels(plotWidth: CGFloat, height: CGFloat) -> some View {
        let minutes = Int(effectiveWindow / 60)
        let left: String = minutes >= 120
            ? String(format: "%.0f 小时前", effectiveWindow / 3600)
            : "\(max(minutes, 1)) 分钟前"
        return ZStack(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 0) {
                Text("100%")
                Spacer(minLength: 0)
                Text("50%")
                Spacer(minLength: 0)
                Text("0")
            }
            .frame(width: labelColumn - 6, height: height - 24, alignment: .leading)
            .offset(y: 2)
            HStack {
                Text(left)
                Spacer()
                Text("现在")
            }
            .frame(width: plotWidth - 24)
            .position(x: labelColumn + plotWidth / 2, y: height - 6)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: labelColumn + plotWidth, height: height, alignment: .topLeading)
    }

    // MARK: - 细带（温度 / 功耗，自适应量程）

    /// 一条 36pt 的细带：名称在左标签列，量程标注在右（上=最大、下=最小），
    /// 断口与主图同一套规矩，悬停时同一条十字线穿过。
    private func strip(_ label: String, color: Color, values: [Double?],
                       format: @escaping (Double) -> String) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotWidth = width - labelColumn
            let height: CGFloat = 36
            let observed = values.compactMap { $0 }
            let low = observed.min() ?? 0
            let high = max(observed.max() ?? 1, low + 1)
            let pad = (high - low) * 0.12
            let scaleLow = low - pad
            let scaleHigh = high + pad
            let y: (Double) -> CGFloat = { value in
                let clamped = min(max(value, scaleLow), scaleHigh)
                return height - height * CGFloat((clamped - scaleLow) / (scaleHigh - scaleLow))
            }
            HStack(alignment: .center, spacing: 0) {
                Text(label)
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: labelColumn - 6, alignment: .leading)
                ZStack(alignment: .topLeading) {
                    seriesPath(values, width: plotWidth, height: height, y: y)
                        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .shadow(color: color.opacity(0.25), radius: 1.5)
                    // 全无观测时（刚装好/引擎一直没上报）没有量程可标，
                    // 别把「0°/1°」这种占位值当真数据挂出来。
                    if !observed.isEmpty {
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(format(high))
                            Spacer(minLength: 0)
                            Text(format(low))
                        }
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .frame(width: 64, alignment: .trailing)
                        .offset(x: plotWidth - 66)
                    }
                    if let index = hoverIndex {
                        crosshair(index: index, plotWidth: plotWidth, height: height)
                        if let value = values.indices.contains(index) ? values[index] : nil {
                            markerDot(color: color, x: xPosition(index, plotWidth: plotWidth),
                                      y: y(value))
                        }
                    }
                }
                .frame(width: plotWidth, height: height, alignment: .topLeading)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let hover):
                    hoverIndex = Self.bucketIndex(
                        x: hover.x - labelColumn, plotWidth: plotWidth, count: bucketCount
                    )
                case .ended:
                    hoverIndex = nil
                @unknown default:
                    break
                }
            }
        }
        .frame(height: 36)
    }

    private func legendItem(_ label: String, value: String?, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 3)
            Text(label)
            if let value {
                Text(value).foregroundStyle(.tertiary)
            }
        }
        .font(.system(size: 11, design: .rounded))
        .foregroundStyle(.secondary)
    }

    private func coverageLabel(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    ) -> String {
        let filled = data.util.compactMap { $0 }.count
        let total = max(data.util.count, 1)
        return String(format: "%d/%d 个采样桶有数据（%.0f%%）", filled, total, Double(filled) / Double(total) * 100)
    }

    // MARK: - Path builders

    /// One path per series, with a break wherever a bucket has no data. A single
    /// Path with move(to:) at each gap start is what keeps the line from
    /// bridging the hole.
    private func seriesPath(_ values: [Double?], width: CGFloat, height: CGFloat,
                            y: (Double) -> CGFloat) -> Path {
        var path = Path()
        guard !values.isEmpty, width > 0 else { return path }
        let step = width / CGFloat(max(values.count - 1, 1))
        var started = false
        for (index, value) in values.enumerated() {
            guard let value else {
                started = false
                continue
            }
            let point = CGPoint(x: CGFloat(index) * step, y: y(value))
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        return path
    }
}
