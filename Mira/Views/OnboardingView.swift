import SwiftUI
import CoreGraphics

// MARK: - Design tokens

private let bg      = Color(red: 0.09, green: 0.09, blue: 0.11)
private let surface = Color(red: 0.13, green: 0.13, blue: 0.16)
private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)

// MARK: - Try-it entry

private struct TryItEntry: Identifiable {
    let id     = UUID()
    let prompt: String
    let icon:   String
    let blurb:  String
}

private let tryItEntries: [TryItEntry] = [
    TryItEntry(prompt: "Build me a website",
               icon: "globe",
               blurb: "Mira asks what kind of site before building"),
    TryItEntry(prompt: "Play SZA on Spotify",
               icon: "music.note",
               blurb: "Mira controls Spotify directly — no typing needed"),
    TryItEntry(prompt: "Show me where dark mode is",
               icon: "cursorarrow.rays",
               blurb: "Mira highlights it on your screen with an overlay"),
    TryItEntry(prompt: "Research the best AI tools in 2026",
               icon: "magnifyingglass",
               blurb: "Mira runs a background research agent and reports back"),
]

// MARK: - Route badge color

private func routeColor(_ route: MiraRoute) -> Color {
    switch route {
    case .clarificationRequired:          return accent
    case .spotifyControl:                 return Color(red: 0.11, green: 0.73, blue: 0.33)
    case .screenGuidance:                 return Color(red: 0.75, green: 0.35, blue: 0.95)
    case .agentTask, .websiteBuilder:     return Color(red: 1.0,  green: 0.70, blue: 0.20)
    case .confirmationRequired:           return .orange
    case .memoryWrite, .memoryQuery:      return Color(red: 0.40, green: 0.80, blue: 0.90)
    default:                              return .white.opacity(0.50)
    }
}

// MARK: - Main view

struct OnboardingView: View {
    let onDismiss: () -> Void

    @State private var step          = 0
    @State private var activatedCard: UUID? = nil
    @StateObject private var service = OnboardingService.shared

    private var missing: [MiraPermission] { service.missingPermissions() }
    private var permStep:    Int { 2 }
    private var doneIndex:   Int { missing.isEmpty ? 2 : 3 }
    private var totalSteps:  Int { doneIndex + 1 }

    var body: some View {
        VStack(spacing: 0) {
            // ── Drag handle + close ──────────────────────────────────────
            HStack {
                Spacer()
                Button { onDismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.20))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            // ── Page content ─────────────────────────────────────────────
            stepContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(step)
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal:   .move(edge: .leading).combined(with: .opacity)
                ))
                .animation(.easeInOut(duration: 0.25), value: step)

