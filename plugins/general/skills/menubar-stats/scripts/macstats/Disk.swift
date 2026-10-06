// The Disk menu bar item: the startup disk's used and total space as "Disk" over
// "215.9/245.1 GB", and a panel listing where the space goes: the APFS volumes as
// coloured rows and a line bar like Stats' RAM panel, then my apps / files broken
// down into folders three levels deep. Private folders (Desktop, Documents,
// Downloads, Music, Movies, other apps' data, Mail, Photos and the like) are never
// opened, so macOS never asks for access to them.

import Cocoa

/// The figures Stats uses: free is the space available for important usage (it
/// counts purgeable space as free), used is total minus free. Decimal gigabytes.
///
/// Read every second, like Stats' CPU and GPU. The plain free space costs next to
/// nothing; the important-usage figure costs about 10 ms of CPU, so it is read
/// every 30 seconds and the purgeable space it adds is carried between reads.
final class DiskSampler {
    private var purgeable: Int64 = 0
    private var lastFullRead = Date.distantPast

    func sample() -> (total: Int64, free: Int64)? {
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
        return (total, min(total, plain + purgeable))
    }
}

/// What the Disk item shows: used/total, and the free space for its tooltip.
func diskItemText(_ sampler: DiskSampler) -> (value: String, tooltip: String)? {
    guard let figures = sampler.sample() else { return nil }
    let gb = { (bytes: Int64) in String(format: "%.1f", Double(bytes) / 1_000_000_000) }
    return ("\(gb(figures.total - figures.free))/\(gb(figures.total)) GB",
            "Free: \(gb(figures.free)) GB. Click for where the space goes.")
}

// MARK: - The five spaces

/// A row in the panel: one of the five spaces, or a folder inside the last.
final class Entry {
    let title: String
    let path: String?
    var bytes: Int64
    /// "private" for a folder MacStats does not open, "no access" for one macOS
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
/// One row of the Spaces section under Used, as it stands now.
struct SpaceRow {
    let title: String
    let color: NSColor
    let colorName: String
    let bytes: Int64
    /// What the row's piece of the bar shows: my apps / files less its purgeable
    /// part, which has a piece of its own.
    let barBytes: Int64
}

/// The Spaces rows under Used, measured now: biggest first, Free always last. The
/// panel and `--legend` both use this, so they cannot disagree.
func spaceRowsNow() -> (used: Int64, total: Int64, rows: [SpaceRow])? {
    guard let disk = containerSpaces(), disk.total > 0 else { return nil }
    let purgeable = purgeableBytes()
    let used = disk.total - disk.free
    let volumes = disk.spaces.map(\.bytes)
    let other = max(0, used - volumes.reduce(0, +))
    let sizes = volumes + [other, purgeable, disk.free]  // one per spaceLegend entry
    let data = spaceRoles.firstIndex { $0.roles.contains("Data") }
    let rows = zip(spaceLegend, sizes).enumerated().map { index, entry in
        SpaceRow(title: entry.0.title, color: entry.0.color, colorName: entry.0.colorName, bytes: entry.1,
                 barBytes: index == data ? max(0, entry.1 - purgeable) : entry.1)
    }
    // Free is the legend's last entry; the rest go biggest first, ties in legend order.
    let order = rows.indices.dropLast().sorted { (rows[$0].bytes, $1) > (rows[$1].bytes, $0) }
    return (used, disk.total, order.map { rows[$0] } + [rows[rows.count - 1]])
}

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
/// person's private data. MacStats never opens them: it lists them by name, and
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

// MARK: - The panel

let foldersHeight: CGFloat = 22 * 15

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

final class DiskPanel: StatsPanel, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    /// Shown at the top of the empty folder list while measuring.
    private let measuring = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let measuringNote = NSStackView()
    /// Shown under the folder list once it is measured.
    private let status = NSTextField(wrappingLabelWithString: "")
    private let usedRow = PanelRow("Used:")
    private let bar = SpaceBar()
    private let spaceRows: [String: PanelRow] = Dictionary(uniqueKeysWithValues: spaceLegend.map {
        ($0.title, PanelRow($0.title + ":", color: $0.color))
    })
    private let spaceList = NSStackView()
    private var folders: [Entry] = []
    private(set) var scanning = false
    private var measuredAt: Date?

