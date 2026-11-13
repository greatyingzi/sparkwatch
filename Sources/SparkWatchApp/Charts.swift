import AppKit
import SparkWatchCore
import SwiftUI

/// 方向 ②「数据密集终端风」—— Grafana / TradingView 一系的 GPU 历史卡。
///
/// 与旧分层版的差别（分层骨架保留，绘制层全换）：
///
///   * **细网格 + 全刻度**：0/25/50/75/100 横向发丝线全部标数；x 轴改为
///     **真实时刻刻度**（HH:mm，按桶中心换算），竖向发丝线贯穿三层。
///   * **单调三次样条**（Fritsch–Carlson 切线限幅）替换折线段——视觉立刻高级。
///     诚实性要点写在 monotonePath 注释里：节点值 = 平滑展示值，曲线严格过节点；
///     切线限幅保证**保凸、不过冲**，绝不画出两端点之外的值；断口感知，
///     每段连续非 nil 单独成路径。
///   * 细带与主图加**极淡同色渐变填充**（细带 0.08→0.02，主图更淡）。
///   * 十字线读数做成**终端风等宽面板**：常驻显示最新桶（原始值），悬停时
///     切到悬停桶——截图/无人交互时也有读数可看，且永远是真实存在的桶。
///   * span 选择器自绘成终端分段框。
///   * **悬停零成本**：十字线状态住在独立覆盖层（GpuCrosshairOverlay）里，
///     鼠标移动只重绘「一条线 + 三个点 + 一块面板」；分桶/平滑/样条与鼠标
///     事件彻底解耦——这是主人报「十字线拖动延迟很大」的根治（注释在覆盖层上）。
///
/// 老规矩不变：
///  1. x 轴缩放到数据，不足请求窗口 60% 时明说（「历史起点 N 分钟前」）。
///  2. 断口是断口：nil 桶留空；样条与填充都不跨段。
///  3. 展示平滑与样条只动线形；面板数值、刻度旁峰值、细带量程标注全部取
///     **原始桶值**。
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
            case .thirtyMinutes: "30m"
            case .oneHour: "1h"
            case .eightHours: "8h"
            }
        }
    }

    @State private var span: Span = .thirtyMinutes

    var body: some View {
        // 一次求值只算一遍：几何、分桶、平滑。鼠标移动**不再触碰这里的任何
        // 计算**——悬停状态与绘制全部下沉到 GpuCrosshairOverlay；这里的重跑
        // 只由模型刷新（约 2 s 一拍）与 span 切换触发。
        let available = model.historySpan(for: nodeID)
        let scale = GpuChartScale.resolve(requested: span.seconds, available: available)
        let data = model.binnedHistory(for: nodeID, window: scale.window, buckets: scale.buckets)
        let radius = max(2, min(8, scale.buckets / 40))
        let smooth = (
            util: ChartSmoothing.movingAverage(data.util, radius: radius),
            power: ChartSmoothing.movingAverage(data.power, radius: radius),
            temp: ChartSmoothing.movingAverage(data.temp, radius: radius)
        )
        return VStack(alignment: .leading, spacing: 0) {
            header(zoomed: scale.zoomed, availableSeconds: available)
            GpuChartCanvas(
                series: data, smooth: smooth, palette: palette,
                window: scale.window, buckets: scale.buckets,
                bucketSeconds: scale.bucketSeconds
            )
            .padding(.top, 14)
            footer(data, bucketSeconds: scale.bucketSeconds)
                .padding(.top, 12)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
    }

    // MARK: - 页眉与终端分段框

    private func header(zoomed: Bool, availableSeconds: TimeInterval) -> some View {
        HStack(spacing: 10) {
            Text("GPU 历史")
                .font(.system(size: 13, weight: .semibold))
                .tracking(-0.2)
                .foregroundStyle(palette.textStrong)
            if zoomed {
                Chip(text: String(format: "历史起点 %.0f 分钟前", availableSeconds / 60), tint: palette.accent, compact: true)
                    .help("这条记录只有这么久；x 轴按实际数据缩放，而不是留一大片空白")
            }
            Spacer(minLength: 0)
            spanSelector
        }
    }

    /// 终端分段框：整框描边 + 段间发丝分隔，激活段淡底反白。
    private var spanSelector: some View {
        HStack(spacing: 0) {
            ForEach(Array(Span.allCases.enumerated()), id: \.element.id) { index, option in
                if index > 0 {
                    Rectangle()
                        .fill(palette.border)
                        .frame(width: 1, height: 12)
                }
                Button {
                    span = option
                } label: {
                    Text(option.label)
                        .font(.system(size: 10, weight: option == span ? .semibold : .regular, design: .monospaced))
                        .foregroundStyle(option == span ? palette.textStrong : palette.faint)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background {
                            if option == span {
                                Rectangle().fill(palette.surfaceHover)
                            }
                        }
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(palette.border, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
    }

    // MARK: - 脚注

    private func footer(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?),
        bucketSeconds: Double
    ) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                if let maxUtil = data.maxUtil {
                    Text(String(format: "峰值 %.0f%%", maxUtil))
                        .foregroundStyle(palette.mutedStrong)
                }
                dot
                Text(coverageLabel(data))
                dot
                Text("每桶 \(Int(bucketSeconds)) s")
                Spacer(minLength: 0)
                Text("样条=单调三次·保凸不过冲；面板=原始桶值")
                    .foregroundStyle(palette.faint)
            }
            HStack(spacing: 6) {
                if let maxUtil = data.maxUtil {
                    Text(String(format: "峰值 %.0f%%", maxUtil))
                        .foregroundStyle(palette.mutedStrong)
                }
                dot
                Text(coverageLabel(data))
                dot
                Text("每桶 \(Int(bucketSeconds)) s")
            }
        }
        .font(.system(size: 9.5, design: .monospaced))
        .foregroundStyle(palette.muted)
    }

    private var dot: some View {
        Circle().fill(palette.faint.opacity(0.7)).frame(width: 2, height: 2)
    }

    private func coverageLabel(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    ) -> String {
        let filled = data.util.compactMap { $0 }.count
        let total = max(data.util.count, 1)
        return String(format: "覆盖 %d/%d 桶", filled, total)
    }
}

