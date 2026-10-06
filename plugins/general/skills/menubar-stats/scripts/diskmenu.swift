// DiskMenu: a menu bar item showing the startup disk's used and total space as
// "Disk" in small text over "215.9/245.1 GB", drawn like the "mini" widget of the
// Stats app (a 7pt label over a 12pt value) so it sits beside Stats' CPU, GPU and
// RAM items. Stats' own Disk widgets cannot put a label over custom text.
//
// Clicking it opens a window listing where the space goes: macOS system,
// update/boot, recovery, swap, and my apps / files, the last broken down into
// folders three levels deep. Right-clicking it shows Quit.
//
//   swiftc -O diskmenu.swift -o DiskMenu   # setup.sh builds it into DiskMenu.app
//   DiskMenu                               # runs as a menu bar item
//   DiskMenu --render out.png              # draws the item to a PNG and exits
//   DiskMenu --report [folder] [--min-mb N]
//                                          # prints the window's list and exits; with a
//                                          # folder, only that folder's tree
//   DiskMenu --spaces                      # prints only the five spaces and exits

import Cocoa

// MARK: - The menu bar item

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

    // Clicks go to the status item's button underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

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

// MARK: - Where the space goes

/// A row in the Disk window: one of the five spaces, or a folder inside the last.
final class Entry {
    let title: String
    let path: String?
    var bytes: Int64?
    var children: [Entry] = []

    init(title: String, path: String? = nil, bytes: Int64? = nil) {
        self.title = title
        self.path = path
        self.bytes = bytes
    }
}

/// The startup disk's APFS volumes, by role, in the order the window lists them.
let spaceRoles: [(title: String, roles: [String])] = [
    ("macOS system", ["System"]),
    ("update/boot", ["Preboot", "Update"]),
    ("recovery", ["Recovery"]),
    ("swap", ["VM"]),
    ("my apps / files", ["Data"]),
]

/// The Data volume's root: everything installed or saved since macOS shipped.
let dataVolume = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
let folderDepth = 3
let defaultMinimumBytes: Int64 = 100_000_000

func runTool(_ path: String, _ arguments: [String]) -> Data? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return data
}

func plist(_ data: Data?) -> [String: Any]? {
    guard let data else { return nil }
    return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}

