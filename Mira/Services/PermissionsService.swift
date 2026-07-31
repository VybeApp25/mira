// PermissionsService.swift
// One place that knows every macOS permission Mira needs, why it needs it, and
// what state it is in.
//
// Before this, permission handling lived in a dozen files that each checked one
// thing their own way — AXIsProcessTrusted here, EKEventStore.authorizationStatus
// there — with no shared idea of what Mira needs overall. Two consequences, both
// of which we hit:
//
//   • Nothing could show the user the whole picture, so a feature that silently
//     did nothing looked like a bug rather than a missing grant. That is exactly
//     what happened with notifications: Full Disk Access had never been granted,
//     had never been asked for, and the panel said "No notifications".
//   • Nothing could ask at the right moment. MacNotch's permission copy is
//     explicit that it requests each one "only when the matching feature is
//     enabled", which is the difference between a considered request and an
//     app that demands nine grants on first launch.
//
// So each permission carries the FEATURES that need it, in the user's words. A
// request Mira cannot justify in one line is a request it should not be making.

import Foundation
import AppKit
import AVFoundation
import EventKit
import CoreBluetooth
import ApplicationServices
import CoreGraphics

// MARK: - Where the permission type lives
//
// `MiraPermission` is NOT declared here. It already existed in
// OnboardingService with the three grants first-run walks through, and it has
// been extended there with the rest. A second enum would have meant two lists
// of what Mira asks for, drifting apart the first time one gained a case.

// MARK: - Status

enum PermissionStatus: Equatable {
    case granted
    case denied
    /// Never asked. Worth distinguishing from denied: this one can still be
    /// resolved with a prompt, where denied can only be resolved in Settings.
    case notDetermined

    var isGranted: Bool { self == .granted }
}

// MARK: - Service

@MainActor
final class PermissionsService: ObservableObject {

    static let shared = PermissionsService()

    @Published private(set) var statuses: [MiraPermission: PermissionStatus] = [:]

    private let eventStore = EKEventStore()
    private var bluetoothManager: CBCentralManager?

    private init() { refresh() }

    func status(for permission: MiraPermission) -> PermissionStatus {
        statuses[permission] ?? .notDetermined
    }

    var missing: [MiraPermission] {
        MiraPermission.allCases.filter { !status(for: $0).isGranted }
    }

    func refresh() {
        var next: [MiraPermission: PermissionStatus] = [:]
        for permission in MiraPermission.allCases {
            next[permission] = evaluate(permission)
        }
        if next != statuses { statuses = next }
    }

    private func evaluate(_ permission: MiraPermission) -> PermissionStatus {
        switch permission {
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined

        case .fullDisk:
            // There is no API for this one. The only honest check is to try to
            // read something only Full Disk Access can read — which is also
            // exactly what the feature needing it does.
            return NotificationCenterStore.isReadable ? .granted : .notDetermined

        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined

        case .camera:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .video))

        case .microphone:
            return Self.map(AVCaptureDevice.authorizationStatus(for: .audio))

        case .calendars:
            return Self.map(EKEventStore.authorizationStatus(for: .event))

        case .reminders:
            return Self.map(EKEventStore.authorizationStatus(for: .reminder))

        case .bluetooth:
            switch CBManager.authorization {
            case .allowedAlways:  return .granted
            case .denied, .restricted: return .denied
            default:              return .notDetermined
            }
        }
    }

    private static func map(_ status: AVAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .authorized:   return .granted
        case .denied, .restricted: return .denied
        default:            return .notDetermined
        }
    }

    private static func map(_ status: EKAuthorizationStatus) -> PermissionStatus {
        switch status {
        case .fullAccess, .authorized: return .granted
        case .denied, .restricted:     return .denied
        default:                       return .notDetermined
        }
    }

    // MARK: Requesting

    /// Ask for a permission the best way macOS allows.
    ///
    /// Denied always goes to Settings: once the user has said no, the system
    /// will not prompt again, and calling the request API would do nothing at
    /// all — the single most common way a permissions screen ends up with a
    /// button that appears broken.
    func request(_ permission: MiraPermission) {
        guard status(for: permission) != .denied, permission.isRequestableInApp else {
            openSettings(permission)
            return
        }

        switch permission {
        case .accessibility:
            // The one system prompt that is opened by asking WITH the option
            // set; AXIsProcessTrusted() alone never prompts.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
            _ = AXIsProcessTrustedWithOptions(options as CFDictionary)

        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }

        case .calendars:
            eventStore.requestFullAccessToEvents { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }

        case .reminders:
            eventStore.requestFullAccessToReminders { [weak self] _, _ in
                Task { @MainActor in self?.refresh() }
            }

        case .bluetooth:
            // Authorisation is only requested by actually starting to use
            // CoreBluetooth; there is no standalone request call. Holding the
            // manager is what triggers the prompt.
            bluetoothManager = CBCentralManager(delegate: nil, queue: nil)

        case .fullDisk, .screenRecording:
            openSettings(permission)
        }
    }

    func openSettings(_ permission: MiraPermission) {
        guard let url = permission.settingsURL else { return }
        NSWorkspace.shared.open(url)
    }
}
