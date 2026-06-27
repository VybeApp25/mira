import SwiftUI
import AppKit

// MARK: - Panel host

final class ClipboardHistoryPanel: NSPanel {
    static let shared = ClipboardHistoryPanel()

    private init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask:   [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing:     .buffered,
            defer:       false
        )
        titlebarAppearsTransparent  = true
        titleVisibility             = .hidden
        isMovableByWindowBackground = true
        backgroundColor             = .clear
        isOpaque                    = false
        level                       = .floating
        // NSPanel defaults hidesOnDeactivate=true, which closes the window whenever
        // a context menu or other popup steals key status. Disable it.
        hidesOnDeactivate           = false
        collectionBehavior         = [.canJoinAllSpaces, .fullScreenAuxiliary]
        minSize                    = NSSize(width: 640, height: 460)
        contentView                = NSHostingView(rootView: ClipboardHistoryView())
    }

    func toggle() {
        if isVisible { orderOut(nil) } else { show() }
    }

    private func show() {
        // Collapse the island so it doesn't sit on top of this window
        NotificationCenter.default.post(name: .miraRequestCollapse, object: nil)

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(
                x: f.minX + (f.width  - frame.width)  / 2,
                y: f.minY + (f.height - frame.height) / 2
            ))
        }
        // Activate the app so makeKeyAndOrderFront actually brings the window front.
        // The island runs as a non-activating panel, so the app may not be active.
        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)
    }
}

// MARK: - Main view

struct ClipboardHistoryView: View {

    @ObservedObject private var monitor = ClipboardMonitorService.shared
    @ObservedObject private var queue   = MultiCopyQueueService.shared

    @State private var query       = ""
    @State private var activeTab   = FilterTab.all
    @State private var pastedIDs   = Set<UUID>()
    @State private var ocrItem:    ClipboardItem? = nil
    @State private var reminderItem: ClipboardItem? = nil

    // MARK: Filter model

    enum FilterTab: String, CaseIterable, Identifiable {
        case all       = "History"
        case favorites = "Favorites"
        case text      = "Text"
        case images    = "Images"
        case colors    = "Colors"
        case urls      = "URLs"
        case code      = "Code"
        case files     = "Files"

        var id: String { rawValue }

        var starIcon: String? { self == .favorites ? "star.fill" : nil }

        func count(in history: [ClipboardItem]) -> Int {
            switch self {
            case .all:       return history.count
            case .favorites: return history.filter { $0.isPinned }.count
            case .text:      return history.filter { $0.kind == .text  }.count
            case .images:    return history.filter { $0.kind == .image }.count
            case .colors:    return history.filter { $0.kind == .color }.count
            case .urls:      return history.filter { $0.kind == .url   }.count
            case .code:      return history.filter { $0.kind == .code  }.count
            case .files:     return history.filter { $0.kind == .file  }.count
            }
        }

        func filter(_ items: [ClipboardItem]) -> [ClipboardItem] {
            switch self {
            case .all:       return items
            case .favorites: return items.filter { $0.isPinned }
            case .text:      return items.filter { $0.kind == .text  }
            case .images:    return items.filter { $0.kind == .image }
            case .colors:    return items.filter { $0.kind == .color }
            case .urls:      return items.filter { $0.kind == .url   }
            case .code:      return items.filter { $0.kind == .code  }
            case .files:     return items.filter { $0.kind == .file  }
            }
        }
    }

    private var filtered: [ClipboardItem] {
        var items = activeTab.filter(monitor.history)
        if !query.isEmpty {
            let q = query.lowercased()
            items = items.filter {
                ($0.text     ?? "").lowercased().contains(q) ||
                ($0.ocrText  ?? "").lowercased().contains(q) ||
                ($0.label    ?? "").lowercased().contains(q) ||
                $0.displayTitle.lowercased().contains(q) ||
                ($0.sourceApp ?? "").lowercased().contains(q)
            }
        }
        return items
    }

    // MARK: Body