    init() {
        super.init(title: "Disk")
        setHeaderButtons(leading: headerButton("arrow.clockwise", "Measure again", #selector(refreshAll)),
                         trailing: headerButton("internaldrive", "Open Storage settings", #selector(openStorageSettings)))
        build()
    }

    var isMeasured: Bool { measuredAt != nil && !scanning }

    private func build() {
        // Laid out like Stats' RAM details: Used, the bar, then a coloured row per
        // part of the bar, in the bar's order.
        body.addArrangedSubview(separatorView("Spaces"))
        body.addArrangedSubview(usedRow)
        body.addArrangedSubview(bar)
        spaceList.orientation = .vertical
        spaceList.alignment = .leading
        spaceList.spacing = 0
        spaceList.setViews(spaceLegend.compactMap { spaceRows[$0.title] }, in: .top)
        body.addArrangedSubview(spaceList)
        let tips = [
            "other": "Space APFS keeps for its own bookkeeping, and any volume not listed above.",
            "Purgeable": "Part of my apps / files that macOS frees on its own when it needs room: caches, "
                + "iCloud copies, snapshots. Counted as used here and as free in the menu bar, as Finder does.",
        ]
        for (title, row) in spaceRows { row.toolTip = tips[title] }
        for row in Array(spaceRows.values) + [usedRow] { row.value.stringValue = "…" }
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

        // While measuring, the list is empty and the measuring note sits at its top,
        // a little below the caption; once measured, the time shows under the list.
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

        NSLayoutConstraint.activate([
            folderArea.widthAnchor.constraint(equalToConstant: Panel.width),
            folderArea.heightAnchor.constraint(equalToConstant: foldersHeight),
            scroll.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: folderArea.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: folderArea.bottomAnchor),
            measuringNote.leadingAnchor.constraint(equalTo: folderArea.leadingAnchor),
            measuringNote.trailingAnchor.constraint(equalTo: folderArea.trailingAnchor),
            measuringNote.topAnchor.constraint(equalTo: folderArea.topAnchor, constant: 12),
            // Room for its line, kept while measuring, so the panel does not jump.
            status.widthAnchor.constraint(equalToConstant: Panel.width),
            status.heightAnchor.constraint(equalToConstant: 14),
        ])
        updateStatus()
    }

    override func willOpen() {
        refreshSpaces()
        if measuredAt.map({ Date().timeIntervalSince($0) > 600 }) ?? true { measureFolders() }
    }

    func refreshSpaces() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let now = spaceRowsNow() else { return }
            DispatchQueue.main.async {
                self.usedRow.value.stringValue = formatSize(now.used)
                for row in now.rows { self.spaceRows[row.title]?.value.stringValue = formatSize(row.bytes) }
                self.spaceList.setViews(now.rows.compactMap { self.spaceRows[$0.title] }, in: .top)
                // The bar follows the rows' order; Free is the rest of the line.
                self.bar.parts = now.rows.dropLast().map { (Double($0.barBytes) / Double(now.total), $0.color) }
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
        if !scanning, let measuredAt {
            let time = DateFormatter.localizedString(from: measuredAt, dateStyle: .none, timeStyle: .short)
            status.stringValue = "Last measured at \(time)."
        } else {
            status.stringValue = ""
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

// MARK: - Command line

// Prints what the panel lists, as an indented tree. With a folder, prints only
// that folder's tree, which keeps tests fast.
func diskReport(folder: String?, minimumBytes: Int64) -> Int32 {
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

