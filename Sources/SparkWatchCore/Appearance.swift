import Foundation

/// Which palette the app paints itself with.
///
/// `system` is the native-correct default (follow the Mac's light/dark setting,
/// which is what every other menu-bar app does). The four explicit choices are
/// the reference project's set, kept because they are genuinely different
/// surfaces rather than four names for two looks:
///
///  * `white`  — cool neutral whites (a bright desk under office lighting)
///  * `light`  — warm paper whites over a grey base (reads calmer than white)
///  * `dark`   — neutral greys on a near-black base (the default look)
///  * `oled`   — true black, for panels where black pixels cost nothing
///
/// The palette values themselves live in the app target (`Palette`), because
/// `NSColor` has no business in the data layer; this enum is here so a theme
/// choice survives in `AppSettings`.
public enum AppTheme: String, Codable, Sendable, CaseIterable {
    case system
    case white
    case light
    case dark
    case oled

    public var label: String {
        switch self {
        case .system: "跟随系统"
        case .white: "白色"
        case .light: "浅色"
        case .dark: "深色"
        case .oled: "纯黑"
        }
    }

    /// Short tag used in the settings window's swatch row.
    public var swatchLabel: String {
        switch self {
        case .system: "系统"
        case .white: "White"
        case .light: "Light"
        case .dark: "Dark"
        case .oled: "OLED"
        }
    }

    /// Whether this choice is a dark surface. Only meaningful for the explicit
    /// themes; `system` resolves at render time from the window's appearance.
    public var isDark: Bool {
        switch self {
        case .dark, .oled: true
        case .white, .light: false
        case .system: true // resolved by appearance in the UI layer
        }
    }
}
