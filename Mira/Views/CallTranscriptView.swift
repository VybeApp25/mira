import SwiftUI

// MARK: - HUD model (driven by CallHUDManager)

@MainActor
final class CallHUDModel: ObservableObject {
    /// Active transcription session (capture running), or nil.
    @Published var session: CallSession?
    /// A detected call app awaiting the user's consent to start, or nil.
    @Published var promptSource: CallSource?
}

// MARK: - iMessage-style bubble

struct CallBubbleRow: View {
    let segment: CallSegment
    private var isMe: Bool { segment.speaker == .me }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            if isMe { Spacer(minLength: 56) }
            Text(segment.text.isEmpty ? "…" : segment.text)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    isMe ? Color.accentColor : Color(nsColor: .windowBackgroundColor)
                )
                .foregroundStyle(isMe ? Color.white : Color.primary)
                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 15, style: .continuous)
                        .stroke(Color.primary.opacity(isMe ? 0 : 0.08), lineWidth: 1)
                )
                .opacity(segment.isFinal ? 1 : 0.55)   // live (non-final) text dimmed
            if !isMe { Spacer(minLength: 56) }
        }
    }
}

// MARK: - Live transcript window content (the iMessage look & feel)

struct CallTranscriptView: View {
    @ObservedObject var session: CallSession

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
        }
        .frame(minWidth: 360, idealWidth: 420, minHeight: 420, idealHeight: 560)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: session.source.symbolName)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(session.title).font(.system(size: 13, weight: .semibold))
                Text(session.source.displayName).font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            if session.isActive {
                Circle().fill(.red).frame(width: 7, height: 7)
            }
            TimelineView(.periodic(from: Date(), by: 1)) { _ in
                Text(session.elapsedString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 8) {
                    if session.segments.isEmpty {
                        Text("Listening…")
                            .font(.system(size: 12))
                            .foregroundStyle(.tertiary)
                            .padding(.top, 24)
                    }
                    ForEach(session.segments) { seg in
                        CallBubbleRow(segment: seg).id(seg.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(12)
            }
            .onChange(of: session.segments.count) { _, _ in
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: session.segments.last?.text) { _, _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }
}

// MARK: - Side notification card

struct CallCardView: View {
    @ObservedObject var model: CallHUDModel
    var onStart: () -> Void   // prompt → begin transcribing
    var onOpen:  () -> Void   // active → open the transcript window
    var onClose: () -> Void   // dismiss prompt / stop transcribing

    var body: some View {
        Group {
            if let session = model.session {
                activeCard(session)
            } else if let source = model.promptSource {
                promptCard(source)
            } else {
                EmptyView()
            }
        }
        .frame(width: 264)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
    }

    private func promptCard(_ source: CallSource) -> some View {
        HStack(spacing: 10) {
            Image(systemName: source.symbolName).font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(source.displayName) detected").font(.system(size: 12, weight: .semibold))
                Text("Transcribe this call?").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onStart) {
                Text("Start").font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            closeButton
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func activeCard(_ session: CallSession) -> some View {
        HStack(spacing: 10) {
            Image(systemName: session.source.symbolName).font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text(session.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                TimelineView(.periodic(from: Date(), by: 1)) { _ in
                    Text("\(session.source.displayName) · \(session.elapsedString)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 10)).foregroundStyle(.tertiary)
            closeButton
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .contentShape(Rectangle())
        .onTapGesture { onOpen() }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
    }
}
