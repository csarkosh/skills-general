// MacStats: menu bar items that sit beside the Stats app's CPU, GPU and RAM items,
// drawn like them: Temp (CPU and GPU temperature, with every sensor in its panel)
// and Disk (used/total space, with where it goes in its panel). Each item lives in
// its own file; MenuKit.swift holds what they share.
//
//   swiftc -O *.swift -o MacStats           # setup.sh builds it into MacStats.app
//   MacStats                                # runs both menu bar items
//   MacStats --show-panel temp|disk         # runs, with that item's panel open
//   MacStats --render temp|disk out.png     # draws that menu bar item to a PNG and exits
//   MacStats --sensors                      # prints the Temp panel and exits
//   MacStats --weigh 49.8 53.0 …            # prints those temperatures' hot-weighted value
//   MacStats --spaces                       # prints the disk's five volume spaces
//   MacStats --legend                       # prints the Disk panel's Spaces rows, in order
//   MacStats --report [folder] [--min-mb N] # prints the Disk panel's folders

import Cocoa

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var temp: MenuBarItem!
    private var disk: MenuBarItem!
    private let reader = SensorReader()
    private lazy var tempPanel = TempPanel(reader: reader)
    private lazy var diskPanel = DiskPanel()
    private let diskSampler = DiskSampler()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        temp = MenuBarItem(autosaveName: "MacStatsTemp", label: "Temp") { [unowned self] in tempPanel.toggle(under: $0) }
        disk = MenuBarItem(autosaveName: "MacStatsDisk", label: "Disk") { [unowned self] in diskPanel.toggle(under: $0) }
        refresh()
        // Every second, like Stats' CPU and GPU.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
        if let which = argument(after: "--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [unowned self] in
                if which == "temp", let button = temp.button { tempPanel.toggle(under: button) }
                if which == "disk", let button = disk.button { diskPanel.toggle(under: button) }
            }
        }
    }

    private func refresh() {
        let readings = reader.read()
        let tempText = tempItemText(readings)
        temp.show(tempText.value, tooltip: tempText.tooltip)
        if tempPanel.isVisible { tempPanel.update(readings) }
        if let diskText = diskItemText(diskSampler) { disk.show(diskText.value, tooltip: diskText.tooltip) }
    }
}

// MARK: - Command line

let arguments = CommandLine.arguments
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--") else { return nil }
    return arguments[index + 1]
}
func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(2)
}

if arguments.contains("--render") {
    guard let index = arguments.firstIndex(of: "--render"), index + 2 < arguments.count else {
        fail("usage: MacStats --render temp|disk <out.png>")
    }
    let path = arguments[index + 2]
    switch arguments[index + 1] {
    case "temp": exit(renderMiniView(label: "Temp", value: tempItemText(SensorReader().read()).value, to: path))
    case "disk":
        guard let text = diskItemText(DiskSampler()) else { fail("Could not read the startup disk's capacity.") }
        exit(renderMiniView(label: "Disk", value: text.value, to: path))
    default: fail("usage: MacStats --render temp|disk <out.png>")
    }
}
if arguments.contains("--sensors") {
    exit(sensorsReport())
}
if let index = arguments.firstIndex(of: "--weigh") {
    let values = arguments[(index + 1)...].compactMap(Double.init)
    guard !values.isEmpty else { fail("usage: MacStats --weigh <°C> <°C> …") }
    print(String(format: "%.2f", hotWeighted(values)))
    exit(0)
}
if arguments.contains("--legend") {
    guard let now = spaceRowsNow() else { exit(1) }
    for row in now.rows { print([row.title, row.colorName, String(row.bytes)].joined(separator: "\t")) }
    exit(0)
}
if arguments.contains("--spaces") {
    let spaces = volumeSpaces()
    for space in spaces { print(space.title + "\t" + formatSize(space.bytes)) }
    exit(spaces.isEmpty ? 1 : 0)
}
if arguments.contains("--report") {
    let minimumBytes = argument(after: "--min-mb").flatMap(Int64.init).map { $0 * 1_000_000 } ?? defaultMinimumBytes
    exit(diskReport(folder: argument(after: "--report"), minimumBytes: minimumBytes))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
