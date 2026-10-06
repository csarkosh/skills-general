// DiskMenu: a menu bar item showing the startup disk's used and total space as
// "Disk" in small text over "215.9/245.1 GB", drawn like the "mini" widget of the
// Stats app (a 7pt label over a 12pt value) so it sits beside Stats' CPU, GPU and
// RAM items. Stats' own Disk widgets cannot put a label over custom text.
//
// Clicking it drops down a panel, styled like Stats' panels, listing where the
// space goes: macOS system, update/boot, recovery, swap, and my apps / files, the
// last broken down into folders three levels deep. Private folders (Desktop,
// Documents, Downloads, other apps' data, Mail, Photos and the like) are never
// opened, so macOS never asks for access to them. Right-clicking it shows Quit.
//
//   swiftc -O diskmenu.swift -o DiskMenu   # setup.sh builds it into DiskMenu.app
//   DiskMenu                               # runs as a menu bar item
//   DiskMenu --show-panel                  # runs, with the panel open
//   DiskMenu --render out.png              # draws the item to a PNG and exits
//   DiskMenu --spaces                      # prints the five spaces and exits
//   DiskMenu --legend                      # prints the Spaces rows with their colours
//   DiskMenu --report [folder] [--min-mb N]
//                                          # prints the panel's list and exits; with a
//                                          # folder, only that folder's tree

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

/// The figures Stats uses: free is the space available for important usage (it
/// counts purgeable space as free), used is total minus free. Decimal gigabytes.
///
/// Read every second, like Stats' CPU and GPU. The plain free space costs next to
/// nothing; the important-usage figure costs about 10 ms of CPU, so it is read
/// every 30 seconds and the purgeable space it adds is carried between reads.
final class DiskSampler {
    private var purgeable: Int64 = 0
    private var lastFullRead = Date.distantPast

    func sample() -> (value: String, free: String)? {
        let full = Date().timeIntervalSince(lastFullRead) >= 30
        var keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]
        if full { keys.insert(.volumeAvailableCapacityForImportantUsageKey) }
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let total = values.volumeTotalCapacity.map(Int64.init),
              let plain = values.volumeAvailableCapacity.map(Int64.init) else { return nil }
        if full, let important = values.volumeAvailableCapacityForImportantUsage {
            purgeable = max(0, important - plain)
            lastFullRead = Date()
        }
        let free = min(total, plain + purgeable)
        let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
        return ("\(gb(total - free))/\(gb(total)) GB", "\(gb(free)) GB")
    }
}

// MARK: - The five spaces

/// A row in the panel: one of the five spaces, or a folder inside the last.
final class Entry {
    let title: String
    let path: String?
    var bytes: Int64
    /// "private" for a folder DiskMenu does not open, "no access" for one macOS
    /// would not let it read. Either way its size is unknown.
    var note: String?
    /// True when a folder inside this one was not counted, so the size is a minimum.
    var partial = false
    var children: [Entry] = []

    init(title: String, path: String? = nil, bytes: Int64 = 0) {
        self.title = title
        self.path = path
        self.bytes = bytes
    }

    var sizeText: String {
        if let note { return note }
        return (partial ? "≥ " : "") + formatSize(bytes)
    }
}

/// The startup disk's APFS volumes, by role, in the order the panel lists them.
/// Colours follow Stats' RAM panel: blue for what you put there (as its App),
/// orange for macOS (as Wired), pink for swap (as Compressed), grey for free.
let spaceRoles: [(title: String, roles: [String], color: NSColor, colorName: String)] = [
    ("macOS system", ["System"], .systemOrange, "orange"),
    ("update/boot", ["Preboot", "Update"], .systemYellow, "yellow"),
    ("recovery", ["Recovery"], .systemPurple, "purple"),
    ("swap", ["VM"], .systemPink, "pink"),
    ("my apps / files", ["Data"], .systemBlue, "blue"),
]

/// Every row of the panel's Spaces section under Used, in order, with its colour.
/// The rows and the bar are both built from this one list, so no row can appear
/// without a colour, and the rows add up to Used. After the volumes: other (APFS's
/// own bookkeeping and any volume not listed), Purgeable (the part of my apps /
/// files macOS frees on its own, shown next to free space) and Free.
let spaceLegend: [(title: String, color: NSColor, colorName: String)] =
    spaceRoles.map { ($0.title, $0.color, $0.colorName) } + [
        ("other", .systemBrown, "brown"),
        ("Purgeable", .systemTeal, "teal"),
        ("Free", NSColor.lightGray.withAlphaComponent(0.5), "light grey"),
    ]

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

