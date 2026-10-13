import AppKit
import SparkWatchCore
import SwiftUI

/// The GPU history chart: utilisation as an envelope + mean line, with temperature
/// and power behind it, over 30 minutes, 1 hour or 8 hours.
///
/// Three decisions, each from looking at the real data rather than at the design:
///
///  1. **An envelope, not just a line.** On this hardware utilisation swings between
///     ~95 % and ~0 % *inside a single bucket* — the engine is busy, then idle, then
///     busy — and the GPU rail swings tens of watts with it (measured on this fleet:
///     adjacent-bucket jumps average 15.6 points of utilisation and 9.3 W, with
///     maxima of 96 points and 84 W). A mean line through that is a picket fence.
///     The min–max band shows the swing, the line shows where it sat, and neither is
///     smoothed into a shape the hardware did not produce.
///  2. **The x-axis zooms to the data.** A fixed 30-minute window is honest but looks
///     broken for the first half hour after launch, because the history starts when
///     the app does. When less than ~60 % of the requested span exists, the chart
///     draws the span it *has* and says so ("历史起点 9 分钟前") instead of leaving
///     two thirds of the canvas empty.
///  3. **Gaps stay gaps.** The series comes from a ring buffer with a 1.5 s sampling
///     floor; anything not observed is a hole, not a straight line through it.
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

    private var available: TimeInterval { model.historySpan(for: nodeID) }

    /// 几何（窗口 / 桶数 / 是否缩放）来自 Core 的纯函数 `GpuChartScale`。
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

    var body: some View {
        let data = series
        return VStack(alignment: .leading, spacing: 10) {
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

            chart(data)

            HStack(spacing: 14) {
                legendItem("利用率", value: data.maxUtil.map { String(format: "峰值 %.0f%%", $0) }, color: palette.accent)
                legendItem("温度", value: data.maxTemp.map { String(format: "峰值 %.0f°C", $0) }, color: palette.info)
                legendItem("功耗", value: data.maxPower.map { String(format: "峰值 %.0f W", $0) }, color: palette.violet)
                Spacer(minLength: 0)
                Text(coverageLabel(data))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }

            Text("共用 0–100 量程（利用率 %、温度 °C、功耗 W）。每格是约 \(Int(bucketSeconds)) 秒的平均值 —— 这台机器几秒内就能从 95% 摆到 0%，所以看到的是**占空比**而不是瞬时值；没观测到的时段留空，不连线。")
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

    private func coverageLabel(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    ) -> String {
        let filled = data.util.compactMap { $0 }.count
        let total = max(data.util.count, 1)
        return String(format: "%d/%d 个采样桶有数据（%.0f%%）", filled, total, Double(filled) / Double(total) * 100)
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

    private func chart(
        _ data: (util: [Double?], power: [Double?], temp: [Double?],
            utilLow: [Double?], utilHigh: [Double?],
            maxUtil: Double?, maxPower: Double?, maxTemp: Double?)
    ) -> some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height: CGFloat = 170
            ZStack(alignment: .topLeading) {
                ForEach([0, 25, 50, 75, 100], id: \.self) { level in
                    let y = height - height * CGFloat(level) / 100
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: width, y: y))
                    }
                    .stroke(palette.grid, style: StrokeStyle(lineWidth: 1, dash: [2, 4]))
                }

                // Secondary series first, so the primary one reads on top of them.
                seriesPath(data.temp, width: width, height: height)
                    .stroke(palette.info.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                seriesPath(data.power, width: width, height: height)
                    .stroke(palette.violet.opacity(0.7), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                envelopePath(low: data.utilLow, high: data.utilHigh, width: width, height: height)
                    .fill(palette.accent.opacity(0.14))
                seriesPath(data.util, width: width, height: height)
                    .stroke(palette.accent, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))

                axisLabels(width: width, height: height)
            }
        }
        .frame(height: 170)
    }

    /// The y scale is written on the left, the actual span on the bottom: without
    /// the span label a zoomed chart silently claims to be the requested window.
    private func axisLabels(width: CGFloat, height: CGFloat) -> some View {
        let minutes = Int(effectiveWindow / 60)
        let left: String = minutes >= 120
            ? String(format: "%.0f 小时前", effectiveWindow / 3600)
            : "\(max(minutes, 1)) 分钟前"
        return ZStack(alignment: .topLeading) {
            Text("100%").position(x: 22, y: 8)
            Text("0").position(x: 12, y: height - 16)
            HStack {
                Text(left)
                Spacer()
                Text("现在")
            }
            .frame(width: width - 24)
            .position(x: width / 2, y: height - 6)
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.tertiary)
        .frame(width: width, height: height, alignment: .topLeading)
    }

    /// One path per series, with a break wherever a bucket has no data. A single
    /// `Path` with `move(to:)` at each gap start is what keeps the line from
    /// bridging the hole.
    private func seriesPath(_ values: [Double?], width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard !values.isEmpty, width > 0 else { return path }
        let step = width / CGFloat(max(values.count - 1, 1))
        var started = false
        for (index, value) in values.enumerated() {
            guard let value else {
                started = false
                continue
            }
            let point = CGPoint(
                x: CGFloat(index) * step,
                y: height - height * CGFloat(min(max(value, 0), 100)) / 100
            )
            if started {
                path.addLine(to: point)
            } else {
                path.move(to: point)
                started = true
            }
        }
        return path
    }

    /// The min–max band: along the highs, back along the lows, closed. Built per
    /// contiguous run, so a gap is a gap and not a bridge.
    private func envelopePath(low: [Double?], high: [Double?], width: CGFloat, height: CGFloat) -> Path {
        var path = Path()
        guard low.count == high.count, !low.isEmpty, width > 0 else { return path }
        let step = width / CGFloat(max(low.count - 1, 1))
        let y = { (value: Double) in height - height * CGFloat(min(max(value, 0), 100)) / 100 }
        var run: [(x: CGFloat, lo: CGFloat, hi: CGFloat)] = []
        func flush() {
            if run.count > 1 {
                path.move(to: CGPoint(x: run[0].x, y: run[0].hi))
                for point in run.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.hi)) }
                for point in run.reversed() { path.addLine(to: CGPoint(x: point.x, y: point.lo)) }
                path.closeSubpath()
            }
            run.removeAll()
        }
        for index in 0..<low.count {
            guard let l = low[index], let h = high[index] else {
                flush()
                continue
            }
            run.append((x: CGFloat(index) * step, lo: y(l), hi: y(h)))
        }
        flush()
        return path
    }
}
