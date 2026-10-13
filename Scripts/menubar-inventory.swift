// Inventory every menu-bar item on this Mac.
//
// Status items are windows at the status-bar level. Those the system actually draws sit
// just above the top of the screen; those it has given up on are parked off-screen
// (negative y). Listing them settles "is the bar full?" with numbers instead of a guess —
// and shows whether it is only our item that got dropped or everyone's.
import AppKit

let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
let options: CGWindowListOption = [.optionAll]
guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("无法读取窗口列表")
    exit(1)
}

struct Item {
    var owner: String
    var bounds: CGRect
}
var items: [Item] = []
for window in raw {
    guard let level = window[kCGWindowLayer as String] as? Int, level == statusLevel else { continue }
    guard let owner = window[kCGWindowOwnerName as String] as? String else { continue }
    guard let dict = window[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
    let rect = CGRect(
        x: dict["X"] ?? 0, y: dict["Y"] ?? 0, width: dict["Width"] ?? 0, height: dict["Height"] ?? 0
    )
    // Owner name "Window Server" is the system's own menu bar chrome.
    guard rect.width > 4, rect.height > 4, rect.height < 40 else { continue }
    items.append(Item(owner: owner, bounds: rect))
}

let screenHeight = NSScreen.main?.frame.height ?? 900
let onScreen = items.filter { $0.bounds.origin.y > 0 }
let parked = items.filter { $0.bounds.origin.y <= 0 }

print("菜单栏项数量: \(items.count)（在屏 \(onScreen.count) / 被收起 \(parked.count)）")
let topRow = onScreen.filter { $0.bounds.origin.y >= screenHeight - 40 }
let width = topRow.reduce(0) { $0 + $1.bounds.width }
print(String(format: "在屏项总宽 ≈ %.0f pt（屏幕宽 %0.f pt）", width, NSScreen.main?.frame.width ?? 1440))
print("占用最宽的 12 个:")
for item in topRow.sorted(by: { $0.bounds.width > $1.bounds.width }).prefix(12) {
    print(String(format: "   %6.0f pt  x=%4.0f  %@", item.bounds.width, item.bounds.origin.x, item.owner))
}
if !parked.isEmpty {
    print("被系统收起的项（origin.y ≤ 0）:")
    for item in parked.prefix(10) {
        print(String(format: "   x=%5.0f y=%5.0f w=%4.0f  %@", item.bounds.origin.x, item.bounds.origin.y, item.bounds.width, item.owner))
    }
}
