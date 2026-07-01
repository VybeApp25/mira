import AVFoundation

// MARK: - CameraPreviewService
//
// First camera-using feature in the app. Owns the AVCaptureSession lifecycle;
// callers must start()/stop() from onAppear/onDisappear of whatever view hosts
// the preview so the camera light is never on while that view isn't visible.

@MainActor
final class CameraPreviewService: ObservableObject {
    static let shared = CameraPreviewService()

    @Published private(set) var isRunning = false
    @Published private(set) var isAuthorized = false

    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.trevonbarbour.mira.camera-session")
    private var configured = false

    private init() {
        isAuthorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
    }

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            isAuthorized = true
            beginRunning()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                Task { @MainActor in
                    self?.isAuthorized = granted
                    if granted { self?.beginRunning() }
                }
            }
        default:
            isAuthorized = false
        }
    }

    func stop() {
        queue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
        isRunning = false
    }

    private func beginRunning() {
        configureIfNeeded()
        queue.async { [session] in
            if !session.isRunning { session.startRunning() }
            Task { @MainActor in self.isRunning = true }
        }
    }

    private func configureIfNeeded() {
        guard !configured else { return }
        configured = true
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return }

        session.beginConfiguration()
        session.sessionPreset = .medium
        if session.canAddInput(input) { session.addInput(input) }
        session.commitConfiguration()
    }
}
