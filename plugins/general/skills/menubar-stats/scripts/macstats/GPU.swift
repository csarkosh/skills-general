// The GPU menu bar item: "GPU" over its utilization, and a panel with two gauges
// (utilization, and GPU temperature on the chip's limits), Usage (a history chart
// and the GPU's figures), Details (model, cores) and Top GPU apps. The figures are
// the ones the Stats app reads (Modules/GPU/reader.swift, MIT; see LICENSE-stats.txt
// beside this file): the accelerator's PerformanceStatistics, and on Apple silicon
// the ML engine's power and the displays' frame swaps from IOReport.

import Cocoa
import IOKit

// MARK: - The accelerator

struct GPUSample {
    let utilization: Double  // 0...1
    let renderer: Double
    let tiler: Double
    let memoryInUse: Double  // bytes
    let memoryAllocated: Double
    let neuralEngine: Double?  // 0...1, Apple silicon only
    let fps: Double?
}

struct GPUInfo {
    let model: String
    let cores: Int?
}

/// The accelerator's registry entry, as an owned object to release.
private func acceleratorEntry() -> io_object_t? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
    else { return nil }
    defer { IOObjectRelease(iterator) }
    let entry = IOIteratorNext(iterator)
    return entry == 0 ? nil : entry
}

private func properties(of entry: io_object_t) -> [String: Any]? {
    var dictionary: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(entry, &dictionary, kCFAllocatorDefault, 0) == KERN_SUCCESS else { return nil }
    return dictionary?.takeRetainedValue() as? [String: Any]
}

func gpuInfo() -> GPUInfo? {
    guard let entry = acceleratorEntry() else { return nil }
    defer { IOObjectRelease(entry) }
    guard let props = properties(of: entry) else { return nil }
    let model = (props["model"] as? String)
        ?? (props["model"] as? Data).flatMap { String(data: $0, encoding: .ascii)?.replacingOccurrences(of: "\0", with: "") }
        ?? "GPU"
    return GPUInfo(model: model, cores: (props["gpu-core-count"] as? NSNumber)?.intValue)
}

// MARK: - IOReport: the ML engine's energy and the displays' frames

