import AppKit
import SparkWatchCore
import SwiftUI

// MARK: - Palette
//
// One place for the visual language, so the status-bar chip, the popover, the
// detail window and the settings window cannot drift apart.
//
// The token set and the exact hex values are the reference project's
// (`src/index.css` themes), which is a deliberately small system:
//
//   * **one accent hue, amber**, in every theme — it means "brand / clickable"
//     and nothing else. Status has its own hues, so state never reads as brand.
//   * four themes that differ in *surface* (white / paper / grey / black) but
//     keep the same semantics.
//   * cards are a 1 px border on a flat surface: no blur, no drop shadow. A
//     dashboard that raises every card also raises nothing.
//
// Colour rules that matter more than the values (learned the hard way, see the
// project README):
//   * a colour only appears when a *rule* fires — thresholds are taken from
//     `Health` itself, never from a generic 0–100 ramp. 55 °C is not "55 % busy"
//     and a box sitting in the 70s under sustained inference must stay calm, or
//     colour becomes noise people learn to ignore.
//   * utilisation is a **magnitude**, not a status: it is drawn in the accent
//     hue, and only escalates when something is actually wrong (thermal
//     throttle, or the temperature rule firing). Painting 95 % utilisation red
//     would put a false alarm on every healthy busy box.
struct Palette: Sendable {
    // Surfaces
    var base: Color
    var surface: Color
    var surfaceElevated: Color
    var surfaceHover: Color
    var border: Color
    var borderStrong: Color

    // Text
    var text: Color
    var textStrong: Color
    var muted: Color
    var mutedStrong: Color
    var faint: Color

    // Brand
    var accent: Color
    var accentSoft: Color
    var accentText: Color
    var onAccent: Color

    // Status
    var ok: Color
    var warn: Color
    var danger: Color
    var info: Color
    var violet: Color

    // Charts / breakdowns
    var grid: Color
    var memEngine: Color
    var memSystem: Color
    var memOther: Color

    var isDark: Bool

    /// Track colour behind every bar and ring.
    var track: Color { surfaceHover }
    /// Card fill in the popover: the surface, slightly lifted off the backdrop
    /// instead of blurred (the reference project dropped `backdrop-filter` too).
    var card: Color { surface }
    var cardBorder: Color { border }

    // MARK: Threshold colours

    /// Utilisation: accent by default. Escalates only when the *thing that
    /// matters* is wrong — the temperature rule firing, or an active clock
    /// throttle. Never a 0–100 ramp.
    func utilization(_ pct: Double?, tempC: Double? = nil, throttled: Bool = false) -> Color {
        // The value itself deliberately does not choose a colour: how busy a box
        // is is a magnitude, not a status. See the doc comment above.
        guard pct != nil else { return faint }
        if throttled { return danger }
        if let tempC, tempC >= 90 { return danger }
        if let tempC, tempC >= 85 { return warn }
        return accent
    }

    /// Temperature, aligned with `Health` (GB10 warns at 85 °C, alerts at 90 °C
    /// on the GPU rail, which exposes no limit of its own to be relative to).
    func temperature(_ celsius: Double?) -> Color {
        guard let celsius else { return faint }
        switch celsius {
        case ..<85: return mutedStrong
        case ..<90: return warn
        default: return danger
        }
    }

    /// Unified memory occupancy. Judged in *percent of the pool* here; the
    /// health rules judge absolute headroom and PSI, and those are what turn the
    /// dot red — this is only the bar's colour.
    func memory(_ pct: Double?) -> Color {
        guard let pct else { return faint }
        switch pct {
        case ..<85: return info
        case ..<90: return warn
        default: return danger
        }
    }

    /// KV-cache pool occupancy: the engine queues or preempts when it fills up.
    func kv(_ pct: Double?) -> Color {
        guard let pct else { return faint }
        switch pct {
        case ..<50: return ok
        case ..<80: return warn
        default: return danger
        }
    }

    func accent(for level: HealthLevel) -> Color {
        switch level {
        case .ok: ok
        case .unknown: muted
        case .warning: warn
        case .critical: danger
        }
    }

    /// Disk / storage: same idea as memory, looser lines (a monitor filling a
    /// disk is normal work).
    func storage(_ pct: Double?) -> Color {
        guard let pct else { return faint }
        switch pct {
        case ..<60: return info
        case ..<85: return mutedStrong
        default: return warn
        }
    }

