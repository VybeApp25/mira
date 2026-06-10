import SwiftUI

// MARK: - ResponseCardView
//
// Three visual states:
//   isMinimized = true  → chip strip docked to the right edge of screen
//   isMinimized = false, expanded = false → gallery strip (default card)
//   isMinimized = false, expanded = true  → code-content expanded card
//
// Mirrors HeyClicky's ResponseCardView minimize-to-chip pattern.

struct ResponseCardView: View {
    let artifacts:   [ClaudeCodeArtifact]
    let isMinimized: Bool
    let onClose:     () -> Void
    let onMinimize:  () -> Void
    let onRestore:   () -> Void

    @State private var selectedIndex: Int  = 0
    @State private var expanded: Bool      = false

    private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let surface = Color(red: 0.11, green: 0.11, blue: 0.15)
    private let border  = Color.white.opacity(0.09)

    var body: some View {
        if isMinimized {
            chipStrip
        } else {
            fullCard
        }
    }

    // MARK: - Chip strip (minimized)

    private var chipStrip: some View {
        VStack(spacing: 0) {
            ForEach(Array(artifacts.enumerated()), id: \.element.id) { idx, art in
                chipRow(art: art, isLast: idx == artifacts.count - 1)
            }
        }
        .frostedGlass(cornerRadius: 14, tiltDegrees: 6)
        .transition(.asymmetric(
            insertion:  .move(edge: .trailing).combined(with: .opacity),
            removal:    .move(edge: .trailing).combined(with: .opacity)
        ))
    }

    private func chipRow(art: ClaudeCodeArtifact, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            // App/file icon
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(accent.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: art.icon)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(accent)
            }

            // Title + line count
            VStack(alignment: .leading, spacing: 2) {
                Text(art.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                    .truncationMode(.middle)

                let lineCount = art.content.components(separatedBy: "\n").count
                Text("\(lineCount) lines")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.38))
            }

            Spacer(minLength: 0)

            // Done badge
            HStack(spacing: 4) {
                Circle()
                    .fill(Color(red: 0.18, green: 0.78, blue: 0.45))
                    .frame(width: 6, height: 6)
                Text("Done")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(red: 0.18, green: 0.78, blue: 0.45))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color(red: 0.18, green: 0.78, blue: 0.45).opacity(0.12))
            .clipShape(Capsule())

            // Expand icon
            Button(action: {
                selectedIndex = artifacts.firstIndex(where: { $0.id == art.id }) ?? 0
                onRestore()
            }) {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.white.opacity(0.40))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.06))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(height: 52)
        .overlay(alignment: .bottom) {
            if !isLast {
                Divider()
                    .background(border)
                    .padding(.leading, 54)
            }
        }
    }

    // MARK: - Full card

    private var fullCard: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider().background(border)
            if expanded {
                cardExpandedBody
            } else {
                galleryStrip
            }
        }
        .frostedGlass(cornerRadius: 16, tiltDegrees: 7)
        .animation(.spring(response: 0.30, dampingFraction: 0.80), value: expanded)
        .transition(.asymmetric(
            insertion:  .opacity.combined(with: .scale(scale: 0.96, anchor: .top)),
            removal:    .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
        ))
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.badge.gearshape.fill")
                .font(.system(size: 12))
                .foregroundColor(accent.opacity(0.80))

            Text(artifacts.count == 1 ? "1 file created" : "\(artifacts.count) files created")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.88))

            Spacer()

            // Expand / collapse toggle
            Button {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
                    expanded.toggle()
                }
            } label: {
                Image(systemName: expanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            // Minimize to chip
            Button(action: onMinimize) {
                Image(systemName: "minus")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Minimize to chip")

            // Close
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.35))
                    .frame(width: 22, height: 22)
                    .background(Color.white.opacity(0.05))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: - Gallery strip

    private var galleryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(artifacts.enumerated()), id: \.element.id) { idx, art in
                    ArtifactThumbnail(
                        artifact:   art,
                        isSelected: idx == selectedIndex
                    ) {
                        selectedIndex = idx
                        withAnimation(.spring(response: 0.25, dampingFraction: 0.78)) {
                            expanded = true
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .frame(height: 110)
    }

    // MARK: - Expanded body

    private var cardExpandedBody: some View {
        VStack(spacing: 0) {
            // Tab row for multi-file switching
            if artifacts.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(Array(artifacts.enumerated()), id: \.element.id) { idx, art in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { selectedIndex = idx }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: art.icon)
                                        .font(.system(size: 9))
                                    Text(art.displayName)
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundColor(idx == selectedIndex ? .white.opacity(0.92) : .white.opacity(0.35))
                                .padding(.horizontal, 9).padding(.vertical, 5)
                                .background(idx == selectedIndex ? Color.white.opacity(0.09) : Color.clear)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 6)
                }
                Divider().background(border)
            }

            if artifacts.indices.contains(selectedIndex) {
                let art = artifacts[selectedIndex]
                ScrollView([.vertical, .horizontal], showsIndicators: false) {
                    Text(art.content)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.80))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
    }
}

// MARK: - ArtifactThumbnail

private struct ArtifactThumbnail: View {
    let artifact:   ClaudeCodeArtifact
    let isSelected: Bool
    let onTap:      () -> Void

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 0) {
                    Image(systemName: artifact.icon)
                        .font(.system(size: 16))
                        .foregroundColor(isSelected ? accent : .white.opacity(0.40))
                    Spacer()
                    if !artifact.language.isEmpty {
                        Text(artifact.language.uppercased())
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.25))
                            .padding(.horizontal, 4).padding(.vertical, 2)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }

                Text(String(artifact.content.prefix(120)))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                Text(artifact.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(isSelected ? .white.opacity(0.90) : .white.opacity(0.50))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(10)
            .frame(width: 100, height: 90)
            .background(Color.white.opacity(isSelected ? 0.10 : 0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isSelected ? accent.opacity(0.45) : Color.white.opacity(0.07),
                            lineWidth: isSelected ? 1 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isSelected)
    }
}
