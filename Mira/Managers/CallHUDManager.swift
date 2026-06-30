import Cocoa
import SwiftUI

// MARK: - CallHUDManager
//
// Phase C/D UI for the meeting assistant. Owns:
//   • a side notification card (NSPanel, top-right) — prompts to transcribe a
//     detected call, then shows live elapsed + caller + source while recording;
//   • the iMessage-style transcript window (NSWindow) opened from the card.
//
// Consent-safe: a detected call only *offers* to transcribe. Capture (and the
// AssemblyAI sockets) start when the user taps Start — see CallCaptureService.

@MainActor
final class CallHUDManager {
    static let shared = CallHUDManager()
    private init() {}

    private let model = CallHUDModel()
    private var cardPanel: NSPanel?
    private var transcriptWindow: NSWindow?

    // MARK: Launch wiring

    /// Start watching for calls. Call once at launch (e.g. from NotchManager).
    func start() {
        let detector = CallDetector.shared
        detector.onCallStart = { [weak self] source in self?.offerTranscription(source) }
        detector.onCallEnd   = { [weak self] in self?.detectedCallEnded() }
        detector.start()

        // Auto-end a live transcription when its call app quits. (When the call
        // ends but the app stays open, the ✕ on the card is the manual stop —
        // detecting hang-up without quitting needs a deeper signal, a follow-up.)
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let session = self.model.session,
                      let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bid = app.bundleIdentifier,
                      session.source.bundleIdentifiers.contains(bid) else { return }
                self.endTranscribing()
            }
        }
    }

    // MARK: Detector → consent prompt

    private func offerTranscription(_ source: CallSource) {
        guard model.session == nil else { return }   // already transcribing
        model.promptSource = source
        showCard()
    }

    private func detectedCallEnded() {
        // If the user never started transcribing, drop the prompt. If a session is
        // live we leave it running — they end it explicitly from the card.
        if model.session == nil {
            model.promptSource = nil
            hideCard()
        }
    }

    // MARK: Card actions

    private func beginTranscribing() {
        guard let source = model.promptSource else { return }
        CallCaptureService.shared.startCall(source: source)
        model.session = CallCaptureService.shared.current
        model.promptSource = nil
        showCard()
        openTranscriptWindow()
    }

    private func endTranscribing() {
        CallCaptureService.shared.endCall()
        model.session = nil
        closeTranscriptWindow()
        hideCard()
    }

    private func dismissPrompt() {
        model.promptSource = nil
        hideCard()
    }

    /// Close button: stops a live session, or dismisses an unstarted prompt.
    private func handleClose() {
        if model.session != nil { endTranscribing() } else { dismissPrompt() }
    }

    // MARK: Card panel

    private func showCard() {
        if cardPanel == nil { makeCardPanel() }
        positionCard()
        cardPanel?.orderFrontRegardless()
    }

    private func hideCard() {
        cardPanel?.orderOut(nil)
    }

    private func makeCardPanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 264, height: 64),
            styleMask:   [.borderless, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        panel.isOpaque            = false
        panel.backgroundColor     = .clear
        panel.hasShadow           = false
        panel.level               = .statusBar
        panel.collectionBehavior  = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.isFloatingPanel     = true
        panel.hidesOnDeactivate   = false

        let card = CallCardView(
            model:   model,
            onStart: { [weak self] in self?.beginTranscribing() },
            onOpen:  { [weak self] in self?.openTranscriptWindow() },
            onClose: { [weak self] in self?.handleClose() }
        )
        let host = NSHostingView(rootView: card)
        host.frame = NSRect(x: 0, y: 0, width: 264, height: 64)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        cardPanel = panel
    }

    private func positionCard() {
        guard let panel = cardPanel, let screen = NSScreen.main else { return }
        let vf = screen.visibleFrame
        let size = panel.frame.size
        let inset: CGFloat = 16
        let origin = NSPoint(x: vf.minX + inset, y: vf.maxY - size.height - inset)
        panel.setFrameOrigin(origin)
    }

    // MARK: Transcript window

    private func openTranscriptWindow() {
        guard let session = model.session ?? CallCaptureService.shared.current else { return }

        if transcriptWindow == nil {
            let win = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 420, height: 560),
                styleMask:   [.titled, .closable, .resizable, .fullSizeContentView],
                backing:     .buffered,
                defer:       false
            )
            win.title                       = "Call Transcript"
            win.titlebarAppearsTransparent  = true
            win.isReleasedWhenClosed         = false
            win.center()
            transcriptWindow = win
        }
        transcriptWindow?.contentView = NSHostingView(rootView: CallTranscriptView(session: session))
        transcriptWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closeTranscriptWindow() {
        transcriptWindow?.orderOut(nil)
    }
}
