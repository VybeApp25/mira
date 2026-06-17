import Foundation
import CoreGraphics
import SwiftUI

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

// MARK: - Sharpie Annotation

enum SharpieStyle {
    case circle                 // draws an ellipse around the target
    case arrow(from: CGPoint)   // draws an arrow from a point to the target center
    case underline              // draws a wobbly line under the target
    case bracket                // draws [ ] around the target
    case polygon([CGPoint])     // traces a closed polygon through the given points
}

enum SharpieColor {
    case orange, blue, red, green

    var color: Color {
        switch self {
        case .orange: return Color(red: 1.0,  green: 0.42, blue: 0.21)
        case .blue:   return DS.Colors.accent
        case .red:    return Color(red: 1.0,  green: 0.25, blue: 0.25)
        case .green:  return Color(red: 0.20, green: 0.84, blue: 0.29)
        }
    }
}

struct SharpieAnnotation: Identifiable {
    let id = UUID()
    let target: CGRect
    let style: SharpieStyle
    let color: SharpieColor
    let strokeWidth: CGFloat

    init(target: CGRect, style: SharpieStyle = .circle, color: SharpieColor = .orange, strokeWidth: CGFloat = 3.5) {
        self.target = target
        self.style = style
        self.color = color
        self.strokeWidth = strokeWidth
    }
}