/// The space each role uses on the startup disk's APFS container, and the
/// container's size and free space, as diskutil reports them. Reads no folders
/// and needs no administrator rights.
func containerSpaces() -> (spaces: [(title: String, bytes: Int64)], total: Int64, free: Int64)? {
    guard let info = plist(runTool("/usr/sbin/diskutil", ["info", "-plist", "/"])),
          let reference = info["APFSContainerReference"] as? String,
          let list = plist(runTool("/usr/sbin/diskutil", ["apfs", "list", "-plist", reference])),
          let container = (list["Containers"] as? [[String: Any]])?.first,
          let volumes = container["Volumes"] as? [[String: Any]]
    else { return nil }
    let spaces = spaceRoles.map { space in
        let bytes = volumes
            .filter { ($0["Roles"] as? [String] ?? []).contains(where: space.roles.contains) }
            .reduce(Int64(0)) { $0 + (($1["CapacityInUse"] as? NSNumber)?.int64Value ?? 0) }
        return (space.title, bytes)
    }
    let number = { (key: String) in (container[key] as? NSNumber)?.int64Value ?? 0 }
    return (spaces, number("CapacityCeiling"), number("CapacityFree"))
}

func volumeSpaces() -> [(title: String, bytes: Int64)] {
    containerSpaces()?.spaces ?? []
}

/// Space macOS can free on its own (caches, iCloud copies, snapshots). The menu
/// bar, like Finder, counts it as free; the panel's volumes count it as used.
func purgeableBytes() -> Int64 {
    guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [
        .volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
    ]), let plain = values.volumeAvailableCapacity, let important = values.volumeAvailableCapacityForImportantUsage
    else { return 0 }
    return max(0, important - Int64(plain))
}

// MARK: - Folders, without opening private ones

/// The Data volume's root: everything installed or saved since macOS shipped.
let dataVolume = FileManager.default.fileExists(atPath: "/System/Volumes/Data") ? "/System/Volumes/Data" : "/"
let folderDepth = 3
let defaultMinimumBytes: Int64 = 100_000_000

/// Folders in each home that macOS guards with a privacy prompt, or that hold a
/// person's private data. DiskMenu never opens them: it lists them by name, and
/// a folder holding one shows its size as a minimum (≥).
let privateHomeFolders = [
    "Desktop", "Documents", "Downloads",
    "Library/Mobile Documents", "Library/CloudStorage", "Library/Application Support/FileProvider",
    "Library/Containers", "Library/Group Containers", "Library/Daemon Containers",
    "Library/Mail", "Library/Messages", "Library/Safari", "Library/Calendars", "Library/Reminders",
    "Library/HomeKit", "Library/Cookies", "Library/Suggestions", "Library/IdentityServices",
    "Library/Accounts", "Library/Sharing", "Library/Biome", "Library/Metadata/CoreSpotlight",
    "Library/Application Support/AddressBook", "Library/Application Support/CallHistoryDB",
    "Library/Application Support/CallHistoryTransactions", "Library/Application Support/Knowledge",
    "Library/Application Support/com.apple.TCC", "Library/Application Support/com.apple.sharedfilelist",
    // Listing anything inside Music or Movies makes macOS ask for the media library.
    "Library/Photos", "Library/Caches/com.apple.Music", "Music", "Movies",
]
/// Library packages of the Photos, Music and TV apps, wherever they are kept.
let privatePackageExtensions: Set<String> = [
    "photoslibrary", "photolibrary", "migratedphotolibrary", "aplibrary", "musiclibrary", "tvlibrary",
]

