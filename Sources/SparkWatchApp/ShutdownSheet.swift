import AppKit
import SparkWatchCore
import SwiftUI

/// Shutting a machine down, behind a gate that has to be worked for.
///
/// Three separate things have to be true before the button enables, and each one
/// exists because of a specific way this goes wrong:
///
///  1. **A capability probe.** The box has to have systemd *and* passwordless sudo
///     (measured: it does). Offering the button on a machine that will then hang on
///     a password prompt is worse than not offering it.
///  2. **A typed word (`poweroff`).** A single mis-click on a popover is one gesture;
///     typing the word is not. This is the only irreversible action in the app.
///  3. **An explicit acknowledgement**, because the consequence is not obvious from
///     the outside: DGX Spark has **no Wake-on-LAN** (`wakeup = disabled` on every
///     physical interface), so a machine shut down from here has to be started by
///     hand — on site.
///
/// The sheet also states what is running *right now*, so the decision is made with
/// the current state in view rather than a stale impression of it.
struct ShutdownSheet: View {
    var node: NodeSnapshot
    var config: NodeConfig?
    var palette: Palette
    /// Called with a one-line summary for the activity log, or nil if the user gave up.
    var onFinish: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var support: NodeControl.Support?
    @State private var typed = ""
    @State private var understood = false
    @State private var busy = false
    @State private var failure: String?

    private var typedOK: Bool { typed.trimmingCharacters(in: .whitespaces).lowercased() == "poweroff" }
    private var canProceed: Bool { typedOK && understood && support?.canShutDown == true && !busy }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "power")
                    .foregroundStyle(palette.danger)
                Text("关机确认 · \(node.name)")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                Spacer(minLength: 0)
            }

            Text("优雅关机 \(node.name)：先停掉服务与容器，再断电。")
                .font(.system(size: 12.5, design: .rounded))

            warnings

            Toggle(isOn: $understood) {
                Text("我明白这个操作无法从面板撤销")
                    .font(.system(size: 12.5, design: .rounded))
            }
            .toggleStyle(.checkbox)

            VStack(alignment: .leading, spacing: 5) {
                Text("输入 poweroff 以确认")
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                TextField("poweroff", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12.5, design: .monospaced))
                    .frame(width: 200)
            }

            if let failure {
                Text(failure)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(palette.danger)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if support == nil {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("正在确认该机是否支持关机…")
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            } else if let support, !support.canShutDown {
                Text(support.note)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(palette.warn)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("取消") {
                    onFinish(nil)
                    dismiss()
                }
                Button(busy ? "关机中…" : "关机") {
                    Task { await shutDown() }
                }
                .disabled(!canProceed)
                .tint(palette.danger)
            }
        }
        .padding(16)
        .frame(width: 460)
        .task {
            guard let config else {
                failure = "找不到 \(node.name) 的 SSH 配置，无法下发关机指令。"
                return
            }
            support = await NodeControl.support(user: config.sshUser, host: config.sshHost)
        }
    }

    /// What is running right now — the facts that make this a decision rather than a
    /// reflex.
    @ViewBuilder
    private var warnings: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let running = node.inference?.running, running > 0 {
                bullet("推理引擎正在处理 \(Int(running)) 个请求"
                    + (node.inference?.kvUsagePct.map { String(format: "（KV 占用 %.0f%%）", $0) } ?? ""))
            }
            if !node.system.containers.isEmpty {
                bullet("容器在跑：\(node.system.containers.prefix(4).map(\.name).joined(separator: "、"))")
            }
            if node.system.gpuProcesses.first.map({ $0.memoryBytes > 1_073_741_824 }) == true {
                bullet("GPU 上有进程持有大量显存（\(node.system.gpuProcesses.prefix(2).map(\.name).joined(separator: "、"))）")
            }
            if support?.wakeAvailable != true {
                bullet("该机不支持网络唤醒，关机后需要到机器跟前手动开机")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(palette.danger.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(palette.danger.opacity(0.35), lineWidth: 1)
        )
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•")
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundStyle(palette.mutedStrong)
    }

    private func shutDown() async {
        guard let config else { return }
        busy = true
        defer { busy = false }
        let outcome = await NodeControl.shutdown(user: config.sshUser, host: config.sshHost)
        if outcome.ok {
            onFinish(outcome.message)
            dismiss()
        } else {
            failure = outcome.message
        }
    }
}

/// The button + sheet pair, so the same gated flow is reachable from the popover and
/// from the machine page without two implementations of the gate.
struct ShutdownButton: View {
    var node: NodeSnapshot
    var config: NodeConfig?
    var palette: Palette
    var onFinish: (String) -> Void
    var compact = false

    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Text("关机")
                .font(.system(size: compact ? 10.5 : 12.5, weight: .medium, design: .rounded))
                .foregroundStyle(palette.danger)
        }
        .buttonStyle(.plain)
        .help("优雅关机（需要输入 poweroff 确认）")
        .sheet(isPresented: $showing) {
            ShutdownSheet(node: node, config: config, palette: palette) { message in
                if let message { onFinish(message) }
            }
        }
    }
}
