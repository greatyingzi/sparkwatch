import AppKit
import SparkWatchCore
import SwiftUI

/// The fleet-level pages: energy, token totals, activity, benchmarks.
///
/// These are the four things that need *time* rather than an instant, which is why
/// they live in the window and not in the popover: a popover can only show what is
/// true right now, and "how much did this box cost me in the last 24 hours" is not
/// that kind of question.
struct FleetPage: View {
    @ObservedObject var model: AppModel
    var page: MainPage
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch page {
            case .energy: EnergyPage(model: model, palette: palette)
            case .tokens: TokenPage(model: model, palette: palette)
            case .activity: ActivityPage(model: model, palette: palette)
            case .benchmarks: BenchmarkPage(model: model, palette: palette)
            default: EmptyView()
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: - Shared pieces

struct PageHeader: View {
    var title: String
    var meta: [String]
    var palette: Palette
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .tracking(-0.5)
                if !meta.isEmpty {
                    Text(meta.joined(separator: " · "))
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
    }
}

struct Panel<Content: View>: View {
    var title: String?
    var palette: Palette
    var trailing: AnyView?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                    Spacer(minLength: 0)
                    if let trailing { trailing }
                }
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(palette.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(palette.border, lineWidth: 1)
        )
    }
}

/// Token counts get big fast, and a dashboard that prints `141006155` is unreadable
/// at a glance.
func compactTokens(_ value: Double) -> String {
    switch value {
    case ..<10_000: String(format: "%.0f", value)
    case ..<1_000_000: String(format: "%.1fk", value / 1_000)
    case ..<1_000_000_000: String(format: "%.2fM", value / 1_000_000)
    default: String(format: "%.2fB", value / 1_000_000_000)
    }
}

// MARK: - Energy

struct EnergyPage: View {
    @ObservedObject var model: AppModel
    var palette: Palette