/// Folders under `root`, down to `depth` levels, each at least `minimumBytes`,
/// biggest first. Counts allocated blocks like du (a cloned file counts in full,
/// a hard-linked one once) and stays on root's volume. Private folders are listed
/// but never opened, so measuring causes no privacy prompt.
func scanFolders(_ root: String, depth: Int = folderDepth, minimumBytes: Int64 = defaultMinimumBytes) -> [Entry] {
    let rootPath = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    let base = rootPath == "/" ? "" : rootPath
    var privatePaths: Set<String> = [base + "/Volumes"]  // removable and network volumes
    let users = base + "/Users"
    // Listing the folder of homes names them without opening any.
    for name in (try? FileManager.default.contentsOfDirectory(atPath: users)) ?? [] {
        for folder in privateHomeFolders { privatePaths.insert("\(users)/\(name)/\(folder)") }
    }

    var top: [Entry] = []
    var ancestors = [Entry?](repeating: nil, count: depth + 1)
    var counted = Set<UInt64>()  // hard-linked files already counted, by inode

    var argv: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
    defer { free(argv[0]) }
    guard let fts = fts_open(&argv, FTS_PHYSICAL | FTS_XDEV | FTS_NOCHDIR, nil) else { return [] }
    defer { fts_close(fts) }

    func add(_ bytes: Int64, through level: Int) {
        for k in stride(from: 1, through: min(level, depth), by: 1) { ancestors[k]?.bytes += bytes }
    }
    func markAncestorsPartial(below level: Int) {
        for k in stride(from: 1, to: min(level, depth + 1), by: 1) { ancestors[k]?.partial = true }
    }

    while let entry = fts_read(fts) {
        let level = Int(entry.pointee.fts_level)
        switch Int32(entry.pointee.fts_info) {
        case FTS_D:
            let path = String(cString: entry.pointee.fts_path)
            if level >= 1 && level <= depth {
                let folder = Entry(title: (path as NSString).lastPathComponent, path: path)
                ancestors[level] = folder
                if level == 1 {
                    top.append(folder)
                } else if let parent = ancestors[level - 1], !(parent.path ?? "").hasSuffix(".app") {
                    parent.children.append(folder)  // an app is one row
                }
            }
            if privatePaths.contains(path)
                || privatePackageExtensions.contains((path as NSString).pathExtension.lowercased()) {
                fts_set(fts, entry, FTS_SKIP)
                if level >= 1 && level <= depth { ancestors[level]?.note = "private" }
                markAncestorsPartial(below: level)
                continue
            }
            add(Int64(entry.pointee.fts_statp.pointee.st_blocks) * 512, through: level)
        case FTS_DNR:
            if level >= 1 && level <= depth { ancestors[level]?.note = "no access" }
            markAncestorsPartial(below: level)
        case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
            let stat = entry.pointee.fts_statp.pointee
            if stat.st_nlink > 1 && !counted.insert(UInt64(stat.st_ino)).inserted { continue }
            add(Int64(stat.st_blocks) * 512, through: level - 1)
        default:
            break
        }
    }

    // Keep what is big enough, every private folder, and unreadable folders in a
    // home (the Trash, say); a folder unreadable elsewhere belongs to the system.
    func keep(_ list: [Entry]) -> [Entry] {
        list.filter { entry in
            entry.bytes >= minimumBytes || entry.note == "private"
                || (entry.note != nil && (entry.path ?? "").hasPrefix(users + "/"))
        }
        .sorted { ($0.bytes, $1.title) > ($1.bytes, $0.title) }
        .map { entry in entry.children = keep(entry.children); return entry }
    }
    return keep(top)
}

func formatSize(_ bytes: Int64) -> String {
    bytes >= 1_000_000_000
        ? String(format: "%.1f GB", Double(bytes) / 1_000_000_000)
        : String(format: "%.0f MB", Double(bytes) / 1_000_000)
}

// MARK: - The panel, styled like Stats' popups

/// Stats' popup sizes: 264 wide inside 8 of margin, a 42-high header, 22-high rows.
enum Panel {
    static let width: CGFloat = 264
    static let margin: CGFloat = 8
    static let header: CGFloat = 42
    static let row: CGFloat = 22
    static let foldersHeight: CGFloat = 22 * 15
}

/// A section caption like Stats': small spaced capitals between two lines.
func separatorView(_ title: String) -> NSView {
    let view = NSView()
    view.translatesAutoresizingMaskIntoConstraints = false
    let label = NSTextField(labelWithString: "")
    label.translatesAutoresizingMaskIntoConstraints = false
    label.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.tertiaryLabelColor,
        .kern: 1.0,
    ])
    let left = NSBox(), right = NSBox()
    for line in [left, right] {
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(line)
    }
    view.addSubview(label)
    NSLayoutConstraint.activate([
        view.heightAnchor.constraint(equalToConstant: 30),
        view.widthAnchor.constraint(equalToConstant: Panel.width),
        label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        left.leadingAnchor.constraint(equalTo: view.leadingAnchor),
        left.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
        left.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        right.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
        right.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        right.centerYAnchor.constraint(equalTo: view.centerYAnchor),
    ])
    return view
}