    /// Theme resolution

    /// Resolve a theme choice against the window's actual appearance, so
    /// `system` follows light/dark live and the explicit themes ignore it.
    static func of(_ theme: AppTheme, dark: Bool) -> Palette {
        switch theme {
        case .system: dark ? .dark : .light
        case .white: .white
        case .light: .light
        case .dark: .dark
        case .oled: .oled
        }
    }

    /// The surface behind a whole popover or window.
    ///
    /// For an explicit theme this is the theme's own base colour: an explicit
    /// choice has to be exact, and a system material underneath it would keep the
    /// chrome light (or dark) on its own schedule. Measured failure this fixes: a
    /// popover with a dark card grid and a **light** header/footer, because the
    /// material followed the Mac while the palette did not.
    ///
    /// `system` keeps the native material — there, matching the OS *is* the
    /// requirement.
    static func chrome(_ theme: AppTheme, dark: Bool, translucent: Bool = true) -> AnyShapeStyle {
        if theme == .system {
            return translucent
                ? AnyShapeStyle(.regularMaterial)
                : AnyShapeStyle(Color(nsColor: .windowBackgroundColor))
        }
        return AnyShapeStyle(of(theme, dark: dark).base)
    }

    static let white = Palette(
        base: hex(0xF3F4F6), surface: hex(0xFFFFFF), surfaceElevated: hex(0xF7F8FA),
        surfaceHover: hex(0xECEEF2), border: hex(0xE1E4E9), borderStrong: hex(0xCCD1D9),
        text: hex(0x14181E), textStrong: hex(0x000000), muted: hex(0x5C6470),
        mutedStrong: hex(0x3C424C), faint: hex(0x8E95A1),
        accent: hex(0xE8A21C), accentSoft: hex(0xE8A21C, 0.15), accentText: hex(0x8C5A00),
        onAccent: hex(0x1C1404),
        ok: hex(0x12915F), warn: hex(0xC85A10), danger: hex(0xCF3038),
        info: hex(0x2A6FDB), violet: hex(0x7A4FD8),
        grid: hex(0x0F172A, 0.05), memEngine: hex(0x0891B2), memSystem: hex(0x6D28D9),
        memOther: hex(0x8A8A8A), isDark: false
    )

    static let light = Palette(
        base: hex(0xDCE0E7), surface: hex(0xFFFFFF), surfaceElevated: hex(0xECEFF4),
        surfaceHover: hex(0xDDE1E8), border: hex(0xCFD5DE), borderStrong: hex(0xB9C1CE),
        text: hex(0x12161C), textStrong: hex(0x000000), muted: hex(0x5A6370),
        mutedStrong: hex(0x3B424D), faint: hex(0x8B93A0),
        accent: hex(0xE8A21C), accentSoft: hex(0xE8A21C, 0.16), accentText: hex(0x8C5A00),
        onAccent: hex(0x1C1404),
        ok: hex(0x12915F), warn: hex(0xC85A10), danger: hex(0xCF3038),
        info: hex(0x2A6FDB), violet: hex(0x7A4FD8),
        grid: hex(0x0F172A, 0.07), memEngine: hex(0x0891B2), memSystem: hex(0x6D28D9),
        memOther: hex(0x8A8478), isDark: false
    )

    static let dark = Palette(
        base: hex(0x0A0C0F), surface: hex(0x12151A), surfaceElevated: hex(0x181C22),
        surfaceHover: hex(0x1F242B), border: hex(0x232830), borderStrong: hex(0x343B46),
        text: hex(0xE9ECF0), textStrong: hex(0xFFFFFF), muted: hex(0x8A919C),
        mutedStrong: hex(0xB3B9C2), faint: hex(0x5B626D),
        accent: hex(0xF0B03A), accentSoft: hex(0xF0B03A, 0.14), accentText: hex(0xF4B942),
        onAccent: hex(0x1C1404),
        ok: hex(0x3FD08F), warn: hex(0xFF914D), danger: hex(0xFF5D62),
        info: hex(0x6EA8FF), violet: hex(0xB690FF),
        grid: hex(0xFFFFFF, 0.045), memEngine: hex(0x3FD0E4), memSystem: hex(0x8F6FF0),
        memOther: hex(0x9AA3AF), isDark: true
    )

