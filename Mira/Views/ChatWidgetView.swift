import SwiftUI
import AppKit

// MARK: - Dispatcher

struct ChatWidgetCardView: View {
    let widget: ChatWidget

    var body: some View {
        switch widget {
        case .stock(let q):       StockWidgetView(quote: q)
        case .images(let rs):     ImageSearchWidgetView(results: rs)
        case .place(let p):       PlaceWidgetView(place: p)
        case .artifact(let info): ArtifactCardView(info: info)
        }
    }
}

// MARK: - Stock

struct StockWidgetView: View {
    let quote: StockQuote

    private let surface = Color.white.opacity(0.06)
    private let border  = Color.white.opacity(0.09)
    private var up: Bool { quote.change >= 0 }
    private var changeColor: Color { up ? Color(red: 0.18, green: 0.78, blue: 0.45) : Color(red: 0.95, green: 0.35, blue: 0.35) }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: symbol + name
            VStack(alignment: .leading, spacing: 3) {
                Text(quote.symbol)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                Text(quote.name)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.40))
                    .lineLimit(1)
                    .truncationMode(.tail)
                marketStateBadge
            }
            Spacer(minLength: 8)
            // Right: price + change
            VStack(alignment: .trailing, spacing: 3) {
                Text(formattedPrice)
                    .font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white.opacity(0.92))
                HStack(spacing: 3) {
                    Image(systemName: up ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .semibold))
                    Text(formattedChange)
                        .font(.system(size: 11, weight: .medium))
                }
                .foregroundColor(changeColor)
                Text(formattedPct)
                    .font(.system(size: 10))
                    .foregroundColor(changeColor.opacity(0.75))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(changeColor.opacity(0.18), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var marketStateBadge: some View {
        let (label, color): (String, Color) = switch quote.marketState {
        case "PRE":    ("Pre-market",  .orange)
        case "POST":   ("After-hours", .orange)
        case "CLOSED": ("Closed",      .white.opacity(0.25))
        default:       ("Live",        Color(red: 0.18, green: 0.78, blue: 0.45))
        }
        return Text(label)
            .font(.system(size: 9, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(Capsule())
    }

    private var formattedPrice: String {
        let sym = quote.currency == "USD" ? "$" : quote.currency + " "
        return "\(sym)\(String(format: "%.2f", quote.price))"
    }
    private var formattedChange: String {
        let sign = quote.change >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", quote.change))"
    }
    private var formattedPct: String {
        let sign = quote.changePercent >= 0 ? "+" : ""
        return "(\(sign)\(String(format: "%.2f", quote.changePercent))%)"
    }
}

// MARK: - Image search

struct ImageSearchWidgetView: View {
    let results: [ImageResult]
    private let cols = Array(repeating: GridItem(.flexible(), spacing: 4), count: 3)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if results.isEmpty {
                Text("No images found")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
                    .padding(.vertical, 8)
            } else {
                LazyVGrid(columns: cols, spacing: 4) {
                    ForEach(results) { img in
                        ImageThumbView(result: img)
                    }
                }
            }
        }
        .padding(8)
        .background(Color.white.opacity(0.05))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.white.opacity(0.08), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct ImageThumbView: View {
    let result: ImageThumbResult
    @State private var phase: AsyncImagePhase = .empty

    // Alias so we can use the generic ImageResult without naming conflict
    typealias ImageThumbResult = ImageResult

    var body: some View {
        AsyncImage(url: URL(string: result.thumbURL)) { p in
            switch p {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                Color.white.opacity(0.05)
                    .overlay(Image(systemName: "photo").font(.system(size: 11)).foregroundColor(.white.opacity(0.20)))
            case .empty:
                Color.white.opacity(0.04)
            @unknown default:
                Color.white.opacity(0.04)
            }
        }
        .frame(height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let url = URL(string: result.srcURL) {
                NSWorkspace.shared.open(url)
            }
        }
        .help(result.title)
    }
}

// MARK: - Place

struct PlaceWidgetView: View {
    let place: PlaceResult

    private let surface = Color.white.opacity(0.06)
    private let border  = Color.white.opacity(0.09)
    private let teal    = Color(red: 0.18, green: 0.75, blue: 0.75)

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 13))
                    .foregroundColor(teal)
                Text(place.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                if !place.category.isEmpty {
                    Text(place.category)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(teal.opacity(0.80))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(teal.opacity(0.10))
                        .clipShape(Capsule())
                }
            }

            // Address
            Text(place.address)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.50))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            // Coords + open button
            HStack(spacing: 0) {
                Text(coordsString)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                Spacer(minLength: 8)
                Button("Open in Maps") {
                    let q = "\(place.lat),\(place.lon)"
                    if let url = URL(string: "maps://?q=\(q)&ll=\(q)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(teal)
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var coordsString: String {
        let latDir = place.lat  >= 0 ? "N" : "S"
        let lonDir = place.lon  >= 0 ? "E" : "W"
        return String(format: "%.4f°%@ %.4f°%@", abs(place.lat), latDir, abs(place.lon), lonDir)
    }
}

// MARK: - Artifact file card

struct ArtifactCardView: View {
    let info: ArtifactInfo
    @State private var isHovered = false

    private let surface = Color.white.opacity(0.06)
    private let border  = Color.white.opacity(0.09)

    private var accentColor: Color {
        switch info.accentColor {
        case "red":    return Color(red: 0.95, green: 0.35, blue: 0.35)
        case "blue":   return DS.Colors.accent
        case "green":  return Color(red: 0.18, green: 0.78, blue: 0.45)
        case "yellow": return Color(red: 0.95, green: 0.80, blue: 0.20)
        case "orange": return Color(red: 0.99, green: 0.58, blue: 0.15)
        case "purple": return Color(red: 0.70, green: 0.40, blue: 0.95)
        default:       return Color.white.opacity(0.60)
        }
    }

    var body: some View {
        HStack(spacing: 11) {
            // File icon badge
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accentColor.opacity(0.14))
                    .frame(width: 36, height: 36)
                Image(systemName: info.sfSymbol)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(accentColor)
            }

            // Name + size
            VStack(alignment: .leading, spacing: 2) {
                Text(info.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(info.formattedSize)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }

            Spacer(minLength: 0)

            // Actions
            HStack(spacing: 6) {
                artifactButton(icon: "folder", tooltip: "Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([info.url])
                }
                artifactButton(icon: "arrow.up.forward.square", tooltip: "Open") {
                    NSWorkspace.shared.open(info.url)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isHovered ? Color.white.opacity(0.09) : surface)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isHovered ? accentColor.opacity(0.25) : border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .onHover { isHovered = $0 }
        .onTapGesture { NSWorkspace.shared.open(info.url) }
    }

    private func artifactButton(icon: String, tooltip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(tooltip)
    }
}