/// A label on the left in secondary text and a value on the right, like Stats' rows;
/// with a colour, a 10-point rounded square before the label, as in its RAM panel.
final class PanelRow: NSView {
    let label = NSTextField(labelWithString: "")
    let value = NSTextField(labelWithString: "")

    init(_ title: String, color: NSColor? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.stringValue = title
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor
        value.font = .systemFont(ofSize: 13)
        value.alignment = .right
        for field in [label, value] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }
        if let color {
            let block = NSView()
            block.wantsLayer = true
            block.layer?.backgroundColor = color.cgColor
            block.layer?.cornerRadius = 3
            block.translatesAutoresizingMaskIntoConstraints = false
            addSubview(block)
            NSLayoutConstraint.activate([
                block.widthAnchor.constraint(equalToConstant: 10),
                block.heightAnchor.constraint(equalToConstant: 10),
                block.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
                block.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Panel.row),
            widthAnchor.constraint(equalToConstant: Panel.width),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: color == nil ? 0 : 18),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// A line bar split into coloured parts, drawn like Stats' horizontal bar chart: 10
/// points high with corners rounded at 3, the rest of the line in faint grey.
final class SpaceBar: NSView {
    var parts: [(fraction: Double, color: NSColor)] = [] { didSet { needsDisplay = true } }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 14),
            widthAnchor.constraint(equalToConstant: Panel.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let bar = NSRect(x: 0, y: (bounds.height - 10) / 2, width: bounds.width, height: 10)
        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: bar, xRadius: 3, yRadius: 3).addClip()
        NSColor.lightGray.withAlphaComponent(0.25).setFill()
        bar.fill()
        var x = bar.minX
        for part in parts {
            let width = bar.width * CGFloat(max(0, part.fraction))
            part.color.setFill()
            NSRect(x: x, y: bar.minY, width: width, height: bar.height).fill()
            x += width
        }
        NSGraphicsContext.restoreGraphicsState()
    }
}

