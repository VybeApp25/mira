import SwiftUI
import AVFoundation

// MARK: - NotchCameraTabView
//
// Camera permission is requested contextually here, NOT during onboarding
// (unlike mic/screen-recording/accessibility) — this is an opt-in mirror-check
// feature the user discovers by tapping the tab, so it shouldn't force a
// camera prompt on every new user before they've ever seen it.

struct NotchCameraTabView: View {
    @ObservedObject private var camera = CameraPreviewService.shared
    @State private var deniedOrRestricted = false

    var body: some View {
        Group {
            if camera.isAuthorized {
                CameraPreviewView(session: camera.session)
                    .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            } else {
                permissionPrompt
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(10)
        .onAppear {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            deniedOrRestricted = (status == .denied || status == .restricted)
            camera.start()
        }
        .onDisappear { camera.stop() }
    }

    private var permissionPrompt: some View {
        VStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 22))
                .foregroundColor(.white.opacity(0.25))
            Text(deniedOrRestricted ? "Camera access denied" : "Camera access needed")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white.opacity(0.55))
            if deniedOrRestricted {
                Button("Open System Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 11, weight: .medium))
                .buttonStyle(.plain)
                .foregroundColor(DS.Colors.accent)
            } else {
                Text("Mira shows a quick camera preview so you can check how you look.")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.30))
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
