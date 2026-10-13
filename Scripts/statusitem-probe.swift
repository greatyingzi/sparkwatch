// Probe: can this Mac place a *brand new* status item at all?
//
// SparkWatch's item gets its window parked at y = -24 (off-screen) even when it is only
// 29 pt wide, while the menu bar still has ~47 pt of gaps. Two explanations remain:
// (a) the system cannot place any new item, or (b) this particular item is in macOS's
// "hidden" list (a Cmd-drag removal, or an identity the system remembers).
//
// A fresh two-line status item settles it: if the probe's window lands at y >= 0, the
// bar can still host items and the fault is SparkWatch's item identity.
import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
item.button?.title = "PROBE"
let other = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
other.button?.title = "PROBE2"

DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
    for (name, probe) in [("PROBE", item), ("PROBE2", other)] {
        let frame = probe.button?.window.map { NSStringFromRect($0.frame) } ?? "nil"
        let visible = probe.button?.window?.isVisible ?? false
        print("\(name): length=\(probe.length) window=\(frame) visible=\(visible)")
    }
}
// Stay alive long enough to be screenshotted: the frames above only say where macOS
// *thinks* the items are; only a capture says whether they are actually drawn.
DispatchQueue.main.asyncAfter(deadline: .now() + 25) { app.terminate(nil) }
app.run()
