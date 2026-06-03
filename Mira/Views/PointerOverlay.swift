import SwiftUI

struct PointerOverlay: View {
    let point: CGPoint
    let label: String
    let screenSize: CGSize
    var color: Color = Color(red: 0.29, green: 0.62, blue: 1.0)

    @State private var ring: CGFloat = 1.0

    private var blue: Color { color }

    var body: some View {
        ZStack {
            Color.clear

            ZStack {
                // Pulsing outer ring
                Circle()
                    .stroke(blue.opacity(0.45), lineWidth: 2)
                    .frame(width: 48 * ring, height: 48 * ring)
                    .opacity(2 - Double(ring))

                // Static inner ring
                Circle()
                    .stroke(blue, lineWidth: 2)
                    .frame(width: 28, height: 28)

                // Center dot
                Circle()
                    .fill(blue)
                    .frame(width: 9, height: 9)
                    .shadow(color: blue.opacity(0.8), radius: 6)

                // Label above
                if !label.isEmpty {
                    Text(label)
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundColor(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 7).fill(blue))
                        .shadow(color: .black.opacity(0.35), radius: 4, y: 2)
                        .offset(y: -32)
                }
            }
            .position(x: point.x, y: point.y)
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                ring = 2.0
            }
        }
    }
}
