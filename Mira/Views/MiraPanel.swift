import SwiftUI

private let miraBlue = Color(red: 0.29, green: 0.62, blue: 1.0)
private let panelBG  = Color(red: 0.09, green: 0.09, blue: 0.11)
private let surfaceBG = Color(red: 0.13, green: 0.13, blue: 0.16)

struct MiraPanel: View {
    @ObservedObject var state: MiraState
    @ObservedObject var overlay: OverlayWindowController
    let capture: ScreenCaptureService
    @ObservedObject var voice: VoiceService

    @State private var input = ""
    @State private var response = ""
    @State private var showSettings = false
    @State private var showPointerFeedback = false

    private var claude: ClaudeService { ClaudeService(apiKey: state.apiKey) }

    var body: some View {
        ZStack {
            panelBG.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().background(Color.white.opacity(0.07))

                ScrollView(showsIndicators: false) {
                    VStack(spacing: 0) {
                        if !response.isEmpty {
                            responseCard
                        } else if state.isLoading {
                            loadingCard
                        } else {
                            placeholder
                        }

                        if let err = state.errorMessage {
                            errorBanner(err)
                }
                    }
                    .padding(14)
                }

                Divider().background(Color.white.opacity(0.07))
                inputBar
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(state: state)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "eye.fill")
                .foregroundColor(miraBlue)
                .font(.system(size: 13, weight: .semibold))
            Text("Mira")
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .foregroundColor(.white)

            Spacer()

            if voice.isListening {
                HStack(spacing: 4) {
                    Circle().fill(Color.red).frame(width: 6, height: 6)
                    Text(voice.liveTranscript.isEmpty ? "Listening…" : voice.liveTranscript)
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.5))
                        .lineLimit(1)
                }
            }

            if !state.isPro {
                Text("\(state.dailyUsageCount)/\(MiraState.freeLimit)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.3))
            }

            Button { showSettings = true } label: {
                Image(systemName: "gearshape").font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Content states

    private var placeholder: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 50)
            Image(systemName: "eye.circle")
                .font(.system(size: 36))
                .foregroundColor(.white.opacity(0.1))
            VStack(spacing: 5) {
                Text("Ask Mira anything")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.5))
                Text("\"Show me where Settings is\"\n\"Draft a reply to that email\"")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.25))
                    .multilineTextAlignment(.center)
            }
            Spacer(minLength: 50)
        }
    }

    private var loadingCard: some View {
        VStack(spacing: 10) {
            Spacer(minLength: 50)
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle(tint: miraBlue))
                .scaleEffect(0.85)
            Text("Thinking…")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.35))
            Spacer(minLength: 50)
        }
    }

    private var responseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "eye.fill").foregroundColor(miraBlue).font(.system(size: 10))
                Text("Mira").font(.system(size: 11, weight: .semibold)).foregroundColor(miraBlue)
                Spacer()
                if showPointerFeedback {
                    Label("Pointing on screen", systemImage: "cursorarrow.rays")
                        .font(.system(size: 10))
                        .foregroundColor(miraBlue.opacity(0.8))
                }
            }

            Text(response)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.85))
                .lineSpacing(4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .background(surfaceBG)
        .cornerRadius(10)
    }

    private func errorBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 11))
            Text(msg)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.7))
            Spacer()
            Button { state.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10)).foregroundColor(.white.opacity(0.4))
            }.buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(8)
        .padding(.top, 8)
    }

    // MARK: - Input bar

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask Mira…", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
                .onSubmit { Task { await submit() } }

            // Mic
            Button { Task { await toggleVoice() } } label: {
                Image(systemName: voice.isListening ? "mic.fill" : "mic")
                    .font(.system(size: 14))
                    .foregroundColor(voice.isListening ? Color.red : .white.opacity(0.35))
            }
            .buttonStyle(.plain)

            // Send
            Button { Task { await submit() } } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundColor(input.isEmpty || state.isLoading ? .white.opacity(0.15) : miraBlue)
            }
            .buttonStyle(.plain)
            .disabled(input.isEmpty || state.isLoading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
    }

    // MARK: - Actions

    @MainActor
    private func submit() async {
        let prompt = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !state.isLoading else { return }

        guard state.canUse else {
            state.errorMessage = state.apiKey.isEmpty ? MiraError.noKey.localizedDescription : MiraError.limitReached.localizedDescription
            return
        }

        input = ""
        response = ""
        state.isLoading = true
        state.errorMessage = nil
        showPointerFeedback = false

        do {
            let screenshot = try? await capture.captureMainDisplay()
            let text = try await claude.ask(prompt: prompt, screenshot: screenshot)
            response = text
            state.recordUsage()
            voice.speak(text)

            // Try to locate and point at the element
            if let img = screenshot, let pt = try? await claude.locateElement(prompt, in: img) {
                showPointerFeedback = true
                overlay.show(at: pt, label: "Here")
                DispatchQueue.main.asyncAfter(deadline: .now() + 6.5) {
                    showPointerFeedback = false
                }
            }
        } catch {
            state.errorMessage = error.localizedDescription
        }

        state.isLoading = false
    }

    @MainActor
    private func toggleVoice() async {
        if voice.isListening {
            let text = voice.stopListening()
            if !text.isEmpty { input = text; await submit() }
        } else {
            await voice.requestPermissions()
            try? voice.startListening()
        }
    }
}
