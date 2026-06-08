import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation

// MARK: - Permission model

enum MiraPermission: String, CaseIterable, Identifiable {
    case screenRecording
    case accessibility
    case microphone

    var id: String { rawValue }

    var title: String {
        switch self {
        case .screenRecording: return "Screen Recording"
        case .accessibility:   return "Accessibility"
        case .microphone:      return "Microphone"
        }
    }

    var icon: String {
        switch self {
        case .screenRecording: return "rectangle.on.rectangle"
        case .accessibility:   return "accessibility"
        case .microphone:      return "mic.fill"
        }
    }

    var reason: String {
        switch self {
        case .screenRecording:
            return "To see your screen and show you exactly where to click during visual guidance."
        case .accessibility:
            return "To let background agents operate apps, type, and click on your behalf."
        case .microphone:
            return "To hear \"Hey Mira\" and respond to voice commands hands-free."
        }
    }

    var isGranted: Bool {
        switch self {
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        case .accessibility:   return AXIsProcessTrusted()
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")
        case .accessibility:   return URL(string: base + "Privacy_Accessibility")
        case .microphone:      return URL(string: base + "Privacy_Microphone")
        }
    }
}

// MARK: - Onboarding service

@MainActor
final class OnboardingService: ObservableObject {
    static let shared = OnboardingService()
    private init() {}

    var isFirstLaunch: Bool {
        !UserDefaults.standard.bool(forKey: "mira_setup_complete")
    }

    func missingPermissions() -> [MiraPermission] {
        MiraPermission.allCases.filter { !$0.isGranted }
    }

    func completeSetup() {
        UserDefaults.standard.set(true, forKey: "mira_setup_complete")
    }

    func openSettings(for permission: MiraPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }

    func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }
}

// MARK: - Onboarding window controller

final class OnboardingWindowController {
    static let shared = OnboardingWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil { buildWindow() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }

    private func buildWindow() {
        let hosting = NSHostingController(rootView: OnboardingView {
            OnboardingWindowController.shared.close()
        })
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 580),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.09, green: 0.09, blue: 0.11, alpha: 1.0)
        w.contentViewController = hosting
        w.center()
        window = w
    }
}
