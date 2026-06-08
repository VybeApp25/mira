import SwiftUI

/// Appears above the input bar when a route is blocked by a missing permission.
/// Polls every 2 s — calls onGranted() automatically when the user returns from Settings.
struct PermissionRecoveryCard: View {
    let permission: MiraPermission
    let onGranted:  () -> Void   // auto-retry the blocked request
    let onDismiss:  () -> Void

    @State private var pollingTimer: Timer? = nil

    private let amber   = Color(red: 1.0,  green: 0.72, blue: 0.30)
    private let surface = Color(red: 0.14, green: 0.10, blue: 0.05)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            reasonText
            continuationHint
            allowButton
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(amber.opacity(0.06))
        .overlay(Rectangle().frame(height: 0.5).foregroundColor(amber.opacity(0.22)), alignment: .top)
        .onAppear  { startPolling() }
        .onDisappear { stopPolling() }
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    // MARK: - Sub-views

    private var headerRow: some View {
        HStack(spacing: 8) {
            Image(systemName: permission.icon)
                .font(.system(size: 13))
                .foregroundColor(amber)

            VStack(alignment: .leading, spacing: 1) {
                Text("Permission needed")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(amber.opacity(0.80))
                Text(permission.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
            }

            Spacer()

            Button { onDismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.25))
            }
            .buttonStyle(.plain)
        }
    }

    private var reasonText: some View {
        Text(permission.reason)
            .font(.system(size: 12))
            .foregroundColor(.white.opacity(0.50))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var continuationHint: some View {
        Text("Mira will continue automatically once access is granted.")
            .font(.system(size: 11))
            .foregroundColor(.white.opacity(0.30))
            .italic()
    }

    private var allowButton: some View {
        Button {
            if permission == .microphone {
                Task { await OnboardingService.shared.requestMicrophone() }
            } else {
                OnboardingService.shared.openSettings(for: permission)
            }
        } label: {
            HStack(spacing: 6) {
                Text("Open Settings")
                    .font(.system(size: 12, weight: .semibold))
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(.black.opacity(0.85))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(amber)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Polling

    private func startPolling() {
        pollingTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            guard permission.isGranted else { return }
            stopPolling()
            onGranted()
        }
    }

    private func stopPolling() {
        pollingTimer?.invalidate()
        pollingTimer = nil
    }
}
