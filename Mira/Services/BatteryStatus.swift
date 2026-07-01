import IOKit.ps

// MARK: - BatteryStatus
//
// Shared IOKit power-source read, factored out so MiraDockView's BatteryWidget/
// BatteryDetailPanel and the notch's compact battery readout all call the same
// code instead of duplicating the IOPSCopyPowerSourcesInfo dance a third time.

enum BatteryStatus {
    static func read() -> (pct: Int, charging: Bool)? {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef],
              let src  = list.first,
              let info = IOPSGetPowerSourceDescription(snap, src)?.takeUnretainedValue() as? [String: Any]
        else { return nil }
        let pct      = info[kIOPSCurrentCapacityKey] as? Int ?? 100
        let charging = (info[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        return (pct, charging)
    }
}
