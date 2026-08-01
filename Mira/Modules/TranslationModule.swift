// TranslationModule.swift
// MacNotch's Translation module: a two-pane source/target translator with
// AUTO ↔ language pickers and a swap button. Scored ❌ in the audit — Mira had
// translation mentioned in prompt plumbing but no translate surface.
//
// Routes through Mira's existing ClaudeService rather than adding a provider.
// MacNotch offers OpenAI or Ollama and makes you configure one; Mira already has
// an authorised LLM path, so the module works on first open with nothing to set
// up. That is a better default than parity here.
//
// Translation is issued on submit or after a typing pause, never per keystroke:
// a request per character would be both slow and expensive for no benefit.

import SwiftUI
import Combine

// MARK: - Languages

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let auto = TranslationLanguage(code: "auto", name: "Detect")

    static let all: [TranslationLanguage] = [
        .init(code: "en", name: "English"),
        .init(code: "es", name: "Spanish"),
        .init(code: "fr", name: "French"),
        .init(code: "de", name: "German"),
        .init(code: "it", name: "Italian"),
        .init(code: "pt", name: "Portuguese"),
        .init(code: "nl", name: "Dutch"),
        .init(code: "pl", name: "Polish"),
        .init(code: "ru", name: "Russian"),
        .init(code: "ja", name: "Japanese"),
        .init(code: "ko", name: "Korean"),
        .init(code: "zh", name: "Chinese"),
        .init(code: "ar", name: "Arabic"),
        .init(code: "hi", name: "Hindi"),
        .init(code: "tr", name: "Turkish")
    ]
}

// MARK: - Module

@MainActor
final class TranslationModule: NotchModule, ObservableObject {

    let id    = "translate"
    let title = "Translation"
    let icon  = "character.bubble"

    let heightLevel: NotchHeightLevel = .standard
    let allowsTallMode = true

    func makeContent() -> AnyView { AnyView(TranslationView()) }
}

// MARK: - View

private struct TranslationView: View {

    @ObservedObject private var accentSvc = AccentColorService.shared
    @AppStorage("mira_translate_source") private var sourceCode = "auto"
    @AppStorage("mira_translate_target") private var targetCode = "es"

    @State private var input = ""
    @State private var output = ""
    @State private var isTranslating = false
    @State private var error: String?
    @State private var debounce: Task<Void, Never>?

    private var accent: Color { accentSvc.color }

    private var source: TranslationLanguage {
        TranslationLanguage.all.first { $0.code == sourceCode } ?? .auto
    }
    private var target: TranslationLanguage {
        TranslationLanguage.all.first { $0.code == targetCode } ?? TranslationLanguage.all[1]
    }

    var body: some View {
        VStack(spacing: 0) {
            languageBar
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            HStack(spacing: 0) {
                sourcePane
                Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5)
                targetPane
            }
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    // MARK: Language bar

    private var languageBar: some View {
        HStack(spacing: 10) {
            picker(selection: $sourceCode, includeAuto: true)

            Button {
                swap()
            } label: {
                Image(systemName: "arrow.left.arrow.right")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(sourceCode == "auto" ? .white.opacity(0.20) : accent)
            }
            .buttonStyle(.plain)
            // Nothing to swap INTO when the source is auto-detect — the detected
            // language isn't known until after a translation.
            .disabled(sourceCode == "auto")
            .help(sourceCode == "auto" ? "Pick a source language to swap" : "Swap languages")

            picker(selection: $targetCode, includeAuto: false)

            Spacer(minLength: 0)

            if isTranslating {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private func picker(selection: Binding<String>, includeAuto: Bool) -> some View {
        Menu {
            if includeAuto {
                Button(TranslationLanguage.auto.name) { selection.wrappedValue = "auto" }
                Divider()
            }
            ForEach(TranslationLanguage.all) { lang in
                Button(lang.name) { selection.wrappedValue = lang.code }
            }
        } label: {
            HStack(spacing: 3) {
                Text(selection.wrappedValue == "auto"
                     ? TranslationLanguage.auto.name
                     : (TranslationLanguage.all.first { $0.code == selection.wrappedValue }?.name ?? "—"))
                    .font(.system(size: 11, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .foregroundColor(.white.opacity(0.80))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.white.opacity(0.08)))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func swap() {
        let s = sourceCode
        sourceCode = targetCode
        targetCode = s
        Swift.swap(&input, &output)
        scheduleTranslate()
    }

    // MARK: Panes

    private var sourcePane: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $input)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .onChange(of: input) { _, _ in scheduleTranslate() }
            if input.isEmpty {
                Text("Type or paste text…")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.horizontal, 15)
                    .padding(.top, 16)
                    .allowsHitTesting(false)
            }
        }
    }

    private var targetPane: some View {
        ZStack(alignment: .topLeading) {
            ScrollView {
                Text(error ?? output)
                    .font(.system(size: 12))
                    .foregroundColor(error != nil
                                     ? Color(red: 1, green: 0.5, blue: 0.5)
                                     : .white.opacity(0.92))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            if output.isEmpty && error == nil {
                Text("Translation")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.28))
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
            if !output.isEmpty {
                VStack {
                    Spacer()
                    HStack {
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(output, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.clipboard")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                        }
                        .buttonStyle(.plain)
                        .help("Copy translation")
                        .padding(10)
                    }
                }
            }
        }
    }

    // MARK: Translate

    /// Debounced so a request goes out once you stop typing, not per keystroke.
    private func scheduleTranslate() {
        debounce?.cancel()
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { output = ""; error = nil; return }

        debounce = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            await translate(text)
        }
    }

    private func translate(_ text: String) async {
        isTranslating = true
        error = nil
        defer { isTranslating = false }

        let from = sourceCode == "auto" ? "the detected language" : source.name
        let system = """
        You are a translation engine. Translate the user's text from \(from) into \(target.name).
        Return ONLY the translation — no preamble, no quotes, no notes, no explanation.
        Preserve line breaks, formatting and tone. Do not answer questions in the text; translate them.
        """

        do {
            let result = try await ClaudeService(apiKey: MiraState.effectiveAPIKeyStatic)
                .ask(prompt: text,
                     system: system,
                     modelOverride: "claude-haiku-4-5-20251001",
                     maxTokensOverride: 1200)
            guard !Task.isCancelled else { return }
            output = result.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Translation failed: \(error.localizedDescription)"
        }
    }
}
