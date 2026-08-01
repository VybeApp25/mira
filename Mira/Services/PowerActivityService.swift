// PowerActivityService.swift
// Power state for the collapsed notch: plugged in, unplugged, and running low.
//
// MacNotch surfaces these as their own collapsed strips ("Plugged in, compact" /
// "Unplugged, compact") with, in its own words, "clearer priority" than the
// ambient sources. Mira had the read already — BatteryStatus — but only ever
// used it for a static readout in the dock and the expanded panel, so nothing
// about power ever reached the closed notch.
//
// WHY THE TRANSIENT/PERSISTENT SPLIT. Plugging in is an EVENT: you want to see
// that it registered, and then you want it gone. A low battery is a STATE: it
// should keep saying so until you do something about it. Treating both the same
// way gives you either a charge notice that never leaves or a low-battery
// warning you blink and miss.
//
// Driven by IOKit's power-source run loop source rather than a poll, so the
// notice appears when the cable goes in rather than up to a poll interval later
// — the whole point is that it is immediate feedback for a physical action.

import Foundation
import IOKit.ps
import Combine

@MainActor
final class PowerActivityService: ObservableObject {

    static let shared = PowerActivityService()

    enum Event: Equatable { case pluggedIn, unplugged }

    /// The most recent power event, while it is still worth showing.
    @Published private(set) var recentEvent: Event?
    @Published private(set) var percent: Int = 100
    @Published private(set) var isCharging = false

    /// How long a plug/unplug notice holds the strip.
    private static let noticeDuration: TimeInterval = 5

    /// Below this, the notch keeps saying so — a state, not an event.
    private static let lowThreshold = 20

    private var eventClearTask: Task<Void, Never>?
    private var runLoopSource: CFRunLoopSource?
    private var hasBaseline = false

    private init() {}

    var isLow: Bool { !isCharging && percent <= Self.lowThreshold }

    func start() {
        refresh()

        // IOPSNotificationCreateRunLoopSource fires on any power-source change.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            let service = Unmanaged<PowerActivityService>.fromOpaque(ctx).takeUnretainedValue()
            Task { @MainActor in service.refresh() }
        }, context)?.takeRetainedValue() else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        runLoopSource = source
    }

    private func refresh() {
        guard let status = BatteryStatus.read() else { return }
        let wasCharging = isCharging
        percent = status.pct
        isCharging = status.charging

        // The first read establishes where things stand. Announcing "plugged in"
        // at launch just because the laptop happens to be on a charger would be
        // reporting the absence of an event.
        guard hasBaseline else { hasBaseline = true; return }
        guard wasCharging != isCharging else { return }

        recentEvent = isCharging ? .pluggedIn : .unplugged
        eventClearTask?.cancel()
        eventClearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.recentEvent = nil }
        }
    }
}