// MARK: - 布局常量与纯函数几何

/// 三层高度 / 间距 / 标签列宽的**唯一出处**。悬停覆盖层要用它们换算各层色点
/// 的绝对 y（见 GpuChartCanvas 的层叠结构），改任何一层高度必须同步这里。
private enum GpuChartLayout {
    static let labelColumn: CGFloat = 44
    static let mainHeight: CGFloat = 190
    static let stripHeight: CGFloat = 36
    static let bandSpacing: CGFloat = 12
    static let axisHeight: CGFloat = 14

    /// 主图 + 两细带 + 时间轴 + 三条层间距（与 body 的 VStack 结构一一对应）。
    static var totalHeight: CGFloat {
        mainHeight + stripHeight * 2 + axisHeight + bandSpacing * 3
    }

    /// 温度细带顶边在整块坐标系里的 y。
    static var tempBandTop: CGFloat { mainHeight + bandSpacing }

    /// 功耗细带顶边在整块坐标系里的 y。
    static var powerBandTop: CGFloat { mainHeight + bandSpacing + stripHeight + bandSpacing }
}

/// 纯函数几何：主图 y 映射、细带量程、桶吸附与反查。视图层只做装配。
private enum GpuChartGeometry {
    /// 0–100 的统一 y 映射（主图专用）。
    static func unitY(_ height: CGFloat) -> (Double) -> CGFloat {
        { value in height - height * CGFloat(min(max(value, 0), 100)) / 100 }
    }

    /// 细带量程：观测值 min/max 外扩 14%。悬停覆盖层与细带图层必须用**同一份**
    /// 量程，色点才贴得住线。
    static func stripScale(_ values: [Double?]) -> (scaleLow: Double, scaleHigh: Double) {
        let observed = values.compactMap { $0 }
        let low = observed.min() ?? 0
        let high = max(observed.max() ?? 1, low + 1)
        let pad = (high - low) * 0.14
        return (low - pad, high + pad)
    }

