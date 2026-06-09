import SwiftUI

// MARK: - Sharpie Overlay
//
// Renders animated marker-style annotations over UI elements — circles, arrows,
// underlines, brackets — each drawn on in real time like a Sharpie on glass.
// Compose with GuidanceOverlayView or show standalone via OverlayWindowController.

struct SharpieOverlayView: View {
    let annotations: [SharpieAnnotation]
    let screenSize: CGSize

    var body: some View {
        ZStack {
            Color.clear
            ForEach(annotations) { annotation in
                SharpieStroke(annotation: annotation, screenSize: screenSize)
            }
        }
        .frame(width: screenSize.width, height: screenSize.height)
    }
}

// MARK: - Individual stroke

private struct SharpieStroke: View {
    let annotation: SharpieAnnotation
    let screenSize: CGSize

    @State private var drawProgress: CGFloat = 0
    @State private var opacity: Double = 0
    @State private var wobble: CGFloat = 0

    private var color: Color { annotation.color.color }
    private var r: CGRect { annotation.target }

    var body: some View {
        Canvas { ctx, size in
            let path = buildPath()
            let trimmed = path.trimmedPath(from: 0, to: drawProgress)

            ctx.stroke(
                trimmed,
                with: .color(color.opacity(0.88)),
                style: StrokeStyle(
                    lineWidth: annotation.strokeWidth,
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        }
        .frame(width: screenSize.width, height: screenSize.height)
        .opacity(opacity)
        .onAppear {
            withAnimation(.easeOut(duration: 0.15)) { opacity = 1 }
            withAnimation(.easeInOut(duration: 0.55).delay(0.05)) { drawProgress = 1 }
            withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true).delay(0.6)) {
                wobble = 1
            }
        }
    }

    // MARK: - Path builders

    private func buildPath() -> Path {
        switch annotation.style {
        case .circle:         return circlePath()
        case .arrow(let from): return arrowPath(from: from)
        case .underline:      return underlinePath()
        case .bracket:        return bracketPath()
        }
    }

    // Ellipse drawn slightly outside the target rect, starting from top-center
    // and going clockwise so it feels natural (like drawing a circle by hand).
    private func circlePath() -> Path {
        let pad: CGFloat = 10
        let rx = (r.width  / 2) + pad
        let ry = (r.height / 2) + pad
        let cx = r.midX
        let cy = r.midY

        var path = Path()
        // Hand-drawn feel: start from top, go clockwise with slight offset
        let steps = 64
        for i in 0...steps {
            let t = CGFloat(i) / CGFloat(steps)
            let angle = t * 2 * .pi - .pi / 2
            // Slight wobble on the radius for the marker feel
            let wobbleR: CGFloat = i % 3 == 0 ? 1.5 : 0
            let x = cx + (rx + wobbleR) * cos(angle)
            let y = cy + (ry + wobbleR) * sin(angle)
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else       { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        return path
    }

    // Arrow from `from` point to the center of the target rect
    private func arrowPath(from start: CGPoint) -> Path {
        let end = CGPoint(x: r.midX, y: r.midY)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = sqrt(dx * dx + dy * dy)
        let ux = dx / len
        let uy = dy / len

        // Stop short of the center so the arrowhead lands on the edge
        let tip = CGPoint(x: end.x - ux * 12, y: end.y - uy * 12)

        // Arrowhead wings
        let wingLen: CGFloat = 14
        let wingAngle: CGFloat = 0.45
        let wx1 = tip.x - wingLen * (ux * cos(wingAngle) - uy * sin(wingAngle))
        let wy1 = tip.y - wingLen * (uy * cos(wingAngle) + ux * sin(wingAngle))
        let wx2 = tip.x - wingLen * (ux * cos(-wingAngle) - uy * sin(-wingAngle))
        let wy2 = tip.y - wingLen * (uy * cos(-wingAngle) + ux * sin(-wingAngle))

        var path = Path()
        path.move(to: start)
        path.addLine(to: tip)
        path.move(to: CGPoint(x: wx1, y: wy1))
        path.addLine(to: tip)
        path.addLine(to: CGPoint(x: wx2, y: wy2))
        return path
    }

    // Wobbly underline beneath the target rect
    private func underlinePath() -> Path {
        let y = r.maxY + 6
        let x0 = r.minX - 4
        let x1 = r.maxX + 4
        let segments = Int((x1 - x0) / 8)

        var path = Path()
        path.move(to: CGPoint(x: x0, y: y))
        for i in 1...max(segments, 1) {
            let t = CGFloat(i) / CGFloat(segments)
            let x = x0 + t * (x1 - x0)
            let yOffset: CGFloat = i % 2 == 0 ? 3 : -3
            path.addLine(to: CGPoint(x: x, y: y + yOffset))
        }
        return path
    }

    // Square bracket markers on left and right of the target rect
    private func bracketPath() -> Path {
        let pad: CGFloat = 8
        let armLen: CGFloat = min(r.height * 0.4, 20)
        var path = Path()

        // Left bracket
        let lx = r.minX - pad
        path.move(to: CGPoint(x: lx + armLen, y: r.minY - pad))
        path.addLine(to: CGPoint(x: lx, y: r.minY - pad))
        path.addLine(to: CGPoint(x: lx, y: r.maxY + pad))
        path.addLine(to: CGPoint(x: lx + armLen, y: r.maxY + pad))

        // Right bracket
        let rx = r.maxX + pad
        path.move(to: CGPoint(x: rx - armLen, y: r.minY - pad))
        path.addLine(to: CGPoint(x: rx, y: r.minY - pad))
        path.addLine(to: CGPoint(x: rx, y: r.maxY + pad))
        path.addLine(to: CGPoint(x: rx - armLen, y: r.maxY + pad))

        return path
    }
}