    private var snapshot: EnergyLedger.Snapshot? { model.energySnapshot }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "能耗",
                meta: [
                    "\(model.nodes.count) 台机器",
                    snapshot.map { String(format: "24 小时覆盖 %.0f%%", $0.coverage24h * 100) } ?? "等待数据",
                    "估算值，非墙上功率计",
                    "按本地日聚合",
                ],
                palette: palette
            )

            Panel(title: "最近 24 小时", palette: palette) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(snapshot.map { String(format: "%.2f", $0.energy24hKWh) } ?? "--")
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                        Text("kWh / 24 h")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if let watts = snapshot?.currentWatts {
                            Text(String(format: "当前 %.0f W", watts))
                                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                                .monospacedDigit()
                                .foregroundStyle(palette.violet)
                        }
                    }
                    histogram
                    if model.hourlyWatts.count > 1 {
                        HStack {
                            Text("24 小时前").font(.system(size: 10.5, design: .monospaced))
                            Spacer()
                            Text("12 小时").font(.system(size: 10.5, design: .monospaced))
                            Spacer()
                            Text("现在").font(.system(size: 10.5, design: .monospaced))
                        }
                        .foregroundStyle(.tertiary)
                    }
                }
            }

            dailyPanel

            HStack(alignment: .top, spacing: 14) {
                statPanel(
                    "31 天", snapshot.map { String(format: "%.1f kWh", $0.energy31dKWh) } ?? "--",
                    foot: snapshot.map { String(format: "覆盖 %.0f%%", $0.coverage31d * 100) } ?? ""
                )
                statPanel(
                    "效率",
                    snapshot?.whPerOutputToken.map { String(format: "%.2f", $0 * 1000) } ?? "--",
                    foot: "每 1000 生成 token 的 Wh（按有覆盖的窗口算）"
                )
                statPanel(
                    "GPU 轨占比",
                    gpuShare,
                    foot: "GPU 实测功耗 ÷ 整机估算 —— 其余是 CPU、内存与网卡"
                )
            }

            Text("整机瓦数 = GPU 轨实测 + CPU 估算（按 TDP 线性）+ 23 W 外设底，上限 240 W。GB10 没有整机功率计（无 RAPL、无 hwmon 功率传感器、无 BMC），所以这是一个模型，不是测量值。")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var gpuShare: String {
        let gpu = model.nodes.reduce(0.0) { $0 + ($1.gpu.powerW ?? 0) }
        let whole = model.nodes.reduce(0.0) {
            $0 + ($1.power?.wallW ?? model.powerEstimate.wholeMachineW(gpuW: $1.gpu.powerW) ?? 0)
        }
        guard whole > 0 else { return "--" }
        return String(format: "%.0f%%", gpu / whole * 100)
    }

    private var histogram: some View {
        DailyBars(
            bars: model.hourlyWatts.enumerated().map { index, watts in
                let hoursAgo = model.hourlyWatts.count - 1 - index
                return DailyBars.Bar(
                    id: "h\(hoursAgo)",
                    label: hoursAgo == 0 ? "现在" : "\(hoursAgo) 小时前",
                    value: watts,
                    // 24 根柱放不下常驻数字：数值走悬停 chip（DailyBars 的规矩）。
                    valueText: watts.map { String(format: "%.0f W", $0) },
                    help: watts.map { String(format: "%@ · %.0f W", hourLabel(index), $0) }
                        ?? "\(hourLabel(index)) · 无完整覆盖"
                )
            },
            tint: palette.accent,
            palette: palette
        )
    }

    /// 按天（31 天）：柱顶 kWh 数字、点击下钻当天详情。
    ///
    /// 单位只在角标与脚注里出现一次——31 根柱每根都缀个"kWh"就是噪声；
    /// valueText 只写数字（`%.1f`）。
    private var dailyPanel: some View {
        Panel(title: "按天（31 天）", palette: palette, trailing: AnyView(
            Text("单位 kWh · 本地日边界")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if model.energyDaily.allSatisfy({ $0.kwh == nil }) {
                    Text("还没有跨天的能耗记录。能耗按分钟桶积分、按本地日聚合展示（保留 31 天）；整机的瓦数是模型估算，不是测量值。")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    DailyBars(
                        bars: model.energyDaily.map { entry in
                            DailyBars.Bar(
                                id: entry.day,
                                label: shortDay(entry.day),
                                // kwh == nil ⇔ 那天无覆盖：画小竖条，不是零高柱。
                                value: entry.kwh,
                                valueText: entry.kwh.map { String(format: "%.1f", $0) },
                                help: entry.kwh.map {
                                    "\(entry.day) · \(String(format: "%.1f", $0)) kWh · 覆盖 \(String(format: "%.0f%%", entry.coverage * 100)) · 点按看当天"
                                } ?? "\(entry.day) · 无覆盖"
                            )
                        },
                        tint: palette.accent,
                        palette: palette,
                        showValues: true,
                        selection: Binding(
                            get: { model.selectedEnergyDay },
                            set: { model.setEnergyDay($0) }
                        )
                    )
                    Text("最后一根是今天（未结束）。柱顶是当天 kWh；点某根柱看当天详情，再点一次或 ✕ 收起。没有覆盖的那天画成小竖条，而不是零高。")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // 选中即面板，不弹窗：详情内联在图下方展开。
                if let detail = model.energyDayDetail {
                    EnergyDayDetailPanel(detail: detail, palette: palette) {
                        model.setEnergyDay(nil)
                    }
                }
            }
            // 动画只跟「选中哪天」走；挂在数据 tick 上会每 2s 闪一次。
            .animation(.easeOut(duration: 0.2), value: model.selectedEnergyDay)
        }
    }

    private func hourLabel(_ index: Int) -> String {
        let hoursAgo = model.hourlyWatts.count - 1 - index
        return hoursAgo == 0 ? "现在" : "\(hoursAgo) 小时前"
    }

    private func statPanel(_ title: String, _ value: String, foot: String) -> some View {
        Panel(title: title, palette: palette) {
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text(foot)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Tokens

struct TokenPage: View {
    @ObservedObject var model: AppModel
    var palette: Palette

    var body: some View {
        let totals = model.tokenTotals
        let grand = totals.completion + totals.cached + max(0, totals.prompt - totals.cached)
        return VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "Token 统计",
                meta: [
                    "\(model.nodes.count) 个端点",
                    "按引擎累计计数器差分记账",
                    "本地日边界（账本内部 UTC 小时桶）",
                ],
                palette: palette,
                trailing: AnyView(rangePicker)
            )

            Panel(palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(compactTokens(totals.completion))
                            .font(.system(size: 34, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            // 大字也不许折行：这是整页最显眼的数字。
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .fixedSize(horizontal: true, vertical: false)
                        Text("生成")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Text(model.tokenRange.label)
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(palette.accentText)
                    }
                    SegBar(segments: [
                        .init(label: "生成", value: totals.completion, color: palette.accent,
                              text: compactTokens(totals.completion), unit: ""),
                        .init(label: "缓存命中", value: totals.cached, color: palette.info,
                              text: compactTokens(totals.cached), unit: ""),
                        .init(label: "实际计算 prefill", value: max(0, totals.prompt - totals.cached),
                              color: palette.violet, text: compactTokens(max(0, totals.prompt - totals.cached)),
                              unit: ""),
                    ], height: 10)

                    if model.tokenRows.isEmpty {
                        Text("这个区间还没有记录到 token。引擎每次上报，账本只记增量；重启或换模型时只重新取基线，不会把差值算成流量。")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        TokenModelTable(rows: model.tokenRows, palette: palette)
                    }
                    Text("合计 \(compactTokens(grand)) · 缓存命中省下的 prefill 就是这一栏与「实际计算」的差")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            Panel(title: "按天", palette: palette, trailing: AnyView(
                Text("最近 14 天 · 本地日边界（账本内部 UTC 小时桶）")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.tokenDaily.allSatisfy({ !$0.hasData }) {
                        Text("还没有跨天的记录。账本按 UTC 小时桶存、此处按本地日聚合，保留 35 天；只记增量 —— 引擎重启或换模型时重新取基线，不会把差值算成流量。")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        DailyBars(
                            bars: model.tokenDaily.map { entry in
                                // 三段堆叠，段序与图例一致（生成/缓存命中/实际计算 prefill）。
                                // value = 合计：柱高与柱顶数字都是「那天总量」，段只回答“谁占的”。
                                let uncached = max(0, entry.prompt - entry.cached)
                                let grand = entry.completion + entry.cached + uncached
                                return DailyBars.Bar(
                                    id: entry.day,
                                    label: shortDay(entry.day),
                                    // hasData == false 是「那天没有任何记录」：画小竖条。
                                    // 把 0 当真值画柱，就是「没记录」冒充「测得为零」。
                                    value: entry.hasData ? grand : nil,
                                    valueText: entry.hasData ? compactTokens(grand) : nil,
                                    parts: entry.hasData ? [
                                        .init(value: entry.completion, color: palette.accent),
                                        .init(value: entry.cached, color: palette.info),
                                        .init(value: uncached, color: palette.violet),
                                    ] : nil,
                                    help: entry.hasData
                                        ? "\(entry.day) · 生成 \(compactTokens(entry.completion)) · 缓存命中 \(compactTokens(entry.cached)) · 实际计算 prefill \(compactTokens(uncached)) · 点按看当天"
                                        : "\(entry.day) · 无记录"
                                )
                            },
                            tint: palette.accent,
                            palette: palette,
                            showValues: true,
                            selection: Binding(
                                get: { model.selectedTokenDay },
                                set: { model.setTokenDay($0) }
                            )
                        )
                        HStack(spacing: 12) {
                            legendDot(palette.accent, "生成")
                            legendDot(palette.info, "缓存命中")
                            legendDot(palette.violet, "实际计算 prefill")
                            Spacer(minLength: 0)
                        }
                        Text("柱高是当天合计（生成 + 缓存命中 + 实际计算 prefill），分段颜色见图例；最后一根是今天（未结束）。点某根柱看当天详情，再点一次或 ✕ 收起。没有记录的那天画成小竖条，而不是零高。")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    // 选中即面板，不弹窗：详情内联在图下方展开，保留上下文。
                    if let detail = model.tokenDayDetail {
                        TokenDayDetailPanel(detail: detail, palette: palette) {
                            model.setTokenDay(nil)
                        }
                    }
                }
                // 动画只跟「选中哪天」走；挂在数据 tick 上会每 2s 闪一次。
                .animation(.easeOut(duration: 0.2), value: model.selectedTokenDay)
            }
        }
    }

    /// 按天图的小图例：三个色点 + 名称，与柱内分段一一对应。
    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.secondary)
        }
        .fixedSize()
    }

    private var rangePicker: some View {
        Picker("", selection: Binding(
            get: { model.tokenRange },
            set: { model.setTokenRange($0) }
        )) {
            ForEach(TokenLedger.Range.allCases, id: \.self) { range in
                Text(range.label).tag(range)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 380)
    }

}

/// `2026-10-10` → `10/10`: the axis has three labels and no room for a year.
func shortDay(_ day: String) -> String {
    let parts = day.split(separator: "-")
    guard parts.count == 3 else { return day }
    return "\(parts[1])/\(parts[2])"
}

// MARK: - Activity

struct ActivityPage: View {
    @ObservedObject var model: AppModel
    var palette: Palette

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "活动",
                meta: ["只记状态变化", "去重窗口 5 秒", "最多 2000 条"],
                palette: palette
            )
            Panel(palette: palette) {
                if model.events.isEmpty {
                    Text("还没有事件。上线/下线、降频、健康项出现与清除、关机与基准跑完都会记在这里。")
                        .font(.system(size: 12.5, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(model.events) { event in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text(event.at.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 66, alignment: .trailing)
                                Circle()
                                    .fill(color(event.severity))
                                    .frame(width: 6, height: 6)
                                    .offset(y: -2)
                                Text(event.message)
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(palette.text)
                                Spacer(minLength: 0)
                                Text(event.kind)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.vertical, 6)
                            .overlay(alignment: .top) { if event.id != model.events.first?.id { Divider() } }
                        }
                    }
                }
            }
        }
    }

    private func color(_ severity: WatchEvent.Severity) -> Color {
        switch severity {
        case .info: palette.info
        case .success: palette.ok
        case .warn: palette.warn
        case .error: palette.danger
        }
    }
}