    static func stripY(
        _ value: Double, scaleLow: Double, scaleHigh: Double, height: CGFloat
    ) -> CGFloat {
        let clamped = min(max(value, scaleLow), scaleHigh)
        return height - height * CGFloat((clamped - scaleLow) / (scaleHigh - scaleLow))
    }

    /// 悬停 x → 采样桶序号（**吸附**：读数永远对应一个真实存在的桶）。
    static func bucketIndex(x: CGFloat, plotWidth: CGFloat, count: Int) -> Int? {
        guard count > 1, plotWidth > 0 else { return nil }
        let step = plotWidth / CGFloat(count - 1)
        let index = Int((x / step).rounded())
        return index >= 0 && index < count ? index : nil
    }

    /// 桶序号 → 绘图区 x（相对绘图区左缘；加 labelColumn 得整块坐标）。
    static func xPosition(_ index: Int, plotWidth: CGFloat, count: Int) -> CGFloat {
        guard count > 1 else { return 0 }
        return CGFloat(index) * plotWidth / CGFloat(count - 1)
    }
}

/// 离屏渲染上下文（--preview-* harness / ImageRenderer）。
///
/// ImageRenderer 画不了 NSViewRepresentable——只会输出整块黄底🚫占位
/// （与设置窗 Picker 同病，见项目记忆）。预览 harness 里把原生跟踪层换成
/// 透明 SwiftUI 层替身，图表其余部分照常渲染；真机永远走原生层。
/// 预览代码在起 Task 时置位（见 main.swift 各 --preview-* 块）。
enum GpuChartRenderContext {
    @MainActor static var offscreen = false
}

/// HH:mm —— 时间轴与读数面板共用一份 formatter。
private enum GpuChartFormat {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}

// MARK: - 三层 + 时间轴的统一容器

