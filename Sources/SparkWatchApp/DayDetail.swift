import SparkWatchCore
import SwiftUI

// MARK: - 当天详情（点历史柱状图下钻）
//
// 「点击某天柱看那天」的两块面板 + 它们共用的壳与按模型表。组件只吃契约
// （DayQueries.swift 的 TokenDayDetail / EnergyDayDetail / TokenLedger.ModelRow），
// 不知道账本怎么存——数据层换实现，这里不用动。
//
// 诚实性规矩沿用 DailyBars：hasData == false / kwh == nil 是「没有任何记录」，
// 不是「用量为零」。空态文案把这一点直接说给用户：那天引擎可能没在跑。

/// `2026-11-09` → `2026-11-09 周日`。星期按**本机日历**算：用户说「那天」时，
/// 心里的周日就是自己时区里的周日（账本内部按 UTC 小时桶存，这里展示本地口径）。
func dayHeading(_ day: String) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
        let date = Calendar.current.date(
            from: DateComponents(year: parts[0], month: parts[1], day: parts[2])
        )
    else { return day }
    let names = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
    return "\(day) \(names[Calendar.current.component(.weekday, from: date) - 1])"
}

/// 「11 月 9 日没有记录」里的日期部分（空态文案用）。
func dayPhrase(_ day: String) -> String {
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3 else { return day }
    return "\(parts[1]) 月 \(parts[2]) 日"
}

/// 时区标注：`Asia/Shanghai` → `UTC+8`。
///
/// 「那天」的边界取决于时区，详情头必须把口径写出来——跨机对账的人看到的
/// UTC+8 与 UTC 的同一天，差着八个钟头的账。
func timeZoneLabel(_ identifier: String) -> String {
    guard let zone = TimeZone(identifier: identifier) else { return identifier }
    let seconds = zone.secondsFromGMT()
    guard seconds != 0 else { return "UTC" }
    let sign = seconds < 0 ? "-" : "+"
    let hours = abs(seconds) / 3600
    let minutes = abs(seconds) % 3600 / 60
    return minutes == 0
        ? "UTC\(sign)\(hours)"
        : "UTC\(sign)\(hours):\(String(format: "%02d", minutes))"
}

/// 详情面板的壳：标题 + 时区 + 右上 ✕，内容由 @ViewBuilder 给。
///
/// 出现动画挂在壳上（底部滑入 + 淡入）；`.animation(..., value: 选中id)` 由调用方
/// 提供——动画跟着「选中哪天」走，而不是跟着数据 tick 走，否则每 2s 刷新一次
/// 面板就要闪一次。
struct DayDetailCard<Content: View>: View {
    var day: String
    var timeZoneIdentifier: String?
    var palette: Palette
    var onClose: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(dayHeading(day))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                if let timeZoneIdentifier {
                    Text(timeZoneLabel(timeZoneIdentifier))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 8)
                Button(action: onClose) {
                    Text("✕")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(palette.surfaceHover))
                }
                .buttonStyle(.plain)
                .help("收起当天详情")
            }
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(palette.surfaceElevated))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Token 按模型表（区间表与当日表共用）

/// Token 按模型表。Token 统计页的区间表和某天详情的当日表共用同一个组件：
/// 列宽、`numberCell` 的不折行规矩只能有一份，两个表面各自实现迟早漂移。
struct TokenModelTable: View {
    var rows: [TokenLedger.ModelRow]
    var palette: Palette

