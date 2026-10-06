// The pieces every MacStats menu bar item shares: the item itself, drawn like the
// Stats app's "mini" widget (a 7pt label over a 12pt value), and a drop-down panel
// styled like Stats' popups (a header, captions between two lines, label and value
// rows). Disk.swift and Temp.swift build their items from these.

import Cocoa

// MARK: - The menu bar item

/// A small label over a value, at the positions of Stats' Mini widget.
final class MiniView: NSView {
    var label = ""
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

    func contentWidth() -> CGFloat {
        let font = { (size: CGFloat, weight: NSFont.Weight) in NSFont.systemFont(ofSize: size, weight: weight) }
        return ceil(max(
            NSAttributedString(string: value, attributes: [.font: font(12, .regular)]).size().width,
            NSAttributedString(string: label, attributes: [.font: font(7, .light)]).size().width))
    }
}

/// One status item: a MiniView in the menu bar, a click that opens its panel, and
/// a right-click menu with Quit.
final class MenuBarItem: NSObject {
    private let item: NSStatusItem
    private let view = MiniView()
    private let menu = NSMenu()
    private let onClick: (NSStatusBarButton) -> Void

    /// `autosaveName` is what macOS stores the item's place under, as
    /// "NSStatusItem Preferred Position <name>" in the app's defaults.
    init(autosaveName: String, label: String, onClick: @escaping (NSStatusBarButton) -> Void) {
        self.onClick = onClick
        item = NSStatusBar.system.statusItem(withLength: 40)
        super.init()
        item.autosaveName = autosaveName
        view.label = label
        let menuBarHeight = NSApplication.shared.mainMenu?.menuBarHeight ?? 0
        let height = (menuBarHeight == 0 ? 22 : menuBarHeight) - 4
        view.frame = CGRect(x: 0, y: 2, width: 40, height: height)
        item.button?.addSubview(view)
        item.button?.image = NSImage()
        item.button?.target = self
        item.button?.action = #selector(clicked)
        item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        menu.addItem(NSMenuItem(title: "Quit MacStats", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
    }

    var button: NSStatusBarButton? { item.button }

    func show(_ value: String, tooltip: String) {
        item.button?.toolTip = tooltip
        guard value != view.value else { return }
        view.value = value
        let width = view.contentWidth()
        view.setFrameSize(NSSize(width: width, height: view.frame.height))
        item.length = width
        view.needsDisplay = true
    }

    @objc private func clicked() {
        guard let button = item.button else { return }
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.height + 4), in: button)
        } else {
            onClick(button)
        }
    }
}

/// Draws a menu bar item, at 4x, on a dark menu bar, so its look can be checked
/// without Screen Recording permission.
func renderMiniView(label: String, value: String, to path: String) -> Int32 {
    let view = MiniView()
    view.label = label
    view.value = value
    view.appearance = NSAppearance(named: .darkAqua)
    let width = view.contentWidth()
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
    print(value)
    return 0
}

// MARK: - The panel, styled like Stats' popups

/// Stats' popup sizes: 264 wide inside 8 of margin, a 42-high header, 22-high rows.
enum Panel {
    static let width: CGFloat = 264
    static let margin: CGFloat = 8
    static let header: CGFloat = 42
    static let row: CGFloat = 22
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
    private let block = NSView()

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

    /// Changes the square's colour, for a row made with one.
    func setColor(_ color: NSColor) {
        block.layer?.backgroundColor = color.cgColor
    }
}

/// A drop-down panel like Stats' popups: a translucent window under its menu bar
/// item, a header with a title and up to two buttons, and `body` for the content.
/// It closes when it stops being the key window, as Stats' do.
class StatsPanel: NSWindow, NSWindowDelegate {
    let body = NSStackView()
    private let header = NSStackView()
    private let titleField = NSTextField(labelWithString: "")

    init(title: String) {
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

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        contentView = background

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 16)
        titleField.alignment = .center
        header.setViews([placeholder(), titleField, placeholder()], in: .leading)
        header.distribution = .equalCentering
        header.translatesAutoresizingMaskIntoConstraints = false
        body.orientation = .vertical
        body.alignment = .leading
        body.spacing = 0
        body.translatesAutoresizingMaskIntoConstraints = false
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
        ])
    }

    /// Puts buttons either side of the title, as Stats' headers have.
    func setHeaderButtons(leading: NSButton?, trailing: NSButton?) {
        header.setViews([leading ?? placeholder(), titleField, trailing ?? placeholder()], in: .leading)
    }

    func headerButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                              target: self, action: action)
        button.isBordered = false
        button.contentTintColor = .secondaryLabelColor
        button.toolTip = tip
        button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return button
    }

    private func placeholder() -> NSView {
        let view = NSView()
        view.widthAnchor.constraint(equalToConstant: 24).isActive = true
        return view
    }

    func windowDidResignKey(_ notification: Notification) {
        orderOut(nil)
    }

    /// Called before the panel opens; a subclass refreshes what it shows.
    func willOpen() {}

    /// Opens under `button`, centred on it, kept on its screen: where Stats opens its panels.
    func toggle(under button: NSStatusBarButton) {
        if isVisible {
            orderOut(nil)
            return
        }
        willOpen()
        fitToContents()
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

    /// Fits the panel to its contents, keeping its top edge where it is.
    func fitToContents() {
        guard let content = contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - size.height, width: size.width, height: size.height), display: true)
    }
}