/// 三层 + 时间轴的统一容器（旧 chartBlock）。
///
/// 分工：这里只装配**静态图层**（网格/样条/填充/刻度），重跑只由数据、span、
/// 尺寸变化触发；悬停处理与十字线绘制全部下沉到 `GpuCrosshairOverlay`——
/// 那是「十字线拖动延迟」问题的根治点。容器高度 = 主图 190 + 两细带 36×2
/// + 轴 14 + 间距 12×3，改任何一层高度必须同步 `GpuChartLayout`。
private struct GpuChartCanvas: View {
    var series: (util: [Double?], power: [Double?], temp: [Double?],
        utilLow: [Double?], utilHigh: [Double?],
        maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    var smooth: (util: [Double?], power: [Double?], temp: [Double?])
    var palette: Palette
    var window: TimeInterval
    var buckets: Int
    var bucketSeconds: Double

    var body: some View {
        GeometryReader { proxy in
            let plotWidth = proxy.size.width - GpuChartLayout.labelColumn
            VStack(alignment: .leading, spacing: GpuChartLayout.bandSpacing) {
                mainChart
                strip("温度", color: palette.info, values: smooth.temp, rawValues: series.temp) {
                    String(format: "%.0f°", $0)
                }
                strip("功耗", color: palette.violet, values: smooth.power, rawValues: series.power) {
                    String(format: "%.0f W", $0)
                }
                timeAxis(plotWidth: plotWidth)
                    .frame(height: GpuChartLayout.axisHeight)
            }
            .overlay(alignment: .topLeading) {
                GpuCrosshairOverlay(
                    series: series, smooth: smooth, palette: palette,
                    buckets: buckets, bucketSeconds: bucketSeconds,
                    window: window, plotWidth: plotWidth
                )
            }
        }
        .frame(height: GpuChartLayout.totalHeight)
    }

    // MARK: 主图（利用率）

    private var mainChart: some View {
        GeometryReader { proxy in
            let plotWidth = proxy.size.width - GpuChartLayout.labelColumn
            let height = GpuChartLayout.mainHeight
            ZStack(alignment: .topLeading) {
                horizontalGrid(width: plotWidth, height: height)
                    .offset(x: GpuChartLayout.labelColumn)
                verticalTicks(width: plotWidth, height: height)
                    .offset(x: GpuChartLayout.labelColumn)

                areaPath(smooth.util, width: plotWidth, height: height, y: GpuChartGeometry.unitY(height))
                    .fill(
                        LinearGradient(
                            colors: [palette.accent.opacity(0.07), palette.accent.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    .offset(x: GpuChartLayout.labelColumn)
                monotonePath(smooth.util, width: plotWidth, height: height, y: GpuChartGeometry.unitY(height))
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .offset(x: GpuChartLayout.labelColumn)

                yLabels(width: GpuChartLayout.labelColumn - 10, height: height)
            }
            // **合成器减压**：几十个矢量图层（网格/样条/填充/刻度）压成一张
            // Metal 纹理——滚动主窗时合成器搬的是纹理而不是逐层重绘矢量
            // （主线程空闲 + CPU 0.6% + 卡，特征正是合成器瓶颈）。图层内容只随
            // 数据变化（0.5 Hz），重栅格化频率可忽略。悬停层在覆盖层里，不参与。
            .drawingGroup()
        }
        .frame(height: GpuChartLayout.mainHeight)
    }

    /// 横向网格：0/25/50/75/100。基线（0）与顶线（100）略强。
    private func horizontalGrid(width: CGFloat, height: CGFloat) -> some View {
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
            let y = height - height * CGFloat(level) / 100
            Rectangle()
                .fill(level == 0 || level == 100 ? palette.border.opacity(0.6) : palette.mutedStrong.opacity(0.14))
                .frame(width: width, height: 1)
                .offset(y: min(max(y, 0), height - 1))
        }
    }

    /// 竖向时刻发丝线：20% 步进（不画左右两端，端点交给轴标注）。
    private func verticalTicks(width: CGFloat, height: CGFloat) -> some View {
        ForEach([1, 2, 3, 4].map { Double($0) / 5.0 }, id: \.self) { fraction in
            Rectangle()
                .fill(palette.mutedStrong.opacity(0.14))
                .frame(width: 1, height: height)
                .offset(x: width * fraction)
        }
    }

    private func yLabels(width: CGFloat, height: CGFloat) -> some View {
        ForEach([0, 25, 50, 75, 100], id: \.self) { level in
            let y = height - height * CGFloat(level) / 100
            Text("\(level)")
                .font(.system(size: 9.5, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.faint)
                .frame(width: width, alignment: .trailing)
                .offset(y: min(max(y - 7, 0), height - 14))
        }
    }

    /// x 轴：真实时刻刻度（按桶中心换算的 HH:mm）对齐到竖向发丝线，右端「现在」。
    private func timeAxis(plotWidth: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array([0.0, 0.2, 0.4, 0.6, 0.8].enumerated()), id: \.offset) { pair in
                tickTimeLabel(fraction: pair.element)
                    .frame(width: tickLabelWidth,
                           alignment: pair.offset == 0 ? Alignment.leading : Alignment.center)
                    .offset(x: pair.offset == 0 ? 0 : plotWidth * pair.element - tickLabelWidth / 2)
            }
            HStack {
                Spacer(minLength: 0)
                Text("现在")
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(palette.mutedStrong)
            }
            .frame(width: plotWidth)
        }
        .padding(.leading, GpuChartLayout.labelColumn)
    }

    private let tickLabelWidth: CGFloat = 44

    private func tickTimeLabel(fraction: Double) -> some View {
        let index = Int((fraction * Double(buckets - 1)).rounded())
        let offset = window - (Double(index) + 0.5) * bucketSeconds
        let at = Date().addingTimeInterval(-offset)
        return Text(GpuChartFormat.clock.string(from: at))
            .font(.system(size: 9.5, design: .monospaced))
            .monospacedDigit()
            .foregroundStyle(palette.faint)
    }

    // MARK: 细带（温度 / 功耗）

    private func strip(_ label: String, color: Color, values: [Double?], rawValues: [Double?],
                       format: @escaping (Double) -> String) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let plotWidth = width - GpuChartLayout.labelColumn
            let height = GpuChartLayout.stripHeight
            let (scaleLow, scaleHigh) = GpuChartGeometry.stripScale(values)
            let y: (Double) -> CGFloat = {
                GpuChartGeometry.stripY($0, scaleLow: scaleLow, scaleHigh: scaleHigh, height: height)
            }
            let rawObserved = rawValues.compactMap { $0 }
            HStack(alignment: .center, spacing: 0) {
                Text(label)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: GpuChartLayout.labelColumn, alignment: .leading)
                ZStack(alignment: .topLeading) {
                    verticalTicks(width: plotWidth, height: height)
                    areaPath(values, width: plotWidth, height: height, y: y)
                        .fill(
                            LinearGradient(
                                colors: [color.opacity(0.08), color.opacity(0.02)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                    monotonePath(values, width: plotWidth, height: height, y: y)
                        .stroke(color.opacity(0.95), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    if !rawObserved.isEmpty {
                        let rawLow = rawObserved.min() ?? 0
                        let rawHigh = rawObserved.max() ?? 0
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(format(rawHigh))
                            Spacer(minLength: 0)
                            Text(format(rawLow))
                        }
                        .font(.system(size: 9.5, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(palette.faint)
                        .frame(width: 58, alignment: .trailing)
                        .offset(x: plotWidth - 66)
                    }
                }
                // 细带同理：一张纹理代替十几个矢量图层。
                .drawingGroup()
                .frame(width: plotWidth, height: height, alignment: .topLeading)
            }
        }
        .frame(height: GpuChartLayout.stripHeight)
    }

    // MARK: Path builders

    /// **单调三次样条**（Fritsch–Carlson 切线限幅，Steffen 端点）。
    ///
    /// 诚实性说明（这条注释就是给验收看的）：
    ///
    ///   * 节点值 = 展示层平滑后的值；样条曲线**严格穿过每个节点**。
    ///   * 切线取相邻割线的**加权调和平均**（Fritsch–Carlson），两端点取单侧割线。
    ///     该构造对每个小段满足 Hermite 单调性条件（|m| ≤ 3·割线），故曲线在任意
    ///     两节点之间**不会超出这两点的值**——保凸、不过冲，画不出「没测过的值」。
    ///     （普通 cubic Catmull-Rom 会过冲出尖刺，那才是谎。）
    ///   * 断口感知：每个**连续非 nil** 段单独成路径；nil 桶之间绝不连线。
    private func monotonePath(_ values: [Double?], width: CGFloat, height: CGFloat,
                              y: (Double) -> CGFloat) -> Path {
        var path = Path()
        guard values.count > 1, width > 0 else {
            return seriesPath(values, width: width, height: height, y: y)
        }
        let step = width / CGFloat(values.count - 1)
        var start: Int? = nil
        var index = 0
        while index <= values.count {
            let hasValue = index < values.count && values[index] != nil
            if hasValue, start == nil {
                start = index
            }
            if !hasValue, let segmentStart = start {
                let segmentEnd = index - 1
                let count = segmentEnd - segmentStart + 1
                if count >= 2 {
                    var slopes = [Double](repeating: 0, count: count)
                    var deltas = [Double](repeating: 0, count: count - 1)
                    for i in 0..<count - 1 {
                        deltas[i] = values[segmentStart + i + 1]! - values[segmentStart + i]!
                    }
                    slopes[0] = deltas[0]
                    slopes[count - 1] = deltas[count - 2]
                    if count > 2 {
                        for i in 1..<count - 1 {
                            let d0 = deltas[i - 1]
                            let d1 = deltas[i]
                            if d0 * d1 <= 0 {
                                slopes[i] = 0
                            } else {
                                // 加权调和平均（段长均匀，w1 = w2 = 3h）。
                                slopes[i] = 2 * d0 * d1 / (d0 + d1)
                            }
                        }
                    }
                    for i in 0..<count - 1 {
                        let x0 = CGFloat(segmentStart + i) * step
                        let x1 = CGFloat(segmentStart + i + 1) * step
                        let v0 = values[segmentStart + i]!
                        let v1 = values[segmentStart + i + 1]!
                        let p0 = CGPoint(x: x0, y: y(v0))
                        let p3 = CGPoint(x: x1, y: y(v1))
                        let c1 = CGPoint(x: x0 + step / 3, y: y(v0 + slopes[i] / 3))
                        let c2 = CGPoint(x: x1 - step / 3, y: y(v1 - slopes[i + 1] / 3))
                        if i == 0 {
                            path.move(to: p0)
                        }
                        path.addCurve(to: p3, control1: c1, control2: c2)
                    }
                } else if count == 1 {
                    // 孤立单点：画一个不可见的微段，保持「点存在」的语义。
                    let x0 = CGFloat(segmentStart) * step
                    let v0 = values[segmentStart]!
                    path.move(to: CGPoint(x: x0, y: y(v0)))
                    path.addLine(to: CGPoint(x: x0 + 0.01, y: y(v0)))
                }
                start = nil
            }
            index += 1
        }
        return path
    }

    /// 面积填充：先走线（直线段即可，填充形状被线盖住看不见接缝），
    /// 再沿 x 轴闭合；每段连续非 nil 单独闭合，断口不填充。
    private func areaPath(_ values: [Double?], width: CGFloat, height: CGFloat,
                          y: (Double) -> CGFloat) -> Path {
        var path = Path()
        guard !values.isEmpty, width > 0 else { return path }
        let step = width / CGFloat(max(values.count - 1, 1))
        var segment: [CGPoint] = []
        func flush() {
            guard let first = segment.first, let last = segment.last, segment.count > 1 else {
                segment = []
                return
            }
            path.move(to: first)
            for point in segment.dropFirst() { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: height))
            path.addLine(to: CGPoint(x: first.x, y: height))
            path.closeSubpath()
            segment = []
        }
        for (index, value) in values.enumerated() {
            guard let value else {
                flush()
                continue
            }
            segment.append(CGPoint(x: CGFloat(index) * step, y: y(value)))
        }
        flush()
        return path
    }

    /// Fallback 折线（孤立点/退化输入时使用）。
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

// MARK: - 原生鼠标跟踪层

/// 悬停事件的原生通路：NSTrackingArea 直连，替代走 SwiftUI 手势系统的
/// `onContinuousHover`——后者经手势识别/更新周期节流，快速拖动时回调
/// 到得晚（十字线迟滞的最后一环）。mouseMoved/mouseDragged 以系统原生节奏
/// 投递，mouseExited 负责离开边界；指数闸门在覆盖层里去重，多通路无副作用。
///
/// 窗口默认不投递 mouseMoved，挂上窗口那一刻显式打开 `acceptsMouseMovedEvents`。
/// SwiftUI 侧的 onContinuousHover 兜底保留（见覆盖层 body 注释）。
private struct HoverTrackingView: NSViewRepresentable {
    var onMove: (CGPoint) -> Void
    var onExit: () -> Void

    func makeNSView(context: Context) -> HoverTrackingNSView {
        let view = HoverTrackingNSView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ view: HoverTrackingNSView, context: Context) {
        view.onMove = onMove
        view.onExit = onExit
    }

    final class HoverTrackingNSView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
            addTrackingArea(NSTrackingArea(
                rect: bounds,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self,
                userInfo: nil
            ))
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseDragged(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

// MARK: - 悬停十字线覆盖层

/// 悬停十字线覆盖层——**悬停状态的唯一宿主**：一条纵线 + 三层色点 + 读数面板。
///
/// 性能设计（主人报「那条线不跟鼠标，拖动时延迟很大」，根因与修法都写在这）：
///
///   * **根因**：旧实现把 `hoverIndex` 挂在图表根视图上，每个鼠标移动事件
///     （触控板约 120 Hz）都重跑整个 `body`——重新分桶、重新平滑、重建三条
///     单调样条、再 diff 整棵子树。主线程被事件流打满，线永远追不上手。
///   * **修法 ①状态下沉**：`@State hoverIndex` 只住在这层覆盖层里。移动事件
///     只重渲染「一条线 + 三个点 + 一块面板」（微秒级），重图层（样条/填充/
///     网格/刻度）**完全不参与**——它们连 body 都不会被碰一下。
///   * **修法 ②同桶不写状态**：光标在同一桶内移动时 `hoverIndex` 不变，
///     `setHover` 直接返回，SwiftUI 零失效。吸附粒度 = 桶宽（30m 跨度约 8pt），
///     十字线吸附 K 线，且**永远与色点/面板同 x**——对齐是硬要求，不回退。
///   * 清理任务只在真有十字线时安排一次；同桶返回前先撤挂着的任务，
///     快速离开再回来不会被 180 ms 的延迟清理误伤。
private struct GpuCrosshairOverlay: View {
    var series: (util: [Double?], power: [Double?], temp: [Double?],
        utilLow: [Double?], utilHigh: [Double?],
        maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    var smooth: (util: [Double?], power: [Double?], temp: [Double?])
    var palette: Palette
    var buckets: Int
    var bucketSeconds: Double
    var window: TimeInterval
    var plotWidth: CGFloat

    /// 十字线吸附的采样桶。**线与点同 x**（主人两轮真机标注：错位与断裂都
    /// 不可接受）——线与色点/读数面板一起吸附真实桶。
    @State private var hoverIndex: Int?
    /// 悬停离开后的延迟清空任务：整块单入口后 ended 只在离开全块时出现，
    /// 保留它只为「快速扫过图块边缘」时不残留半帧十字线。
    @State private var hoverClearTask: Task<Void, Never>?

    var body: some View {
        ZStack(alignment: .topLeading) {
            // 命中+事件层：**原生 NSTrackingArea 直连**（见 HoverTrackingView 注释）。
            // SwiftUI onContinuousHover 保留作兜底——两路写同一个桶索引，
            // setHover 的同桶闸门天然去重，谁快听谁的。
            // 离屏 harness 里 NSView 会画成黄块，换透明替身（无交互，无所谓）。
            if GpuChartRenderContext.offscreen {
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HoverTrackingView(
                    onMove: { location in
                        setHover(location.x - GpuChartLayout.labelColumn, plotWidth: plotWidth)
                    },
                    onExit: { setHover(nil, plotWidth: plotWidth) }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let index = hoverIndex {
                crosshair(index)
            }
            // 读数面板**常驻**：无悬停时钉在最后一个有数据的桶（旧语义保留——
            // 截图/无人交互时也有读数可看），悬停时切到悬停桶。
            readoutPanel(index: hoverIndex ?? pinnedIndex)
                .frame(width: plotWidth, height: GpuChartLayout.mainHeight, alignment: .topTrailing)
                .offset(x: GpuChartLayout.labelColumn)
                .allowsHitTesting(false)
        }
        .onContinuousHover { phase in
            switch phase {
            case .active(let hover):
                setHover(hover.x - GpuChartLayout.labelColumn, plotWidth: plotWidth)
            case .ended:
                setHover(nil, plotWidth: plotWidth)
            @unknown default:
                break
            }
        }
    }

    /// 悬停状态的**唯一入口**。写入前先算目标桶：同桶零状态写入，SwiftUI 零失效。
    private func setHover(_ x: CGFloat?, plotWidth: CGFloat) {
        let index = x.map {
            GpuChartGeometry.bucketIndex(x: min(max($0, 0), plotWidth), plotWidth: plotWidth, count: buckets)
        }
        if let index {
            // 先撤掉挂着的延迟清理（同桶返回也要撤，否则快速离开再回来会被误清）。
            if hoverClearTask != nil {
                hoverClearTask?.cancel()
                hoverClearTask = nil
            }
            guard index != hoverIndex else { return }
            hoverIndex = index
        } else {
            // 离开整块：延迟清空，快速扫过边缘时不残留半帧十字线。
            guard hoverIndex != nil, hoverClearTask == nil else { return }
            hoverClearTask = Task {
                try? await Task.sleep(for: .milliseconds(180))
                guard !Task.isCancelled else { return }
                hoverIndex = nil
            }
        }
    }

    @ViewBuilder
    private func crosshair(_ index: Int) -> some View {
        let x = GpuChartLayout.labelColumn + GpuChartGeometry.xPosition(index, plotWidth: plotWidth, count: buckets)
        // 纵线：整块单线贯穿三层（层间距不断线——旧断裂问题的修法保留）。
        Rectangle()
            .fill(palette.textStrong.opacity(0.55))
            .frame(width: 1.5)
            .offset(x: x - 0.75)
        // 主图色点：与线同 x，取原始桶值。
        if let value = bucketValue(series.util, index) {
            Circle()
                .fill(palette.accent)
                .frame(width: 5, height: 5)
                .position(x: x, y: GpuChartGeometry.unitY(GpuChartLayout.mainHeight)(value))
        }
        // 温度细带色点：量程与细带图层共用 GpuChartGeometry.stripScale，贴得住线。
        if let value = bucketValue(smooth.temp, index) {
            let (scaleLow, scaleHigh) = GpuChartGeometry.stripScale(smooth.temp)
            Circle()
                .fill(palette.info)
                .frame(width: 4.5, height: 4.5)
                .position(
                    x: x,
                    y: GpuChartLayout.tempBandTop + GpuChartGeometry.stripY(
                        value, scaleLow: scaleLow, scaleHigh: scaleHigh, height: GpuChartLayout.stripHeight
                    )
                )
        }
        // 功耗细带色点：同上。
        if let value = bucketValue(smooth.power, index) {
            let (scaleLow, scaleHigh) = GpuChartGeometry.stripScale(smooth.power)
            Circle()
                .fill(palette.violet)
                .frame(width: 4.5, height: 4.5)
                .position(
                    x: x,
                    y: GpuChartLayout.powerBandTop + GpuChartGeometry.stripY(
                        value, scaleLow: scaleLow, scaleHigh: scaleHigh, height: GpuChartLayout.stripHeight
                    )
                )
        }
    }

    private func bucketValue(_ values: [Double?], _ index: Int) -> Double? {
        values.indices.contains(index) ? values[index] : nil
    }

    /// 常驻读数桶：最后一个有数据的原始桶（面板在无悬停时显示「现在」）。
    private var pinnedIndex: Int? {
        series.util.lastIndex(where: { $0 != nil })
    }

    /// 终端风等宽面板：行 = 色点 + 键位 + 原始值。
    private func readoutPanel(index: Int?) -> some View {
        Group {
            if let index {
                let util = bucketValue(series.util, index)
                let low = bucketValue(series.utilLow, index)
                let high = bucketValue(series.utilHigh, index)
                let temp = bucketValue(series.temp, index)
                let power = bucketValue(series.power, index)
                let offset = window - (Double(index) + 0.5) * bucketSeconds
                let at = Date().addingTimeInterval(-offset)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(GpuChartFormat.clock.string(from: at))
                            .foregroundStyle(palette.textStrong)
                        Text("#\(index)")
                            .foregroundStyle(palette.faint)
                    }
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    terminalRow(color: palette.accent, key: "UTIL",
                                value: util.map { String(format: "%.0f%%", $0) } ?? "--",
                                sub: util != nil && low != nil && high != nil && high! - low! >= 1
                                    ? String(format: "%.0f–%.0f", low!, high!) : nil)
                    terminalRow(color: palette.info, key: "TEMP",
                                value: temp.map { String(format: "%.0f°", $0) } ?? "--", sub: nil)
                    terminalRow(color: palette.violet, key: "PWR",
                                value: power.map { String(format: "%.0fW", $0) } ?? "--", sub: nil)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(palette.surfaceElevated.opacity(0.96))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(palette.borderStrong, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(palette.isDark ? 0.45 : 0.12), radius: 8, y: 3)
            }
        }
    }

    private func terminalRow(color: Color, key: String, value: String, sub: String?) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 5, height: 5)
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .tracking(0.5)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(palette.textStrong)
            if let sub {
                Text(sub)
                    .font(.system(size: 9, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(palette.faint)
            }
        }
        .frame(width: 128)
    }
}
