import AppKit

// Manages an ordered queue of clipboard items for sequential pasting.
// User adds items to the queue from the Labs tab; each "Paste Next" call
// copies the front item to the pasteboard and injects ⌘V.

@MainActor
final class MultiCopyQueueService: ObservableObject {
    static let shared = MultiCopyQueueService()

    @Published private(set) var queue: [ClipboardItem] = []

    private init() {}

    var isEmpty: Bool { queue.isEmpty }
    var nextPreview: String? { queue.first?.displayTitle }

    func enqueue(_ item: ClipboardItem) {
        guard !queue.contains(where: { $0.id == item.id }) else { return }
        queue.append(item)
    }

    func dequeue(id: UUID) {
        queue.removeAll { $0.id == id }
    }

    func move(from source: IndexSet, to destination: Int) {
        queue.move(fromOffsets: source, toOffset: destination)
    }

    func clear() { queue.removeAll() }

    func pasteNext() {
        guard !queue.isEmpty else { return }
        let item = queue.removeFirst()
        ClipboardMonitorService.shared.copyToPasteboard(item)
        injectPaste()
    }

    private func injectPaste() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
        down?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        let up = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        up?.flags = .maskCommand
        up?.post(tap: .cgSessionEventTap)
    }
}
