// The battery's charge: what a full charge holds and how much is left, from the
// AppleSmartBattery entry in the I/O Registry. Reading it needs no permission.

import Foundation
import IOKit

struct BatteryCharge {
    /// What a full charge holds now, in watt-hours.
    let fullWh: Double
    /// What it held when new.
    let designWh: Double
    let leftWh: Double
    /// The percentage the battery icon shows.
    let percent: Int
    let cycles: Int
}

/// Nil on a Mac without a battery.
func batteryCharge() -> BatteryCharge? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    var properties: Unmanaged<CFMutableDictionary>?
    guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
          let battery = properties?.takeRetainedValue() as? [String: Any] else { return nil }
    let number = { (key: String) in (battery[key] as? NSNumber)?.doubleValue ?? 0 }
    // Capacities are in mAh; at the battery's voltage (mV) they give watt-hours.
    let volts = number("Voltage") / 1000
    let fullMah = number("AppleRawMaxCapacity"), designMah = number("DesignCapacity")
    guard volts > 0, fullMah > 0 else { return nil }
    // Apple silicon reports the charge as a percentage (out of 100), older Macs in mAh.
    let current = number("CurrentCapacity"), maximum = number("MaxCapacity")
    guard maximum > 0 else { return nil }
    let percent = Int((current / maximum * 100).rounded())
    let fullWh = fullMah * volts / 1000
    return BatteryCharge(fullWh: fullWh, designWh: designMah * volts / 1000,
                         leftWh: fullWh * Double(percent) / 100, percent: percent, cycles: Int(number("CycleCount")))
}
