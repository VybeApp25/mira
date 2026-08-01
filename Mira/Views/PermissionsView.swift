// PermissionsView.swift
// Two surfaces over PermissionsService:
//
//   • PermissionsListView — the whole picture, for Settings. What Mira uses,
//     what state each grant is in, and one action per row.
//   • PermissionPromptView — a small inline card a feature shows when IT is
//     blocked. This is the one that matters for matching MacNotch, whose
//     permission copy is explicit that each is requested "only when the
//     matching feature is enabled".
//
// Both lead with the REASON rather than the permission name. "Mira needs
// Accessibility" asks the user to take it on trust; "Snap Zones and controlling
// your Mac" lets them decide.

import SwiftUI

// MARK: - Full list

struct PermissionsListView: View {

    @ObservedObject private var service = PermissionsService.shared
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(MiraPermission.allCases) { permission in
                row(permission)
            }
        }
        .onAppear { service.refresh() }
    }

    private func row(_ permission: MiraPermission) -> some View {
        let status = service.status(for: permission)

        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: permission.icon)
                .font(.system(size: 13))
                .foregroundColor(status.isGranted ? accent : .white.opacity(0.45))
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.92))
                    StatusPill(status: status, accent: accent)
                }
                Text(permission.reason)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.45))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !status.isGranted {
                Button(action: { service.request(permission) }) {
                    // Says what will actually happen. A button labelled "Allow"
                    // that silently opens System Settings — or worse, does
                    // nothing because the user already denied it — is the usual
                    // way these screens lose people.
                    Text(actionTitle(for: permission, status: status))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.04)))
    }

    private func actionTitle(for permission: MiraPermission, status: PermissionStatus) -> String {
        // Denied can only be undone in Settings — the system will not prompt a
        // second time, so offering "Allow" would be a button that does nothing.
        if status == .denied || !permission.isRequestableInApp { return "Open Settings" }
        return "Allow"
    }
}

private struct StatusPill: View {
    let status: PermissionStatus
    let accent: Color

    var body: some View {
        Text(label)
            .font(.system(size: 8, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(color.opacity(0.16)))
    }

    private var label: String {
        switch status {
        case .granted:       return "Granted"
        case .denied:        return "Denied"
        case .notDetermined: return "Not set"
        }
    }

    private var color: Color {
        switch status {
        case .granted:       return Color(red: 0.40, green: 0.80, blue: 0.62)
        case .denied:        return Color(red: 0.95, green: 0.50, blue: 0.45)
        case .notDetermined: return .white.opacity(0.45)
        }
    }
}

// MARK: - Inline prompt

/// Shown by a feature that is blocked, in place of its own content.
///
/// The point of asking here rather than at launch: the user is looking at the
/// thing that needs it, so the request explains itself. Dismissable per feature,
/// because someone who does not want Mira reading notifications should be able
/// to stop being asked without turning the module off.
struct PermissionPromptView: View {

    let permission: MiraPermission
    /// One line about what THIS feature does with it. Falls back to the
    /// permission's own reason when a caller has nothing more specific.
    var detail: String?

    @ObservedObject private var service = PermissionsService.shared
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: permission.icon)
                .font(.system(size: 16))
                .foregroundColor(.white.opacity(0.35))

            Text("\(permission.title) needed")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.75))

            Text(detail ?? permission.reason)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.40))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 340)

            HStack(spacing: 8) {
                Button {
                    service.request(permission)
                } label: {
                    Text(service.status(for: permission) == .denied || !permission.isRequestableInApp
                         ? "Open Settings" : "Allow")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.black)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(accent))
                }
                .buttonStyle(.plain)

                // Granting Accessibility or Full Disk Access requires quitting
                // and reopening the app on macOS, so say so rather than leaving
                // the user staring at an unchanged panel.
                if !permission.isRequestableInApp {
                    Text("Then relaunch Mira")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
            }
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { service.refresh() }
    }
}
