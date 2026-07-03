import Foundation

// MARK: - Call source (which app the call is happening in)

/// Where a call is taking place. Drives the label shown on the notification card
/// ("Zoom", "FaceTime", …) and detection via running-application bundle IDs.
enum CallSource: String, Codable, CaseIterable {
    case zoom
    case facetime
    case skype
    case teams
    case webex
    case discord
    case slack
    case browser   // Google Meet / Teams-web and other in-browser calls
    case unknown

    var displayName: String {
        switch self {
        case .zoom:     return "Zoom"
        case .facetime: return "FaceTime"
        case .skype:    return "Skype"
        case .teams:    return "Microsoft Teams"
        case .webex:    return "Webex"
        case .discord:  return "Discord"
        case .slack:    return "Slack"
        case .browser:  return "Browser call"
        case .unknown:  return "Call"
        }
    }

    /// SF Symbol used on the card.
    var symbolName: String {
        switch self {
        case .facetime: return "video.fill"
        case .browser:  return "globe"
        default:        return "phone.fill"
        }
    }

    /// Native app bundle identifiers that identify this source. `browser`/`unknown`
    /// have no native bundle (handled separately).
    var bundleIdentifiers: [String] {
        switch self {
        case .zoom:     return ["us.zoom.xos"]
        case .facetime: return ["com.apple.FaceTime"]
        case .skype:    return ["com.skype.skype"]
        case .teams:    return ["com.microsoft.teams", "com.microsoft.teams2"]
        case .webex:    return ["com.cisco.webexmeetingsapp", "Cisco-Systems.Spark"]
        case .discord:  return ["com.hnc.Discord"]
        case .slack:    return ["com.tinyspeck.slackmacgap"]
        case .browser, .unknown: return []
        }
    }

    /// Resolve a running-app bundle identifier to a known source, if any.
    static func from(bundleIdentifier id: String) -> CallSource? {
        allCases.first { $0.bundleIdentifiers.contains(id) }
    }
}

// MARK: - Transcript segments

/// Who is speaking. The label is decided by the capture source, not by ML:
/// `me` = the local microphone, `caller` = system (remote) audio.
enum CallSpeaker: String, Codable {
    case me      // right-aligned bubble (the user)
    case caller  // left-aligned bubble (the other party)
}

/// One utterance in the conversation. While a stream is mid-sentence the segment
/// is `isFinal == false` and its `text` updates live; once AssemblyAI finalizes
/// the sentence it flips to `true` and a new live segment begins.
struct CallSegment: Identifiable, Codable, Equatable {
    let id: UUID
    let speaker: CallSpeaker
    var text: String
    let startedAt: Date
    var isFinal: Bool

    init(id: UUID = UUID(), speaker: CallSpeaker, text: String, startedAt: Date = Date(), isFinal: Bool = false) {
        self.id = id
        self.speaker = speaker
        self.text = text
        self.startedAt = startedAt
        self.isFinal = isFinal
    }
}

// MARK: - Live call session

/// A single in-progress (or just-ended) call. Observable so the notification card
/// and the iMessage-style window both update live. A `CallTranscriptSnapshot` is
/// persisted to history when the call ends.
@MainActor
final class CallSession: ObservableObject, Identifiable {
    let id = UUID()
    let source: CallSource
    /// Human label for the card, e.g. "Zoom call" or a detected window/tab title.
    @Published var title: String
    let startedAt: Date
    @Published private(set) var endedAt: Date?
    @Published var segments: [CallSegment] = []
    /// Where the finished transcript was saved (set on end).
    @Published var savedFileURL: URL?
    /// Last time any speech was transcribed — drives the inactivity auto-end.
    private(set) var lastActivityAt = Date()

    init(source: CallSource, title: String? = nil, startedAt: Date = Date()) {
        self.source = source
        self.title = title ?? "\(source.displayName)"
        self.startedAt = startedAt
    }

    var isActive: Bool { endedAt == nil }

    var elapsed: TimeInterval { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    /// "12:04" / "1:02:33" style elapsed string for the collapsed card.
    var elapsedString: String {
        let s = Int(elapsed)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, sec)
            : String(format: "%d:%02d", m, sec)
    }

    /// Update (or append) the live, non-final segment for a speaker as partial
    /// transcripts arrive. There is at most one live segment per speaker.
    func updatePartial(_ text: String, speaker: CallSpeaker) {
        guard !text.isEmpty else { return }
        lastActivityAt = Date()
        if let i = segments.lastIndex(where: { $0.speaker == speaker && !$0.isFinal }) {
            segments[i].text = text
        } else {
            segments.append(CallSegment(speaker: speaker, text: text, isFinal: false))
        }
    }

    /// Finalize the current live segment for a speaker with confirmed text.
    func finalize(_ text: String, speaker: CallSpeaker) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lastActivityAt = Date()
        if let i = segments.lastIndex(where: { $0.speaker == speaker && !$0.isFinal }) {
            segments[i].text = trimmed
            segments[i].isFinal = true
        } else {
            segments.append(CallSegment(speaker: speaker, text: trimmed, isFinal: true))
        }
    }

    func end(at date: Date = Date()) {
        guard endedAt == nil else { return }
        endedAt = date
    }

    func snapshot() -> CallTranscriptSnapshot {
        CallTranscriptSnapshot(
            id: id,
            source: source,
            title: title,
            startedAt: startedAt,
            endedAt: endedAt ?? Date(),
            segments: segments.filter { $0.isFinal }
        )
    }
}

// MARK: - Persisted snapshot

/// Immutable, Codable record of a finished call, saved to history.
struct CallTranscriptSnapshot: Identifiable, Codable {
    let id: UUID
    let source: CallSource
    let title: String
    let startedAt: Date
    let endedAt: Date
    let segments: [CallSegment]

    var duration: TimeInterval { endedAt.timeIntervalSince(startedAt) }
}