    static let oled = Palette(
        base: hex(0x000000), surface: hex(0x0B0C0E), surfaceElevated: hex(0x121417),
        surfaceHover: hex(0x1A1D21), border: hex(0x1F2328), borderStrong: hex(0x30363D),
        text: hex(0xE9ECF0), textStrong: hex(0xFFFFFF), muted: hex(0x858C97),
        mutedStrong: hex(0xB3B9C2), faint: hex(0x555B65),
        accent: hex(0xF0B03A), accentSoft: hex(0xF0B03A, 0.14), accentText: hex(0xF4B942),
        onAccent: hex(0x1C1404),
        ok: hex(0x3FD08F), warn: hex(0xFF914D), danger: hex(0xFF5D62),
        info: hex(0x6EA8FF), violet: hex(0xB690FF),
        grid: hex(0xFFFFFF, 0.045), memEngine: hex(0x3FD0E4), memSystem: hex(0x8F6FF0),
        memOther: hex(0x9AA3AF), isDark: true
    )

    private static func hex(_ rgb: UInt32, _ alpha: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((rgb >> 16) & 0xFF) / 255,
            green: Double((rgb >> 8) & 0xFF) / 255,
            blue: Double(rgb & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - AppKit appearance
//
// The palette paints the SwiftUI content; this makes the *native* controls
// inside that content agree with it. Without it a dark popover keeps a light
// progress spinner, light buttons and a light menu, which is exactly the kind
// of half-themed surface that reads as a bug.
extension AppTheme {
    /// `nil` for `system`, which means "inherit the Mac's setting" — the whole
    /// point of that option.
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .white, .light: NSAppearance(named: .aqua)
        case .dark, .oled: NSAppearance(named: .darkAqua)
        }
    }
}

// MARK: - Geometry and labels
//
// Kept separate from the palette: these are layout facts (verified by measuring
// the rendered popover), not colours, and they do not change with the theme.
enum Theme {
    /// One inset for the header, the cards and the footer, so their left and
    /// right edges share a single vertical axis.
    static let gutter: CGFloat = 12
    /// Popover width. 400 pt is the measured sweet spot: wide enough for a
    /// 88 pt ring plus a 2×2 block of numbers, narrow enough to stay a popover.
    static let popoverWidth: CGFloat = 400
    /// Height the popover may occupy, taken from the real screen instead of a
    /// guess: the old hard-coded 900 exceeded the usable height of a 1440×900
    /// display, so the cap could not prevent a squeeze. What does not fit now
    /// overflows into an explicit row that opens the main window.
    ///
    /// `availableHeightOverride` exists for the preview/verification path: an
    /// offscreen render has no real screen, so without it the capacity rule can
    /// only ever be measured at the fallback size. Written once at CLI startup,
    /// before any view is built (`nonisolated(unsafe)` for that reason).
    nonisolated(unsafe) static var availableHeightOverride: CGFloat?
    static var availableHeight: CGFloat {
        if let availableHeightOverride { return availableHeightOverride }
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(240, visible - 120)
    }
    /// Chrome the popover spends outside the cards: header + deployment banner +
    /// the 9 pt body padding top and bottom + footer. **Measured on the real
    /// popover** (1-machine render 371 pt, of which the card is 284), not
    /// estimated — this number decides how many machines fit, so a guess here
    /// shows up as a machine silently disappearing into the overflow row.
    static let popoverChrome: CGFloat = 140
    /// A card's height. Fixed on purpose — data-dependent height is what made
    /// the old popover grow until AppKit compressed text into its neighbours.
    /// 302 pt fits the tallest card (one with a health chip) with the unified
    /// memory breakdown in it; verified by rendering, not by adding up padding.
    static let cardHeight: CGFloat = 302

    static func levelLabel(_ level: HealthLevel) -> String {
        switch level {
        case .ok: "正常"
        case .unknown: "未知"
        case .warning: "注意"
        case .critical: "异常"
        }
    }

    /// How many machine cards fit on this screen, given the measured chrome and
    /// card heights. The popover never scrolls: what does not fit is summarised.
    ///
    /// `+ gap` because n cards spend n−1 gaps; measured at 780 pt of room this
    /// yields 2 cards (total 715 pt), which is what the design's capacity table
    /// claims, and at 1360 pt it yields 4.
    static func cardCapacity(available: CGFloat = availableHeight) -> Int {
        max(1, Int((available - popoverChrome + cardGap) / (cardHeight + cardGap)))
    }

    /// Vertical rhythm between cards.
    static let cardGap: CGFloat = 7
}
