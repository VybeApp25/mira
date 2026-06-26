import SwiftUI
import AppKit

// MARK: - Panel host

final class ClipboardHistoryPanel: NSPanel {
    static let shared = ClipboardHistoryPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 580),
            styleMask:   [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
            backing:     .buffered,
            defer:       false
        )
        isFloatingPanel      = true
        titlebarAppearsTransparent = true
        titleVisibility      = .hidden
        isMovableByWindowBackground = true
        backgroundColor      = .clear
        isOpaque             = false
        level                = .floating
        collectionBehavior   = [.canJoinAllSpaces, .fullScreenAuxiliary]
        contentView          = NSHostingView(rootView: ClipboardHistoryView())
    }

    func toggle() {
        if isVisible { close() } else { show() }
    }

    private func show() {
        if let screen = NSScreen.main {
            let sw = screen.visibleFrame.width
            let sh = screen.visibleFrame.height
            let ox = screen.visibleFrame.minX
            let oy = screen.visibleFrame.minY
            setFrameOrigin(NSPoint(
                x: ox + (sw - frame.width) / 2,
                y: oy + (sh - frame.height) / 2
            ))
        }
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - Main view

struct ClipboardHistoryView: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared
    @State private var query = ""
    @State private var selected: UUID?
    @State private var confirmClear = false

    private var filtered: [ClipboardItem] {
        if query.isEmpty { return monitor.history }
        let q = query.lowercased()
        return monitor.history.filter {
            ($0.text ?? "").lowercased().contains(q) ||
            ($0.ocrText ?? "").lowercased().contains(q) ||
            ($0.label ?? "").lowercased().contains(q) ||
            ($0.displayTitle).lowercased().contains(q) ||
            ($0.sourceApp ?? "").lowercased().contains(q)
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.ultraThinMaterial)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                header
                Divider().opacity(0.15)
                if filtered.isEmpty {
                    emptyState
                } else {
                    list
                }
                Divider().opacity(0.15)
                footer
            }
        }
        .frame(width: 480, height: 580)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))
            TextField("Search clips…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: List

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(filtered) { item in
                    ClipboardRow(item: item, isSelected: selected == item.id)
                        .onTapGesture {
                            selected = item.id
                            pasteItem(item)
                        }
                        .contextMenu { contextMenu(for: item) }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func contextMenu(for item: ClipboardItem) -> some View {
        Button {
            pasteItem(item)
        } label: { Label("Paste", systemImage: "doc.on.clipboard") }

        Button {
            monitor.copyToPasteboard(item)
        } label: { Label("Copy", systemImage: "doc.on.doc") }

        Divider()

        Button {
            monitor.togglePin(item)
        } label: {
            Label(item.isPinned ? "Unpin" : "Pin", systemImage: item.isPinned ? "pin.slash" : "pin")
        }

        Button {
            askLabel(for: item)
        } label: { Label("Add Label…", systemImage: "tag") }

        Divider()

        Button(role: .destructive) {
            monitor.delete(item)
        } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(monitor.history.count) clips")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.3))
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Text("Clear All")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .confirmationDialog("Clear clipboard history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear All", role: .destructive) { monitor.clear() }
                Button("Keep Pinned", role: .destructive) { monitor.clear(keepPinned: true) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clipboard")
                .font(.system(size: 32))
                .foregroundColor(.white.opacity(0.15))
            Text(query.isEmpty ? "Copy something to get started." : "No results for \"\(query)\"")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Actions

    private func pasteItem(_ item: ClipboardItem) {
        monitor.copyToPasteboard(item)
        ClipboardHistoryPanel.shared.close()
        // Brief delay so the target app is frontmost before we inject ⌘V
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply { $0.flags = .maskCommand }
            CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
        }
    }

    private func askLabel(for item: ClipboardItem) {
        let alert = NSAlert()
        alert.messageText = "Label this clip"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        tf.stringValue = item.label ?? ""
        tf.placeholderString = "e.g. Work email, API key…"
        alert.accessoryView = tf
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.setLabel(tf.stringValue, for: item)
        }
    }
}

// MARK: - Row

private struct ClipboardRow: View {
    let item: ClipboardItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            // Thumbnail or icon
            if item.kind == .image, let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 14))
                    .foregroundColor(kindColor)
                    .frame(width: 36, height: 36)
                    .background(kindColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.white.opacity(0.4))
                    }
                    if let label = item.label {
                        Text(label)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.5))
                    }
                }
                Text(item.displayTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.85))
                    .lineLimit(1)
                if let snippet = item.snippet {
                    Text(snippet)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .lineLimit(1)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                if let app = item.sourceApp {
                    Text(app)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.25))
                }
                Text(item.copiedAt, style: .relative)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.2))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.white.opacity(0.06) : Color.clear)
        .contentShape(Rectangle())
    }

    private var kindColor: Color {
        switch item.kind {
        case .text:  return .white
        case .url:   return .blue
        case .code:  return .green
        case .image: return .purple
        case .color: return .orange
        case .file:  return .yellow
        }
    }
}

// MARK: - CGEvent helper

private extension CGEvent {
    func apply(_ block: (CGEvent) -> Void) {
        block(self)
        self.post(tap: .cgSessionEventTap)
    }
}
