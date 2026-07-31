import Foundation
import SwiftUI
import CoreGraphics
import AVFoundation
import EventKit
import CoreBluetooth

// MARK: - Permission model

enum MiraPermission: String, CaseIterable, Identifiable {
    // Onboarding asks for these three, because they are what the first-run
    // demo actually exercises.
    case microphone
    case screenRecording
    case accessibility
    // The rest are requested LATER, by whichever feature needs them, which is
    // how MacNotch does it ("only when the matching feature is enabled"). They
    // live on the same enum so Settings, onboarding and an in-panel prompt can
    // never disagree about what Mira asks for or why.
    case fullDisk
    case camera
    case calendars
    case reminders
    case bluetooth

    /// The subset first-run onboarding walks through.
    static var onboarding: [MiraPermission] { [.microphone, .screenRecording, .accessibility] }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone:      return "Microphone"
        case .screenRecording: return "Screen Recording"
        case .accessibility:   return "Accessibility"
        case .fullDisk:        return "Full Disk Access"
        case .camera:          return "Camera"
        case .calendars:       return "Calendars"
        case .reminders:       return "Reminders"
        case .bluetooth:       return "Bluetooth"
        }
    }

    var icon: String {
        switch self {
        case .microphone:      return "mic.fill"
        case .screenRecording: return "rectangle.on.rectangle"
        case .accessibility:   return "accessibility"
        case .fullDisk:        return "externaldrive"
        case .camera:          return "camera.fill"
        case .calendars:       return "calendar"
        case .reminders:       return "checklist"
        case .bluetooth:       return "wave.3.right"
        }
    }

    // One-line "what you unlock" copy shown below the title
    var reason: String { unlock }
    var unlock: String {
        switch self {
        case .microphone:
            return "So Mira can hear \"Hey Mira\" and your voice commands."
        case .screenRecording:
            return "So Mira can see your screen and point to things."
        case .accessibility:
            return "So background agents can type and click for you."
        case .fullDisk:
            return "So Mira can read your notifications, which macOS keeps in a protected database."
        case .camera:
            return "So the camera panel can show a preview."
        case .calendars:
            return "So Mira can show today's events, Day Progress and meeting alerts."
        case .reminders:
            return "So the Todo module can sync with Reminders."
        case .bluetooth:
            return "So Mira can show device battery levels and warn you before something dies."
        }
    }

    // Step-by-step coaching copy (shown in the orb speech bubble)
    var coachSteps: [String] {
        switch self {
        case .microphone:
            return [
                "Click \"Allow\" when macOS asks about the microphone.",
                "If you don't see a prompt, flip the Mira toggle in System Settings → Privacy → Microphone.",
            ]
        case .screenRecording:
            return [
                "Click \"Open System Settings\" below.",
                "Find Mira in the list and flip its toggle on.",
                "macOS may ask you to quit and reopen Mira — do that and come back.",
            ]
        case .accessibility:
            return [
                "Click \"Open System Settings\" below.",
                "Click the + button and drag Mira into the Accessibility list.",
                "Make sure the toggle next to Mira is on.",
            ]
        case .fullDisk:
            return [
                "Click \"Open System Settings\" below.",
                "Click the + button and add Mira to the Full Disk Access list.",
                "macOS will ask you to quit and reopen Mira — do that and come back.",
            ]
        default:
            return [
                "Click \"Allow\" when macOS asks.",
                "If you don't see a prompt, turn Mira on in System Settings → Privacy.",
            ]
        }
    }

    /// Whether macOS lets an app ask directly, or whether System Settings is
    /// the only route. The distinction matters in the UI: a button labelled
    /// "Allow" that silently opens Settings — or does nothing, because the user
    /// already said no — is how a permissions screen loses people.
    var isRequestableInApp: Bool {
        switch self {
        case .microphone, .camera, .calendars, .reminders, .bluetooth, .accessibility:
            return true
        case .fullDisk, .screenRecording:
            return false
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone:
            return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .screenRecording:
            return CGPreflightScreenCaptureAccess()
        case .accessibility:
            return AXIsProcessTrusted()
        case .fullDisk:
            // No API exists for this. The only honest check is to try reading
            // something only Full Disk Access can read — which is exactly what
            // the feature needing it does anyway.
            return NotificationCenterStore.isReadable
        case .camera:
            return AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        case .calendars:
            return [.fullAccess, .authorized].contains(EKEventStore.authorizationStatus(for: .event))
        case .reminders:
            return [.fullAccess, .authorized].contains(EKEventStore.authorizationStatus(for: .reminder))
        case .bluetooth:
            return CBManager.authorization == .allowedAlways
        }
    }

    var settingsURL: URL? {
        let base = "x-apple.systempreferences:com.apple.preference.security?"
        switch self {
        case .microphone:      return URL(string: base + "Privacy_Microphone")
        case .screenRecording: return URL(string: base + "Privacy_ScreenCapture")
        case .accessibility:   return URL(string: base + "Privacy_Accessibility")
        case .fullDisk:        return URL(string: base + "Privacy_AllFiles")
        case .camera:          return URL(string: base + "Privacy_Camera")
        case .calendars:       return URL(string: base + "Privacy_Calendars")
        case .reminders:       return URL(string: base + "Privacy_Reminders")
        case .bluetooth:       return URL(string: base + "Privacy_Bluetooth")
        }
    }

    /// macOS only re-reads these grants at launch, so the app has to be
    /// restarted before the feature actually starts working. Saying so beats
    /// leaving the user staring at a panel that hasn't changed.
    var needsRelaunch: Bool {
        self == .screenRecording || self == .fullDisk || self == .accessibility
    }
}

