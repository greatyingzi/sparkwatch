import Foundation

/// `tailscale status --json` on the node itself.
///
/// Why ask the node rather than look at this Mac's peer list: "this machine left
/// the tailnet" and "I cannot see this machine from here" are different faults
/// with different fixes, and reading the wrong end is how a monitoring problem
/// gets mistaken for a broken machine (measured on this fleet: a node showed ✕
/// in the panel while it was alive and decoding at 34 tok/s — only its *relay*
/// path was broken).
///
/// The JSON is parsed with `JSONSerialization` rather than a `Codable` struct:
/// tailscale's schema is large, versioned and mostly irrelevant here, and a
/// missing field must not make the whole parse fail.
public enum TailnetParser {
    public static func parse(_ text: String) -> TailnetInfo? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == "unavailable" { return nil }
        guard let data = trimmed.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let selfNode = root["Self"] as? [String: Any] ?? [:]
        let ips = selfNode["TailscaleIPs"] as? [String] ?? []
        var info = TailnetInfo(
            available: true,
            online: selfNode["Online"] as? Bool ?? false,
            ip: ips.first(where: { !$0.contains(":") }) ?? ips.first,
            relay: selfNode["Relay"] as? String,
            keyExpired: keyExpired(selfNode),
            version: root["Version"] as? String
        )
        // A node with a backend state of Running but Self.Online missing (older
        // builds) should still read as online rather than as a silent failure.
        if !info.online, let state = root["BackendState"] as? String, state == "Running" {
            info.online = true
        }
        return info
    }

    /// Two spellings exist: a boolean `Self.Expired` on some builds, and
    /// `Self.KeyExpiry` (an RFC3339 timestamp) on the one shipped on these boxes —
    /// where `Expired` is simply absent. Reading only the boolean reported "key
    /// fine" on a wrong field, which is the kind of quiet lie that only shows up
    /// the day the node drops off the tailnet.
    private static func keyExpired(_ selfNode: [String: Any]) -> Bool {
        if let expired = selfNode["Expired"] as? Bool { return expired }
        guard let raw = selfNode["KeyExpiry"] as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        guard let date else { return false }
        // A zero timestamp means "no expiry set" on some builds.
        if date.timeIntervalSince1970 <= 0 { return false }
        return date < Date()
    }
}
