import Foundation

/// Settings live in Application Support; secrets do not.
///
/// Password policy (same as DGXPulse, MIT): the dashboard password is *never*
/// stored. We keep the 14-day JWT and the username, and ask for the password
/// again only when the token expires.
///
/// Token storage: Keychain first, 0600 file second. The Keychain binds an item's
/// ACL to the exact binary that created it, which breaks between an ad-hoc
/// signed dev build and a differently-signed app (verified: the probe wrote the
/// item fine, then the app's read came back empty with no prompt). So the
/// Keychain is best-effort and a `sessions.json` file (owner-only) is the
/// reliable store for unsigned local builds. Still never the password.
public struct SettingsStore: Sendable {
    public static let directory: URL = {
        // `SPARKWATCH_HOME` redirects every store (settings, sessions, ledgers) so a
        // diagnostic run can exercise the real pipeline against the real boxes
        // without touching the installed app's state — the two instances share no
        // files and, with their own `dashboardLocalPort`, no SSH forwards either.
        // This is what makes `--print-status` usable while the menu-bar app is up.
        if let override = ProcessInfo.processInfo.environment["SPARKWATCH_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appending(path: "SparkWatch", directoryHint: .isDirectory)
    }()

    public static var settingsURL: URL { directory.appending(path: "settings.json") }

    public static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: settingsURL),
            let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    public static func save(_ settings: AppSettings) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(settings).write(to: settingsURL, options: .atomic)
    }
}

/// Sessions live in an owner-only file, never in the Keychain.
///
/// Why not the Keychain: its ACL binds an item to the exact binary that created
/// it, and an ad-hoc signed build changes identity on every rebuild, so macOS
/// re-asks for authorisation on each access — after a few iterations that is a
/// prompt storm for a token that only grants read access to a box we already
/// have passwordless SSH to. The password is still never stored at all; only the
/// 14-day session token is, at mode 0600 under Application Support.
public enum SessionStore {
    private static var sessionsURL: URL {
        SettingsStore.directory.appending(path: "sessions.json")
    }

    private static func usernameKey(_ nodeID: UUID) -> String { "username.\(nodeID.uuidString)" }

    public static func username(for nodeID: UUID) -> String? {
        let value = UserDefaults.standard.string(forKey: usernameKey(nodeID))
        return (value?.isEmpty ?? true) ? nil : value
    }

    public static func setUsername(_ username: String, for nodeID: UUID) {
        UserDefaults.standard.set(username, forKey: usernameKey(nodeID))
    }

    private static func readTokens() -> [String: String] {
        guard let data = try? Data(contentsOf: sessionsURL),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return [:] }
        return object
    }

    private static func writeTokens(_ tokens: [String: String]) {
        try? FileManager.default.createDirectory(
            at: SettingsStore.directory, withIntermediateDirectories: true
        )
        guard let data = try? JSONSerialization.data(withJSONObject: tokens, options: [.prettyPrinted])
        else { return }
        try? data.write(to: sessionsURL, options: [.atomic])
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: sessionsURL.path
        )
    }

    public static func token(for nodeID: UUID) -> String? {
        readTokens()[nodeID.uuidString]
    }

    public static func save(token: String, for nodeID: UUID) {
        var tokens = readTokens()
        tokens[nodeID.uuidString] = token
        writeTokens(tokens)
    }

    public static func clear(for nodeID: UUID) {
        UserDefaults.standard.removeObject(forKey: usernameKey(nodeID))
        var tokens = readTokens()
        tokens.removeValue(forKey: nodeID.uuidString)
        writeTokens(tokens)
    }
}
