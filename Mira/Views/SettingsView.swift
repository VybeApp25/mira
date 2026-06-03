import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: MiraState
    @Environment(\.dismiss) var dismiss
    @State private var keyInput = ""
    @State private var saved = false

    var body: some View {
        ZStack {
            Color(red: 0.1, green: 0.1, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                    Spacer()
                    Button("Done") { dismiss() }
                        .foregroundColor(Color(red: 0.29, green: 0.62, blue: 1.0))
                        .buttonStyle(.plain)
                        .font(.system(size: 14, weight: .medium))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 14)

                Divider().background(Color.white.opacity(0.08))

                VStack(alignment: .leading, spacing: 20) {
                    // API key section
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Claude API Key", systemImage: "key.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(.white.opacity(0.5))

                        SecureField("sk-ant-api03-...", text: $keyInput)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundColor(.white)
                            .padding(10)
                            .background(Color.white.opacity(0.06))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.1)))

                        Button(action: saveKey) {
                            HStack {
                                Text(saved ? "Saved ✓" : "Save Key")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .foregroundColor(.white)
                            .background(Color(red: 0.29, green: 0.62, blue: 1.0))
                            .cornerRadius(8)
                        }
                        .buttonStyle(.plain)

                        Text("Get a free key at console.anthropic.com")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    }

                    Divider().background(Color.white.opacity(0.08))

                    // Usage + Pro
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Label("Daily usage", systemImage: "chart.bar.fill")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundColor(.white.opacity(0.5))
                            Spacer()
                            Text(state.isPro ? "Pro — unlimited" : "\(state.dailyUsageCount) / \(MiraState.freeLimit)")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundColor(state.isPro ? Color(red: 0.29, green: 0.62, blue: 1.0) : .white.opacity(0.5))
                        }

                        if !state.isPro {
                            Button(action: openProPage) {
                                HStack {
                                    Image(systemName: "bolt.fill")
                                    Text("Upgrade to Pro — $15/mo")
                                }
                                .font(.system(size: 13, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .foregroundColor(Color(red: 0.29, green: 0.62, blue: 1.0))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.29, green: 0.62, blue: 1.0).opacity(0.5)))
                                .cornerRadius(8)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(18)

                Spacer()
            }
        }
        .frame(width: 320, height: 320)
        .onAppear { keyInput = state.apiKey }
    }

    private func saveKey() {
        state.apiKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }

    private func openProPage() {
        NSWorkspace.shared.open(URL(string: "https://getmira.app/pro")!)
    }
}