// MARK: - Voice persona

struct MiraPersona: Identifiable {
    let id:      MiraVoice
    let tagline: String
    let color:   Color

    static let all: [MiraPersona] = [
        MiraPersona(id: .alloy,   tagline: "I can guide you through any app on your screen.",        color: Color(red: 0.37, green: 0.51, blue: 0.95)),
        MiraPersona(id: .ash,     tagline: "I can run research agents while you stay focused.",       color: Color(red: 0.45, green: 0.75, blue: 0.60)),
        MiraPersona(id: .ballad,  tagline: "I can build websites and apps from a quick description.", color: Color(red: 0.75, green: 0.45, blue: 0.90)),
        MiraPersona(id: .cedar,   tagline: "I can manage your calendar and draft emails hands-free.", color: Color(red: 0.90, green: 0.60, blue: 0.30)),
        MiraPersona(id: .coral,   tagline: "I can take notes, summarize meetings, and remember things.", color: Color(red: 0.90, green: 0.40, blue: 0.45)),
        MiraPersona(id: .echo,    tagline: "I can control Spotify, set reminders, and open anything.", color: Color(red: 0.30, green: 0.80, blue: 0.85)),
        MiraPersona(id: .marin,   tagline: "I can coordinate multiple agents on complex projects.",   color: Color(red: 0.55, green: 0.45, blue: 0.90)),
        MiraPersona(id: .sage,    tagline: "I can write code, debug issues, and explain how things work.", color: Color(red: 0.40, green: 0.85, blue: 0.55)),
        MiraPersona(id: .shimmer, tagline: "I can teach you any topic at your own pace.",             color: Color(red: 0.95, green: 0.75, blue: 0.30)),
        MiraPersona(id: .verse,   tagline: "I can be your always-on thinking partner.",               color: Color(red: 0.65, green: 0.50, blue: 0.95)),
    ]
}

// MARK: - Discovery channel

enum DiscoveryChannel: String, CaseIterable, Identifiable {
    case twitter     = "X / Twitter"
    case youtube     = "YouTube"
    case reddit      = "Reddit"
    case productHunt = "Product Hunt"
    case friend      = "A friend"
    case podcast     = "Podcast"
    case other       = "Other"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .twitter:     return "bubble.left.and.bubble.right"
        case .youtube:     return "play.rectangle"
        case .reddit:      return "antenna.radiowaves.left.and.right"
        case .productHunt: return "rocket"
        case .friend:      return "person.2"
        case .podcast:     return "headphones"
        case .other:       return "ellipsis"
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

    // Discovery channel — saved locally and can be synced to backend later
    var discoveryChannel: DiscoveryChannel? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "mira_discovery_channel") else { return nil }
            return DiscoveryChannel(rawValue: raw)
        }
        set { UserDefaults.standard.set(newValue?.rawValue, forKey: "mira_discovery_channel") }
    }

    var discoveryChannelOther: String {
        get { UserDefaults.standard.string(forKey: "mira_discovery_other") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "mira_discovery_other") }
    }

    // Agent working folder — defaults to ~/Documents/Mira
    var agentFolderURL: URL {
        get {
            if let bookmark = UserDefaults.standard.data(forKey: "mira_agent_folder_bookmark") {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: bookmark,
                                      options: .withSecurityScope,
                                      relativeTo: nil,
                                      bookmarkDataIsStale: &stale), !stale {
                    return url
                }
            }
            return defaultAgentFolder
        }
        set {
            let bookmark = try? newValue.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)
            UserDefaults.standard.set(bookmark, forKey: "mira_agent_folder_bookmark")
            UserDefaults.standard.set(newValue.path, forKey: "mira_agent_folder_path")
        }
    }

    var agentFolderPath: String {
        UserDefaults.standard.string(forKey: "mira_agent_folder_path")
            ?? defaultAgentFolder.path
    }

    private var defaultAgentFolder: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent("Mira")
    }

    func createDefaultAgentFolder() {
        let url = defaultAgentFolder
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 640),
            styleMask:   [.titled, .closable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        w.titlebarAppearsTransparent = true
        w.titleVisibility            = .hidden
        w.isMovableByWindowBackground = true
        w.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0)
        w.contentViewController = hosting
        w.center()
        window = w
    }
}
