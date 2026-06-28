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
    // Explicit Terms/Privacy consent — required to create an account (sign-up
    // only; existing users agreed at their own sign-up). Gates both the email
    // "Create account" button and the Apple sign-in button.
    @State private var agreedToTerms = false

    private let accent  = DS.Colors.accent
    private let surface = Color(red: 0.13, green: 0.13, blue: 0.16)

    private var isLoading: Bool { busy || account.authState == .loading }

    private var canSubmit: Bool {
        guard !isLoading else { return false }
        guard email.contains("@"), email.contains("."), password.count >= 6 else { return false }
        if mode == .signUp && !agreedToTerms { return false }   // must accept Terms to create an account
        return true
    }

    /// In sign-up mode, account creation (email or Apple) requires consent.
    private var consentRequiredButMissing: Bool { mode == .signUp && !agreedToTerms }

    /// Whether to surface the "Sign in with Apple" button. ON: uses the browser
    /// web-OAuth flow (no entitlement — native Sign in with Apple can't launch on
    /// a Developer-ID Mac app). A `mira_apple_signin_enabled` override can force
    /// it off. Requires the Supabase Apple provider + the mira://auth-callback
    /// redirect URL to be configured (see docs).
    static var appleSignInEnabled: Bool {
        if UserDefaults.standard.object(forKey: "mira_apple_signin_enabled") != nil {
            return UserDefaults.standard.bool(forKey: "mira_apple_signin_enabled")
        }
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

            if mode == .signUp {
                consentCheckbox
                    .padding(.top, 12)
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

            // "Sign in with Apple" — browser web-OAuth flow (no entitlement; the
            // native flow can't launch on a Developer-ID Mac app). Tapping opens
            // Apple sign-in in the browser; the result returns via mira://auth-callback.
            // A custom button (not SignInWithAppleButton, which only drives the
            // native flow). Can be hidden via the mira_apple_signin_enabled default.
            if Self.appleSignInEnabled {
                HStack(spacing: 10) {
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                    Text("or").font(.system(size: 11)).foregroundColor(.white.opacity(0.30))
                    Rectangle().fill(Color.white.opacity(0.10)).frame(height: 1)
                }
                .padding(.top, 14)

                Button {
                    AccountService.shared.signInWithAppleWeb()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo").font(.system(size: 15))
                        Text("Sign in with Apple").font(.system(size: 14, weight: .medium))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity)
                    .frame(height: 42)
                    .background(Color.white)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
                // Apple sign-in creates an account too — require the same consent.
                .disabled(consentRequiredButMissing)
                .opacity(consentRequiredButMissing ? 0.45 : 1)
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

    // Explicit consent checkbox shown in sign-up mode. The checkbox image and the
    // Terms/Privacy links are siblings (not nested buttons) so taps don't conflict:
    // tapping the box toggles consent; tapping a link opens that document.
    private var consentCheckbox: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: agreedToTerms ? "checkmark.square.fill" : "square")
                .font(.system(size: 16))
                .foregroundColor(agreedToTerms ? accent : .white.opacity(0.40))
                .contentShape(Rectangle())
                .onTapGesture { agreedToTerms.toggle() }

            HStack(spacing: 0) {
                Text("I agree to Mira's ")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.50))
                Button("Terms") {
                    NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/terms.html")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent.opacity(0.9))
                Text(" and ")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.50))
                Button("Privacy Policy") {
                    NSWorkspace.shared.open(URL(string: "https://rdbljrbjsmbfqwwpwwvn.supabase.co/storage/v1/object/public/releases/privacy.html")!)
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(accent.opacity(0.9))
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        if error is MiraAuthError { return error.localizedDescription }
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
