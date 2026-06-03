import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: MiraState
    @ObservedObject private var memory = MemoryStore.shared
    @Environment(\.dismiss) var dismiss
    @State private var keyInput      = ""
    @State private var saved         = false
    @State private var showOverride  = false
    @State private var selectedVoice: MiraVoice = MiraVoice.saved

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color(red: 0.10, green: 0.10, blue: 0.12).ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.08))

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 20) {
                        keySection
                        Divider().background(Color.white.opacity(0.08))
                        voiceSection
                        Divider().background(Color.white.opacity(0.08))
                        memorySection
                        Divider().background(Color.white.opacity(0.08))
                        usageSection
                    }
                    .padding(18)
                }
            }
        }
        .frame(width: 340, height: 660)
        .onAppear { keyInput = state.userAPIKey }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Settings")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            Button("Done") { dismiss() }
                .foregroundColor(accent)
                .buttonStyle(.plain)
                .font(.system(size: 14, weight: .medium))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    // MARK: - API key section

    @ViewBuilder
    private var keySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("API Key", systemImage: "key.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            if state.usingBundledKey {
                // Bundled key is active — show green status, offer override
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 14))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bundled key active")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                        Text("No setup needed — you're good to go.")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.40))
                    }
                    Spacer()
                    Button(showOverride ? "Cancel" : "Override") {
                        showOverride.toggle()
                        if !showOverride { keyInput = "" }
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                .padding(10)
                .background(Color.green.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.green.opacity(0.20)))
                .cornerRadius(8)

                if showOverride {
                    overrideField
                }
            } else if state.hasKey {
                // User's own key is active
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(accent)
                        .font(.system(size: 12))
                    Text("Custom key active")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.6))
                    Spacer()
                    Button("Clear") {
                        state.userAPIKey = ""
                        keyInput = ""
                    }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .buttonStyle(.plain)
                }
                overrideField
            } else {
                // No bundled key configured
                overrideField
                Text("Get a key at console.anthropic.com")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.30))
            }
        }
    }

    private var overrideField: some View {
        VStack(spacing: 8) {
            SecureField("sk-ant-api03-...", text: $keyInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white)
                .padding(10)
                .background(Color.white.opacity(0.06))
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10)))

            Button(action: saveKey) {
                Text(saved ? "Saved ✓" : "Save Key")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .foregroundColor(.white)
                    .background(accent)
                    .cornerRadius(8)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Voice section

    @ViewBuilder
    private var voiceSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Mira Voice", systemImage: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))

            VStack(spacing: 4) {
                ForEach(MiraVoice.allCases) { v in
                    Button {
                        MiraVoice.saved = v
                        selectedVoice = v
                        NotificationCenter.default.post(name: .miraVoiceChanged, object: nil)
                    } label: {
                        HStack {
                            Text(v.label)
                                .font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.85))
                            Spacer()
                            if selectedVoice == v {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(accent)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(selectedVoice == v ? accent.opacity(0.10) : Color.white.opacity(0.04))
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }

            Text("OpenAI Realtime API · gpt-4o-realtime-preview")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
        }
    }

    // MARK: - Memory section

    @ViewBuilder
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Memory", systemImage: "brain")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.5))
                Spacer()
                if !memory.memories.isEmpty {
                    Button("Clear All") { memory.clear() }
                        .font(.system(size: 11))
                        .foregroundColor(.red.opacity(0.7))
                        .buttonStyle(.plain)
                }
            }

            if memory.memories.isEmpty {
                Text("No memories yet. Mira will learn your preferences over time.")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 3) {
                    ForEach(memory.memories.sorted { $0.confidence > $1.confidence }) { mem in
                        memoryRow(mem)
                    }
                }
            }
        }
    }

    private func memoryRow(_ mem: Memory) -> some View {
        HStack(spacing: 8) {
            Image(systemName: mem.category.icon)
                .font(.system(size: 10))
                .foregroundColor(confidenceColor(mem))
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(mem.key.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.80))
                Text(mem.value)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.45))
            }

            Spacer()

            // Confidence bar
            RoundedRectangle(cornerRadius: 2)
                .fill(confidenceColor(mem).opacity(0.25))
                .frame(width: 36, height: 4)
                .overlay(
                    RoundedRectangle(cornerRadius: 2)
                        .fill(confidenceColor(mem))
                        .frame(width: 36 * mem.confidence, height: 4),
                    alignment: .leading
                )

            Button { memory.delete(id: mem.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.25))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
    }

    private func confidenceColor(_ mem: Memory) -> Color {
        switch mem.confidenceTier {
        case .high:   return Color(red: 0.20, green: 0.84, blue: 0.29)
        case .medium: return Color(red: 1.0,  green: 0.75, blue: 0.20)
        case .low:    return Color(red: 0.75, green: 0.75, blue: 0.75)
        }
    }

    // MARK: - Usage section

    private var usageSection: some View {
        HStack {
            Label("Usage today", systemImage: "chart.bar.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.5))
            Spacer()
            Text(state.usingBundledKey ? "Unlimited" : "\(state.dailyUsageCount) / \(MiraState.freeLimit)")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(state.usingBundledKey ? .green : .white.opacity(0.5))
        }
    }

    // MARK: - Helpers

    private func saveKey() {
        state.userAPIKey = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        saved = true
        showOverride = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saved = false }
    }
}