final class DiskPanel: NSWindow, NSWindowDelegate, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    /// Shown over the empty folder list while measuring, a third of the way down.
    private let measuring = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let measuringNote = NSStackView()
    /// Shown under the folder list once it is measured.
    private let status = NSTextField(wrappingLabelWithString: "")
    private let usedRow = PanelRow("Used:")
    private let bar = SpaceBar()
    private let spaceRows: [PanelRow] = spaceLegend.map { PanelRow($0.title + ":", color: $0.color) }
    private var folders: [Entry] = []
    private(set) var scanning = false
    private var measuredAt: Date?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: Panel.width + Panel.margin * 2, height: 400),
                   styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: true)
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        collectionBehavior = .moveToActiveSpace
        isReleasedWhenClosed = false
        hasShadow = true
        delegate = self
        build()
    }

    var isMeasured: Bool { measuredAt != nil && !scanning }

    // Like Stats' popups, the panel closes when it stops being the key window.
    func windowDidResignKey(_ notification: Notification) {
        orderOut(nil)
    }

    private func build() {
        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        contentView = background

        let refresh = headerButton("arrow.clockwise", "Measure again", #selector(refreshAll))
        let storage = headerButton("internaldrive", "Open Storage settings", #selector(openStorageSettings))
        let title = NSTextField(labelWithString: "Disk")
        title.font = .systemFont(ofSize: 16)
        title.alignment = .center
        let header = NSStackView(views: [refresh, title, storage])
        header.distribution = .equalCentering
        header.translatesAutoresizingMaskIntoConstraints = false

        let body = NSStackView()
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
        // Laid out like Stats' RAM details: Used, the bar, then a coloured row per
        // part of the bar, in the bar's order.
        body.addArrangedSubview(separatorView("Spaces"))
        body.addArrangedSubview(usedRow)
        body.addArrangedSubview(bar)
        for row in spaceRows { body.addArrangedSubview(row) }
        let tips = [
            "other": "Space APFS keeps for its own bookkeeping, and any volume not listed above.",
            "Purgeable": "Part of my apps / files that macOS frees on its own when it needs room: caches, "
                + "iCloud copies, snapshots. Counted as used here and as free in the menu bar, as Finder does.",
        ]
        for (row, part) in zip(spaceRows, spaceLegend) { row.toolTip = tips[part.title] }
        for row in spaceRows + [usedRow] { row.value.stringValue = "…" }
        body.addArrangedSubview(separatorView("My apps / files"))

        // The name column takes whatever the fixed size column leaves.
        let name = NSTableColumn(identifier: .init("name"))
        name.width = Panel.width - 90
        name.resizingMask = .autoresizingMask
        let size = NSTableColumn(identifier: .init("size"))
        size.width = 72
        size.resizingMask = []
        outline.addTableColumn(name)
        outline.addTableColumn(size)
        outline.outlineTableColumn = name
        outline.style = .plain
        outline.headerView = nil
        outline.backgroundColor = .clear
        outline.rowSizeStyle = .custom
        outline.rowHeight = Panel.row
        outline.indentationPerLevel = 10
        outline.intercellSpacing = NSSize(width: 4, height: 0)
        outline.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        outline.selectionHighlightStyle = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.doubleAction = #selector(revealInFinder)
        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        // While measuring, the list is empty and the measuring note sits a third
        // of the way down it; once measured, the note under the list takes over.
        spinner.style = .spinning
        spinner.controlSize = .small
        for text in [measuring, status] {
            text.font = .systemFont(ofSize: 10)
            text.textColor = .tertiaryLabelColor
            text.toolTip = "Private folders (Desktop, Documents, Downloads, Music, Movies, other apps' data, Mail, "
                + "Messages, Photos) are never opened, so macOS never asks for access to them. A folder holding one "
                + "shows ≥, at least its size. Folder sizes count a cloned file in full, so they can add up to more "
                + "than the volume. Double-click a folder to show it in Finder, whose Get Info shows a private folder's size."
        }
        measuring.preferredMaxLayoutWidth = Panel.width - 24
        status.preferredMaxLayoutWidth = Panel.width
        measuringNote.setViews([spinner, measuring], in: .leading)
        measuringNote.alignment = .top
        measuringNote.translatesAutoresizingMaskIntoConstraints = false
        let folderArea = NSView()
        folderArea.translatesAutoresizingMaskIntoConstraints = false
        folderArea.addSubview(scroll)
        folderArea.addSubview(measuringNote)
        body.addArrangedSubview(folderArea)
        status.translatesAutoresizingMaskIntoConstraints = false
        body.setCustomSpacing(6, after: folderArea)
        body.addArrangedSubview(status)

        background.addSubview(header)
        background.addSubview(body)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: background.topAnchor),
            header.heightAnchor.constraint(equalToConstant: Panel.header),
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Panel.margin),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Panel.margin),
            body.topAnchor.constraint(equalTo: header.bottomAnchor),
            body.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: Panel.margin),
            body.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -Panel.margin),
            body.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -Panel.margin),
            folderArea.widthAnchor.constraint(equalToConstant: Panel.width),
            folderArea.heightAnchor.constraint(equalToConstant: Panel.foldersHeight),
            scroll.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: folderArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: folderArea.bottomAnchor),
            measuringNote.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            measuringNote.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            measuringNote.topAnchor.constraint(equalTo: folderArea.topAnchor, constant: Panel.foldersHeight / 3),
            // Room for two lines, kept while measuring, so the panel does not jump.
            status.widthAnchor.constraint(equalToConstant: Panel.width),
            status.heightAnchor.constraint(equalToConstant: 28),
        ])
        updateStatus()
    }

    /// Fits the panel to its contents, keeping its top edge where it is.
    private func fitToContents() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }

    private func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    /// Opens under `button`, centred on it, kept on its screen: where Stats opens its panels.
    func toggle(under button: NSStatusBarButton) {
        if isVisible {
            orderOut(nil)
            return
        }
        refreshSpaces()
        if measuredAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { measureFolders() }
        if let anchor = button.window?.frame {
            var x = anchor.midX - frame.width / 2
            if let screen = button.window?.screen ?? NSScreen.main {
                x = min(max(x, screen.frame.minX + 3), screen.frame.maxX - frame.width - 3)
            }
            setFrameOrigin(NSPoint(x: x, y: anchor.minY - frame.height - 3))
        }
        if #available(macOS 14, *) { NSApp.activate() } else { NSApp.activate(ignoringOtherApps: true) }
        makeKeyAndOrderFront(nil)
    }

    func refreshSpaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let disk = containerSpaces(), disk.total > 0 else { return }
            let purgeable = purgeableBytes()
            DispatchQueue.main.async {
                let used = disk.total - disk.free
                let volumes = disk.spaces.map(\.bytes)
                let other = max(0, used - volumes.reduce(0, +))
                // One figure per legend entry, in its order.
                let rows = volumes + [other, purgeable, disk.free]
                for (row, bytes) in zip(self.spaceRows, rows) { row.value.stringValue = formatSize(bytes) }
                self.usedRow.value.stringValue = formatSize(used)
                // The bar shows purgeable space out of my apps / files, next to free;
                // free is the rest of the line.
                var pieces = rows
                if let data = spaceRoles.firstIndex(where: { $0.roles.contains("Data") }) {
                    pieces[data] = max(0, pieces[data] - purgeable)
                }
                self.bar.parts = zip(pieces, spaceLegend).dropLast().map { bytes, part in
                    (Double(bytes) / Double(disk.total), part.color)
                }
            }
        }
    }

    func measureFolders() {
        guard !scanning else { return }
        scanning = true
        folders = []
        outline.reloadData()
        spinner.startAnimation(nil)
        updateStatus()
        DispatchQueue.global(qos: .utility).async {
            let measured = scanFolders(dataVolume)
            DispatchQueue.main.async {
                self.folders = measured
                self.scanning = false
                self.measuredAt = Date()
                self.spinner.stopAnimation(nil)
                self.outline.reloadData()
                // Open the biggest branch, so its third level shows.
                var next = self.folders.first
                while let folder = next, !folder.children.isEmpty {
                    self.outline.expandItem(folder)
                    next = folder.children.first
                }
                self.updateStatus()
            }
        }
    }

    private func updateStatus() {
        let privacy = "Private folders are never opened; ≥\u{00A0}means at least."
        measuringNote.isHidden = !scanning
        measuring.stringValue = "Measuring folders, about a minute… " + privacy
        if scanning {
            status.stringValue = ""
        } else if let measuredAt {
            let time = DateFormatter.localizedString(from: measuredAt, dateStyle: .none, timeStyle: .short)
            status.stringValue = "Measured \(time). " + privacy
        } else {
            status.stringValue = privacy
        }
        fitToContents()
    }

    @objc private func refreshAll() {
        refreshSpaces()
        measureFolders()
    }

    @objc private func openStorageSettings() {
        orderOut(nil)
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.Storage") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func revealInFinder() {
        guard let entry = outline.item(atRow: outline.clickedRow) as? Entry, let path = entry.path else { return }
        orderOut(nil)
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Entry)?.children.count ?? folders.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Entry)?.children[index] ?? folders[index]
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
                text.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
                text.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
                text.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
            return cell
        }()
        if id.rawValue == "size" {
            cell.textField?.stringValue = entry.sizeText
            cell.textField?.alignment = .right
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = entry.note == nil ? .labelColor : .tertiaryLabelColor
        } else {
            cell.textField?.stringValue = entry.title
            cell.textField?.font = .systemFont(ofSize: 12)
            cell.textField?.textColor = .secondaryLabelColor
            cell.toolTip = entry.path
        }
        return cell
    }
}

// MARK: - The app

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var item: NSStatusItem!
    private let view = DiskView()
    private lazy var panel = DiskPanel()
    private let menu = NSMenu()
    private let sampler = DiskSampler()
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

        menu.addItem(NSMenuItem(title: "Quit DiskMenu", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 0.2
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.togglePanel() }
        }
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp, let button = item.button {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            togglePanel()
        }
    }

    private func togglePanel() {
        if let button = item.button { panel.toggle(under: button) }
    }

    private func refresh() {
        guard let figures = sampler.sample(), figures.value != view.value else { return }
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
    guard let figures = DiskSampler().sample() else {
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

// Prints what the panel lists, as an indented tree. With a folder, prints only
// that folder's tree, which keeps tests fast.
func report(folder: String?, minimumBytes: Int64) -> Int32 {
    func printTree(_ entries: [Entry], indent: Int) {
        for entry in entries {
            print(String(repeating: "  ", count: indent) + entry.title + "\t" + entry.sizeText)
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
if arguments.contains("--legend") {
    for part in spaceLegend { print(part.title + "\t" + part.colorName) }
    exit(0)
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
