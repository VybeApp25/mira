// BluetoothModule.swift
// MacNotch's Bluetooth module: connected gear with battery levels — AirPods,
// headphones, mice, keyboards, trackpads, controllers — plus low-battery alerts
// and per-device disconnect. The parity audit scored this ❌: Mira had zero
// IOBluetooth or CoreBluetooth usage anywhere.
//
// Uses the IOBluetooth device list rather than CoreBluetooth. CoreBluetooth is
// for BLE peripherals you connect to yourself and cannot see the system's
// already-paired classic devices at all, which is exactly what this module is
// about. Battery level isn't in IOBluetooth's public API, so it's read from
// IORegistry, where macOS publishes it for HID devices.
//
// `bluetooth` is second in MacNotch's live-activity priority order (decoded from
// its prefs), so this also fills a source LiveActivityService declared but could
// not populate.

import SwiftUI
import IOBluetooth
import IOKit
import Combine

// MARK: - Model

struct BluetoothDevice: Identifiable, Equatable {
    let id: String            // address
    let name: String
    let isConnected: Bool
    /// 0–100, or nil when the device doesn't publish one (most non-HID gear).
    let batteryPercent: Int?
    /// SF Symbol chosen from the device's major/minor class.
    let icon: String

    /// Apple's own threshold for the low-battery warning.
    var isLowBattery: Bool { (batteryPercent ?? 100) <= 20 }
}

// MARK: - Service

@MainActor
final class BluetoothService: ObservableObject {

    static let shared = BluetoothService()

    @Published private(set) var devices: [BluetoothDevice] = []

    private var timer: Timer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        refresh()
        // Battery levels move slowly; polling harder would burn power to learn
        // nothing. Connection changes are the fast-moving part and 5s is well
        // inside "felt instant" for a panel you glance at.
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        let batteries = Self.batteryLevels()

        devices = paired.compactMap { d in
            guard let address = d.addressString else { return nil }
            let name = d.name ?? address
            return BluetoothDevice(
                id: address,
                name: name,
                isConnected: d.isConnected(),
                batteryPercent: batteries[name] ?? batteries[address],
                icon: Self.icon(for: d)
            )
        }
        // Connected first, then low battery, then name — the order you'd scan in.
        .sorted { a, b in
            if a.isConnected != b.isConnected { return a.isConnected }
            if a.isLowBattery != b.isLowBattery { return a.isLowBattery }
            return a.name < b.name
        }
    }

    func disconnect(_ device: BluetoothDevice) {
        let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []
        paired.first { $0.addressString == device.id }?.closeConnection()
        refresh()
    }

    /// Battery percentages from IORegistry, keyed by product name. IOBluetooth
    /// exposes no battery API, but macOS publishes BatteryPercent for HID
    /// devices, which covers AirPods, mice, keyboards and trackpads.
    private static func batteryLevels() -> [String: Int] {
        var out: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("AppleDeviceManagementHIDEventService")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return out }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any]
            else { continue }

            guard let name = dict["Product"] as? String else { continue }
            if let pct = dict["BatteryPercent"] as? Int { out[name] = pct }
        }
        return out
    }

    private static func icon(for device: IOBluetoothDevice) -> String {
        // Major/minor device classes per the Bluetooth assigned-numbers spec.
        let minor = device.deviceClassMinor

        switch device.deviceClassMajor {
        case UInt32(kBluetoothDeviceClassMajorAudio):
            switch minor {
            case 1:        return "hifispeaker"      // loudspeaker
            case 2:        return "car"              // hands-free (a car kit)
            case 4, 6:     return "headphones"       // headset / headphones
            default:       return "hifispeaker"
            }

        case UInt32(kBluetoothDeviceClassMajorPeripheral):
            // The peripheral minor class packs TWO fields: bits 4-5 are
            // keyboard/pointing flags, and the low nibble is the device type.
            // Matching the whole byte against 0x08 (as this did) never fires —
            // an Xbox controller reports minor = 2, so it fell through to the
            // generic icon. Verified against real paired devices.
            if minor & 0x10 != 0 { return "keyboard" }
            if minor & 0x20 != 0 { return "computermouse" }
            switch minor & 0x0F {
            case 1, 2:     return "gamecontroller"   // joystick, gamepad
            case 3:        return "av.remote"
            case 5:        return "pencil.tip"       // digitizer tablet
            default:       return "rectangle.and.hand.point.up.left"
            }

        case UInt32(kBluetoothDeviceClassMajorPhone):
            return "iphone"
        case UInt32(kBluetoothDeviceClassMajorComputer):
            return "laptopcomputer"
        case UInt32(kBluetoothDeviceClassMajorWearable):
            return "applewatch"
        default:
            // Major 0 (miscellaneous) is what unconnected Apple devices report,
            // so this is a common path rather than an edge case.
            return "dot.radiowaves.left.and.right"
        }
    }
}

// MARK: - Module

@MainActor
final class BluetoothModule: NotchModule, ObservableObject {

    let id    = "bluetooth"
    let title = "Bluetooth"
    let icon  = "dot.radiowaves.left.and.right"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    private let service = BluetoothService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        let n = service.devices.filter(\.isConnected).count
        guard n > 0 else { return nil }
        return NotchHeaderSubtitle(text: "\(n) connected")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [NotchHeaderAccessory(id: "refresh", systemImage: "arrow.clockwise",
                              label: "Refresh devices") { [weak self] in
            self?.service.refresh()
        }]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func didAppear()    { service.start() }
    func didDisappear() { service.stop() }

    func makeContent() -> AnyView { AnyView(BluetoothModuleView(service: service)) }
}

// MARK: - View

private struct BluetoothModuleView: View {

    @ObservedObject var service: BluetoothService

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                ForEach(service.devices) { device in
                    row(device)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
        .overlay {
            if service.devices.isEmpty {
                VStack(spacing: 5) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18))
                        .foregroundColor(.white.opacity(0.22))
                    Text("No paired devices")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.white.opacity(0.50))
                }
            }
        }
    }

    private func row(_ device: BluetoothDevice) -> some View {
        HStack(spacing: 10) {
            Image(systemName: device.icon)
                .font(.system(size: 13))
                .foregroundColor(device.isConnected ? .white.opacity(0.85) : .white.opacity(0.28))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(device.isConnected ? 0.92 : 0.45))
                    .lineLimit(1)
                Text(device.isConnected ? "Connected" : "Not connected")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.35))
            }

            Spacer(minLength: 0)

            if let pct = device.batteryPercent {
                batteryPill(pct, low: device.isLowBattery)
            }

            if device.isConnected {
                Button {
                    service.disconnect(device)
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.30))
                }
                .buttonStyle(.plain)
                .help("Disconnect \(device.name)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.05))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(device.name), \(device.isConnected ? "connected" : "not connected")"
            + (device.batteryPercent.map { ", battery \($0) percent" } ?? "")
        )
    }

    private func batteryPill(_ pct: Int, low: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: low ? "battery.25" : "battery.100")
                .font(.system(size: 9))
            Text("\(pct)%")
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundColor(low ? Color(red: 1, green: 0.45, blue: 0.45) : .white.opacity(0.65))
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(low ? Color(red: 1, green: 0.35, blue: 0.35).opacity(0.14)
                               : Color.white.opacity(0.07))
        )
    }
}
