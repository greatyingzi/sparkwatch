import AppKit
import SparkWatchCore
import SwiftUI

/// The per-machine detail page: one panel per subsystem, instead of one dense card.
///
/// Why split the card up here: on the popover a machine has to answer "what is it
/// doing" in 302 pt. A window has room to answer the next question — *why* — and
/// that needs the pieces in their own panels, each with its own units and its own
/// thresholds, so the eye can compare like with like (two percentages side by side,
/// two temperatures side by side).
///
/// Two rules carried over from the popover, because they are what keeps this
/// readable rather than merely complete:
///   * **a tile renders only when the engine actually reported it** — no zeros and
///     no dashes standing in for "this engine does not export histograms";
///   * **each metric keeps its own threshold family** (temperature is never painted
///     with the utilisation ramp).
struct MachinePanels: View {
    var model: AppModel
    var node: NodeSnapshot
    var palette: Palette

    private var gpu: GpuSample { node.gpu }
    private var system: SystemSample { node.system }
    private var inference: InferenceSample? { node.inference }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                gpuPanel
                unifiedMemoryPanel
                cpuPanel
                thermalAndFaultPanel
            }
            .frame(maxWidth: .infinity, alignment: .top)

            VStack(spacing: 14) {
                llmPanel
                storagePanel
                networkPanel
                tailnetPanel
                workloadPanel
            }
            .frame(width: 420, alignment: .top)
        }
    }

    // MARK: - Thermal margin, clock lock, failure signature, last shutdown

    /// Four facts that each answer "is this box about to hurt itself", and that no
    /// other panel expresses together.
    ///
    ///  * **thermal margin** — the ACPI zone's distance from its *own* trip point,
    ///    plus the rate of climb. This hardware power-offs at ~96 °C while
    ///    declaring 104.8 °C, so a level test near the ceiling can never fire in
    ///    time; a slope can (the crash curve is 92 → 96 °C in ~150 s).
    ///  * **clock lock** — `-lgc` is the one real power lever on a Spark, it costs
    ///    ~0 % on bandwidth-bound decode, and it does not survive a reboot.
    ///  * **failure signature** — four documented modes with four different
    ///    actions: RMA / lock+airflow / driver upgrade / power drain.
    ///  * **last shutdown** — read off-box from the previous boot's journal, the
    ///    only copy that survives a power cut.
    private var thermalAndFaultPanel: some View {
        Panel(title: "热与故障", palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                statLine("热区", thermalZoneText, tint: thermalZoneTint, help: thermalZoneHelp)
                statLine("热余量", thermalMarginText, tint: thermalMarginTint, help: thermalMarginHelp)
                statLine("锁频", node.clockLock?.label ?? "未知", tint: palette.textStrong, help: clockLockHelp)
                statLine(
                    "故障模式",
                    node.faultMode.map { "\($0.label)（\($0.token)）" } ?? "未命中已知模式",
                    tint: node.faultMode == nil ? palette.muted : (node.faultMode == .thermalLimit ? palette.warn : palette.danger),
                    help: faultModeHelp
                )
                if let forensics = node.forensics {
                    statLine(
                        "上次关机",
                        forensics.label,
                        tint: forensics.verdict == .cleanShutdown ? palette.muted : palette.warn,
                        help: forensics.summary
                            + (forensics.previousBootTail.isEmpty
                                ? ""
                                : "\n上次日志尾部：\n" + forensics.previousBootTail.joined(separator: "\n"))
                    )
                }
                if let age = node.fastSampleAge {
                    statLine(
                        "2s 通道",
                        age < 6 ? String(format: "在线（%.0fs 前）", age) : String(format: "已停 %.0f 秒", age),
                        tint: age < 6 ? palette.muted : palette.warn,
                        help: "常驻 SSH 会每 2 秒采一次 acpitz / SM 时钟 / 功耗。它比 60 秒慢通道快 30 倍，是断电前留证的唯一来源；停了这个数字会变黄。"
                    )
                }
            }
        }
    }

    private var thermalZoneText: String {
        guard let zone = system.cpuTempC else { return "--" }
        return system.thermalLimitC.map { String(format: "%.0f / %.0f °C", zone, $0) }
            ?? String(format: "%.0f °C", zone)
    }

    private var thermalZoneTint: Color? {
        guard let zone = system.cpuTempC, let limit = system.thermalLimitC else { return palette.textStrong }
        let margin = limit - zone
        if margin <= 8 { return palette.danger }
        if margin <= 18 { return palette.warn }
        return palette.textStrong
    }

    private var thermalZoneHelp: String {
        "最热 ACPI 热区（GB10 没有 CPU 封装温度传感器）/ 该热区自己声明的 trip point。"
            + "注意 nvidia-smi 比热区低 8–15°C：实测断电前最后样本是热区 92.2°C、smi 84°C，所以判断热状态必须看这一行。"
    }

    private var thermalMarginText: String {
        guard let zone = system.cpuTempC else { return "--" }
        let limit = system.thermalLimitC ?? 100
        let margin = limit - zone
        let trend = node.thermalTrend.map { String(format: " %+.1f°/min", $0.slopePerMinute) } ?? ""
        return String(format: "%.0f °C%@", margin, trend)
    }

    private var thermalMarginTint: Color? {
        guard let zone = system.cpuTempC else { return palette.textStrong }
        let margin = (system.thermalLimitC ?? 100) - zone
        let climbing = (node.thermalTrend?.slopePerMinute ?? 0) >= 0.5
        if margin <= 12 { return palette.danger }
        if margin <= 22, climbing { return palette.warn }
        if margin <= 18 { return palette.warn }
        return palette.textStrong
    }

    private var thermalMarginHelp: String {
        "距热区上限的余量，以及最近几分钟的升温速率（最小二乘，窗口 5 分钟，需 ≥90 秒数据）。"
            + "这台机器是约 96°C 硬断电、而上限声明 104.8°C，所以绝对阈值永远来不及："
            + "现场曲线是 150 秒内从 92°C 爬到 96°C（≈1.5°C/min）。"
    }

    private var clockLockHelp: String {
        "nvidia-smi 不会回读锁频状态（Applications/Max Clocks 始终显示 2418/3003），"
            + "所以这里是在负载下统计 SM 时钟：锁 2200 时实测稳定在 2164–2184MHz（±40MHz 内持平），"
            + "未锁时自由 boost 到 2400+。锁频不跨重启，需要 systemd oneshot。"
            + "\n省电参考：锁 2200MHz 峰值功耗 −21%，而带宽受限的 MoE 解码几乎不损失速度。"
    }

    private var faultModeHelp: String {
        guard let mode = node.faultMode else {
            return "四种已知故障签名都没命中：时钟崩溃（util 高/功耗≤25W/时钟≤800MHz）、"
                + "PCIe 供电不足（启动后仍有 insufficient power 事件且功耗卡 27–30W）、"
                + "热节流（热降频位有效）、5W 驱动 bug（仅 550.x）。"
        }
        return "\(mode.label)：\(mode.action)"
    }

    private var wholePowerHelp: String {
        guard let reading = node.power else {
            return "按 GPU 轨拟合的估值，不是实测"
        }
        var text = "\(model.powerEstimate.formula(for: reading))\n"
        text += reading.cpuAssumed ? "CPU 占用未读到，按 20% 估。\n" : "输入：GPU 轨实测 + CPU 占用（含频率权重）。\n"
        if let note = reading.note { text += "低置信：\(note)\n" }
        text += "GB10 没有任何整机功率计（无 RAPL / hwmon 功率输入 / PD 遥测），这一项只能是拟合值。"
        return text
    }

    // MARK: - GPU

    private var gpuPanel: some View {
        Panel(title: "GPU", palette: palette, trailing: AnyView(
            Text(gpu.powerLimitW.map { String(format: "功耗上限 %.0f W", $0) } ?? "功耗上限 N/A（GB10 不上报）")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
        )) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 18) {
                    Ring(
                        value: gpu.utilPct,
                        size: 140,
                        stroke: 11,
                        tint: palette.utilization(gpu.utilPct, tempC: gpu.tempC),
                        caption: "利用率",
                        help: "官方遥测通道，约 1 Hz"
                    )
                    VStack(alignment: .leading, spacing: 10) {
                        statLine("温度", gpu.tempC.map { String(format: "%.0f °C", $0) } ?? "--",
                                 tint: palette.temperature(gpu.tempC),
                                 help: "GB10 的 GPU 轨不上报上限，所以用绝对线：85 °C 注意、90 °C 异常")
                        statLine("功耗（GPU 轨）",
                                 gpu.powerW.map { String(format: "%.1f W", $0) } ?? "--",
                                 help: "NVML power.draw，只覆盖 GPU 那一侧；整机没有功率计")
                        statLine("整机 ≈",
                                 (node.power?.wallW
                                    ?? model.powerEstimate.wholeMachineW(gpuW: gpu.powerW))
                                    .map { String(format: "%.0f W", $0) } ?? "--",
                                 help: wholePowerHelp)
                        statLine("SM 时钟",
                                 gpu.smClockMHz.map { String(format: "%.2f GHz", $0 / 1000) } ?? "--",
                                 help: "降频判据：利用率高但时钟塌到 ≤800 MHz 且功耗低")
                        if let throttle = gpu.throttle {
                            HStack(spacing: 6) {
                                Chip(
                                    text: throttle.label,
                                    tint: throttle.thermal ? palette.danger
                                        : (throttle.active ? palette.warn : palette.muted),
                                    compact: true
                                )
                                if let pct = throttle.smClockPct {
                                    Text(String(format: "%.0f%% of max", pct))
                                        .font(.system(size: 10.5, design: .rounded))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                    Spacer(minLength: 0)
                }

                if !system.gpuProcesses.isEmpty {
                    Divider()
                    Text("显存占用进程（top \(system.gpuProcesses.count)）")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                    VStack(spacing: 0) {
                        ForEach(system.gpuProcesses) { process in
                            HStack(spacing: 8) {
                                Text("\(process.pid)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 74, alignment: .leading)
                                Text(process.name)
                                    .font(.system(size: 12, design: .rounded))
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Text(String(format: "%.1f GiB", Double(process.memoryBytes) / 1_073_741_824))
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .top) { if process.id != system.gpuProcesses.first?.id { Divider() } }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Unified memory

    private var unifiedMemoryPanel: some View {
        let split = system.memorySplit()
        var segments: [SegBar.Segment] = []
        if let gpuShare = split.gpu {
            segments.append(.init(label: "模型权重 + KV", value: Double(gpuShare),
                                  color: palette.memEngine, text: gib(gpuShare)))
        }
        if let rest = split.system {
            segments.append(.init(label: "系统", value: Double(rest), color: palette.memSystem, text: gib(rest)))
        }
        if let free = split.free {
            segments.append(.init(label: "空闲", value: Double(free), color: palette.surfaceHover, text: gib(free)))
        }
        return Panel(title: "统一内存", palette: palette, trailing: AnyView(
            Text(system.memUsedPct.map { String(format: "占池 %.0f%%", $0) } ?? "")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
        )) {
            VStack(alignment: .leading, spacing: 10) {
                if segments.isEmpty {
                    Text("还在等第一帧内存读数…")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    SegBar(segments: segments, height: 12)
                }
                HStack(spacing: 0) {
                    StatCell(key: "可用", value: bytes(system.memAvailableBytes),
                             help: "MemAvailable（GB10 的 GPU 与 CPU 共享同一池）")
                    StatCell(key: "页缓存", value: bytes(system.memCacheBytes),
                             help: "缓存与 CUDA 抢同一个池，所以它是压力的一部分")
                    StatCell(key: "PSI 压力", value: system.memPressureAvg10.map { String(format: "%.2f", $0) } ?? "--",
                             help: "full avg10：大于 0 表示真的有东西在等内存 —— 这是「装不下」的唯一硬证据")
                    StatCell(key: "swap", value: system.swapUsedBytes.flatMap {
                        $0 > 100_000_000 ? gib($0) : nil } ?? "未用",
                             help: "超过 8 GB 才升级为注意")
                }
            }
        }
    }

    // MARK: - CPU

    private var cpuPanel: some View {
        Panel(title: "CPU", palette: palette, trailing: AnyView(
            Text(system.cpuCores.map { "\($0) 核" } ?? "")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
        )) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 24) {
                    bigNumber("利用率",
                              system.cpuUsagePct.map { String(format: "%.0f", $0) } ?? "--", "%",
                              tint: palette.textStrong)
                    bigNumber("最热区",
                              system.cpuTempC.map { String(format: "%.0f", $0) } ?? "--", "°C",
                              tint: palette.temperature(system.cpuTempC))
                    if let limit = system.thermalLimitC, let zone = system.cpuTempC {
                        bigNumber("距上限", String(format: "%.0f", limit - zone), "°C",
                                  tint: limit - zone <= 6 ? palette.danger
                                      : (limit - zone <= 12 ? palette.warn : palette.muted))
                    }
                    Spacer(minLength: 0)
                }
                HStack(spacing: 0) {
                    StatCell(key: "负载", value: system.load1.map { String(format: "%.2f", $0) } ?? "--")
                    StatCell(key: "运行时长", value: system.uptimeSeconds.map { uptime($0) } ?? "--")
                    StatCell(key: "热区上限", value: system.thermalLimitC.map { String(format: "%.0f °C", $0) } ?? "--",
                             help: "平台自己声明的 ACPI 跳点（GB10 为 104 °C），阈值相对它算")
                    StatCell(key: "CPU 功耗", value: "估算",
                             help: "GB10 没有 CPU 封装功率传感器（实测：无 RAPL、无 IMC、无 BMC），这里是模型值")
                }
            }
        }
    }

    // MARK: - LLM

    private var llmPanel: some View {
        Panel(title: "LLM 服务", palette: palette, trailing: AnyView(
            HStack(spacing: 6) {
                if let engine = inference?.engine {
                    Chip(text: engine, tint: palette.violet, compact: true)
                }
                if let endpoint = inference?.endpoint {
                    Text(endpoint.replacingOccurrences(of: "http://", with: ""))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        )) {
            if let inference {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 6) {
                        Text(inference.model ?? "无模型加载")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let quant = inference.quantization {
                            Chip(text: quant.uppercased(), tint: palette.violet, compact: true)
                        }
                        if let ctx = inference.contextLength {
                            Chip(text: ctx >= 1024 ? "\(ctx / 1024)K ctx" : "\(ctx) ctx",
                                 tint: .secondary, compact: true)
                        }
                        Spacer(minLength: 0)
                        if let role = inference.taskRole {
                            Chip(text: role, tint: palette.accent, compact: true)
                        }
                    }

                    HStack(alignment: .top, spacing: 20) {
                        decodeHalf(inference)
                        prefillHalf(inference)
                    }

                    if !tiles(inference).isEmpty {
                        Divider()
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 104, maximum: 200), spacing: 8)],
                            alignment: .leading, spacing: 8
                        ) {
                            ForEach(tiles(inference), id: \.label) { tile in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(tile.value)
                                        .font(.system(size: 17, weight: .semibold, design: .monospaced))
                                        .foregroundStyle(tile.tint)
                                        // 数值永不折行（窄瓦片里宁可缩字号，也不能把
                                        // "235.32k" 拆成两行）。
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                    Text(tile.label)
                                        .font(.system(size: 11, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(9)
                                .background(
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .fill(palette.surfaceElevated)
                                )
                                .help(tile.help ?? "")
                            }
                        }
                    }

                    if let note = node.inferenceNote, !note.isEmpty {
                        Text(note).font(.system(size: 11, design: .rounded)).foregroundStyle(.tertiary)
                    }
                    if let error = node.inferenceError {
                        Text(error).font(.system(size: 11, design: .rounded)).foregroundStyle(palette.danger)
                    }
                }
            } else {
                Text(node.inferenceConfigured
                     ? (node.inferenceError ?? "正在探测推理端点…")
                     : "未配置推理端点（设置 → 监控的机器）")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func decodeHalf(_ inference: InferenceSample) -> some View {
        let state = SpeedDisplay.state(
            rate: inference.decodeTPS, age: inference.decodeTPSAge, running: inference.running
        )
        let tint: Color = state == .live ? palette.ok : palette.muted
        return VStack(alignment: .leading, spacing: 4) {
            Text("解码").font(.system(size: 11, weight: .semibold, design: .rounded))
                .textCase(.uppercase).foregroundStyle(.secondary)
            NumberUnit(
                value: inference.decodeTPS.map { String(format: "%.1f", $0) } ?? "--",
                unit: "tok/s",
                size: 26,
                tint: tint
            )
            Text(decodeStateText(inference, state: state))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prefillHalf(_ inference: InferenceSample) -> some View {
        // Same contract as the decode half: the number survives the end of the
        // work but stops claiming to be current. A prefill that just finished is
        // exactly the moment a person looks at the panel.
        let fresh = (inference.prefillTPSAge ?? 0) <= SpeedDisplay.freshnessSeconds
        let tint: Color = fresh ? palette.text : palette.muted
        return VStack(alignment: .leading, spacing: 4) {
            Text("prefill").font(.system(size: 11, weight: .semibold, design: .rounded))
                .textCase(.uppercase).foregroundStyle(.secondary)
            NumberUnit(
                value: inference.prefillTPS.map {
                    $0 >= 10_000 ? String(format: "%.0fk", $0 / 1000) : String(format: "%.0f", $0)
                } ?? "--",
                unit: "tok/s",
                size: 26,
                tint: tint
            )
            Text(prefillNote(inference))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func decodeStateText(_ inference: InferenceSample, state: SpeedDisplay.State) -> String {
        switch state {
        case .live:
            // Name the source: "live" used to mean one thing (a counter delta over
            // the wall clock) and that one is wrong on an engine that publishes its
            // totals at request boundaries.
            if inference.counterStale { return "计数器未刷新（引擎按请求边界发布）" }
            return inference.decodeTPSNative != nil
                ? "实时（引擎 /health 原生速率）"
                : "实时（计数器差值 ÷ 墙钟）"
        case .stopped:
            if inference.counterStale { return "计数器未刷新（引擎按请求边界发布）" }
            return inference.decodeTPSAge.map { String(format: "已停 %.0f 秒，数字仍是真的", $0) } ?? "已停"
        case .hidden:
            if inference.counterStale { return "请求在跑，计数器尚未刷新" }
            return inference.capabilities.hasSpeed ? "空闲" : "该引擎不提供速率"
        }
    }

    private func prefillNote(_ inference: InferenceSample) -> String {
        // The engine reports prefill live while it runs (`/health`
        // `live.prefill_tokens_per_second`); once it ends the figure is kept and
        // labelled as the last one instead of turning back into "--".
        if let age = inference.prefillTPSAge, age >= 1 {
            return String(format: "上一段填充 · %.0f 秒前（引擎只在填充时更新）", age)
        }
        if inference.prefillTPSNative != nil {
            return "实时（引擎 /health 原生速率）"
        }
        if let cached = inference.cachedTokens, let prompt = inference.promptTokens, prompt > 0 {
            let uncached = max(0, prompt - cached)
            return String(format: "其中缓存命中 %.1fM、实际计算 %.1fM（引擎只在请求结束时记账）",
                          cached / 1_000_000, uncached / 1_000_000)
        }
        return "引擎只在请求结束时上报 prompt token 与 prefill 秒数"
    }

    private struct Tile {
        var label: String
        var value: String
        var tint: Color
        var help: String?
    }

    /// Only tiles the engine actually reported. A tile that prints `--` for a metric
    /// the engine does not export turns "no histogram here" into "the histogram is
    /// zero", which is the one thing this app refuses to do.
    private func tiles(_ inference: InferenceSample) -> [Tile] {
        var out: [Tile] = []
        if let kv = inference.kvUsagePct {
            out.append(Tile(label: "KV 池占用", value: String(format: "%.0f%%", kv),
                            tint: palette.kv(kv),
                            help: "共享池占用 = 1 − pool_free/pool_tokens。注意另一个同名的指标是单流上下文填充率（空闲时为 0），不是容量"))
        }
        if let running = inference.running {
            out.append(Tile(label: "运行 / 等待",
                            value: String(format: "%.0f / %.0f", running, inference.waiting ?? 0),
                            tint: (inference.waiting ?? 0) > 0 ? palette.warn : palette.textStrong,
                            help: "等待 > 0 表示请求在排队"))
        }
        if let decoding = inference.decoding {
            out.append(Tile(label: "解码中流", value: String(format: "%.0f", decoding), tint: palette.textStrong))
        }
        if let prefilling = inference.prefilling {
            out.append(Tile(label: "prefill 中流", value: String(format: "%.0f", prefilling),
                            tint: prefilling > 0 ? palette.info : palette.textStrong))
        }
        if let ttft = inference.ttftMeanSeconds {
            out.append(Tile(label: "TTFT 均值", value: seconds(ttft), tint: palette.textStrong,
                            help: "引擎直方图：Σttft ÷ 请求数（对整段历史，不是最近窗口）"))
        }
        if let ttft = inference.ttftP95Seconds {
            out.append(Tile(label: "TTFT p95", value: seconds(ttft),
                            tint: ttft > 60 ? palette.danger : (ttft > 15 ? palette.warn : palette.textStrong),
                            help: "引擎直方图线性插值。目标落在 +Inf 桶里时不给数 —— 那说明导出的边界框不住它"))
        }
        if let e2e = inference.e2eP95Seconds {
            out.append(Tile(label: "E2E p95", value: seconds(e2e), tint: palette.textStrong,
                            help: "整请求（prefill + 解码）p95"))
        }
        if let itl = inference.itlP95Seconds {
            out.append(Tile(label: "ITL p95", value: String(format: "%.0f ms", itl * 1000),
                            tint: palette.textStrong, help: "相邻 token 间隔 p95 —— 流式的手感"))
        }
        if let hit = inference.cacheHitPct {
            out.append(Tile(label: "前缀缓存命中", value: String(format: "%.0f%%", hit),
                            tint: palette.textStrong,
                            help: "命中率决定了 300K 的 prompt 要不要真的算一遍"))
        }
        if let acceptance = inference.acceptancePct {
            out.append(Tile(label: "MTP 接受率", value: String(format: "%.0f%%", acceptance),
                            tint: palette.textStrong, help: "投机解码：被接受的草稿 token 占比"))
        }
        if let oldest = inference.oldestSeconds {
            out.append(Tile(label: "最老在途请求", value: seconds(oldest), tint: palette.textStrong,
                            help: "prefill 期间唯一还在走的数"))
        }
        if let generated = inference.generationTokens {
            out.append(Tile(label: "累计生成", value: compactTokens(generated), tint: palette.textStrong))
        }
        if let processed = inference.requestsProcessed {
            out.append(Tile(label: "累计请求", value: compactTokens(processed), tint: palette.textStrong))
        }
        return out
    }

    // MARK: - Storage / network / tailnet / workload

    private var storagePanel: some View {
        let used = system.diskUsedBytes, total = system.diskTotalBytes
        let pct = used.flatMap { u in total.map { Double(u) / Double($0) * 100 } }
        return Panel(title: "存储", palette: palette, trailing: AnyView(
            Text(throughput(system.diskReadBytesPerSec, system.diskWriteBytesPerSec))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if let pct {
                    Text("根分区 \(bytes(used)) / \(bytes(total))")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                    MeterBar(fraction: pct / 100, tint: palette.storage(pct), label: "", palette: palette, height: 8)
                } else {
                    Text("还没有磁盘读数").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                }
                Text("实时吞吐来自两次 /sys/block 采样差分；这台机器上磁盘通常不是瓶颈，列在这里是为了解释「为什么卡」。")
                    .font(.system(size: 10.5, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var networkPanel: some View {
        let network = system.network
        let primary = network.primaryInterface
        return Panel(title: "网络", palette: palette, trailing: AnyView(
            Text(primary.map { "主接口 \($0.name)" } ?? "无接口")
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.secondary)
        )) {
            VStack(alignment: .leading, spacing: 8) {
                if network.interfaces.isEmpty {
                    Text("还没有网络读数").font(.system(size: 12, design: .rounded)).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 20) {
                        bigNumber("下载", Rate.compact(network.totalRxBytesPerSec), "", tint: palette.ok)
                        bigNumber("上传", Rate.compact(network.totalTxBytesPerSec), "", tint: palette.violet)
                        if let speed = primary?.linkSpeedMbps {
                            bigNumber("协商", String(format: "%.0f", speed), "Mb/s", tint: palette.textStrong)
                        }
                        Spacer(minLength: 0)
                    }
                    VStack(spacing: 0) {
                        ForEach(network.interfaces, id: \.name) { interface in
                            HStack(spacing: 8) {
                                Text(interface.name).font(.system(size: 12, design: .monospaced))
                                if interface.name == primary?.name {
                                    Chip(text: "主", tint: palette.accent, compact: true)
                                }
                                Spacer(minLength: 0)
                                Text(interface.ip ?? "—")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                Text("↑ \(Rate.compact(interface.txBytesPerSec)) ↓ \(Rate.compact(interface.rxBytesPerSec))")
                                    .font(.system(size: 11.5, design: .monospaced))
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .top) { if interface.name != network.interfaces.first?.name { Divider() } }
                        }
                    }
                    Text("只统计物理网卡：虚拟网卡（docker/veth/tailscale）承载的是同一份字节，算进去会把千兆链路显示成两条。")
                        .font(.system(size: 10.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var tailnetPanel: some View {
        Panel(title: "Tailnet", palette: palette, trailing: AnyView(
            HStack(spacing: 6) {
                if let tailnet = system.tailnet {
                    Chip(text: tailnet.online ? tailnet.pathLabel : "离线",
                         tint: tailnet.online ? palette.ok : palette.danger, compact: true)
                }
            }
        )) {
            if let tailnet = system.tailnet {
                VStack(alignment: .leading, spacing: 0) {
                    keyRow("地址", tailnet.ip ?? "—")
                    keyRow("路径", tailnet.pathLabel,
                           help: "「直连」= 打洞成功；括号里是中继名（DERP）。本机走中继不是故障，但延迟会比直连高一个量级")
                    keyRow("密钥", tailnet.keyExpired ? "已过期，需要重新认证" : "有效",
                           tint: tailnet.keyExpired ? palette.danger : nil)
                    if let version = tailnet.version { keyRow("版本", version) }
                }
            } else {
                Text("该节点读不到 tailscale 状态（未安装或没有权限）")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var workloadPanel: some View {
        let kernel = system.kernelErrors
        return Panel(title: "负载与内核事件", palette: palette) {
            VStack(alignment: .leading, spacing: 10) {
                if system.containers.isEmpty {
                    Text("没有在跑的容器（或该机没装 docker）")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(system.containers, id: \.name) { container in
                            HStack(spacing: 8) {
                                Text(container.name).font(.system(size: 12, design: .rounded))
                                Text(container.image)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Text(container.ports)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                            .overlay(alignment: .top) { if container.name != system.containers.first?.name { Divider() } }
                        }
                    }
                }

                Divider()
                HStack(spacing: 0) {
                    StatCell(key: "Xid", value: kernel.available ? "\(kernel.xid)" : "不可读",
                             help: "GPU 致命错误计数（开机以来）。只有「上升」才升级为异常")
                    StatCell(key: "OOM-kill", value: kernel.available ? "\(kernel.oomKills)" : "不可读",
                             help: "被内核 OOM 杀掉的进程数。实测这台机器在 10/7 有过一次把推理引擎自己打死的事件")
                    StatCell(key: "显存分配失败", value: kernel.available ? "\(kernel.nvErrNoMemory)" : "不可读",
                             help: "NV_ERR_NO_MEMORY 次数（驱动日志）")
                    StatCell(key: "状态", value: kernel.available ? (kernel.isClean ? "干净" : (system.incidentActive ? "上升中" : "有历史")) : "不可读",
                             tint: system.incidentActive ? .red : nil)
                }
            }
        }
    }

    // MARK: - Small pieces

    private func statLine(_ key: String, _ value: String, tint: Color? = nil, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(tint ?? palette.textStrong)
            Spacer(minLength: 0)
        }
        .help(help ?? "")
    }

    private func bigNumber(_ key: String, _ value: String, _ unit: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(key).font(.system(size: 11, design: .rounded)).foregroundStyle(.secondary)
            NumberUnit(value: value, unit: unit, size: 22, tint: tint)
        }
    }

    private func keyRow(_ key: String, _ value: String, tint: Color? = nil, help: String? = nil) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(key)
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .frame(width: 56, alignment: .leading)
            Text(value)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(tint ?? palette.text)
                .lineLimit(2)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .help(help ?? "")
    }

    private func bytes(_ value: UInt64?) -> String {
        guard let value else { return "--" }
        return String(format: "%.1f GiB", Double(value) / 1_073_741_824)
    }

    private func gib(_ value: UInt64) -> String {
        String(format: "%.1f", Double(value) / 1_073_741_824)
    }

    private func seconds(_ value: Double) -> String {
        value >= 60 ? String(format: "%.1f s", value) : String(format: "%.2f s", value)
    }

    private func uptime(_ seconds: Double) -> String {
        let days = seconds / 86_400
        if days >= 1 { return String(format: "%.1f 天", days) }
        return String(format: "%.0f 小时", seconds / 3600)
    }

    private func throughput(_ read: Double?, _ write: Double?) -> String {
        guard read != nil || write != nil else { return "" }
        return "r \(Rate.compact(read ?? 0))/s · w \(Rate.compact(write ?? 0))/s"
    }
}

// MARK: - Daily bars
//
// One bar per bucket, used by both the energy page (24 hours) and the token page
// (14 days). Two callers with the same job share one implementation so the two
// charts cannot drift apart in how they show a gap: a bucket with no data draws a
// stub, not a zero-height bar that reads as "measured zero".
struct DailyBars: View {
    struct Bar: Identifiable {
        var id = UUID()
        var label: String
        var value: Double?
        var help: String
    }

    var bars: [Bar]
    var tint: Color
    var palette: Palette
    var height: CGFloat = 64
    /// Highlight the last bar (it is "now", or today, and is usually partial).
    var highlightLast = true

    private var peak: Double {
        max(bars.compactMap { $0.value }.max() ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(Array(bars.enumerated()), id: \.element.id) { index, bar in
                    let fraction = (bar.value ?? 0) / peak
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(
                            highlightLast && index == bars.count - 1
                                ? tint
                                : tint.opacity(bar.value == nil ? 0.12 : 0.45)
                        )
                        .frame(height: bar.value == nil ? 3 : max(4, height * fraction))
                        .help(bar.help)
                }
            }
            .frame(height: height, alignment: .bottom)

            if bars.count > 1 {
                HStack {
                    Text(bars.first?.label ?? "")
                    Spacer()
                    if bars.count > 2 { Text(bars[bars.count / 2].label) }
                    Spacer()
                    Text(bars.last?.label ?? "")
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            }
        }
    }
}

/// One place for byte-rate formatting, so every panel prints the same units.
enum Rate {
    /// 「数字 + 单位」之间用**不换行空格**（U+00A0）。
    ///
    /// 这类值经常被拼进更长的字符串（`r 12.3 KB/s · w 0 B/s`），而普通空格是可换行点 ——
    /// 一行到头时就会在数字和单位之间断开，看上去又是一个"数字换了行"。不换行空格让
    /// 整个「值+单位」成为一个不可断开的词，换行只会发生在条目之间。
    static let nbsp = "\u{00A0}"

    static func compact(_ bytesPerSecond: Double) -> String {
        let text: String =
            switch bytesPerSecond {
            case ..<1024: String(format: "%.0f B", bytesPerSecond)
            case ..<1_048_576: String(format: "%.0f KB", bytesPerSecond / 1024)
            case ..<1_073_741_824: String(format: "%.1f MB", bytesPerSecond / 1_048_576)
            default: String(format: "%.2f GB", bytesPerSecond / 1_073_741_824)
            }
        return text.replacingOccurrences(of: " ", with: nbsp)
    }
}
