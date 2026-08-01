// SupportModule.swift
// MacNotch's Support & Feedback: "Feedback with optional reply email, App help,
// app review / Setapp rating." Scored ❌ in the parity audit — Mira had no
// surface for telling anyone something was wrong.
//
// FEEDBACK GOES THROUGH THE USER'S OWN MAIL CLIENT, not a Mira endpoint.
//
// A send button that posts to a server is the obvious build, and it is the
// wrong one here for two reasons. It would mean Mira transmitting text the user
// wrote — plus whatever diagnostics were attached — with no chance to read it
// first, which is exactly the pattern people are right to distrust. And it would
// mean standing up an endpoint, storing what arrives, and being responsible for
// it. `mailto:` costs neither: the draft opens, the user sees every character
// including the diagnostics, and they press send. Nothing leaves this Mac
// without them doing it.
//
// The diagnostics block is the reason this module earns its slot rather than
// being a link. "It doesn't work" is unactionable; version, macOS build and
// which permissions are actually granted answers most of the follow-up
// questions before they are asked — and permissions are where Mira's failures
// concentrate, since a denied grant looks like a broken feature.
//
// NO APP STORE RATING LINK. MacNotch has one because it ships on the App Store
// and Setapp. Mira ships direct with Sparkle, so the honest equivalent is the
// website, and a button labelled "Rate" that opens a marketing page would be a
// small lie.

import SwiftUI
import AppKit

@MainActor
final class SupportModule: NotchModule, ObservableObject {

    let id    = "support"
    let title = "Support"
    let icon  = "lifepreserver"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    static let siteURL = URL(string: "https://getmira.today")!
    static let feedbackAddress = "support@getmira.today"

    @Published var message = ""
    @Published var replyEmail = ""
    @Published private(set) var copiedDiagnostics = false

    // MARK: Diagnostics

    /// Facts a support reply would otherwise have to ask for. Assembled fresh
    /// rather than cached, so it reflects the state at the moment of writing —
    /// a permission granted five minutes ago should not report as denied.
    static func diagnostics() -> String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build   = info["CFBundleVersion"] as? String ?? "?"
        let os      = ProcessInfo.processInfo.operatingSystemVersionString

        let service = PermissionsService.shared
        let granted = MiraPermission.allCases
            .filter { service.status(for: $0) == PermissionStatus.granted }
            .map(\.title)
        let missing = MiraPermission.allCases
            .filter { service.status(for: $0) != PermissionStatus.granted }
            .map(\.title)

        return """
        Mira \(version) (\(build))
        \(os)
        Granted: \(granted.isEmpty ? "none" : granted.joined(separator: ", "))
        Not granted: \(missing.isEmpty ? "none" : missing.joined(separator: ", "))
        """
    }

    // MARK: Actions

    /// Opens a prefilled draft. The user reads it and sends it — Mira does not.
    func composeFeedback() {
        let body = """
        \(message)


        ---
        \(Self.diagnostics())
        \(replyEmail.isEmpty ? "" : "Reply to: \(replyEmail)")
        """

        var comps = URLComponents()
        comps.scheme = "mailto"
        comps.path = Self.feedbackAddress
        comps.queryItems = [
            URLQueryItem(name: "subject", value: "Mira feedback"),
            URLQueryItem(name: "body", value: body)
        ]
        guard let url = comps.url else { return }
        NSWorkspace.shared.open(url)
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.diagnostics(), forType: .string)
        copiedDiagnostics = true
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedDiagnostics = false
        }
    }

    func openHelp() { NSWorkspace.shared.open(Self.siteURL) }

    func makeContent() -> AnyView { AnyView(SupportView(module: self)) }
}

// MARK: - View

private struct SupportView: View {

    @ObservedObject var module: SupportModule
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Tell us what happened")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.88))

                TextEditor(text: $module.message)
                    .font(.system(size: 11))
                    .scrollContentBackground(.hidden)
                    .foregroundColor(.white.opacity(0.9))
                    .frame(height: 74)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))

                HStack(spacing: 7) {
                    TextField("Email, if you'd like a reply (optional)", text: $module.replyEmail)
                        .textFieldStyle(.plain)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05)))

                    Button(action: module.composeFeedback) {
                        Text("Write email")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(.black)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(accent))
                    }
                    .buttonStyle(.plain)
                    .disabled(module.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                // Says plainly what the button does. "Send" would imply Mira
                // transmits it, and it does not.
                Text("Opens a draft in your mail app with version and permission "
                     + "details attached. Nothing is sent until you send it.")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.34))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider().overlay(Color.white.opacity(0.08))

            HStack(spacing: 8) {
                supportButton("Help & docs", systemImage: "book") { module.openHelp() }
                supportButton(module.copiedDiagnostics ? "Copied" : "Copy diagnostics",
                              systemImage: module.copiedDiagnostics ? "checkmark" : "doc.on.doc") {
                    module.copyDiagnostics()
                }
                Spacer(minLength: 0)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
        .background(Color.black)
    }

    private func supportButton(_ label: String,
                               systemImage: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage).font(.system(size: 10))
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.78))
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }
}
