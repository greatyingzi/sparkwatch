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
                    label: hoursAgo == 0 ? "现在" : "\(hoursAgo) 小时前",
                    value: watts,
                    help: watts.map { String(format: "%@ · %.0f W", hourLabel(index), $0) }
                        ?? "\(hourLabel(index)) · 无完整覆盖"
                )
            },
            tint: palette.accent,
            palette: palette
        )
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
                    "UTC 日边界",
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
                        table
                    }
                    Text("合计 \(compactTokens(grand)) · 缓存命中省下的 prefill 就是这一栏与「实际计算」的差")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }

            Panel(title: "按天", palette: palette, trailing: AnyView(
                Text("最近 14 天 · UTC 日")
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            )) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.tokenDaily.allSatisfy({ $0.completion == 0 }) {
                        Text("还没有跨天的记录。账本按 UTC 日分桶、保留 35 天；只记增量 —— 引擎重启或换模型时重新取基线，不会把差值算成流量。")
                            .font(.system(size: 12, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        DailyBars(
                            bars: model.tokenDaily.map { entry in
                                DailyBars.Bar(
                                    label: shortDay(entry.day),
                                    value: entry.completion,
                                    help: "\(entry.day) · 生成 \(compactTokens(entry.completion)) token"
                                )
                            },
                            tint: palette.accent,
                            palette: palette
                        )
                        Text("最后一根是今天（未结束）。柱高按这 14 天里的最大值归一；没有记录的那天画成小竖条，而不是零高。")
                            .font(.system(size: 11.5, design: .rounded))
                            .foregroundStyle(.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
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

    /// 数字列宽：只用来对齐，不当作硬约束。
    private static let numberColumn: CGFloat = 74

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

    private var table: some View {
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

            ForEach(model.tokenRows, id: \.model) { row in
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