/// The space each role uses on the startup disk's APFS container, as diskutil
/// reports it. Needs no administrator rights.
func volumeSpaces() -> [(title: String, bytes: Int64)] {
    guard let info = plist(runTool("/usr/sbin/diskutil", ["info", "-plist", "/"])),
          let container = info["APFSContainerReference"] as? String,
          let list = plist(runTool("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])),
          let volumes = (list["Containers"] as? [[String: Any]])?.first?["Volumes"] as? [[String: Any]]
    else { return [] }
    return spaceRoles.map { space in
        let bytes = volumes
            .filter { ($0["Roles"] as? [String] ?? []).contains(where: space.roles.contains) }
            .reduce(Int64(0)) { $0 + (($1["CapacityInUse"] as? NSNumber)?.int64Value ?? 0) }
        return (space.title, bytes)
    }
}

/// Folders under `root`, down to `depth` levels, each at least `minimumBytes`,
/// biggest first. Sizes come from du, which counts a cloned file in full and
/// skips what macOS does not let this app read.
func scanFolders(_ root: String, depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes) -> [Entry] {
    guard let data = runTool("/usr/bin/du", ["-k", "-x", "-d", String(depth), root]) else { return [] }
    let rootPath = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    var entries: [String: Entry] = [:]
    for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
        guard let tab = line.firstIndex(of: "\t"), let kilobytes = Int64(line[..<tab]) else { continue }
        let path = String(line[line.index(after: tab)...]).replacingOccurrences(of: "//", with: "/")
        entries[path] = Entry(title: (path as NSString).lastPathComponent, path: path, bytes: kilobytes * 1024)
    }
    var top: [Entry] = []
    // A folder is never bigger than its parent, so a parent under the minimum
    // has no children over it. An app is one row: its insides are just Contents.
    for (path, entry) in entries where path != rootPath && (entry.bytes ?? 0) >= minimumBytes {
        let parent = (path as NSString).deletingLastPathComponent
        if parent == rootPath {
            top.append(entry)
        } else if !parent.contains(".app/") && !parent.hasSuffix(".app") {
            entries[parent]?.children.append(entry)
        }
    }
    func sort(_ list: inout [Entry]) {
        list.sort { ($0.bytes ?? 0, $1.title) > ($1.bytes ?? 0, $0.title) }
        for entry in list { sort(&entry.children) }
    }
    sort(&top)
    return top
}

func formatSize(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000
        ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        : String(format: "%.0f MB", Double(bytes) / 1_000_000)
}

// MARK: - The Disk window

final class DiskWindow: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    private var window: NSWindow?
    private let outline = NSOutlineView()
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let spaces: [Entry] = spaceRoles.map { Entry(title: $0.title) }
    private var files: Entry { spaces[spaces.count - 1] }
    private var scannedAt: Date?
    private var scanning = false

    func show() {
        if window == nil { build() }
        refreshVolumes()
        // A full scan takes a minute or two, so reuse one from the last 10 minutes.
        if scannedAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { measureFolders() }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        window?.makeKeyAndOrderFront(nil)
    }

    private func build() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 640),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Disk"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 300)

        let name = NSTableColumn(identifier: .init("name"))
        name.title = "Space"
        name.width = 460
        let size = NSTableColumn(identifier: .init("size"))
        size.title = "Size"
        size.width = 90
        size.headerCell.alignment = .right
        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.usesAlternatingRowBackgroundColors = true
        // A custom row size, so the table keeps the fonts set below.
        outline.rowSizeStyle = .custom
        outline.rowHeight = 22
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(revealInFinder)

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.lineBreakMode = .byTruncatingTail
        status.toolTip = "Folder sizes count a cloned file in full, so they can add up to more than the volume. "
            + "Folders macOS protects (Mail, Messages, other apps' data) count only when DiskMenu has Full Disk Access."
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        let refresh = NSButton(title: "Refresh", target: self, action: #selector(refreshAll))
        refresh.bezelStyle = .rounded

        let bar = NSStackView(views: [spinner, status, refresh])
        bar.orientation = .horizontal
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stack = NSStackView(views: [scroll, bar])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor),
            stack.bottomAnchor.constraint(equalTo: window.contentView!.bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        window.center()
        self.window = window
    }

    private func refreshVolumes() {
        DispatchQueue.global(qos: .userInitiated).async {
            let measured = volumeSpaces()
            DispatchQueue.main.async {
                for (entry, space) in zip(self.spaces, measured) { entry.bytes = space.bytes }
                self.outline.reloadData()
            }
        }
    }

    private func measureFolders() {
        guard !scanning else { return }
        scanning = true
        spinner.startAnimation(nil)
        updateStatus()
        DispatchQueue.global(qos: .utility).async {
            let folders = scanFolders(dataVolume)
            DispatchQueue.main.async {
                self.files.children = folders
                self.scanning = false
                self.scannedAt = Date()
                self.spinner.stopAnimation(nil)
                self.outline.reloadData()
                self.outline.expandItem(self.files)
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        if scanning {
            status.stringValue = "Measuring folders; this takes a minute or two…"
        } else if let scannedAt {
            let time = DateFormatter.localizedString(from: scannedAt, dateStyle: .none, timeStyle: .short)
            status.stringValue = "Folders 3 deep, 100 MB and over, measured \(time). Double-click to show in Finder."
        }
    }

    @objc private func refreshAll() {
        refreshVolumes()
        measureFolders()
    }

    @objc private func revealInFinder() {
        guard let entry = outline.item(atRow: outline.clickedRow) as? Entry, let path = entry.path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Entry)?.children.count ?? spaces.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Entry)?.children[index] ?? spaces[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        !((item as? Entry)?.children.isEmpty ?? true)
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let entry = item as? Entry, let id = tableColumn?.identifier else { return nil }
        let cell = outlineView.makeView(withIdentifier: id, owner: self) as? NSTableCellView ?? {
            let cell = NSTableCellView()
            cell.identifier = id
            let text = NSTextField(labelWithString: "")
            text.translatesAutoresizingMaskIntoConstraints = false
            text.lineBreakMode = .byTruncatingMiddle
            cell.addSubview(text)
            cell.textField = text
            NSLayoutConstraint.activate([
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        let isSpace = entry.path == nil
        if id.rawValue == "size" {
            cell.textField?.stringValue = entry.bytes.map(formatSize) ?? "…"
            cell.textField?.alignment = .right
            cell.textField?.font = .monospacedDigitSystemFont(ofSize: 13, weight: isSpace ? .semibold : .regular)
        } else {
            cell.textField?.stringValue = entry.title
            cell.textField?.font = .systemFont(ofSize: 13, weight: isSpace ? .semibold : .regular)
            cell.toolTip = entry.path
        }
        return cell
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let view = DiskView()
    private let diskWindow = DiskWindow()
    private let menu = NSMenu()
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
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        menu.addItem(NSMenuItem(title: "Show Disk Usage", action: #selector(showWindow), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit DiskMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for entry in menu.items where entry.action == #selector(showWindow) { entry.target = self }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            showWindow()
        }
    }

    @objc private func showWindow() {
        diskWindow.show()
    }

    private func refresh() {
        guard let figures = diskFigures() else { return }
        view.value = figures.value
        item.button?.toolTip = "Free: \(figures.free). Click for where the space goes."
        let width = view.valueWidth()
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        item.length = width
        view.needsDisplay = true
    }
}

// MARK: - Command line

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

// Prints what the window lists, as an indented tree. With a folder, prints only
// that folder's tree, which keeps tests fast.
func report(folder: String?, minimumBytes: Int64) -> Int32 {
    func printTree(_ entries: [Entry], indent: Int) {
        for entry in entries {
            print(String(repeating: "  ", count: indent) + entry.title + "\t" + formatSize(entry.bytes ?? 0))
            printTree(entry.children, indent: indent + 1)
        }
    }
    if let folder {
        printTree(scanFolders(folder, minimumBytes: minimumBytes), indent: 0)
        return 0
    }
    let spaces = volumeSpaces()
    guard !spaces.isEmpty else {
        FileHandle.standardError.write("Could not read the startup disk's volumes from diskutil.\n".data(using: .utf8)!)
        return 1
    }
    for space in spaces {
        print(space.title + "\t" + formatSize(space.bytes))
    }
    printTree(scanFolders(dataVolume, minimumBytes: minimumBytes), indent: 1)
    return 0
}

let arguments = CommandLine.arguments
func argument(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count,
          !arguments[index + 1].hasPrefix("--") else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--render") {
    guard let path = argument(after: "--render") else {
        FileHandle.standardError.write("usage: DiskMenu --render <out.png>\n".data(using: .utf8)!)
        exit(2)
    }
    exit(render(to: path))
}
if arguments.contains("--spaces") {
    let spaces = volumeSpaces()
    for space in spaces { print(space.title + "\t" + formatSize(space.bytes)) }
    exit(spaces.isEmpty ? 1 : 0)
}
if arguments.contains("--report") {
    let minimumBytes = argument(after: "--min-mb").flatMap(Int64.init).map { $0 * 1_000_000 } ?? defaultMinimumBytes
    exit(report(folder: argument(after: "--report"), minimumBytes: minimumBytes))
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
