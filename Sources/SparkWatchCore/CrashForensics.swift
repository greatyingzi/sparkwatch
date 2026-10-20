import Foundation

/// Why the box stopped last time — read from the box's own logs, on the Mac.
///
/// This is the one piece of forensic value the architecture already has: the
/// monitor lives off-box, so it survives the failure. What it lacked was the
/// ability to *say* what happened. Field reports for this hardware list five
/// independent pieces of evidence for a hard power-off rather than a crash:
/// journald stops mid-line, pstore is empty, the watchdog never fired, the peer's
/// ConnectX-7 reports both ports link-down in the same second, and Wake-on-LAN
/// does nothing. Three of those are readable over SSH after the fact.
///
/// Only `journalctl -b -1` (previous boot) is used: it is read-only, needs no
/// install, and answers "did the last shutdown write a clean marker". The verdict
/// is deliberately phrased as *suspected* — an OTA reboot and a forced reboot both
/// leave the same shape as a power cut, so absence of a marker is evidence, not
/// proof. Anything we cannot read (pstore needs root) is reported as unknown
/// rather than as clean.
public struct BootForensics: Sendable, Equatable, Codable {
    public enum Verdict: String, Codable, Sendable {
        case cleanShutdown
        case powerLossSuspected
        case kernelCrash
        case watchdog
        case undetermined
    }

    public var verdict: Verdict
    /// How firmly the verdict is supported by what we could actually read.
    public var confident: Bool
    public var summary: String
    /// Last lines of the previous boot, newest last. Evidence, not decoration.
    public var previousBootTail: [String] = []
    /// "2026-10-06 05:17:24" — when the previous boot's log stopped.
    public var previousBootEndedAt: String?
    /// `journalctl --list-boots` entries, newest last.
    public var bootList: [String] = []
    /// Clean-shutdown markers found in the previous boot (Power-Off/Reboot/Shutdown).
    public var shutdownMarkers: Int = 0
    /// Panic / lockup / hung-task lines in the previous boot's kernel log.
    public var panicMarkers: Int = 0
    /// Files in /sys/fs/pstore, or nil when it could not be read (needs root).
    public var pstoreEntries: Int?
    /// Whether the previous boot left any readable log at all. (Its *exact* line
    /// count was dropped on purpose: measuring it costs a full 21 s pass over a
    /// 762 973-line journal on this hardware, while everything the verdict needs
    /// lives in the last few hundred lines.)
    public var previousBootHadLog: Bool = false
    public var collectedAt: Date = Date()
    public var bootID: String?

    public init(verdict: Verdict, confident: Bool, summary: String) {
        self.verdict = verdict
        self.confident = confident
        self.summary = summary
    }

    public var label: String {
        switch verdict {
        case .cleanShutdown: "上次正常关机"
        case .powerLossSuspected: "疑似硬断电"
        case .kernelCrash: "内核崩溃（pstore 有转储）"
        case .watchdog: "看门狗/内核挂死"
        case .undetermined: "无法判定"
        }
    }
}

public enum CrashForensics {
    /// Read-only, one SSH round trip. Ends with `##done` so a non-zero `grep -c`
    /// in the middle cannot make ssh report failure (it would, and the whole
    /// probe would be treated as an error).
    public static let script = """
    echo '##bootid'; cat /proc/sys/kernel/random/boot_id 2>/dev/null || true
    echo '##uptime'; cut -d' ' -f1 /proc/uptime 2>/dev/null || true
    echo '##boots'; journalctl --list-boots --no-pager 2>/dev/null | tail -4 || true
    echo '##tail'; journalctl -b -1 --no-pager -n 6 2>/dev/null || true
    # Everything below is bounded to a tail on purpose. A full `journalctl -b -1`
    # pass costs ~21 s on this hardware (762 k lines), while `-n` seeks from the
    # end in ~2 s — and a clean shutdown's markers are by definition the last lines
    # of the boot, so a bounded tail loses nothing that the verdict needs.
    echo '##markers'; journalctl -b -1 --no-pager -n 400 2>/dev/null | grep -cE 'Reached target (Power-Off|Reboot|Shutdown)|systemd-shutdown' || true
    echo '##panics'; journalctl -k -b -1 --no-pager 2>/dev/null | grep -ciE 'Kernel panic|BUG: soft lockup|watchdog: BUG|hard LOCKUP|blocked for more than' || true
    echo '##pstore'; ls -1 /sys/fs/pstore 2>/dev/null | wc -l; ls -d /sys/fs/pstore 2>&1 | head -1 || true
    echo '##done'
    """

