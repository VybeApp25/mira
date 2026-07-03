import SwiftUI
import AVFoundation

// MARK: - CameraPreviewView
//
// NSViewRepresentable wrapping an AVCaptureVideoPreviewLayer for the notch's
// mirror-check tab.

struct CameraPreviewView: NSViewRepresentable {
    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()
        override func layout() {
            super.layout()
            previewLayer.frame = bounds
        }
    }

    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let v = PreviewNSView()
        v.wantsLayer = true
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        v.layer = v.previewLayer
        return v
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {}
}
