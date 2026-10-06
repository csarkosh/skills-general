// DiskMenu: a menu bar item showing the startup disk's used and total space as
// "Disk" in small text over "215.9/245.1 GB", drawn like the "mini" widget of the
// Stats app (a 7pt label over a 12pt value) so it sits beside Stats' CPU, GPU and
// RAM items. Stats' own Disk widgets cannot put a label over custom text.
//
//   swiftc -O diskmenu.swift -o DiskMenu   # setup.sh builds it into DiskMenu.app
//   DiskMenu                               # runs as a menu bar item
//   DiskMenu --render out.png              # draws the item to a PNG and exits

import Cocoa

final class DiskView: NSView {
    var label = "Disk"
    var value = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let left = NSMutableParagraphStyle()
        left.alignment = .left

        // Positions copied from Stats' Mini widget: label at y 12, value at y 1.
        NSAttributedString(string: label, attributes: [
            .font: NSFont.systemFont(ofSize: 7, weight: .light),
            .foregroundColor: isDarkMode ? NSColor.white : NSColor.textColor,
            .paragraphStyle: left,
        ]).draw(with: CGRect(x: 0, y: 12, width: bounds.width, height: 7))

        NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: isDarkMode ? NSColor.white : NSColor.black,
            .paragraphStyle: left,
        ]).draw(with: CGRect(x: 0, y: 1, width: bounds.width, height: 13))
    }

    var isDarkMode: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    func valueWidth() -> CGFloat {
        ceil(NSAttributedString(string: value, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
        ]).size().width)
    }
}

// The figures Stats uses: free is the space available for important usage (it
// counts purgeable space as free), used is total minus free. Decimal gigabytes.
func diskFigures() -> (value: String, free: String)? {
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]), let total = values.volumeTotalCapacity.map(Int64.init),
          let free = values.volumeAvailableCapacityForImportantUsage else { return nil }
    let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
    return ("\(gb(total - free))/\(gb(total)) GB", "\(gb(free)) GB")
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let view = DiskView()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: 40)
        // The name macOS stores this item's place under, as
        // "NSStatusItem Preferred Position DiskMenu" in this app's defaults.
        item.autosaveName = "DiskMenu"
        let menuBarHeight = NSApplication.shared.mainMenu?.menuBarHeight ?? 0
        let height = (menuBarHeight == 0 ? 22 : menuBarHeight) - 4
        view.frame = CGRect(x: 0, y: 2, width: 40, height: height)
        item.button?.addSubview(view)
        item.button?.image = NSImage()

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Quit DiskMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        item.menu = menu

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    private func refresh() {
        guard let figures = diskFigures() else { return }
        view.value = figures.value
        item.button?.toolTip = "Free: \(figures.free)"
        let width = view.valueWidth()
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        item.length = width
        view.needsDisplay = true
    }
}

// Draws the item, at 4x, on a dark menu bar, so its look can be checked without
// Screen Recording permission.
func render(to path: String) -> Int32 {
    guard let figures = diskFigures() else {
        FileHandle.standardError.write("Could not read the startup disk's capacity.\n".data(using: .utf8)!)
        return 1
    }
    let view = DiskView()
    view.value = figures.value
    view.appearance = NSAppearance(named: .darkAqua)
    let width = view.valueWidth()
    let size = NSSize(width: width + 20, height: 22)
    let scale: CGFloat = 4
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0.12, alpha: 1).setFill()
    NSRect(origin: .zero, size: size).fill()
    view.frame = CGRect(x: 10, y: 2, width: width, height: 18)
    NSGraphicsContext.current!.cgContext.translateBy(x: 10, y: 2)
    view.appearance!.performAsCurrentDrawingAppearance { view.draw(view.bounds) }
    NSGraphicsContext.restoreGraphicsState()
    do {
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    } catch {
        FileHandle.standardError.write("Could not write \(path): \(error.localizedDescription)\n".data(using: .utf8)!)
        return 1
    }
    print(figures.value)
    return 0
}

let arguments = CommandLine.arguments
if let index = arguments.firstIndex(of: "--render") {
    guard index + 1 < arguments.count else {
        FileHandle.standardError.write("usage: DiskMenu --render <out.png>\n".data(using: .utf8)!)
        exit(2)
    }
    exit(render(to: arguments[index + 1]))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