// IOReport is a private macOS library, so it is looked up at run time rather than
// linked; on a Mac without it, the ML engine and FPS rows read "–".
private let ioReport = dlopen("/usr/lib/libIOReport.dylib", RTLD_NOW)
private func ioReportFunction<T>(_ name: String, as type: T.Type) -> T? {
    guard let ioReport, let pointer = dlsym(ioReport, name) else { return nil }
    return unsafeBitCast(pointer, to: type)
}
private typealias CopyChannelsInGroup = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
private typealias MergeChannels = @convention(c) (CFMutableDictionary, CFDictionary, CFTypeRef?) -> Void
private typealias CreateSubscription = @convention(c) (UnsafeMutableRawPointer?, CFMutableDictionary,
                                                       UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> OpaquePointer?
private typealias CreateSamples = @convention(c) (OpaquePointer, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
private typealias ChannelString = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
private typealias SimpleIntegerValue = @convention(c) (CFDictionary, Int32) -> Int64

private let copyChannelsInGroup = ioReportFunction("IOReportCopyChannelsInGroup", as: CopyChannelsInGroup.self)
private let mergeChannels = ioReportFunction("IOReportMergeChannels", as: MergeChannels.self)
private let createSubscription = ioReportFunction("IOReportCreateSubscription", as: CreateSubscription.self)
private let createSamples = ioReportFunction("IOReportCreateSamples", as: CreateSamples.self)
private let channelGroup = ioReportFunction("IOReportChannelGetGroup", as: ChannelString.self)
private let channelSubGroup = ioReportFunction("IOReportChannelGetSubGroup", as: ChannelString.self)
private let channelName = ioReportFunction("IOReportChannelGetChannelName", as: ChannelString.self)
private let channelUnit = ioReportFunction("IOReportChannelGetUnitLabel", as: ChannelString.self)
private let simpleIntegerValue = ioReportFunction("IOReportSimpleGetIntegerValue", as: SimpleIntegerValue.self)

/// A subscription to some IOReport channels, read as running totals.
private final class ReportSubscription {
    private let channels: CFMutableDictionary
    private let subscription: OpaquePointer

    /// The channels of `groups`, with `subGroup` if given, merged into one subscription.
    init?(groups: [String], subGroup: String?) {
        guard let copyChannelsInGroup, let mergeChannels, let createSubscription else { return nil }
        var merged: CFMutableDictionary?
        for group in groups {
            guard let channel = copyChannelsInGroup(group as CFString, subGroup as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let merged { mergeChannels(merged, channel, nil) } else { merged = channel }
        }
        guard let merged, (merged as NSDictionary)["IOReportChannels"] != nil else { return nil }
        var unused: Unmanaged<CFMutableDictionary>?
        guard let subscription = createSubscription(nil, merged, &unused, 0, nil) else { return nil }
        unused?.release()
        channels = merged
        self.subscription = subscription
    }

    /// Each channel now: its group, subgroup, name, unit and value.
    func sample() -> [(group: String, subGroup: String, name: String, unit: String, value: Int64)] {
        guard let createSamples, let channelGroup, let channelSubGroup, let channelName, let channelUnit, let simpleIntegerValue,
              let sample = createSamples(subscription, channels, nil)?.takeRetainedValue(),
              let list = (sample as NSDictionary)["IOReportChannels"] as? [CFDictionary] else { return [] }
        return list.map { item in
            (channelGroup(item)?.takeUnretainedValue() as String? ?? "",
             channelSubGroup(item)?.takeUnretainedValue() as String? ?? "",
             channelName(item)?.takeUnretainedValue() as String? ?? "",
             (channelUnit(item)?.takeUnretainedValue() as String? ?? "").trimmingCharacters(in: .whitespaces),
             simpleIntegerValue(item, 0))
        }
    }
}

/// The ML engine's peak power by chip, as Stats has it, so its power reads as a share.
private func neuralEnginePeakWatts() -> Double {
    switch Chip.current {
    case .m1, .m1Pro, .m1Max: return 2
    case .m1Ultra: return 4
    case .m2, .m2Pro, .m2Max: return 2.5
    case .m2Ultra: return 5
    case .m3, .m3Pro, .m3Max: return 3
    case .m3Ultra: return 6
    case .m4, .m4Pro, .m4Max: return 6
    case .m4Ultra: return 12
    case .m5, .m5Pro, .m5Max: return 8
    case .m5Ultra: return 16
    default: return 8
    }
}

/// Reads the GPU once a second: utilization and memory from the accelerator, and on
/// Apple silicon the ML engine's share (its energy over the last interval, against
/// its peak power) and frames per second (displays' frame swaps over the interval).
final class GPUSampler {
    private let energy = ReportSubscription(groups: ["Energy Model"], subGroup: nil)
    private let frames = ReportSubscription(groups: ["DCP", "DCP0", "DCPEXT0", "DCPEXT1", "DCPEXT2", "DCPEXT3"], subGroup: "swap")
    private var last: (time: Date, joules: Double?, frames: Int64?)?

    func sample() -> GPUSample? {
        guard let entry = acceleratorEntry() else { return nil }
        defer { IOObjectRelease(entry) }
        guard let stats = properties(of: entry)?["PerformanceStatistics"] as? [String: Any] else { return nil }
        let percent = { (key: String) in ((stats[key] as? NSNumber)?.doubleValue ?? 0) / 100 }
        let bytes = { (key: String) in (stats[key] as? NSNumber)?.doubleValue ?? 0 }

        let now = Date()
        let joules = energy.map { report -> Double in
            report.sample().filter { $0.group == "Energy Model" && $0.name.hasPrefix("ANE") }.reduce(0) { total, channel in
                let scale: Double
                switch channel.unit.lowercased() {
                case "mj": scale = 1e-3
                case "uj", "µj": scale = 1e-6
                case "pj": scale = 1e-12
                default: scale = 1e-9
                }
                return total + Double(channel.value) * scale
            }
        }
        let frameCount = frames.map { report in
            report.sample().filter { $0.group.hasPrefix("DCP") && $0.subGroup == "swap" }.reduce(0) { $0 + $1.value }
        }
        var neuralEngine: Double?, fps: Double?
        if let last, case let elapsed = now.timeIntervalSince(last.time), elapsed > 0 {
            if let joules, let before = last.joules { neuralEngine = min(1, max(0, (joules - before) / elapsed / neuralEnginePeakWatts())) }
            if let frameCount, let before = last.frames, frameCount >= before { fps = Double(frameCount - before) / elapsed }
        }
        last = (now, joules, frameCount)

        return GPUSample(utilization: percent("Device Utilization %"), renderer: percent("Renderer Utilization %"),
                         tiler: percent("Tiler Utilization %"), memoryInUse: bytes("In use system memory"),
                         memoryAllocated: bytes("Alloc system memory"), neuralEngine: neuralEngine, fps: fps)
    }
}

// MARK: - Apps using the GPU

struct GPUApp {
    let pid: Int32
    let name: String
    let share: Double  // 0...1 of the GPU's time
}

/// The apps using the GPU, as Activity Monitor's "% GPU" counts it: each app's GPU
/// time (summed over its connections to the GPU) since the last look, as a share of
/// the time passed.
final class GPUAppSampler {
    private var last: (time: Date, gpuTime: [Int32: Double])?

    func sample(_ count: Int = 8) -> [GPUApp] {
        guard let accelerator = acceleratorEntry() else { return [] }
        defer { IOObjectRelease(accelerator) }
        var children: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accelerator, kIOServicePlane, &children) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(children) }
        var gpuTime: [Int32: Double] = [:], names: [Int32: String] = [:]
        while case let child = IOIteratorNext(children), child != 0 {
            defer { IOObjectRelease(child) }
            guard let props = properties(of: child), let creator = props["IOUserClientCreator"] as? String,
                  let usage = props["AppUsage"] as? [[String: Any]] else { continue }
            // "pid 601, WindowServer"
            let parts = creator.dropFirst(4).split(separator: ",", maxSplits: 1)
            guard let first = parts.first, let pid = Int32(first) else { continue }
            gpuTime[pid, default: 0] += usage.reduce(0) { $0 + ((($1["accumulatedGPUTime"] as? NSNumber)?.doubleValue) ?? 0) }
            names[pid] = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "pid \(pid)"
        }
        let now = Date()
        defer { last = (now, gpuTime) }
        guard let last, case let elapsed = now.timeIntervalSince(last.time) * 1e9, elapsed > 0 else { return [] }
        return gpuTime.compactMap { pid, time -> GPUApp? in
            let share = (time - (last.gpuTime[pid] ?? time)) / elapsed
            guard share > 0.0005 else { return nil }
            return GPUApp(pid: pid, name: NSRunningApplication(processIdentifier: pid)?.localizedName ?? names[pid] ?? "pid \(pid)",
                          share: min(1, share))
        }
        .sorted { $0.share > $1.share }
        .prefix(count).map { $0 }
    }
}

// MARK: - The panel

/// Stats' green, yellow and red zones for utilization: from 60% and 80%.
let utilizationLimits = (warm: 0.6, hot: 0.8)

func utilizationWord(_ value: Double) -> String {
    value < utilizationLimits.warm ? "Normal" : value < utilizationLimits.hot ? "Busy" : "Heavy"
}

func formatPercent(_ value: Double) -> String { String(format: "%.0f%%", value * 100) }

/// The chart's series and the rows coloured like them.
let gpuSeries: [(title: String, color: NSColor, value: (GPUSample) -> Double)] = [
    ("Utilization", .systemBlue, { $0.utilization }),
    ("Renderer", .systemOrange, { $0.renderer }),
    ("Tiler", .systemPink, { $0.tiler }),
]

/// The last three minutes, a sample a second.
final class GPUHistory {
    private(set) var samples: [GPUSample] = []
    let capacity = 180

    func add(_ sample: GPUSample) {
        samples.append(sample)
        if samples.count > capacity { samples.removeFirst(samples.count - capacity) }
    }
}

/// Utilization over three minutes as a blue area, with Renderer and Tiler as lines in
/// their rows' colours, newest at the right, and a time axis underneath.
final class GPUChart: NSView {
    var history: GPUHistory?
    private let plotHeight: CGFloat = 90
    private let axisHeight: CGFloat = 13

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: plotHeight + axisHeight),
            widthAnchor.constraint(equalToConstant: Panel.width),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let plot = NSRect(x: 0, y: axisHeight, width: bounds.width, height: plotHeight)
        drawTimeAxis(in: NSRect(x: 2, y: 0, width: bounds.width - 4, height: axisHeight - 2), minutes: (history?.capacity ?? 180) / 60)
        let frame = NSBezierPath(roundedRect: plot, xRadius: 6, yRadius: 6)
        NSColor.lightGray.withAlphaComponent(0.1).setFill()
        frame.fill()
        guard let history, history.samples.count > 1, let latest = history.samples.last else { return }
        NSGraphicsContext.saveGraphicsState()
        frame.addClip()
        let samples = history.samples
        let step = plot.width / CGFloat(history.capacity - 1)
        let point = { (index: Int, value: Double) in
            CGPoint(x: plot.maxX - CGFloat(samples.count - 1 - index) * step, y: plot.minY + CGFloat(min(1, value)) * plot.height)
        }
        for (index, series) in gpuSeries.enumerated() {
            let path = NSBezierPath()
            for (sampleIndex, sample) in samples.enumerated() {
                let p = point(sampleIndex, series.value(sample))
                if sampleIndex == 0 { path.move(to: p) } else { path.line(to: p) }
            }
            if index == 0 {
                let area = path.copy() as! NSBezierPath
                area.line(to: point(samples.count - 1, 0))
                area.line(to: point(0, 0))
                area.close()
                series.color.withAlphaComponent(0.7).setFill()
                area.fill()
            } else {
                path.lineWidth = 1.5
                series.color.setStroke()
                path.stroke()
            }
        }
        let right = NSMutableParagraphStyle()
        right.alignment = .right
        let text = NSAttributedString(string: "Utilization: \(formatPercent(latest.utilization))", attributes: [
            .font: NSFont.systemFont(ofSize: 9, weight: .semibold), .foregroundColor: NSColor.labelColor, .paragraphStyle: right,
        ])
        let height = ceil(text.size().height)
        text.draw(with: NSRect(x: plot.minX, y: plot.maxY - height, width: plot.width - 10, height: height))
        NSGraphicsContext.restoreGraphicsState()
    }
}

