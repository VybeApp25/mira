import SwiftUI

// MARK: - EventToastView
//
// Short-lived confirmation that surfaces transient PillEvents.
// Uses the same Mira palette (teal/violet) and stays under 500 ms visibility.
// Never the sole indicator — always paired with a visual state change in SharedStatusView.

struct EventToastView: View {
    let event: PillEvent?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var accentColor: Color {
        switch event {
        case .error:    return Color(red: 1.0, green: 0.45, blue: 0.45)
        case .complete: return miraTeale
        case nil:       return miraTeale
        default:        return miraViolet
        }
    }

    var body: some View {
        if let event {
            HStack(spacing: 5) {
                Image(systemName: event.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(event.label)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(accentColor.opacity(0.12))
            .clipShape(Capsule())
            .transition(
                reduceMotion
                    ? .opacity
                    : .opacity
                        .combined(with: .scale(scale: 0.82))
                        .combined(with: .offset(y: 6))
            )
            .accessibilityLabel(event.label)
        }
    }
}
