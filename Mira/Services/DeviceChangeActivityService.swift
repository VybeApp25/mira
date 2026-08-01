// DeviceChangeActivityService.swift
// "Display connected", "AirPods Pro" — the collapsed strips for hardware that
// just appeared or went away.
//
// MacNotch groups these with power in its own release notes: "Plugged in,
// Unplugged, and monitor connect strips get clearer priority. Volume and
// brightness HUDs stay hidden during those sequences, and audio output labels
// fit better on built-in notches." Both halves of that are implemented here —
// the strips, and the HUD suppression that goes with them.
//
// WHY THE HUD SUPPRESSION MATTERS. Connecting a display or switching audio
// output changes the output device, and often its volume with it. Without a
// quiet window, plugging in a monitor fires a volume HUD, then a brightness HUD,
// on top of the "Display connected" notice you actually wanted — three strips
// fighting over one event. The quiet window is why MacNotch mentions it.

import AppKit
import Combine

extension Notification.Name {
    static let miraAudioOutputChanged = Notification.Name("miraAudioOutputChanged")
}

@MainActor
final class DeviceChangeActivityService: ObservableObject {

    static let shared = DeviceChangeActivityService()

    struct Notice: Equatable {
        let icon: String
        let text: String
    }

    @Published private(set) var notice: Notice?

    /// Volume and brightness stay quiet until this passes.
    private(set) var hudQuietUntil = Date.distantPast

    private static let noticeDuration: TimeInterval = 4
    private static let quietDuration: TimeInterval = 2.5

    private var clearTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()
    private var screenCount = NSScreen.screens.count
    /// Suppresses the notice for the audio device present at launch — that is
    /// the status quo, not a change.
    private var hasAudioBaseline = false

    private init() {}

    func start() {
        NotificationCenter.default
            .publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in self?.screensChanged() }
            .store(in: &cancellables)

        NotificationCenter.default
            .publisher(for: .miraAudioOutputChanged)
            .sink { [weak self] note in
                guard let self else { return }
                guard self.hasAudioBaseline else { self.hasAudioBaseline = true; return }
                guard let name = note.userInfo?["name"] as? String else { return }
                self.show(Notice(icon: Self.audioIcon(for: name), text: name))
            }
            .store(in: &cancellables)
    }

    /// Fires for resolution and arrangement changes too, so it reports only when
    /// the COUNT moves — otherwise dragging a window between displays or waking
    /// from sleep would announce a connection that didn't happen.
    private func screensChanged() {
        let now = NSScreen.screens.count
        defer { screenCount = now }
        guard now != screenCount else { return }
        show(Notice(icon: now > screenCount ? "display.2" : "display",
                    text: now > screenCount ? "Display connected" : "Display disconnected"))
    }

    private func show(_ notice: Notice) {
        self.notice = notice
        hudQuietUntil = Date().addingTimeInterval(Self.quietDuration)

        clearTask?.cancel()
        clearTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.noticeDuration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.notice = nil }
        }
    }

    private static func audioIcon(for name: String) -> String {
        let lower = name.lowercased()
        if lower.contains("airpod") || lower.contains("buds")     { return "airpods" }
        if lower.contains("headphone") || lower.contains("beats") { return "headphones" }
        if lower.contains("display") || lower.contains("tv")      { return "tv" }
        if lower.contains("macbook") || lower.contains("built-in"){ return "laptopcomputer" }
        return "hifispeaker.fill"
    }
}
