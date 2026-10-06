// Prints the menu bar's status items from left to right, one per line:
//   <x> <width> <owner> <name>
// On macOS 26 every item's owner is "Control Center" and its name is the item's
// autosave name (CPU_mini, DiskMenu, or Item-0 for an app that never named its
// item); on older macOS the owner is the app. Positions and widths always come
// back. Names may come back blank when the terminal lacks Screen Recording
// permission; the script then says to tell the items apart by width.
//
//   swift menubar-order.swift

import CoreGraphics
import Foundation

let statusLevel = Int(CGWindowLevelForKey(.statusWindow))
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let items: [(x: Int, width: Int, owner: String, name: String)] = windows.compactMap { window in
    guard window[kCGWindowLayer as String] as? Int == statusLevel,
          let bounds = window[kCGWindowBounds as String] as? [String: Any],
          let x = (bounds["X"] as? NSNumber)?.intValue,
          let width = (bounds["Width"] as? NSNumber)?.intValue else { return nil }
    let owner = window[kCGWindowOwnerName as String] as? String ?? "?"
    let name = window[kCGWindowName as String] as? String ?? ""
    return (x, width, owner, name)
}
for item in items.sorted(by: { $0.x < $1.x }) {
    print(item.x, item.width, item.owner, item.name.isEmpty ? "-" : item.name)
}
if items.isEmpty {
    FileHandle.standardError.write("""
    No menu bar items are on screen. Is an app in full screen, or the screen locked?
    Show the desktop and run this again.

    """.data(using: .utf8)!)
    exit(1)
}
if items.allSatisfy({ $0.name.isEmpty }) {
    FileHandle.standardError.write("""
    Item names are hidden (the terminal probably lacks Screen Recording permission).
    Tell the items apart by width: CPU, GPU and RAM about 47 each, Disk about 100,
    the temperatures about 44, Zoom about 32.

    """.data(using: .utf8)!)
}
