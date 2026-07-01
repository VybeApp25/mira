import SwiftUI

// MARK: - SystemHUDView
//
// Replacement for macOS's stock volume/brightness HUD — matches the notch's
// own visual language (capsule bar in DS.Colors.accent) rather than looking
// like a bolted-on stock replica.

struct SystemHUDView: View {
    let symbol: String
    let level: Double   // 0...1

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .frame(width: 20)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.12))
                    Capsule().fill(DS.Colors.accent)
                        .frame(width: geo.size.width * CGFloat(max(0, min(1, level))))
                }
            }
            .frame(height: 5)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 180)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.82))
                .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 6)
        )
    }
}
