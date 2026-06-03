import SwiftUI

// MARK: - Island state

enum IslandState: Equatable { case collapsed, expanded }

// MARK: - Controller

/// Drives all island animations. Views observe state + contentVisible to decide what to draw.
@MainActor
final class AnimationController: ObservableObject {

    @Published private(set) var state:          IslandState = .collapsed
    @Published private(set) var contentVisible: Bool        = false

    private let geometry: NotchGeometry

    // Expanded target dimensions — wide horizontal layout matching Perch-style mockups
    static let expandedW:  CGFloat = 700
    static let expandedH:  CGFloat = 252

    // Corner radius targets
    // Top stays 0 so the panel reads as physically growing from the notch hardware.
    static let collapsedTopR:  CGFloat = 0
    static let collapsedBotR:  CGFloat = 10
    static let expandedTopR:   CGFloat = 0
    static let expandedBotR:   CGFloat = 20

    init(geometry: NotchGeometry) {
        self.geometry = geometry
    }

    // MARK: - Public API

    func expand() {
        guard state != .expanded else { return }
        state = .expanded
        // Content fades in after the frame has begun opening
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { [weak self] in
            self?.contentVisible = true
        }
    }

    func collapse() {
        guard state != .collapsed else { return }
        // Fade content first, then shrink the frame
        contentVisible = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) { [weak self] in
            self?.state = .collapsed
        }
    }
}
