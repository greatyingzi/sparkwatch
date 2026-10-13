// What does the window server itself say about our status item?
//
// The pixel captures say "nothing drawn", while the item's own NSWindow says "on screen
// at x=669". The window server is the arbiter: `kCGWindowIsOnscreen` is its answer, and
// the remaining fields (`alpha`, `sharing`, layer) say whether it is being composited.
import AppKit

let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
for (label, option) in [("onScreenOnly", CGWindowListOption.optionOnScreenOnly), ("all", .optionAll)] {
    guard let raw = CGWindowListCopyWindowInfo(option, kCGNullWindowID) as? [[String: Any]] else { continue }
    let ours = raw.filter { ($0[kCGWindowOwnerName as String] as? String) == "SparkWatch" }
    print("=== \(label)：SparkWatch 的窗口 \(ours.count) 个 ===")
    for window in ours {
        let layer = window[kCGWindowLayer as String] as? Int ?? -999
        let onScreen = window[kCGWindowIsOnscreen as String] as? Bool
        let alpha = window[kCGWindowAlpha as String] as? Double
        let sharing = window[kCGWindowSharingState as String] as? Int
        let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        let number = window[kCGWindowNumber as String] as? Int
        print("   #\(number ?? -1) layer=\(layer) isOnscreen=\(String(describing: onScreen))"
            + " alpha=\(alpha ?? -1) sharing=\(sharing ?? -1)"
            + " bounds=\(bounds) (statusLevel=\(statusLevel))")
    }
}
