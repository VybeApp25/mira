import SwiftUI

/// Stepped clarification panel that sits above the input bar.
/// Guides the user through structured questions before launching an agent task.
struct ClarificationCard: View {
    @Binding var spec: ClarificationSpec?
    let onComplete: (String) -> Void

    @State private var currentStep = 0
    @State private var textInput   = ""

    private let accent   = DS.Colors.accent
    private let surface  = Color.white.opacity(0.04)
    private let divider  = Color.white.opacity(0.08)

    private var stepData: ClarificationStep? {
        guard let s = spec, currentStep < s.steps.count else { return nil }
        return s.steps[currentStep]
    }

    var body: some View {
        if let s = spec, let step = stepData {
            VStack(alignment: .leading, spacing: 10) {
                header(spec: s, step: step)
                if let options = step.options {
                    chipList(options: options)
                } else {
                    textInputRow(step: step)
                }
                footerRow(step: step, totalSteps: s.steps.count)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(surface)
            .overlay(Rectangle().frame(height: 0.5).foregroundColor(divider), alignment: .top)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    // MARK: - Sub-views

    private func header(spec: ClarificationSpec, step: ClarificationStep) -> some View {
        HStack(alignment: .top) {
            Text(step.question)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.90))
            Spacer()
            Text("\(currentStep + 1) of \(spec.steps.count)")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.28))
                .padding(.top, 2)
        }
    }

    private func chipList(options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    selectOption(option)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                            .frame(width: 13, height: 13)
                        Text(option)
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.82))
                        Spacer()
                    }
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func textInputRow(step: ClarificationStep) -> some View {
        HStack(spacing: 8) {
            TextField(step.placeholder ?? "Type your answer...", text: $textInput)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .tint(accent)
                .onSubmit { submitText(step: step) }

            Button { submitText(step: step) } label: {
                Image(systemName: "arrow.right.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(canSubmitText(step: step) ? accent : .white.opacity(0.15))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmitText(step: step))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func footerRow(step: ClarificationStep, totalSteps: Int) -> some View {
        HStack {
            if currentStep > 0 {
                Button("← Back") {
                    currentStep -= 1
                    textInput = ""
                }
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.28))
                .buttonStyle(.plain)
            }
            Spacer()
            if step.isOptional {
                Button("Skip") { advance(answer: nil) }
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.28))
                    .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func canSubmitText(step: ClarificationStep) -> Bool {
        !textInput.trimmingCharacters(in: .whitespaces).isEmpty || step.isOptional
    }

    private func selectOption(_ option: String) {
        guard let s = stepData else { return }
        spec?.answers[s.key] = option
        advance(answer: option)
    }

    private func submitText(step: ClarificationStep) {
        let value = textInput.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty { spec?.answers[step.key] = value }
        textInput = ""
        advance(answer: value.isEmpty ? nil : value)
    }

    private func advance(answer: String?) {
        let stepCount = spec?.steps.count ?? 0
        if currentStep + 1 < stepCount {
            withAnimation(.easeInOut(duration: 0.18)) { currentStep += 1 }
        } else {
            let assembled = spec?.assembledPrompt() ?? ""
            withAnimation(.easeOut(duration: 0.15)) { spec = nil }
            if !assembled.isEmpty { onComplete(assembled) }
        }
    }
}