    public static func collect(
        user: String,
        host: String,
        timeout: TimeInterval = 20
    ) async throws -> BootForensics {
        let output = try await SshRunner.run(user: user, host: host, script: script, timeout: timeout)
        return parse(output)
    }

    /// Pure parser + verdict, so the decision table can be tested against the
    /// shapes real boxes produce (including this fleet's own boot log).
    public static func parse(_ text: String) -> BootForensics {
        var section = ""
        var bootID: String?
        var boots: [String] = []
        var tail: [String] = []
        var markers = 0
        var panics = 0
        var pstoreEntries: Int?
        var pstoreUnreadable = false


        for raw in text.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if line.hasPrefix("##") {
                section = String(line.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                continue
            }
            switch section {
            case "bootid":
                let value = line.trimmingCharacters(in: .whitespaces)
                if !value.isEmpty { bootID = value }
            case "boots":
                boots.append(line)
            case "tail":
                // Drop the "No journal files were found" style noise: an empty
                // journal is reported through `lines`, not through a fake line.
                if !line.hasPrefix("-- ") && !line.contains("No journal files") {
                    tail.append(String(line.prefix(180)))
                }
            case "markers":
                markers = Int(line.trimmingCharacters(in: .whitespaces)) ?? markers
            case "panics":
                panics = Int(line.trimmingCharacters(in: .whitespaces)) ?? panics
            case "pstore":
                if pstoreEntries == nil, let n = Int(line.trimmingCharacters(in: .whitespaces)) {
                    pstoreEntries = n
                } else if line.contains("Permission denied") || line.contains("No such file") {
                    pstoreUnreadable = true
                    pstoreEntries = nil
                }
            case "lines":
                // Retired: the exact line count needed a full journal pass (21 s on
                // this fleet). Kept as an ignored section so an older fixture still
                // parses.
                continue
            default:
                break
            }
        }

        var result = BootForensics(verdict: .undetermined, confident: false, summary: "")
        result.bootID = bootID
        result.bootList = boots
        result.previousBootTail = Array(tail.suffix(6))
        result.shutdownMarkers = markers
        result.panicMarkers = panics
        result.pstoreEntries = pstoreEntries
        result.previousBootHadLog = !tail.isEmpty
        result.previousBootEndedAt = tail.last

        // Decision table, most specific evidence first.
        if markers > 0 {
            result.verdict = .cleanShutdown
            result.confident = true
            result.summary = "上次关机写了干净关机标记（\(markers) 条），不是断电。"
        } else if let entries = pstoreEntries, entries > 0 {
            result.verdict = .kernelCrash
            result.confident = true
            result.summary = "pstore 有 \(entries) 条崩溃转储：上次是内核崩溃，不是断电。"
        } else if panics > 0 {
            result.verdict = .watchdog
            result.confident = true
            result.summary = "上次内核日志有 \(panics) 条 panic/lockup/hung-task：看门狗或挂死，不是断电。"
        } else if !tail.isEmpty {
            result.verdict = .powerLossSuspected
            result.confident = pstoreEntries == 0
            result.summary = "上次启动的日志停在「\(tail.last?.prefix(60) ?? "")」，随后没有干净关机标记"
                + (pstoreEntries == 0 ? "且 pstore 为空" : "")
                + " → 疑似硬断电或被强杀（两者在日志上无法区分）。"
        } else {
            result.verdict = .undetermined
            result.confident = false
            result.summary = "读不到上一次启动的日志（已轮转或无权限），无法判定上次怎么关的。"
        }
        if pstoreUnreadable {
            result.summary += " pstore 不可读（需要 root），该条证据缺失。"
        }
        return result
    }
}