/// "N min ago" at the left and "now" at the right, as the RAM chart has.
func drawTimeAxis(in row: NSRect, minutes: Int) {
    let attributes = { (alignment: NSTextAlignment) -> [NSAttributedString.Key: Any] in
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        return [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: style]
    }
    NSAttributedString(string: "\(minutes) min ago", attributes: attributes(.left)).draw(with: row)
    NSAttributedString(string: "now", attributes: attributes(.right)).draw(with: row)
}

/// What the GPU item shows: its utilization.
func gpuItemText(_ sample: GPUSample) -> (value: String, tooltip: String) {
    (formatPercent(sample.utilization),
     "GPU \(formatPercent(sample.utilization)) busy (\(utilizationWord(sample.utilization).lowercased())). Click for more.")
}

final class GPUPanel: StatsPanel {
    private let history: GPUHistory
    private let reader: SensorReader
    private let info = gpuInfo()
    private let utilizationGauge = GaugeView()
    private let heatGauge = GaugeView()
    private let chart = GPUChart()
    private let seriesRows = gpuSeries.map { PanelRow($0.title + ":", color: $0.color) }
    private let neuralRow = PanelRow("ML engine:")
    private let fpsRow = PanelRow("FPS:")
    private let memoryRow = PanelRow("Memory:")
    private let appRows = (0..<8).map { _ in ProcessRow() }
    private let noApps = NSTextField(labelWithString: "Measuring…")
    private let appSampler = GPUAppSampler()
    private var appTimer: Timer?

