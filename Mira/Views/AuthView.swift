import SwiftUI
import AuthenticationServices

struct AuthView: View {
    /// Compact = embedded in Settings (no big header); else onboarding styling.
    var compact: Bool = false
    /// Called once a real Supabase session exists.
    var onAuthenticated: () -> Void = {}

    @ObservedObject private var account = AccountService.shared

    private enum Mode { case signIn, signUp, confirmEmail }
    @State private var mode: Mode = .signUp
    @State private var email = ""
    @State private var password = ""
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false

    private let accent  = DS.Colors.accent
    private let surface = Color(red: 0.13, green: 0.13, blue: 0.16)

    private var isLoading: Bool { busy || account.authState == .loading }

    private var canSubmit: Bool {
        guard !isLoading else { return false }
        guard email.contains("@"), email.contains("."), password.count >= 6 else { return false }
        return true
    }

    var body: some View {
        if mode == .confirmEmail {
            confirmEmailView
        } else {
            formView
        }
    }

    private var confirmEmailView: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.checkmark")
                .font(.system(size: 40))
                .foregroundColor(accent)
                .padding(.top, compact ? 8 : 24)
            Text("Check your email")
                .font(.system(size: 17, weight: .semibold))
                .foregroundColor(.white)
            Text("We sent a confirmation link to **\(email)**. Click it to activate your account, then come back and sign in.")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.50))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                withAnimation { mode = .signIn; error = nil }
            } label: {
                Text("Go to sign in")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(accent)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .padding(.horizontal, compact ? 0 : 8)
    }

    private var formView: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !compact {
                VStack(alignment: .leading, spacing: 4) {
                    Text(mode == .signUp ? "Create your account" : "Welcome back")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(.white)
                    Text("Mira keeps your API keys on its servers — sign in to use it securely.")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.40))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.bottom, 18)
            }

            VStack(spacing: 10) {
                if mode == .signUp {
                    field(icon: "person", placeholder: "Name (optional)", text: $name, secure: false)
                }
                field(icon: "envelope", placeholder: "Email", text: $email, secure: false)
                field(icon: "lock", placeholder: "Password (6+ characters)", text: $password, secure: true)
            }

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(.orange)
                    .padding(.top, 10)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button(action: { Task { await submit() } }) {
                HStack(spacing: 8) {
                    if isLoading { ProgressView().controlSize(.small).tint(.white) }
                    Text(mode == .signUp ? "Create account" : "Sign in")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(canSubmit ? accent : accent.opacity(0.35))
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .padding(.top, 14)

            HStack(spacing: 10) {
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                Text("or").font(.system(size: 11)).foregroundColor(.white.opacity(0.30))
                Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
            }
            .padding(.top, 14)

            SignInWithAppleButton(.continue, onRequest: { request in
                request.requestedScopes = [.fullName, .email]
            }, onCompletion: { result in
                switch result {
                case .success(let auth):
                    AccountService.shared.handleAppleAuthorization(auth)
                case .failure:
                    break
                }
            })
            .signInWithAppleButtonStyle(.white)
            .frame(height: 42)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .padding(.top, 8)

            if mode == .signUp {
                legalBlurb
            }

            Button {
                withAnimation { mode = (mode == .signUp ? .signIn : .signUp); error = nil }
            } label: {
                Text(mode == .signUp ? "Already have an account? Sign in"
                                     : "New to Mira? Create an account")
                    .font(.system(size: 12))
                    .foregroundColor(accent)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
        }
        // Apple sign-in completes asynchronously via AccountService's delegate;
        // observe the published state so onboarding advances either way.
        .onChange(of: account.authState) { _, newValue in
            if case .signedIn = newValue { onAuthenticated() }
        }
    }

    private var legalBlurb: some View {
        HStack(spacing: 0) {
            Text("By creating an account you agree to our ")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.30))
            Button("Terms") {
                NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/terms.html")!)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.45))
            Text(" and ")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.30))
            Button("Privacy Policy") {
                NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/privacy.html")!)
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundColor(.white.opacity(0.45))
            Text(".")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.30))
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    @ViewBuilder
    private func field(icon: String, placeholder: String, text: Binding<String>, secure: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.35))
                .frame(width: 18)
            Group {
                if secure {
                    SecureField(placeholder, text: text)
                } else {
                    TextField(placeholder, text: text)
                }
            }
            .textFieldStyle(.plain)
            .font(.system(size: 13))
            .foregroundColor(.white)
            .autocorrectionDisabled(true)
            .onSubmit { Task { await submit() } }
        }
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(surface)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @MainActor
    private func submit() async {
        guard canSubmit else { return }
        error = nil
        busy = true
        defer { busy = false }
        do {
            if mode == .signIn {
                try await account.signIn(email: email.trimmingCharacters(in: .whitespaces), password: password)
                // onAuthenticated fires via the authState onChange above.
            } else {
                let display = name.trimmingCharacters(in: .whitespaces)
                let fallback = email.components(separatedBy: "@").first ?? "there"
                try await account.signUp(email: email.trimmingCharacters(in: .whitespaces),
                                         password: password,
                                         name: display.isEmpty ? fallback : display)
                // Signup always requires email confirmation — show the check-email screen.
                withAnimation { mode = .confirmEmail }
            }
        } catch {
            self.error = friendly(error)
        }
    }

    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("invalid login") || msg.contains("credentials") {
            return "Wrong email or password."
        }
        if msg.contains("already registered") || msg.contains("already been registered") || msg.contains("user already") {
            return "That email already has an account — try signing in."
        }
        if msg.contains("password") && msg.contains("6") {
            return "Password must be at least 6 characters."
        }
        if msg.contains("network") || msg.contains("offline") || msg.contains("connection") {
            return "Network error — check your connection and try again."
        }
        return error.localizedDescription
    }
}
