import Foundation
import CoreGraphics

struct GuidanceTarget {
    let id: UUID
    let rect: CGRect          // logical SwiftUI coords, origin top-left of screen
    let confidence: Double
    let label: String
    let explanation: String
}

struct GuidanceFrame {
    let timestamp: Date
    let targets: [GuidanceTarget]
}
