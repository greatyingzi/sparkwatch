import AppKit
import Foundation

/// Launch-at-login via a LaunchAgent in ~/Library/LaunchAgents.
///
/// `SMAppService.mainApp` would be the modern route, but it requires the app to
/// be code-signed by a real identity and installed in /Applications; an ad-hoc
/// signed local build fails registration with a permission error. The
/// LaunchAgent route works for both, and matches how the other menu-bar app on
/// this Mac does it (macfan), so there is one convention to remember.
enum LoginItem {
    static let label = "com.yingzi.sparkwatch"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    /// The binary the agent should launch: prefer the *installed* copy, because
    /// `install.sh` deletes the repo's `dist/` bundle on purpose (two identical
    /// bundles make LaunchServices hand `open` the stale one). Enabling autostart
    /// while running the dev copy used to write that doomed path into the plist,
    /// and login then failed with no visible error — `launchctl list` showed
    /// `- 78 com.yingzi.sparkwatch` (78 = EX_CONFIG, executable not found) and the
    /// menu bar simply never appeared. Measured 2026-10-03.
    static var executablePath: String {
        let installed = [
            "/Applications/SparkWatch.app",
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Applications/SparkWatch.app").path,
        ]
        .map { "\($0)/Contents/MacOS/SparkWatch" }
        .first { FileManager.default.fileExists(atPath: $0) }
        return installed ?? Bundle.main.executablePath ?? CommandLine.arguments[0]
    }

    @discardableResult
    static func setEnabled(_ enabled: Bool) -> String? {
        if enabled {
            do {
                try FileManager.default.createDirectory(
                    at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                let plist = """
                <?xml version="1.0" encoding="UTF-8"?>
                <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
                <plist version="1.0">
                <dict>
                    <key>Label</key><string>\(label)</string>
                    <key>ProgramArguments</key>
                    <array><string>\(executablePath)</string></array>
                    <key>RunAtLoad</key><true/>
                    <key>KeepAlive</key><false/>
                    <key>ProcessType</key><string>Interactive</string>
                </dict>
                </plist>
                """
                try plist.write(to: plistURL, atomically: true, encoding: .utf8)
                // Reload so an edited path takes effect immediately.
                launchctl(["unload", plistURL.path])
                let result = launchctl(["load", plistURL.path])
                return result.isEmpty ? nil : result
            } catch {
                return String(describing: error)
            }
        } else {
            _ = launchctl(["unload", plistURL.path])
            try? FileManager.default.removeItem(at: plistURL)
            return nil
        }
    }

    @discardableResult
    private static func launchctl(_ arguments: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        task.arguments = arguments
        let pipe = Pipe()
        task.standardError = pipe
        task.standardOutput = Pipe()
        guard (try? task.run()) != nil else { return "launchctl 无法执行" }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        task.waitUntilExit()
        return task.terminationStatus == 0
            ? "" : String(decoding: data ?? Data(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Small summary used by the About panel and the settings footer.
enum AppInfo {
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        return short ?? "dev"
    }

    static var build: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "-"
    }

    static var bundlePath: String { Bundle.main.bundlePath }
}