    /// 数字列宽：只用来对齐，不当作硬约束。
    static let numberColumn: CGFloat = 74

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("模型").frame(maxWidth: .infinity, alignment: .leading)
                numberCell("缓存")
                numberCell("prefill")
                numberCell("生成")
            }
            .font(.system(size: 10.5, weight: .semibold, design: .rounded))
            .textCase(.uppercase)
            .tracking(0.8)
            .foregroundStyle(.tertiary)
            .padding(.vertical, 5)

            ForEach(rows, id: \.model) { row in
                HStack(spacing: 8) {
                    Text(row.model)
                        .font(.system(size: 12.5, design: .rounded))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if row.seriesCount > 1 {
                        Text("×\(row.seriesCount)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                    numberCell(row.cached > 0 ? compactTokens(row.cached) : "—")
                    numberCell(compactTokens(max(0, row.prompt - row.cached)))
                    numberCell(compactTokens(row.completion))
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                }
                .font(.system(size: 12.5, design: .monospaced))
                .foregroundStyle(palette.mutedStrong)
                .padding(.vertical, 5)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    /// 一个数字格：**永远单行**。
    ///
    /// 原来只写 `.frame(width: 70, alignment: .trailing)`，窗口一窄 SwiftUI 会把这几个
    /// "固定宽"一起压缩，数字于是**折到第二行** —— 用户报的「token 这里数字都换行了」。
    /// 实测 900 pt 宽时最后那一列直接看不见，中间还飘出 `20M` / `236.1k` 这样的碎片。
    /// 所以：`lineLimit(1)` 保证不折行，`minimumScaleFactor` 允许在极窄时缩一点字号，
    /// `layoutPriority(1)` 让**被压的是模型名**（它本来就按中间省略号截断，那才是该让位的列）。
    private func numberCell(_ text: String) -> some View {
        Text(text)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: Self.numberColumn, alignment: .trailing)
            .layoutPriority(1)
    }
}

// MARK: - Token 某天

struct TokenDayDetailPanel: View {
    var detail: TokenDayDetail
    var palette: Palette
    var onClose: () -> Void

    /// totals 全 0 且没有任何模型行 = 那天真的什么都没记（不是「用量为零」）。
    private var isEmpty: Bool {
        detail.totals.prompt == 0 && detail.totals.completion == 0
            && detail.totals.cached == 0 && detail.byModel.isEmpty
    }

    var body: some View {
        DayDetailCard(day: detail.day, timeZoneIdentifier: detail.timeZoneIdentifier, palette: palette, onClose: onClose) {
            if isEmpty {
                Text("\(dayPhrase(detail.day))没有记录：那天引擎可能没在跑。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    // 当日构成：分段与配色对齐 Token 统计页顶部——看得懂上面，
                    // 就读得懂这里；同一天两种画法反而让人怀疑数据。
                    SegBar(segments: [
                        .init(label: "生成", value: detail.totals.completion, color: palette.accent,
                              text: compactTokens(detail.totals.completion), unit: ""),
                        .init(label: "缓存命中", value: detail.totals.cached, color: palette.info,
                              text: compactTokens(detail.totals.cached), unit: ""),
                        .init(label: "实际计算 prefill",
                              value: max(0, detail.totals.prompt - detail.totals.cached),
                              color: palette.violet,
                              text: compactTokens(max(0, detail.totals.prompt - detail.totals.cached)),
                              unit: ""),
                    ], height: 10)

                    // 当日逐小时生成量。valueText 传 nil：柱顶不常驻数字，
                    // 悬停 chip 里读（DailyBars 对 nil 退回紧凑数字）。
                    DailyBars(
                        bars: detail.hourly.enumerated().map { index, hour in
                            DailyBars.Bar(
                                id: "\(detail.day)-hour-\(index)",
                                label: "\(index)时",
                                value: hour.hasData ? hour.completion : nil,
                                valueText: nil,
                                help: hour.hasData
                                    ? "\(index) 时 · 生成 \(compactTokens(hour.completion)) token"
                                    : "\(index) 时 · 无记录"
                            )
                        },
                        tint: palette.accent,
                        palette: palette,
                        height: 44,
                        highlightLast: false
                    )

                    TokenModelTable(rows: detail.byModel, palette: palette)

                    Text("\(detail.seriesCount) 条 series 记账 · 账本按 UTC 小时桶存储，此处按本地日聚合")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 能耗某天

struct EnergyDayDetailPanel: View {
    var detail: EnergyDayDetail
    var palette: Palette
    var onClose: () -> Void

    var body: some View {
        DayDetailCard(day: detail.day, timeZoneIdentifier: detail.timeZoneIdentifier, palette: palette, onClose: onClose) {
            if detail.kwh == nil {
                // kwh == nil ⇔ coverage == 0：那天一分钟的读数都没有。
                Text("\(dayPhrase(detail.day))没有记录：那天引擎可能没在跑。")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .top, spacing: 0) {
                        statCell("当天电量", String(format: "%.2f", detail.kwh!), unit: "kWh",
                                 help: "该日分钟桶积分的 Wh ÷ 1000（估算模型，不是功率计）")
                        statCell("平均功率", detail.avgWatts.map { String(format: "%.0f", $0) }, unit: "W",
                                 help: "覆盖时间加权的平均瓦数")
                        statCell("峰值小时", detail.peakWatts.map { String(format: "%.0f", $0) }, unit: "W",
                                 help: "各小时均值里的最大值——那天最猛的一小时")
                        statCell("采样覆盖", String(format: "%.0f%%", detail.coverage * 100), unit: nil,
                                 help: "被采样覆盖的时间比例；缺口时段没有读数，不是零")
                    }

                    // 逐小时均值瓦数。nil 小时由 DailyBars 画成小竖条（无覆盖 ≠ 0 W）。
                    DailyBars(
                        bars: detail.hourly.enumerated().map { index, watts in
                            DailyBars.Bar(
                                id: "\(detail.day)-hour-\(index)",
                                label: "\(index)时",
                                value: watts,
                                valueText: watts.map { String(format: "%.0f W", $0) },
                                help: watts.map { "\(index) 时 · 均值 \(String(format: "%.0f", $0)) W" }
                                    ?? "\(index) 时 · 无覆盖"
                            )
                        },
                        tint: palette.accent,
                        palette: palette,
                        height: 44,
                        highlightLast: false
                    )

                    Text("估算值，非墙上功率计 · 覆盖 \(String(format: "%.0f%%", detail.coverage * 100))，缺口时段无读数")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// statPanel 风格的一格：小标签 + 大数字（+ 单位）。四格平铺一排。
    private func statCell(_ label: String, _ value: String?, unit: String?, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            NumberUnit(value: value ?? "--", unit: unit ?? "", size: 18, tint: palette.textStrong)
                .help(help)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