    init(history: GPUHistory, reader: SensorReader) {
        self.history = history
        self.reader = reader
        super.init(title: "GPU")
        setHeaderButtons(leading: headerButton("chart.bar.fill", "Open Activity Monitor", #selector(openActivityMonitor)),
                         trailing: nil)

        let dashboard = NSStackView(views: [utilizationGauge, heatGauge])
        dashboard.orientation = .horizontal
        dashboard.distribution = .fillEqually
        dashboard.spacing = 0
        dashboard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dashboard.widthAnchor.constraint(equalToConstant: Panel.width),
            dashboard.heightAnchor.constraint(equalToConstant: 108),
        ])
        utilizationGauge.heading = "Utilization"
        heatGauge.heading = "Temperature"
        utilizationGauge.toolTip = "How busy the GPU is: normal below 60%, busy below 80%, heavy from 80%, Stats' zones."
        heatGauge.toolTip = "The GPU's temperature on the chip's limits, as its row in the Temp menu has it."
        body.addArrangedSubview(dashboard)

        body.addArrangedSubview(separatorView("Usage"))
        chart.history = history
        body.addArrangedSubview(chart)
        body.setCustomSpacing(6, after: chart)
        for row in seriesRows + [neuralRow, fpsRow, memoryRow] { body.addArrangedSubview(row) }
        seriesRows[1].toolTip = "The share of time the GPU spent drawing pixels."
        seriesRows[2].toolTip = "The share of time the GPU spent sorting geometry into tiles, before drawing."
        neuralRow.toolTip = "How busy the ML engine, Apple's machine-learning cores, is: its power against its peak, as Stats reads it."
        fpsRow.toolTip = "Frames the displays showed in the last second."
        memoryRow.toolTip = "Memory the GPU is using now, out of what it has set aside."

        body.addArrangedSubview(separatorView("Details"))
        let model = PanelRow("Model:")
        model.value.stringValue = info?.model ?? "Unknown"
        let cores = PanelRow("Cores:")
        cores.value.stringValue = info?.cores.map(String.init) ?? "Unknown"
        body.addArrangedSubview(model)
        body.addArrangedSubview(cores)

