import AppKit
import Vision
import CryptoKit

@MainActor
final class ClipboardMonitorService: ObservableObject {
    static let shared = ClipboardMonitorService()

    @Published private(set) var history: [ClipboardItem] = []

    private var changeCount: Int = NSPasteboard.general.changeCount
    private var timer: Timer?
    private let maxItems = 500
    private let storageURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("clipboard_history.json")
    }()

    private init() { load() }

    // MARK: - Lifecycle

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    // MARK: - Polling

    private func poll() {
        let board = NSPasteboard.general
        guard board.changeCount != changeCount else { return }
        changeCount = board.changeCount

        let sourceApp = NSWorkspace.shared.frontmostApplication?.localizedName
        let now = Date()

        // ── Image (screenshots land here) ───────────────────────────────────
        if let tiffData = board.data(forType: .tiff) {
            let png = NSImage(data: tiffData).flatMap { thumbnail($0, side: 400) }
            var item = ClipboardItem(id: UUID(), kind: .image, imageData: png,
                                     sourceApp: sourceApp, copiedAt: now)
            addItem(item)
            // Run OCR in background then update the item
            let itemID = item.id
            if let img = NSImage(data: tiffData) {
                Task.detached(priority: .background) {
                    let text = await ocrImage(img)
                    await MainActor.run {
                        if let i = self.history.firstIndex(where: { $0.id == itemID }) {
                            self.history[i].ocrText = text
                            self.persist()
                        }
                    }
                }
            }
            return
        }

        // ── File URLs ────────────────────────────────────────────────────────
        if let urls = board.readObjects(forClasses: [NSURL.self], options: [
            NSPasteboard.ReadingOptionKey.urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            let paths = urls.map { $0.path }
            let item = ClipboardItem(id: UUID(), kind: .file, filePaths: paths,
                                     sourceApp: sourceApp, copiedAt: now)
            addItem(item)
            return
        }

        // ── String (text / url / code / color) ──────────────────────────────
        if let text = board.string(forType: .string), !text.isEmpty {
            let kind = classify(text)
            // Skip duplicates of the same text (dedup by content hash)
            let hash = sha(text)
            if history.first(where: { sha($0.text ?? "") == hash }) != nil { return }
            let item = ClipboardItem(id: UUID(), kind: kind, text: text,
                                     sourceApp: sourceApp, copiedAt: now)
            addItem(item)
        }
    }

    // MARK: - Classify

    private func classify(_ text: String) -> ClipboardItem.Kind {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("http://") || t.hasPrefix("https://") || t.hasPrefix("ftp://") { return .url }
        if t.hasPrefix("#") && (t.count == 4 || t.count == 7 || t.count == 9) { return .color }
        if t.hasPrefix("rgb(") || t.hasPrefix("rgba(") || t.hasPrefix("hsl(") { return .color }
        let codeSignals = ["{", "}", "=>", "->", "func ", "def ", "class ", "import ", "const ", "var ", "let "]
        let newlines = t.components(separatedBy: .newlines).count
        if newlines > 2 && codeSignals.contains(where: { t.contains($0) }) { return .code }
        return .text
    }

    // MARK: - Mutations

    func addItem(_ item: ClipboardItem) {
        history.removeAll { !$0.isPinned && sha($0.text ?? "") == sha(item.text ?? "") && $0.kind == item.kind }
        history.insert(item, at: 0)
        // Keep pinned items at the front but don't overflow them
        let pinned   = history.filter { $0.isPinned }
        let unpinned = history.filter { !$0.isPinned }
        history = pinned + Array(unpinned.prefix(maxItems - pinned.count))
        persist()
    }

    func delete(_ item: ClipboardItem) {
        history.removeAll { $0.id == item.id }
        persist()
    }

    func togglePin(_ item: ClipboardItem) {
        guard let i = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[i].isPinned.toggle()
        persist()
    }

    func setLabel(_ label: String?, for item: ClipboardItem) {
        guard let i = history.firstIndex(where: { $0.id == item.id }) else { return }
        history[i].label = label?.isEmpty == true ? nil : label
        persist()
    }

    func clear(keepPinned: Bool = true) {
        history = keepPinned ? history.filter { $0.isPinned } : []
        persist()
    }

    // MARK: - Copy to clipboard

    func copyToPasteboard(_ item: ClipboardItem) {
        let board = NSPasteboard.general
        board.clearContents()
        switch item.kind {
        case .text, .url, .code, .color:
            if let text = item.text { board.setString(text, forType: .string) }
        case .image:
            if let data = item.imageData, let img = NSImage(data: data) {
                board.writeObjects([img])
            }
        case .file:
            if let paths = item.filePaths {
                let urls = paths.map { URL(fileURLWithPath: $0) } as [NSURL]
                board.writeObjects(urls)
            }
        }
    }

    // MARK: - AI context helper

    /// Returns up to `max` recent text items for injection into prompts.
    func recentTextContext(max: Int = 3) -> String? {
        let textItems = history
            .filter { $0.kind == .text || $0.kind == .url || $0.kind == .code }
            .prefix(max)
        guard !textItems.isEmpty else { return nil }
        let lines = textItems.enumerated().map { i, item in
            let preview = String((item.text ?? "").prefix(200))
            return "[\(i + 1)] \(preview)"
        }
        return "Recent clipboard:\n" + lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func persist() {
        Task.detached(priority: .background) { [history = self.history, url = storageURL] in
            guard let data = try? JSONEncoder().encode(history) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let items = try? JSONDecoder().decode([ClipboardItem].self, from: data)
        else { return }
        history = items
    }

    // MARK: - Helpers

    private func sha(_ text: String) -> String {
        let digest = SHA256.hash(data: Data(text.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - OCR (off main thread)

private func ocrImage(_ image: NSImage) async -> String? {
    guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
    return await withCheckedContinuation { cont in
        let req = VNRecognizeTextRequest { req, _ in
            let text = (req.results as? [VNRecognizedTextObservation])?
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: " ")
            cont.resume(returning: text?.isEmpty == true ? nil : text)
        }
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        try? VNImageRequestHandler(cgImage: cgImage, options: [:]).perform([req])
    }
}

// MARK: - Thumbnail helper

private func thumbnail(_ image: NSImage, side: CGFloat) -> Data? {
    let size = image.size
    let scale = min(side / max(size.width, size.height), 1.0)
    let newSize = NSSize(width: size.width * scale, height: size.height * scale)
    let thumb = NSImage(size: newSize)
    thumb.lockFocus()
    image.draw(in: NSRect(origin: .zero, size: newSize))
    thumb.unlockFocus()
    guard let tiff = thumb.tiffRepresentation,
          let rep  = NSBitmapImageRep(data: tiff) else { return nil }
    return rep.representation(using: .png, properties: [.compressionFactor: 0.8])
}
