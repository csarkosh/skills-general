// The Temp menu bar item: "Temp" over the CPU and GPU temperatures, and a panel
// with every sensor the Mac has: temperatures as one row per part (hottest first,
// coloured by heat), then power in plain words, then fans.

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

/// One row of the Power section.
struct PowerLine {
    let id: String
    let title: String
    let value: String
    let tooltip: String?
}

/// The Power section: the SMC's voltage, current and power readings in plain words,
/// and the battery's charge. What the whole Mac uses, the battery's draw and what is
/// left in it, the charger (only while one is connected, with its voltage and current
/// in the tooltip) and the internal supply; any other such sensor follows under its
/// own name.
func powerLines(_ readings: [Reading], battery charge: BatteryCharge?) -> [PowerLine] {
    let byKey = Dictionary(readings.map { ($0.sensor.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    var lines: [PowerLine] = []
    if let total = byKey["PSTR"] {
        lines.append(PowerLine(id: "PSTR", title: "Total", value: String(format: "%.1f W", total),
                               tooltip: "Everything the Mac is using right now."))
    }
    if let battery = byKey["PPBR"] {
        lines.append(PowerLine(id: "PPBR", title: "Battery", value: String(format: "%.1f W", battery),
                               tooltip: "Power coming out of the battery; about 0 while a charger covers everything."))
    }
    if let charge {
        lines.append(PowerLine(
            id: "batteryLeft", title: "Battery left",
            value: String(format: "%.1f/%.1f Wh (%d%%)", charge.leftWh, charge.fullWh, charge.percent),
            tooltip: String(format: "A full charge holds %.1f Wh; new, it held %.1f Wh. %d charge cycles so far. "
                + "The percentage is the one the battery icon shows.", charge.fullWh, charge.designWh, charge.cycles)))
    }
    let chargerWatts = byKey["PDTR"] ?? 0, chargerVolts = byKey["VD0R"] ?? 0, chargerAmps = byKey["ID0R"] ?? 0
    if chargerWatts > 0.5 || chargerVolts > 1 {
        lines.append(PowerLine(id: "charger", title: "Charger", value: String(format: "%.1f W", chargerWatts),
                               tooltip: String(format: "Coming in from the charger at %.1f V and %.2f A.", chargerVolts, chargerAmps)))
    }
    if let supply = byKey["VP0R"] {
        lines.append(PowerLine(id: "VP0R", title: "Internal supply", value: String(format: "%.2f V", supply),
                               tooltip: "The Mac's main internal supply line; it stays near 12 V."))
    }
    let shown: Set<String> = ["PSTR", "PPBR", "PDTR", "VD0R", "ID0R", "VP0R"]
    for reading in readings where [.power, .voltage, .current].contains(reading.sensor.kind) && !shown.contains(reading.sensor.key) {
        lines.append(PowerLine(id: reading.sensor.key, title: reading.sensor.name, value: formatReading(reading), tooltip: nil))
    }
    return lines
}

final class TempPanel: StatsPanel {
    private let reader: SensorReader
    private let temperatureList = NSStackView()
    private var temperatureRows: [String: PanelRow] = [:]
    private let powerCaption = separatorView("Power")
    private let powerList = NSStackView()
    private var powerRows: [String: PanelRow] = [:]  // by PowerLine id
    private var fanRows: [String: PanelRow] = [:]    // by SMC key

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
        if reader.sensors.contains(where: { [.power, .voltage, .current].contains($0.kind) }) || batteryCharge() != nil {
            body.addArrangedSubview(powerCaption)
            powerList.orientation = .vertical
            powerList.alignment = .leading
            powerList.spacing = 0
            body.addArrangedSubview(powerList)
        }
        let fans = reader.sensors.filter { $0.kind == .fan }
        if !fans.isEmpty {
            body.addArrangedSubview(separatorView("Fans"))
            for fan in fans {
                let row = PanelRow(fan.name + ":")
                fanRows[fan.key] = row
                body.addArrangedSubview(row)
            }
        }
        if groups.isEmpty && body.arrangedSubviews.isEmpty {
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
        // Power rows come and go with the charger.
        let lines = powerLines(readings, battery: batteryCharge())
        for line in lines {
            let row = powerRows[line.id] ?? PanelRow(line.title + ":")
            powerRows[line.id] = row
            row.value.stringValue = line.value
            row.toolTip = line.tooltip
        }
        powerList.setViews(lines.compactMap { powerRows[$0.id] }, in: .top)
        let byKey = Dictionary(readings.map { ($0.sensor.key, $0) }, uniquingKeysWith: { first, _ in first })
        for (key, row) in fanRows {
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
    let lines = powerLines(readings, battery: batteryCharge())
    if !lines.isEmpty { print("Power") }
    for line in lines { print(line.title + "\t" + line.value) }
    let fans = readings.filter { $0.sensor.kind == .fan }
    if !fans.isEmpty { print("Fans") }
    for reading in fans { print(reading.sensor.name + "\t" + formatReading(reading)) }
    return 0
}