            // ── Step dots ─────────────────────────────────────────────────
            HStack(spacing: 6) {
                ForEach(0..<totalSteps, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(i == step ? accent : Color.white.opacity(0.15))
                        .frame(width: i == step ? 18 : 6, height: 6)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.bottom, 24)
        }
        .background(bg.ignoresSafeArea())
    }

    // MARK: - Step router

    @ViewBuilder
    private var stepContent: some View {
        switch step {
        case 0:           welcomeStep
        case 1:           tryItStep
        case permStep where !missing.isEmpty: permissionsStep
        default:          doneStep
        }
    }

    // MARK: - Welcome

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            Spacer()

            // Logo
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "eye.fill")
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(accent)
            }
            .padding(.bottom, 24)

            // Headline
            Text("Meet Mira.")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.bottom, 10)

            Text("Your always-on Mac companion.")
                .font(.system(size: 15))
                .foregroundColor(.white.opacity(0.55))
                .padding(.bottom, 32)

            // Capability pills
            HStack(spacing: 10) {
                ForEach([
                    ("bubble.left.fill",  "Chat"),
                    ("cpu",               "Agents"),
                    ("rectangle.on.rectangle", "Screen"),
                    ("music.note",        "Music"),
                ], id: \.1) { icon, label in
                    capabilityPill(icon: icon, label: label)
                }
            }
            .padding(.bottom, 40)

            Spacer()

            nextButton(label: "Show me how") { step = 1 }
                .padding(.horizontal, 36)
                .padding(.bottom, 20)
        }
    }

    private func capabilityPill(icon: String, label: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(accent)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
        }
        .frame(width: 74, height: 56)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Try-it

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("See how Mira routes requests")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text("Every prompt is classified before anything runs.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.40))
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(tryItEntries) { entry in
                        tryItCard(entry: entry)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            nextButton(label: "Continue") { step = missing.isEmpty ? doneIndex : permStep }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
    }

    private func tryItCard(entry: TryItEntry) -> some View {
        let activated = activatedCard == entry.id
        let decision  = RouterService.shared.route(prompt: entry.prompt, context: RouterContext())

        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: entry.icon)
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.55))
                    .frame(width: 20)

                Text("\"\(entry.prompt)\"")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))

                Spacer()

                if !activated {
                    Button("Try it") {
                        withAnimation(.easeInOut(duration: 0.2)) { activatedCard = entry.id }
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(accent)
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            if activated {
                Divider().background(Color.white.opacity(0.06))
                HStack(spacing: 8) {
                    Text(decision.route.displayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(routeColor(decision.route))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(routeColor(decision.route).opacity(0.12))
                        .clipShape(Capsule())

                    Text(entry.blurb)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(2)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(activated ? routeColor(decision.route).opacity(0.30) : Color.clear)
        )
        .animation(.easeInOut(duration: 0.2), value: activated)
    }

    // MARK: - Permissions

    private var permissionsStep: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("A few settings help Mira do more")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(.white)
                Text("Mira only asks for what actually unlocks new capabilities.")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.40))
            }
            .padding(.horizontal, 28)
            .padding(.top, 12)
            .padding(.bottom, 16)

            ScrollView(showsIndicators: false) {
                VStack(spacing: 8) {
                    ForEach(missing) { permission in
                        permissionCard(permission)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 8)
            }

            nextButton(label: "Continue") { step = doneIndex }
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
        }
    }

    private func permissionCard(_ permission: MiraPermission) -> some View {
        HStack(spacing: 14) {
            ZStack {
                Circle()
                    .fill(accent.opacity(0.12))
                    .frame(width: 40, height: 40)
                Image(systemName: permission.icon)
                    .font(.system(size: 16))
                    .foregroundColor(accent)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Text(permission.reason)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            Button("Allow →") {
                if permission == .microphone {
                    Task { await service.requestMicrophone() }
                } else {
                    service.openSettings(for: permission)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(accent)
            .buttonStyle(.plain)
        }
        .padding(14)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: - Done

    private var doneStep: some View {
        VStack(spacing: 0) {
            Spacer()

            ZStack {
                Circle()
                    .fill(Color(red: 0.11, green: 0.73, blue: 0.33).opacity(0.12))
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundColor(Color(red: 0.11, green: 0.73, blue: 0.33))
            }
            .padding(.bottom, 24)

            Text("You're all set.")
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .padding(.bottom, 10)

            Text("Mira is ready. Try:")
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.50))
                .padding(.bottom, 20)

            VStack(alignment: .leading, spacing: 8) {
                ForEach([
                    ("\"Build me a website\"", "globe"),
                    ("\"What's on my calendar?\"", "calendar"),
                    ("Say \"Hey Mira\" to activate voice", "mic.fill"),
                ], id: \.0) { line, icon in
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.system(size: 12))
                            .foregroundColor(accent.opacity(0.70))
                            .frame(width: 16)
                        Text(line)
                            .font(.system(size: 13))
                            .foregroundColor(.white.opacity(0.65))
                    }
                }
            }
            .padding(.horizontal, 48)

            Spacer()

            Button {
                service.completeSetup()
                onDismiss()
            } label: {
                Text("Start using Mira")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 44)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 36)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Shared button

    private func nextButton(label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(accent)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