// MARK: - Benchmarks

/// Decode benchmark: the one *action* that measures rather than reports.
///
/// It talks HTTP straight to the engine — no SSH, nothing installed — and the
/// number it produces is measured under controlled concurrency instead of being
/// read off a counter, which is what makes it comparable between two machines or
/// two builds.
struct BenchmarkPage: View {
    @ObservedObject var model: AppModel
    var palette: Palette

    @State private var selectedNode: UUID?
    @State private var levels: Set<Int> = [1, 2, 4]
    @State private var maxTokens = 400
    @State private var running = false
    @State private var status = ""
    @State private var waves: [DecodeBenchmark.WaveResult] = []
    @State private var tunnel: SshTunnel?
    @State private var tunnelPort: Int?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(
                title: "解码基准",
                meta: ["纯 HTTP，不需要 SSH 权限", "先跑一次预热，JIT 成本不计入成绩", "并发逐档递进"],
                palette: palette
            )

            Panel(title: "配置", palette: palette) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 10) {
                        Text("目标").font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                        Picker("", selection: Binding(
                            get: { selectedNode ?? model.nodes.first?.id },
                            set: { selectedNode = $0 }
                        )) {
                            ForEach(model.nodes) { node in
                                Text("\(node.name)\(endpointSuffix(node))").tag(Optional(node.id))
                            }
                        }
                        .labelsHidden()
                        .frame(width: 300)

                        Text("最大 token").font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                        Stepper(value: $maxTokens, in: 64...2048, step: 64) {
                            Text("\(maxTokens)").font(.system(size: 12.5, design: .monospaced))
                        }
                        .frame(width: 130)
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 6) {
                        Text("并发档").font(.system(size: 12.5, design: .rounded)).foregroundStyle(.secondary)
                        ForEach(DecodeBenchmark.allowedConcurrency, id: \.self) { level in
                            Button {
                                if levels.contains(level) { levels.remove(level) } else { levels.insert(level) }
                            } label: {
                                Text("\(level)")
                                    .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        Capsule().fill(levels.contains(level) ? palette.accentSoft : palette.surfaceHover)
                                    )
                                    .foregroundStyle(levels.contains(level) ? palette.accentText : palette.mutedStrong)
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer(minLength: 0)
                    }

                    HStack(spacing: 10) {
                        Button(running ? "运行中…" : "开始测试") { Task { await run() } }
                            .disabled(running || levels.isEmpty || model.nodes.isEmpty)
                        if running { ProgressView().controlSize(.small) }
                        Text(status)
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        if !waves.isEmpty {
                            Button("清空结果") { waves = []; status = "" }
                                .controlSize(.small)
                        }
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(palette.danger)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if !waves.isEmpty { results }
        }
        .onDisappear { tunnel?.stop(); tunnel = nil; tunnelPort = nil }
    }

    private func endpointSuffix(_ node: NodeSnapshot) -> String {
        guard let endpoint = node.inference?.endpoint else { return " · 无推理端点" }
        return " · \(endpoint)"
    }

    private var results: some View {
        Panel(title: "结果", palette: palette) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("并发").frame(width: 46, alignment: .leading)
                    Text("单流均值").frame(width: 84, alignment: .trailing)
                    Text("中位").frame(width: 70, alignment: .trailing)
                    Text("最好").frame(width: 70, alignment: .trailing)
                    Text("合计吞吐").frame(width: 84, alignment: .trailing)
                    Text("首 token").frame(width: 76, alignment: .trailing)
                    Text("生成 token").frame(width: 86, alignment: .trailing)
                    Spacer(minLength: 0)
                }
                .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.vertical, 5)

                ForEach(waves, id: \.concurrency) { wave in
                    HStack(spacing: 8) {
                        Text("\(wave.concurrency)").font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                            .frame(width: 46, alignment: .leading)
                        number(wave.meanDecodeTPS, width: 84, tint: palette.accent)
                        number(wave.medianDecodeTPS, width: 70, tint: .primary)
                        number(wave.maxDecodeTPS, width: 70, tint: .primary)
                        number(wave.aggregateDecodeTPS, width: 84, tint: palette.ok)
                        Text(wave.meanTtftMs.map { String(format: "%.0f ms", $0) } ?? "--")
                            .frame(width: 76, alignment: .trailing)
                        Text("\(wave.totalDecodeTokens)")
                            .frame(width: 86, alignment: .trailing)
                        Spacer(minLength: 0)
                    }
                    .font(.system(size: 12.5, design: .monospaced))
                    .padding(.vertical, 6)
                    .overlay(alignment: .top) { Divider() }
                }
            }
            Text("单流均值 = 每条流的 tok/s 平均；合计吞吐 = 整波生成 token 总数 ÷ 墙钟时长，这才是并发真的把机器用满时该看的数。")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.top, 8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func number(_ value: Double?, width: CGFloat, tint: Color) -> some View {
        Text(value.map { String(format: "%.1f", $0) } ?? "--")
            .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(value == nil ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint))
            .frame(width: width, alignment: .trailing)
    }

    // MARK: - Running

    private func run() async {
        guard let nodeID = selectedNode ?? model.nodes.first?.id,
            let node = model.nodes.first(where: { $0.id == nodeID })
        else { return }
        error = nil
        waves = []
        running = true
        defer { running = false }

        guard let base = await prepareEndpoint(for: node) else { return }
        let options = DecodeBenchmark.Options(
            baseURL: base,
            model: node.inference?.model,
            maxTokens: maxTokens,
            concurrencyLevels: levels.sorted()
        )
        status = "准备中…"
        let started = Date()
        let results = await DecodeBenchmark.run(options) { progress in
            Task { @MainActor in
                status = "并发 \(progress.concurrency)（第 \(progress.waveIndex + 1)/\(progress.waveCount) 档）· 已完成 \(progress.finishedStreams) 条流"
            }
        } onWave: { wave in
            Task { @MainActor in waves.append(wave) }
        }
        let elapsed = Date().timeIntervalSince(started)
        status = String(format: "完成，用时 %.0f 秒 · %d 档", elapsed, results.count)
        let best = results.compactMap(\.aggregateDecodeTPS).max()
        model.noteAction(
            "解码基准完成：\(node.name) 最高合计吞吐 \(best.map { String(format: "%.1f", $0) } ?? "--") tok/s（\(results.count) 档并发）",
            severity: .success, kind: "bench.decode", node: node
        )
        tunnel?.stop()
        tunnel = nil
        tunnelPort = nil
    }

    /// Resolve a URL the benchmark can actually reach.
    ///
    /// A loopback-bound engine (TensorFold binds 127.0.0.1 on these boxes, and so do
    /// Ollama and LM Studio by default) is unreachable from this Mac — so the page
    /// opens a temporary SSH forward and talks to `127.0.0.1:<local>` instead of
    /// asking the user to re-bind their server.
    private func prepareEndpoint(for node: NodeSnapshot) async -> String? {
        guard let endpoint = node.inference?.endpoint else {
            error = "\(node.name) 没有可用的推理端点：先在设置里指定来源，或让自动发现找到一个。"
            return nil
        }
        guard let url = URL(string: endpoint), let port = url.port else {
            error = "无法解析端点地址：\(endpoint)"
            return nil
        }
        let isLoopback = url.host == "127.0.0.1" || url.host == "localhost" || url.host == "::1"
        if !isLoopback {
            return "http://\(url.host ?? ""):\(port)"
        }
        guard let config = model.nodeConfigs.first(where: { $0.name == node.name }) else {
            error = "找不到 \(node.name) 的 SSH 配置，无法为 loopback 端点开隧道。"
            return nil
        }
        tunnel?.stop()
        let local = 19_500 + abs(port % 200)
        let forward = SshTunnel(
            host: config.sshHost, user: config.sshUser, remotePort: port, localPort: local
        )
        do {
            try forward.start()
        } catch {
            self.error = "SSH 隧道建立失败：\(String(describing: error).prefix(120))"
            return nil
        }
        tunnel = forward
        tunnelPort = local
        // Give the forward a moment to bind before the first request.
        try? await Task.sleep(for: .milliseconds(400))
        status = "经 SSH 隧道 127.0.0.1:\(local) → \(node.name):\(port)"
        return "http://127.0.0.1:\(local)"
    }
}