        body.addArrangedSubview(separatorView("Top GPU apps"))
        let heading = ProcessRow()
        heading.name.stringValue = "App"
        heading.value.stringValue = "GPU"
        for field in [heading.name, heading.value] {
            field.font = .systemFont(ofSize: 11)
            field.textColor = .tertiaryLabelColor
        }
        body.addArrangedSubview(heading)
        noApps.font = .systemFont(ofSize: 11)
        noApps.textColor = .secondaryLabelColor
        body.addArrangedSubview(noApps)
        for row in appRows {
            row.isHidden = true
            body.addArrangedSubview(row)
        }
        if let latest = history.samples.last { update(latest) }
    }

    func update(_ sample: GPUSample) {
        chart.needsDisplay = true
        utilizationGauge.fraction = gaugeFraction(sample.utilization, low: 0, warm: utilizationLimits.warm,
                                                  hot: utilizationLimits.hot, high: 1)
        utilizationGauge.title = "\(utilizationWord(sample.utilization)) · \(formatPercent(sample.utilization))"
        utilizationGauge.subtitle = info.map { "\($0.model)\($0.cores.map { ", \($0) cores" } ?? "")" } ?? ""
        if let gpu = cpuAndGPU(reader.read()).gpu {
            heatGauge.fraction = heatFraction(of: "GPU", celsius: gpu)
            heatGauge.title = "\(heat(of: "GPU", celsius: gpu).word) · \(degrees(gpu))"
            heatGauge.subtitle = "GPU"
        }
        for (row, series) in zip(seriesRows, gpuSeries) { row.value.stringValue = formatPercent(series.value(sample)) }
        neuralRow.value.stringValue = sample.neuralEngine.map(formatPercent) ?? "–"
        fpsRow.value.stringValue = sample.fps.map { String(format: "%.0f", $0) } ?? "–"
        memoryRow.value.stringValue = "\(formatMemory(sample.memoryInUse)) of \(formatMemory(sample.memoryAllocated))"
    }

    override func willOpen() {
        if let latest = history.samples.last { update(latest) }
        // GPU use is measured between two looks: the first sets the baseline, the list
        // fills a second later and refreshes every two seconds while the panel is open.
        _ = appSampler.sample()
        noApps.stringValue = "Measuring…"
        noApps.isHidden = false
        for row in appRows { row.isHidden = true }
        appTimer?.invalidate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.isVisible else { return }
            self.refreshApps()
            self.appTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                guard let self else { return }
                if self.isVisible { self.refreshApps() } else { self.appTimer?.invalidate() }
            }
        }
    }

    func refreshApps() {
        let apps = appSampler.sample(appRows.count)
        noApps.stringValue = "No app is using the GPU."
        noApps.isHidden = !apps.isEmpty
        for (index, row) in appRows.enumerated() {
            guard index < apps.count else { row.isHidden = true; continue }
            row.isHidden = false
            row.icon.image = processIcon(apps[index].pid)
            row.name.stringValue = apps[index].name
            row.value.stringValue = String(format: "%.1f%%", apps[index].share * 100)
        }
        if isVisible { fitToContents() }
    }

    @objc private func openActivityMonitor() {
        dismiss()
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Activity Monitor.app"))
    }
}

/// Prints what the panel shows, from two looks a second apart.
func gpuReport() -> Int32 {
    let sampler = GPUSampler(), apps = GPUAppSampler()
    _ = sampler.sample()
    _ = apps.sample()
    Thread.sleep(forTimeInterval: 1)
    guard let sample = sampler.sample() else {
        FileHandle.standardError.write("Could not read the GPU.\n".data(using: .utf8)!)
        return 1
    }
    print("Usage")
    for series in gpuSeries { print(series.title + "\t" + formatPercent(series.value(sample))) }
    print("ML engine\t" + (sample.neuralEngine.map(formatPercent) ?? "–"))
    print("FPS\t" + (sample.fps.map { String(format: "%.0f", $0) } ?? "–"))
    print("Memory\t" + String(Int64(sample.memoryInUse)) + "\t" + String(Int64(sample.memoryAllocated)))
    print("Details")
    let info = gpuInfo()
    print("Model\t" + (info?.model ?? "Unknown"))
    print("Cores\t" + (info?.cores.map(String.init) ?? "Unknown"))
    print("Top GPU apps")
    for app in apps.sample() { print(app.name + "\t" + String(format: "%.1f%%", app.share * 100)) }
    return 0
}
