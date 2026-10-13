import AppKit
import SparkWatchCore
import SwiftUI

/// ⌘K: jump to a page, a machine, or run an action.
///
/// Why a palette in a monitoring app: the popover is for a glance and the sidebar
/// is for browsing, but once a fleet has more than a handful of machines both get
/// slow — you scan a list to find one name you already know. A palette turns "find
/// spark-07" into three keystrokes, and it is the one place where an *action* (pause,
/// refresh, cycle theme) is reachable without hunting for the control that does it.
struct CommandPalette: View {
    @ObservedObject var model: AppModel
    @ObservedObject var state: MainWindowState
    var palette: Palette

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    private struct Command: Identifiable {
        var id: String { "\(group)/\(title)" }
        var group: String
        var title: String
        var hint: String?
        var run: () -> Void
    }

    var body: some View {
        ZStack {
            // Click-anywhere-to-dismiss, the same gesture every palette has.
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture { close() }

            VStack(spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    TextField("跳转到机器、执行动作、打开设置…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13.5, design: .rounded))
                        .focused($focused)
                        .onSubmit { runSelection() }
                    Text("esc")
                        .font(.system(size: 10, design: .monospaced))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(palette.border, lineWidth: 1))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .overlay(alignment: .bottom) { Divider() }

                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                row(command, selected: index == selection)
                                    .id(index)
                                    .onTapGesture {
                                        selection = index
                                        runSelection()
                                    }
                            }
                            if matches.isEmpty {
                                Text("没有匹配「\(query)」的项")
                                    .font(.system(size: 12.5, design: .rounded))
                                    .foregroundStyle(.secondary)
                                    .padding(14)
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .onChange(of: selection) { _, newValue in
                        withAnimation(.linear(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
                    }
                }

                HStack(spacing: 14) {
                    Text("↑↓ 移动")
                    Text("↵ 打开")
                    Text("esc 关闭")
                    Spacer(minLength: 0)
                    Text("⌘K")
                }
                .font(.system(size: 10.5, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .overlay(alignment: .top) { Divider() }
            }
            .frame(width: 600)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous).fill(palette.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(palette.borderStrong, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.5), radius: 30, y: 10)
            .padding(.top, 90)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .onAppear { focused = true }
    }

    private func row(_ command: Command, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if command.group != previousGroup(before: command) {
                Text(command.group)
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)
                    .padding(.bottom, 3)
            }
            HStack(spacing: 10) {
                Text(command.title)
                    .font(.system(size: 13.5, design: .rounded))
                Spacer(minLength: 0)
                if let hint = command.hint {
                    Text(hint)
                        .font(.system(size: 11.5, design: .rounded))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(selected ? palette.surfaceHover : .clear)
            .contentShape(Rectangle())
        }
    }

    private func previousGroup(before command: Command) -> String? {
        guard let index = matches.firstIndex(where: { $0.id == command.id }), index > 0 else { return nil }
        return matches[index - 1].group
    }

    // MARK: - Commands

    private var allCommands: [Command] {
        var commands: [Command] = []
        let pages: [MainPage] = [.overview, .energy, .tokens, .activity, .benchmarks]
        for page in pages {
            commands.append(Command(group: "前往", title: page.title, hint: "页面") { [self] in
                state.page = page
            })
        }
        for node in model.nodes {
            commands.append(Command(
                group: "机器",
                title: node.name,
                hint: node.source == .down ? "离线" : (node.inference?.decodeTPS.map { String(format: "%.0f/s", $0) } ?? "在线")
            ) { [self] in
                state.page = .machine(node.id)
            })
        }
        commands.append(contentsOf: [
            Command(group: "动作", title: "添加机器", hint: "设置") { [self] in
                NotificationCenter.default.post(name: .sparkwatchOpenSettingsMachines, object: nil)
            },
            Command(group: "动作", title: model.isPaused ? "恢复监控" : "暂停监控", hint: nil) { [self] in
                Task { await model.togglePause() }
            },
            Command(group: "动作", title: "立即刷新", hint: "⌘R") { [self] in
                Task { await model.refresh() }
            },
            Command(group: "动作", title: "切换主题", hint: AppTheme.allCases.map(\.swatchLabel).joined(separator: " · ")) { [self] in
                let order = AppTheme.allCases
                let next = order[(order.firstIndex(of: model.theme).map { $0 + 1 } ?? 1) % order.count]
                Task { await model.setTheme(next) }
            },
            Command(group: "动作", title: "打开设置", hint: "⌘,") { [self] in
                NSApp.sendAction(#selector(AppDelegate.openSettingsFromMenu), to: nil, from: nil)
            },
        ])
        return commands
    }

    private var matches: [Command] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return allCommands }
        // Subsequence match, so "s7" finds "spark-07" — the same trick every
        // command palette uses, and the reason a palette beats a menu at scale.
        return allCommands.filter { fuzzy(trimmed, $0.title) }
    }

    private func fuzzy(_ needle: String, _ haystack: String) -> Bool {
        let target = Array(haystack.lowercased())
        let query = Array(needle.lowercased())
        var index = 0
        for character in query {
            guard let found = target[index...].firstIndex(of: character) else { return false }
            index = found + 1
        }
        return true
    }

    private func runSelection() {
        guard matches.indices.contains(selection) else { return }
        let command = matches[selection]
        close()
        command.run()
    }

    private func close() { state.paletteOpen = false }
}

extension Notification.Name {
    /// Raised by the palette's "添加机器"; the app delegate opens the settings
    /// window on the machines tab. A notification rather than a closure because the
    /// palette lives inside the window hierarchy while the window is owned by the
    /// delegate.
    static let sparkwatchOpenSettingsMachines = Notification.Name("SparkWatchOpenSettingsMachines")
}
