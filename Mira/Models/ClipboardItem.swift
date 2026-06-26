import AppKit

// MARK: - ClipboardItem

struct ClipboardItem: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: Kind
    // Text content (text / url / code / color kinds).
    var text: String?
    // PNG thumbnail for image clips.
    var imageData: Data?
    // Absolute paths stored as strings for Codable compatibility.
    var filePaths: [String]?
    // OCR result extracted from imageData in the background.
    var ocrText: String?
    var sourceApp: String?
    var copiedAt: Date
    var isPinned: Bool = false
    var label: String?
    var reminderDate: Date?
    var isQueued: Bool = false

    enum Kind: String, Codable {
        case text, url, code, image, color, file
    }

    // Human-readable title shown in the history panel.
    var displayTitle: String {
        switch kind {
        case .text:
            return text.flatMap { $0.isEmpty ? nil : String($0.prefix(80)) } ?? "Text"
        case .url:
            return text ?? "URL"
        case .code:
            return text.flatMap { String($0.prefix(80)) } ?? "Code"
        case .color:
            return text ?? "Color"
        case .image:
            return ocrText.flatMap { $0.isEmpty ? nil : "Image: \(String($0.prefix(60)))" } ?? "Image"
        case .file:
            return filePaths?.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "File"
        }
    }

    // Preview snippet for the detail row.
    var snippet: String? {
        switch kind {
        case .text, .url, .code, .color:
            return text.flatMap { $0.count > 80 ? String($0.prefix(200)) + "…" : nil }
        case .image:
            return ocrText
        case .file:
            guard let paths = filePaths else { return nil }
            return paths.map { URL(fileURLWithPath: $0).lastPathComponent }.joined(separator: ", ")
        }
    }

    var icon: String {
        switch kind {
        case .text:  return "doc.text"
        case .url:   return "link"
        case .code:  return "chevron.left.forwardslash.chevron.right"
        case .image: return "photo"
        case .color: return "paintpalette"
        case .file:  return "folder"
        }
    }

    static func == (lhs: ClipboardItem, rhs: ClipboardItem) -> Bool { lhs.id == rhs.id }
}

// MARK: - TextExpansion

struct TextExpansion: Identifiable, Codable {
    let id: UUID
    var shortcut: String    // e.g. ";em"
    var expansion: String   // e.g. "trevonbarbour@gmail.com"
    var label: String?
}