    var body: some View {
        ZStack {
            // Frosted glass background matching notch island style
            ClipWindowBackground()
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                filterStrip
                Divider().opacity(0.08)
                if filtered.isEmpty {
                    emptyState
                } else {
                    cardGrid
                }
                statusBar
            }

            // Overlays
            if let item = ocrItem {
                ImageDetailOverlay(
                    item:      item,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.15)) { ocrItem = nil } },
                    onPaste:   { pasteItem(item) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }
            if let item = reminderItem {
                ReminderPickerView(
                    item:      item,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.15)) { reminderItem = nil } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: ocrItem?.id)
        .animation(.easeInOut(duration: 0.15), value: reminderItem?.id)
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: 12) {
            // Traffic lights sit in the real title bar — add a spacer so search doesn't crowd them
            Spacer().frame(width: 72)

            // Centered search pill
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 13))
                    .foregroundColor(.white.opacity(0.35))
                TextField("Search clipboard…", text: $query)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .frame(maxWidth: 400)

            Spacer()

            // Toolbar buttons
            HStack(spacing: 6) {
                toolbarBtn(icon: "star") {
                    withAnimation(.easeInOut(duration: 0.15)) { activeTab = .favorites }
                }
                toolbarBtn(icon: "square.grid.2x2") { }
                Divider()
                    .frame(height: 16)
                    .opacity(0.25)
                Button {
                    monitor.clear(keepPinned: true)
                } label: {
                    Text("Clear")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.white.opacity(0.07))
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private func toolbarBtn(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 30, height: 30)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    // MARK: Filter strip (collection tabs)

    private var filterStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(FilterTab.allCases) { tab in
                    let count = tab.count(in: monitor.history)
                    if tab == .all || tab == .favorites || count > 0 {
                        filterPill(tab: tab, count: count)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private func filterPill(tab: FilterTab, count: Int) -> some View {
        let isActive = activeTab == tab
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { activeTab = tab }
        } label: {
            HStack(spacing: 5) {
                if let icon = tab.starIcon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(isActive ? .white.opacity(0.65) : .white.opacity(0.3))
                }
            }
            .foregroundColor(isActive ? .white : .white.opacity(0.5))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                isActive
                    ? DS.Colors.accent
                    : Color.white.opacity(0.07),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .animation(.easeInOut(duration: 0.15), value: isActive)
    }

    // MARK: Card grid

    private var cardGrid: some View {
        ScrollView(showsIndicators: false) {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 190, maximum: 300), spacing: 8)],
                spacing: 8
            ) {
                ForEach(filtered) { item in
                    ClipCard(
                        item:          item,
                        isHighlighted: false,
                        inQueue:       queue.queue.contains { $0.id == item.id },
                        justPasted:    pastedIDs.contains(item.id),
                        onPaste: {
                            if item.kind == .image {
                                withAnimation(.easeInOut(duration: 0.15)) { ocrItem = item }
                            } else {
                                pasteItem(item)
                            }
                        },
                        onAskReminder: {
                            withAnimation(.easeInOut(duration: 0.15)) { reminderItem = item }
                        }
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
    }

    // MARK: Status bar

    private var statusBar: some View {
        HStack {
            Text("\(filtered.count) of \(monitor.history.count) clips")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.black.opacity(0.15))
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clipboard")
                .font(.system(size: 40))
                .foregroundColor(.white.opacity(0.1))
            Text(query.isEmpty ? "Nothing here yet — copy something" : "No results for \"\(query)\"")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.3))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Paste action

    private func pasteItem(_ item: ClipboardItem) {
        monitor.copyToPasteboard(item)
        pastedIDs.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pastedIDs.remove(item.id) }
        ClipboardHistoryPanel.shared.close()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            let src = CGEventSource(stateID: .combinedSessionState)
            CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply  { $0.flags = .maskCommand }
            CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
        }
    }
}

// MARK: - Window background (dark glass matching island)

private struct ClipWindowBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material     = .hudWindow
        v.blendingMode = .behindWindow
        v.state        = .active
        v.wantsLayer   = true
        v.layer?.backgroundColor = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 0.92).cgColor
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

// MARK: - CGEvent helper

private extension CGEvent {
    func apply(_ block: (CGEvent) -> Void) {
        block(self)
        self.post(tap: .cgSessionEventTap)
    }
}
