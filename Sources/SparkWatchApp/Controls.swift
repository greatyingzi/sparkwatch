import AppKit
import SparkWatchCore
import SwiftUI

// MARK: - Ring
//
// The circular gauge: a full-circle track plus a value arc, the figure in the
// middle and an optional caption above it.
//
// Why this replaced "big number over a long bar": a bar's information is bound
// to its *length*. To fit "label + bar + value" on one row the bar has to be
// short, and a short bar cannot show a 5 % difference. A ring puts the same
// three roles (what / how much / how much of the whole) inside one square, so
// more of them fit on screen — measured on this app's own popover, the ring
// layout is 700 pt tall against 734 pt for the bar layout, for the same two
// machines. It also reads better: arc length resolves small changes better than
// a straight line of the same extent, which is why dials have survived a
// century of dashboards.
//
// Geometry rule: a **full** circle, arc starting at 12 o'clock, clockwise,
// round cap. Deliberately *not* the 270°-open automotive dial — an open arc
// throws away a quarter of the available arc resolution and "turn all the way
// round" carries no meaning of its own.
//
// A ring holds exactly **one** number. Anything else about the same machine
// goes outside it; two values fighting for one ring is worse than two bars.
struct Ring: View {
    /// 0–100. `nil` draws the track only (a value we do not have, rather than 0).
    var value: Double?
    var size: CGFloat = 88
    var stroke: CGFloat = 8
    var tint: Color
    /// Drawn above the ring, outside it.
    var caption: String?
    /// Centre label. Defaults to the rounded percentage.
    var label: String?
    /// Small unit under the centre label ("%" by default; use "" to hide).
    var unit: String? = "%"
    var help: String?

    private var fraction: Double {
        guard let value, value.isFinite else { return 0 }
        return min(max(value, 0), 100) / 100
    }

    var body: some View {
        VStack(spacing: 5) {
            if let caption {
                Text(caption)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
            }
            ZStack {
                Circle()
                    .stroke(tint.opacity(value == nil ? 0.10 : 0.16), lineWidth: stroke)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(tint, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.5), value: fraction)
                VStack(spacing: 0) {
                    Text(label ?? (value.map { String(format: "%.0f", $0) } ?? "--"))
                        .font(.system(size: size * 0.30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(value == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(tint))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    if let unit, !unit.isEmpty {
                        Text(unit)
                            .font(.system(size: size * 0.12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, stroke + 2)
            }
            .frame(width: size, height: size)
        }
        .help(help ?? "")
    }
}

// MARK: - SegBar
//
// A stacked breakdown bar answering "**who** took it", which a single-colour
// occupancy bar cannot: on a unified-memory box, "96 GB of 121 GB used" is the
// normal reading for a healthy machine, and it is the split (model weights vs
// KV cache vs system) that turns it into a decision.
struct SegBar: View {
    struct Segment {
        var label: String
        var value: Double
        var color: Color
        /// Right-hand figure for the legend, e.g. "97.1". Pre-formatted so the
        /// view never has to know whether the unit is GB, tokens or percent.
        var text: String
        var unit: String = "GB"
    }

    var segments: [Segment]
    var height: CGFloat = 10
    /// One line, no wrap, smaller labels — for the popover, where 30 pt of
    /// legend is 30 pt the cards cannot spend.
    var compact: Bool = false
    /// Shows the legend under the bar. Off when the caller draws its own.
    var showsLegend: Bool = true

    private var total: Double {
        let sum = segments.reduce(0) { $0 + max(0, $1.value) }
        return sum > 0 ? sum : 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { proxy in
                let gap: CGFloat = 2
                let usable = max(0, proxy.size.width - gap * CGFloat(max(0, segments.count - 1)))
                HStack(spacing: gap) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(segment.color)
                            .frame(width: usable * CGFloat(max(0, segment.value) / total))
                    }
                }
            }
            .frame(height: height)

            if showsLegend {
                if compact {
                    HStack(spacing: 10) {
                        ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                            legendItem(segment, size: 7)
                        }
                        Spacer(minLength: 0)
                    }
                    .lineLimit(1)
                } else {
                    // Wraps: the full tier has room for real labels.
                    FlowLegend(segments: segments)
                }
            }
        }
    }

    private func legendItem(_ segment: Segment, size: CGFloat) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(segment.color)
                .frame(width: size, height: size)
            Text(segment.label)
            Text(segment.text)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.system(size: compact ? 10 : 11, design: .rounded))
        .foregroundStyle(.secondary)
        .fixedSize()
    }
}

/// Simple wrapping legend for the non-compact tier (SwiftUI has no flow layout
/// before macOS 13's `Layout`, and a hand-rolled two-row layout is more
/// predictable than a `LazyVGrid` for four short items).
private struct FlowLegend: View {
    var segments: [SegBar.Segment]
    var body: some View {
        let rows = stride(from: 0, to: segments.count, by: 2).map {
            Array(segments[$0..<min($0 + 2, segments.count)])
        }
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 14) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, segment in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(segment.color)
                                .frame(width: 8, height: 8)
                            Text(segment.label)
                            Text("\(segment.text) \(segment.unit)")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Small display pieces

struct StatusDot: View {
    var level: HealthLevel
    var palette: Palette

