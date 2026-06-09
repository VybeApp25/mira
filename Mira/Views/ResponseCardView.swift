import SwiftUI

// MARK: - ResponseCardView
// Mirrors HeyClicky's ResponseCardView: cardHeader + galleryStrip + expandedBody + closeButton.
// Slides up below the island when Claude Code produces file artifacts.

struct ResponseCardView: View {
    let artifacts:  [ClaudeCodeArtifact]
    let onClose:    () -> Void

    @State private var selectedIndex: Int = 0
    @State private var expanded: Bool = false

    private let accent  = Color(red: 0.29, green: 0.62, blue: 1.0)
    private let surface = Color(red: 0.11, green: 0.11, blue: 0.15)
    private let border  = Color.white.opacity(0.09)

    var body: some View {
        VStack(spacing: 0) {
            cardHeader
            Divider().background(border)
            if expanded {
                cardExpandedBody
            } else {
                galleryStrip
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(border, lineWidth: 0.5)
                )
        )
        .shadow(color: .black.opacity(0.45), radius: 20, x: 0, y: 8)
        .animation(.spring(response: 0.30, dampingFraction: 0.80), value: expanded)
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

    // MARK: - Gallery strip (mirrors HeyClicky ResponseCardGalleryStrip)

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

    // MARK: - Expanded body (full file content)

    private var cardExpandedBody: some View {
        VStack(spacing: 0) {
            // Tab row for file switching
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

            // Code content
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

// MARK: - ArtifactThumbnail (mirrors HeyClicky's ArtifactPreviewCard / ResponseCardGalleryThumbnail)

private struct ArtifactThumbnail: View {
    let artifact:   ClaudeCodeArtifact
    let isSelected: Bool
    let onTap:      () -> Void

    private let accent = Color(red: 0.29, green: 0.62, blue: 1.0)

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                // File icon + language badge
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

                // Code preview snippet
                Text(codePreview)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 0)

                // Filename
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
                    .stroke(isSelected ? accent.opacity(0.45) : Color.white.opacity(0.07), lineWidth: isSelected ? 1 : 0.5)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .scaleEffect(isSelected ? 1.02 : 1.0)
        .animation(.spring(response: 0.22, dampingFraction: 0.75), value: isSelected)
    }

    private var codePreview: String {
        String(artifact.content.prefix(120))
    }
}
