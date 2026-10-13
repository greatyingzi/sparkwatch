import Foundation

/// Actions that change a machine's state, as opposed to reading it.
///
/// Everything here is deliberately explicit and separately testable, because it is
/// the only part of this app that can *break* something: a monitor that can power
/// your box off is a different risk class from one that draws a number wrong.
///
/// Facts measured on this fleet (2026-10-10), which shape the design:
///  * the DGX boxes have **no** `/usr/local/bin/spark-shutdown` (the script the
///    reference implementation calls), but the login user has passwordless sudo,
///    so `sudo -n systemctl poweroff` is the honest primitive;
///  * **Wake-on-LAN is not available**: every physical interface reports
///    `wakeup = disabled`, so a powered-off Spark has to be started by hand. The
///    UI therefore does not offer a wake button that cannot work.
public enum NodeControl {
    public enum Capability: String, Sendable {
        case shutdown
        case wake
    }

    public struct Support: Sendable, Equatable {
        /// Passwordless sudo works, so a shutdown can be issued without a prompt.
        public var sudoAvailable: Bool
        /// At least one interface has WoL enabled.
        public var wakeAvailable: Bool
        public var note: String

        public var canShutDown: Bool { sudoAvailable }
    }

    public struct Outcome: Sendable, Equatable {
        public var ok: Bool
        public var message: String

        public init(ok: Bool, message: String) {
            self.ok = ok
            self.message = message
        }
    }

    /// Read-only capability probe. Cheap enough to run when the confirmation sheet
    /// opens — asking at that moment also means the answer reflects the machine's
    /// state now, not whenever the last slow probe ran.
    public static func support(user: String, host: String, timeout: TimeInterval = 12) async -> Support {
        let script = supportScript
        do {
            let output = try await SshRunner.run(user: user, host: host, script: script, timeout: timeout)
            return parseSupport(output)
        } catch {
            return Support(
                sudoAvailable: false,
                wakeAvailable: false,
                note: "无法读取该机的关机能力：\(String(describing: error).prefix(120))"
            )
        }
    }

    static let supportScript = """
    echo '##sudo'; sudo -n true 2>/dev/null && echo ok || echo no
    echo '##systemd'; systemctl --version >/dev/null 2>&1 && echo ok || echo no
    echo '##wake'; for f in /sys/class/net/*/device/power/wakeup; do [ -f "$f" ] && cat "$f"; done 2>/dev/null || true
    echo '##done'
    """

    static func parseSupport(_ text: String) -> Support {
        var sudo = false
        var systemd = false
        var wakeStates: [String] = []
        var section = ""
        for line in text.split(whereSeparator: \.isNewline) {
            let line = String(line).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("##") {
                section = String(line.dropFirst(2))
                continue
            }
            switch section {
            case "sudo": sudo = (line == "ok")
            case "systemd": systemd = (line == "ok")
            case "wake": if !line.isEmpty { wakeStates.append(line.lowercased()) }
            default: break
            }
        }
        let wake = wakeStates.contains("enabled")
        var note: String
        if !systemd {
            note = "该机没有 systemd，无法用标准方式关机"
        } else if !sudo {
            note = "登录用户在目标机上没有免密 sudo，关机需要先配置 NOPASSWD（或手动执行）"
        } else if wake {
            note = "支持关机；有网卡开启了 WoL"
        } else {
            note = "支持关机（免密 sudo 可用）。该机不支持网络唤醒，关机后需手动开机"
        }
        return Support(sudoAvailable: sudo && systemd, wakeAvailable: wake, note: note)
    }

    /// The exact command issued. Kept as a separate function so a test can assert
    /// on it — the difference between `poweroff` and `poweroff -f`, or between
    /// `-n` and a prompt, is the difference between a graceful stop and a hang.
    ///
    /// `sync` first: the unified pool is DRAM-backed and a 100 GB model has been
    /// writing to it; a poweroff that races the writeback is how a filesystem
    /// ends up dirty.
    static func shutdownScript() -> String {
        """
        sync
        if command -v spark-shutdown >/dev/null 2>&1; then
          sudo -n spark-shutdown
        else
          sudo -n systemctl poweroff
        fi
        echo "##accepted"
        """
    }

    /// Issue a graceful shutdown. Returns as soon as the machine accepts the
    /// command — the SSH connection dies with the box, so waiting for the exit
    /// status would report a failure for a shutdown that worked.
    public static func shutdown(user: String, host: String, timeout: TimeInterval = 15) async -> Outcome {
        do {
            let output = try await SshRunner.run(
                user: user, host: host, script: shutdownScript(), timeout: timeout
            )
            if output.contains("##accepted") {
                return Outcome(ok: true, message: "已下发关机指令，\(host) 正在停止服务并断电")
            }
            return Outcome(ok: true, message: "已下发关机指令（未收到确认回显，连接可能已中断）")
        } catch {
            // The usual "failure" here is the connection dropping *because* the
            // poweroff worked. That is not an error a user should be shown as one.
            let text = String(describing: error)
            if text.contains("超时") || text.contains("transport") || text.contains("Connection") {
                return Outcome(ok: true, message: "连接已断开（与关机一致），\(host) 应已断电")
            }
            return Outcome(ok: false, message: "关机指令失败：\(text.prefix(160))")
        }
    }

    /// The magic packet for Wake-on-LAN. Present because a *host* (non-Spark)
    /// machine may support it, and because a packet is cheap; `support()` decides
    /// whether the UI offers it at all.
    public static func magicPacket(mac: String) -> [UInt8]? {
        let cleaned = mac.replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "-", with: "")
        guard cleaned.count == 12 else { return nil }
        var bytes: [UInt8] = []
        for index in stride(from: 0, to: 12, by: 2) {
            let start = cleaned.index(cleaned.startIndex, offsetBy: index)
            let end = cleaned.index(start, offsetBy: 2)
            guard let byte = UInt8(cleaned[start..<end], radix: 16) else { return nil }
            bytes.append(byte)
        }
        return Array(repeating: 0xFF, count: 6) + Array(repeating: bytes, count: 16).flatMap { $0 }
    }
}
