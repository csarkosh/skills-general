// The Temp menu bar item: "Temp" over the CPU and GPU temperatures, and a panel
// with every sensor the Mac has: temperatures as one row per part (hottest first,
// coloured by heat), then voltage, current, power and fans.

import Cocoa

/// What the Temp item shows: CPU°/GPU°, and both with units for its tooltip.
func tempItemText(_ readings: [Reading]) -> (value: String, tooltip: String) {
    let figures = cpuAndGPU(readings)
    let short = { (celsius: Double?) in celsius.map { degrees($0, unit: false) } ?? "–" }
    let long = { (celsius: Double?) in celsius.map { degrees($0) } ?? "unknown" }
    return ("\(short(figures.cpu))/\(short(figures.gpu))",
            "CPU \(long(figures.cpu)), GPU \(long(figures.gpu)). Click for every sensor.")
}

/// Green under 60 °C, yellow under 80 °C, red from 80 °C.
func heatColor(_ celsius: Double) -> NSColor {
    celsius < 60 ? .systemGreen : celsius < 80 ? .systemYellow : .systemRed
}

/// The sections after Temperature, in Stats' order, with their captions.
let otherSections: [(kind: SensorKind, title: String)] = [
    (.voltage, "Voltage"), (.current, "Current"), (.power, "Power"), (.fan, "Fans"),
]

final class TempPanel: StatsPanel {
    private let reader: SensorReader
    private let temperatureList = NSStackView()
    private var temperatureRows: [String: PanelRow] = [:]
    private var otherRows: [String: PanelRow] = [:]  // by SMC key

    init(reader: SensorReader) {
        self.reader = reader
        super.init(title: "Sensors")
        build(reader.read())
    }

    private func build(_ readings: [Reading]) {
        let groups = temperatureGroups(readings)
        if !groups.isEmpty {
            body.addArrangedSubview(separatorView("Temperature"))
            temperatureList.orientation = .vertical
            temperatureList.alignment = .leading
            temperatureList.spacing = 0
            for group in groups {
                temperatureRows[group.name] = PanelRow(group.name + ":", color: heatColor(group.celsius))
            }
            body.addArrangedSubview(temperatureList)
        }
        for section in otherSections {
            let sensors = reader.sensors.filter { $0.kind == section.kind }
            guard !sensors.isEmpty else { continue }
            body.addArrangedSubview(separatorView(section.title))
            for sensor in sensors {
                let row = PanelRow(sensor.name + ":")
                otherRows[sensor.key] = row
                body.addArrangedSubview(row)
            }
        }
        if groups.isEmpty && otherRows.isEmpty {
            let none = NSTextField(labelWithString: "This Mac reports no sensors.")
            none.font = .systemFont(ofSize: 12)
            none.textColor = .secondaryLabelColor
            body.addArrangedSubview(none)
        }
        update(readings)
    }

    override func willOpen() {
        update(reader.read())
    }

    /// Shows new readings: temperature rows re-sorted hottest first and recoloured.
    func update(_ readings: [Reading]) {
        let groups = temperatureGroups(readings)
        for group in groups {
            guard let row = temperatureRows[group.name] else { continue }
            row.value.stringValue = degrees(group.celsius)
            row.setColor(heatColor(group.celsius))
            row.toolTip = group.count == 1 ? nil
                : "\(group.count) sensors, \(degrees(group.coolest)) to \(degrees(group.hottest)), weighted toward the hottest."
        }
        temperatureList.setViews(groups.compactMap { temperatureRows[$0.name] }, in: .top)
        let byKey = Dictionary(readings.map { ($0.sensor.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, row) in otherRows {
            row.value.stringValue = byKey[key].map(formatReading) ?? "–"
        }
        if isVisible { fitToContents() }
    }
}

/// Prints what the panel shows: each section, then its rows.
func sensorsReport() -> Int32 {
    let reader = SensorReader()
    let readings = reader.read()
    guard !readings.isEmpty else {
        FileHandle.standardError.write("This Mac reports no sensors.\n".data(using: .utf8)!)
        return 1
    }
    let groups = temperatureGroups(readings)
    if !groups.isEmpty { print("Temperature") }
    for group in groups {
        print([group.name, String(format: "%.1f", group.celsius), String(group.count),
               String(format: "%.1f-%.1f", group.coolest, group.hottest)].joined(separator: "\t"))
    }
    for section in otherSections {
        let rows = readings.filter { $0.sensor.kind == section.kind }
        if !rows.isEmpty { print(section.title) }
        for reading in rows { print(reading.sensor.name + "\t" + formatReading(reading)) }
    }
    return 0
}
