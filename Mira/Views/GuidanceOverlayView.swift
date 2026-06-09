import SwiftUI

struct GuidanceOverlayView: View {
    let guidanceFrame: GuidanceFrame
    let screenSize: CGSize
    var sharpieAnnotations: [SharpieAnnotation] = []

    @State private var opacity: Double = 0

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        ZStack {
            Color.clear

            // Sharpie strokes underneath labels — replace the plain box when present
            if !sharpieAnnotations.isEmpty {
                SharpieOverlayView(annotations: sharpieAnnotations, screenSize: screenSize)
            }

            ForEach(guidanceFrame.targets, id: \.id) { target in
                if sharpieAnnotations.isEmpty { highlightBox(target) }
                labelBadge(target)
                explanationBadge(target)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.22)) { opacity = 1.0 }
        }
    }

    // MARK: - Annotation layers

    @ViewBuilder
    private func highlightBox(_ target: GuidanceTarget) -> some View {
        let r = target.rect
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(accent.opacity(0.09))
            RoundedRectangle(cornerRadius: 6).stroke(accent, lineWidth: 2.5)
        }
        .frame(width: r.width, height: r.height)
        .position(x: r.midX, y: r.midY)
    }

    @ViewBuilder
    private func labelBadge(_ target: GuidanceTarget) -> some View {
        let r = target.rect
        Text(target.label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 5).fill(accent))
            .shadow(color: .black.opacity(0.30), radius: 3, y: 1)
            .position(x: r.midX, y: Swift.max(r.minY - 16, 16))
    }

    @ViewBuilder
    private func explanationBadge(_ target: GuidanceTarget) -> some View {
        let r = target.rect
        Text(target.explanation)
            .font(.system(size: 12))
            .foregroundColor(.white)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: Swift.min(Swift.max(r.width + 60, 240), 340))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.14).opacity(0.94))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(accent.opacity(0.30), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.40), radius: 8, y: 3)
            .position(
                x: r.midX.clamped(to: 170...(screenSize.width - 170)),
                y: Swift.min(r.maxY + 38, screenSize.height - 48)
            )
    }
}

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