    var body: some View {
        Circle()
            .fill(palette.accent(for: level))
            .frame(width: 8, height: 8)
            .overlay(Circle().stroke(palette.base.opacity(0.35), lineWidth: 0.5))
            .shadow(color: palette.accent(for: level).opacity(level == .ok ? 0.55 : 0), radius: 3)
    }
}

struct Chip: View {
    var text: String
    var tint: Color = .secondary
    var compact = false

    var body: some View {
        Text(text)
            .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold, design: .rounded))
            .padding(.horizontal, compact ? 5 : 6)
            .padding(.vertical, compact ? 1.5 : 2)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundStyle(tint)
            .lineLimit(1)
            .fixedSize()
    }
}

/// Label over a big monospaced number over an optional unit line — the repeating
/// unit of the cards' right-hand block.
struct KVBox: View {
    var key: String
    var value: String
    var unit: String?
    var tint: Color
    var help: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit)
                        .font(.system(size: 9.5, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(help ?? "")
    }
}

/// One line of `key value` pairs — the popover's replacement for four separate
/// boxes. Saves ~30 pt per card, which is what decides whether two machines fit
/// on a 900 pt screen.
struct StatLine: View {
    struct Item {
        var key: String
        var value: String
        var tint: Color = .secondary
    }
    var items: [Item]
    var trailing: String?

    var body: some View {
        HStack(spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 3) {
                    Text(item.key)
                    Text(item.value)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(item.tint)
                }
                .fixedSize()
            }
            Spacer(minLength: 0)
            if let trailing {
                Text(trailing)
                    .font(.system(size: 9.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10, design: .rounded))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

/// Filled area sparkline with an end dot. Reads as "trend" at a glance without
/// axes or labels; the end dot is what makes "now" findable in a 30-point line.
struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var fixedMax: Double?
    var showsEndDot = true

    var body: some View {
        GeometryReader { geometry in
            let points = normalized(in: geometry.size)
            ZStack {
                if points.count > 1 {
                    Path { path in
                        path.move(to: CGPoint(x: points[0].x, y: geometry.size.height))
                        for point in points { path.addLine(to: point) }
                        path.addLine(to: CGPoint(x: points[points.count - 1].x, y: geometry.size.height))
                        path.closeSubpath()
                    }
                    .fill(
                        LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.01)],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                    Path { path in
                        path.move(to: points[0])
                        for point in points.dropFirst() { path.addLine(to: point) }
                    }
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineJoin: .round))
                    if showsEndDot, let last = points.last {
                        Circle()
                            .fill(tint)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(tint.opacity(0.25), lineWidth: 3))
                            .position(last)
                    }
                }
            }
        }
    }

    private func normalized(in size: CGSize) -> [CGPoint] {
        guard !values.isEmpty else { return [] }
        let top = max(fixedMax ?? 0, values.max() ?? 1, 1)
        let step = size.width / CGFloat(max(values.count - 1, 1))
        return values.enumerated().map { index, value in
            let ratio = min(max(value / top, 0), 1)
            return CGPoint(x: CGFloat(index) * step, y: size.height * (1 - ratio))
        }
    }
}

/// 6 pt occupancy bar with a caption row. Kept alongside `Ring` because not
/// every metric deserves a ring — a ring is for the one number a machine is
/// judged by, a bar is for the rest.
struct MeterBar: View {
    var fraction: Double?
    var tint: Color
    var label: String
    var caption: String?
    var palette: Palette
    var height: CGFloat = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption {
                HStack(alignment: .firstTextBaseline) {
                    Text(label)
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(caption)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(max(fraction ?? 0, 0), 1))
                }
            }
            .frame(height: height)
            if caption == nil {
                Text(label)
                    .font(.system(size: 9.5, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Label / big value / detail — the detail window's metric cell.
struct Metric: View {
    var title: String
    var value: String
    var unit: String?
    var detail: String?
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                .tracking(0.4)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                    .fixedSize()
                if let unit {
                    Text(unit)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            if let detail {
                Text(detail)
                    .font(.system(size: 9.5, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A key/value pair in a fixed column, so pairs line up between rows and between
/// cards instead of drifting with the value's width.
/// 「数字 + 单位」：**永不折行的一对**。
///
/// 这一对在窄容器里会被 SwiftUI 拆开 —— 数字断成两行、单位飘到下一行 —— 因为数值文本
/// 默认允许折行，而 `frame(width:)` 并不提供"不许折行"的保证。同一个数字被拆成两半是
/// 最难认的一种 UI bug：它看起来像排版问题，其实是数据看着不像数据了。
///
/// 所以凡是「值 + 单位」都走这里：数值 `lineLimit(1)` + 可缩字号（宁可缩也不折也不截），
/// 单位 `fixedSize`（单位很短，永远保住）。
struct NumberUnit: View {
    var value: String
    var unit: String
    var size: CGFloat = 22
    var unitSize: CGFloat = 11
    var tint: Color = .primary
    var weight: Font.Weight = .semibold
    var design: Font.Design = .monospaced
    var tracking: CGFloat = 0

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: weight, design: design))
                .monospacedDigit()
                .tracking(tracking)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: unitSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
    }
}

struct StatCell: View {
    var key: String
    var value: String
    var help: String?
    /// Optional emphasis for values that carry a state (an incident counter that is
    /// rising, a pressure that is high). Nil keeps the calm secondary colour.
    var tint: Color?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(tint ?? .secondary)
                .lineLimit(1)
                // 宁可缩字号也别截断：一个被省略号吃掉的数字同样是读不出来的数据。
                .minimumScaleFactor(0.8)
        }
        .help(help ?? "")
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
