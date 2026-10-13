// What displays does this Mac actually have, and where is the menu bar?
//
// Status items report on-screen frames yet never appear in a capture of (0,0) — so the
// capture and the item may be on different displays (macOS shows a menu bar on each).
import AppKit

for (index, screen) in NSScreen.screens.enumerated() {
    print("screen \(index): frame=\(NSStringFromRect(screen.frame))"
        + " visible=\(NSStringFromRect(screen.visibleFrame))"
        + " menuBarHeight=\(screen.frame.maxY - screen.visibleFrame.maxY)"
        + " scale=\(screen.backingScaleFactor)")
}
print("main: \(NSStringFromRect(NSScreen.main?.frame ?? .zero))")
print("screens: \(NSScreen.screens.count)")
