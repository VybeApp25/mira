import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Labs tab entry point

struct LabsTabView: View {
    enum SubTab: String, CaseIterable {
        case clipboard = "Clipboard"
        case shelf     = "Shelf"
        case shortcuts = "Shortcuts"
        case queue     = "Queue"
        case reminders = "Reminders"

        var icon: String {
            switch self {
            case .clipboard: return "clipboard"
            case .shelf:     return "tray.full"
            case .shortcuts: return "keyboard"
            case .queue:     return "list.number"
            case .reminders: return "bell"
            }
        }
    }

    @State private var subTab: SubTab = .clipboard
    @State private var highlightClipID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            subTabPicker
            Divider().opacity(0.1)
            content
        }
        .onReceive(NotificationCenter.default.publisher(for: .miraShowLabsClipboard)) { notif in
            subTab = .clipboard
            highlightClipID = notif.object as? UUID
        }
    }

    private var subTabPicker: some View {
        HStack(spacing: 2) {
            ForEach(SubTab.allCases, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { subTab = tab }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                        if subTab == tab {
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
                        }
                    }
                    .foregroundColor(subTab == tab ? .white : .white.opacity(0.35))
                    .padding(.horizontal, subTab == tab ? 10 : 7)
                    .padding(.vertical, 5)
                    .background(subTab == tab ? DS.Colors.accent.opacity(0.22) : Color.clear)
                    .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var content: some View {
        switch subTab {
        case .clipboard: ClipboardLabsView(highlightID: $highlightClipID)
        case .shelf:     FileShelfLabsView()
        case .shortcuts: ShortcutsLabsView()
        case .queue:     QueueLabsView()
        case .reminders: RemindersLabsView()
        }
    }
}

// MARK: - Clipboard sub-tab

private struct ClipboardLabsView: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared
    @ObservedObject private var queue   = MultiCopyQueueService.shared
    @Binding var highlightID: UUID?

    @State private var query        = ""
    @State private var filter: Kind? = nil
    @State private var pastedIDs    = Set<UUID>()

    private typealias Kind = ClipboardItem.Kind

    private var filtered: [ClipboardItem] {
        var items = monitor.history
        if let f = filter { items = items.filter { $0.kind == f } }
        else if filter == nil && pinnedOnly {
            items = items.filter { $0.isPinned }
        }
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

    @State private var pinnedOnly        = false
    @State private var ocrDetailItem:    ClipboardItem? = nil   // image detail overlay
    @State private var reminderPickerItem: ClipboardItem? = nil // custom reminder picker

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                searchBar
                categoryTabs
                Divider().opacity(0.08)
                if filtered.isEmpty {
                    emptyState
                } else {
                    cardGrid
                }
                footer
            }

            // Image + OCR detail overlay
            if let detail = ocrDetailItem {
                ImageDetailOverlay(
                    item:      detail,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.15)) { ocrDetailItem = nil } },
                    onPaste:   { pasteItem(detail) }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(10)
            }

            // Beautiful reminder date/time picker overlay
            if let pickerItem = reminderPickerItem {
                ReminderPickerView(
                    item:      pickerItem,
                    onDismiss: { withAnimation(.easeInOut(duration: 0.15)) { reminderPickerItem = nil } }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.97)))
                .zIndex(11)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: ocrDetailItem?.id)
        .animation(.easeInOut(duration: 0.15), value: reminderPickerItem?.id)
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
            TextField("Search clipboard history…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.white.opacity(0.3))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .padding(.horizontal, 10)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }

    // MARK: Category tabs (Supaste-style)

    private var categoryTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                // Starred/Pinned
                categoryTab(
                    icon:     "star.fill",
                    label:    nil,
                    count:    monitor.history.filter { $0.isPinned }.count,
                    selected: pinnedOnly && filter == nil
                ) {
                    filter = nil
                    withAnimation { pinnedOnly.toggle() }
                }

                categoryTab(label: "All",    count: monitor.history.count,                        selected: filter == nil && !pinnedOnly) { filter = nil; pinnedOnly = false }
                categoryTab(label: "Text",   count: monitor.history.filter { $0.kind == .text   }.count, selected: filter == .text)   { setFilter(.text) }
                categoryTab(label: "Images", count: monitor.history.filter { $0.kind == .image  }.count, selected: filter == .image)  { setFilter(.image) }
                categoryTab(label: "Colors", count: monitor.history.filter { $0.kind == .color  }.count, selected: filter == .color)  { setFilter(.color) }
                categoryTab(label: "URLs",   count: monitor.history.filter { $0.kind == .url    }.count, selected: filter == .url)    { setFilter(.url) }
                categoryTab(label: "Code",   count: monitor.history.filter { $0.kind == .code   }.count, selected: filter == .code)   { setFilter(.code) }
                categoryTab(label: "Files",  count: monitor.history.filter { $0.kind == .file   }.count, selected: filter == .file)   { setFilter(.file) }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 7)
        }
    }

    private func setFilter(_ kind: Kind) {
        pinnedOnly = false
        withAnimation { filter = (filter == kind) ? nil : kind }
    }

    private func categoryTab(icon: String? = nil, label: String?, count: Int, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .medium))
                }
                if let label {
                    Text(label)
                        .font(.system(size: 11, weight: selected ? .semibold : .medium))
                }
                if count > 0 {
                    Text("\(count)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(selected ? .white.opacity(0.7) : .white.opacity(0.35))
                }
            }
            .foregroundColor(selected ? .white : .white.opacity(0.45))
            .padding(.horizontal, label == nil ? 9 : 10)
            .padding(.vertical, 5)
            .background(
                selected
                    ? (label == nil ? Color.orange.opacity(0.2) : DS.Colors.accent.opacity(0.22))
                    : Color.white.opacity(0.06)
            )
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Card grid

    private var cardGrid: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150, maximum: 260), spacing: 6)],
                    spacing: 6
                ) {
                    ForEach(filtered) { item in
                        ClipCard(
                            item:          item,
                            isHighlighted: highlightID == item.id,
                            inQueue:       queue.queue.contains { $0.id == item.id },
                            justPasted:    pastedIDs.contains(item.id),
                            onPaste: {
                                // Images open the detail/OCR view; everything else pastes directly
                                if item.kind == .image {
                                    withAnimation(.easeInOut(duration: 0.15)) { ocrDetailItem = item }
                                } else {
                                    pasteItem(item)
                                }
                            },
                            onAskReminder: {
                                withAnimation(.easeInOut(duration: 0.15)) { reminderPickerItem = item }
                            }
                        )
                        .id(item.id)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .onChange(of: highlightID) { _, id in
                if let id { withAnimation { proxy.scrollTo(id, anchor: .top) } }
            }
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private func clipContextMenu(for item: ClipboardItem) -> some View {
        Button { pasteItem(item) } label: {
            Label("Paste", systemImage: "doc.on.clipboard")
        }
        Button { monitor.copyToPasteboard(item) } label: {
            Label("Copy", systemImage: "doc.on.doc")
        }
        Divider()
        Button { queue.enqueue(item) } label: {
            Label("Add to Queue", systemImage: "list.number")
        }
        Divider()
        Button { monitor.togglePin(item) } label: {
            Label(item.isPinned ? "Unpin" : "Pin",
                  systemImage: item.isPinned ? "pin.slash" : "pin")
        }
        Button { askLabel(for: item) } label: {
            Label("Label…", systemImage: "tag")
        }
        Button { askReminder(for: item) } label: {
            Label(item.reminderDate != nil ? "Change Reminder…" : "Remind Me…",
                  systemImage: "bell")
        }
        if item.reminderDate != nil {
            Button { monitor.setReminder(nil, for: item) } label: {
                Label("Clear Reminder", systemImage: "bell.slash")
            }
        }
        Divider()
        Button(role: .destructive) { monitor.delete(item) } label: {
            Label("Delete", systemImage: "trash")
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text("\(monitor.history.count) clips")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.25))
            Spacer()
            Button {
                NotificationCenter.default.post(name: .miraShowClipboard, object: nil)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.system(size: 10))
                    Text("Full Window")
                        .font(.system(size: 11))
                }
                .foregroundColor(.white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help("Open clipboard in a large moveable window")
            Spacer()
            Button { monitor.clear(keepPinned: true) } label: {
                Text("Clear")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    // MARK: Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "clipboard")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text(query.isEmpty ? "Copy something to get started" : "No results for \"\(query)\"")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    private func pasteItem(_ item: ClipboardItem) {
        monitor.copyToPasteboard(item)
        pastedIDs.insert(item.id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { pastedIDs.remove(item.id) }
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply  { $0.flags = .maskCommand }
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
        // Quick Paste: collapse the island so the user returns to their app immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .miraRequestCollapse, object: nil)
        }
    }

    private func askLabel(for item: ClipboardItem) {
        let alert = NSAlert()
        alert.messageText = "Label this clip"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        tf.stringValue       = item.label ?? ""
        tf.placeholderString = "e.g. Work email, API key…"
        alert.accessoryView  = tf
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.setLabel(tf.stringValue, for: item)
        }
    }

    private func askReminder(for item: ClipboardItem) {
        let alert = NSAlert()
        alert.messageText     = "Remind me about this clip"
        alert.informativeText = item.displayTitle
        alert.addButton(withTitle: "Set Reminder")
        alert.addButton(withTitle: "Cancel")
        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 240, height: 28))
        picker.datePickerStyle    = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinute]
        picker.minDate            = Date()
        picker.dateValue          = item.reminderDate ?? Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        alert.accessoryView       = picker
        if alert.runModal() == .alertFirstButtonReturn {
            monitor.setReminder(picker.dateValue, for: item)
        }
    }
}

// MARK: - Clip card (Supaste-style grid card)

struct ClipCard: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared
    let item:          ClipboardItem
    let isHighlighted: Bool
    let inQueue:       Bool
    let justPasted:    Bool
    let onPaste:       () -> Void
    let onAskReminder: () -> Void

    @State private var hovering = false

    init(item: ClipboardItem, isHighlighted: Bool, inQueue: Bool, justPasted: Bool,
         onPaste: @escaping () -> Void, onAskReminder: @escaping () -> Void) {
        self.item          = item
        self.isHighlighted = isHighlighted
        self.inQueue       = inQueue
        self.justPasted    = justPasted
        self.onPaste       = onPaste
        self.onAskReminder = onAskReminder
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Card background / content
            cardContent

            // Bottom meta: source app + time
            VStack(spacing: 0) {
                Spacer()
                bottomBar
            }

            // Status badges top-left
            if item.isPinned || inQueue || item.reminderDate != nil || item.label != nil {
                HStack(spacing: 3) {
                    if item.isPinned {
                        statusBadge(icon: "pin.fill", tint: .orange)
                    }
                    if inQueue {
                        statusBadge(icon: "list.number", tint: DS.Colors.accent)
                    }
                    if item.reminderDate != nil {
                        statusBadge(icon: "bell.fill", tint: .yellow)
                    }
                    if let lbl = item.label {
                        Text(lbl)
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(.white.opacity(0.75))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.5))
                            .clipShape(Capsule())
                    }
                }
                .padding(5)
            }

            // Paste feedback overlay
            if justPasted {
                ZStack {
                    Color.black.opacity(0.5)
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(.white)
                        Text("Pasted")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.white.opacity(0.8))
                    }
                }
            }
        }
        .frame(height: 110)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isHighlighted ? DS.Colors.accent :
                    hovering      ? Color.white.opacity(0.18) : Color.white.opacity(0.06),
                    lineWidth: isHighlighted ? 1.5 : 1
                )
        )
        // Cocoa-native drag handler — sits below hover buttons so buttons keep click priority.
        // Handles tap, drag-to-other-app, hover tracking, and right-click context menu.
        .overlay(
            ClipDragHandler(
                item: item,
                onPaste: onPaste,
                onHoverChange:  { h in withAnimation(.easeInOut(duration: 0.1)) { hovering = h } },
                onAskReminder:  onAskReminder
            )
        )
        // Hover buttons rendered above the drag handler so SwiftUI intercepts their clicks first
        .overlay(
            Group {
                if hovering && !justPasted {
                    VStack {
                        HStack { Spacer(); hoverActions.padding(5) }
                        Spacer()
                    }
                }
            }
        )
        .animation(.easeInOut(duration: 0.1), value: justPasted)
    }

    // MARK: Card content

    @ViewBuilder
    private var cardContent: some View {
        switch item.kind {
        case .image:
            imageCard
        case .color:
            colorCard
        default:
            textCard
        }
    }

    private var imageCard: some View {
        Group {
            if let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                Color(red: 0.14, green: 0.14, blue: 0.16)
                    .overlay(
                        Image(systemName: "photo")
                            .font(.system(size: 22))
                            .foregroundColor(.white.opacity(0.2))
                    )
            }
        }
    }

    private var colorCard: some View {
        Group {
            if let hex = item.text, !hex.isEmpty {
                Color(hex: hex).overlay(
                    VStack {
                        Spacer()
                        Text(hex.uppercased())
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.9))
                            .shadow(color: .black.opacity(0.5), radius: 3)
                            .padding(.bottom, 28)
                    }
                )
            } else {
                Color(red: 0.14, green: 0.14, blue: 0.16)
            }
        }
    }

    private var textCard: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 0.11, green: 0.11, blue: 0.14)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.displayTitle)
                    .font(item.kind == .code
                          ? .system(size: 10, weight: .regular, design: .monospaced)
                          : .system(size: 11, weight: .regular))
                    .foregroundColor(.white.opacity(item.kind == .url ? 0.6 : 0.85))
                    .lineLimit(4)
                    .padding(.horizontal, 9)
                    .padding(.top, 9)
                    .padding(.bottom, 2)
                Spacer()
            }
        }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 4) {
            if let app = item.sourceApp {
                Text(appIcon(app))
                    .font(.system(size: 10))
                Text(app)
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.45))
                    .lineLimit(1)
            }
            Spacer()
            Text(item.copiedAt, style: .relative)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
            if item.kind == .image, let data = item.imageData {
                Text(formatBytes(data.count))
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(needsGradient ? 0.7 : 0.45)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var needsGradient: Bool {
        item.kind == .image || item.kind == .color
    }

    // MARK: Hover actions

    private var hoverActions: some View {
        HStack(spacing: 3) {
            cardActionBtn(icon: "doc.on.clipboard.fill") { onPaste() }
            cardActionBtn(icon: item.isPinned ? "pin.slash.fill" : "pin.fill") {
                monitor.togglePin(item)
            }
            cardActionBtn(icon: "bell.fill",
                          tint: item.reminderDate != nil ? .yellow : .white) {
                onAskReminder()
            }
            cardActionBtn(icon: "trash", tint: .red) {
                monitor.delete(item)
            }
        }
    }

    private func cardActionBtn(icon: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(tint.opacity(0.85))
                .frame(width: 24, height: 24)
                .background(Color.black.opacity(0.55))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private func statusBadge(icon: String, tint: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 8))
            .foregroundColor(tint)
            .padding(4)
            .background(Color.black.opacity(0.5))
            .clipShape(Circle())
    }

    private func appIcon(_ appName: String) -> String {
        switch appName.lowercased() {
        case let n where n.contains("chrome"):   return "🌐"
        case let n where n.contains("safari"):   return "🧭"
        case let n where n.contains("mail"):     return "✉️"
        case let n where n.contains("slack"):    return "💬"
        case let n where n.contains("figma"):    return "🎨"
        case let n where n.contains("xcode"):    return "🔨"
        case let n where n.contains("terminal"): return "⌨️"
        case let n where n.contains("notion"):   return "📝"
        case let n where n.contains("vs code"):  return "💻"
        default: return "📋"
        }
    }

    private func formatBytes(_ n: Int) -> String {
        if n < 1024 { return "\(n) B" }
        if n < 1024 * 1024 { return "\(n / 1024) KB" }
        return String(format: "%.1f MB", Double(n) / 1_048_576)
    }
}

// MARK: - Shortcuts sub-tab

private struct ShortcutsLabsView: View {
    @ObservedObject private var svc = TextExpansionService.shared
    @State private var showAdd = false
    @State private var editing: TextExpansion?

    var body: some View {
        VStack(spacing: 0) {
            shortcutsHeader
            if svc.expansions.isEmpty {
                emptyShortcuts
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(spacing: 4) {
                        ForEach(svc.expansions) { exp in
                            ExpansionRow(expansion: exp) { editing = exp }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .sheet(isPresented: $showAdd) { ExpansionEditor(existing: nil) }
        .sheet(item: $editing)        { ExpansionEditor(existing: $0) }
    }

    private var shortcutsHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Inline Shortcuts")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("Click a chip to paste · or type it anywhere to expand")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            Spacer()
            Button { showAdd = true } label: {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(DS.Colors.accent)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyShortcuts: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "keyboard")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text("No shortcuts yet")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
            Text("Type `;em` and it expands to your email. Add one below.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.2))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Button { showAdd = true } label: {
                Text("Add Shortcut")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.accent)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ExpansionRow: View {
    let expansion: TextExpansion
    let onEdit: () -> Void
    @State private var hovering = false
    @State private var justPasted = false

    var body: some View {
        HStack(spacing: 10) {
            // Trigger chip — click to use inline
            Button {
                pasteExpansion()
            } label: {
                HStack(spacing: 4) {
                    Text(expansion.shortcut)
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(justPasted ? .white : DS.Colors.accent)
                    if justPasted {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(.white)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(justPasted ? DS.Colors.accent : DS.Colors.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
            .buttonStyle(.plain)
            .help("Click to paste this shortcut's expansion")

            VStack(alignment: .leading, spacing: 1) {
                if let label = expansion.label {
                    Text(label)
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.35))
                }
                Text(expansion.expansion)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.75))
                    .lineLimit(1)
            }

            Spacer()

            if hovering {
                HStack(spacing: 4) {
                    Button { onEdit() } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    Button { TextExpansionService.shared.remove(id: expansion.id) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.red.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Color.white.opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.white.opacity(0.04) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
        .onTapGesture { onEdit() }
        .animation(.easeInOut(duration: 0.15), value: justPasted)
    }

    private func pasteExpansion() {
        let board = NSPasteboard.general
        let saved = board.string(forType: .string)
        board.clearContents()
        board.setString(expansion.expansion, forType: .string)

        // Flash chip green
        withAnimation { justPasted = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation { justPasted = false }
            board.clearContents()
            if let s = saved { board.setString(s, forType: .string) }
        }

        // Collapse island and inject ⌘V into whatever was focused before
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            NotificationCenter.default.post(name: .miraRequestCollapse, object: nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let src = CGEventSource(stateID: .combinedSessionState)
                CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply { $0.flags = .maskCommand }
                CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
            }
        }
    }
}

private struct ExpansionEditor: View {
    let existing: TextExpansion?
    @Environment(\.dismiss) private var dismiss

    @State private var shortcut   = ""
    @State private var expansion  = ""
    @State private var label      = ""

    init(existing: TextExpansion?) {
        self.existing = existing
        _shortcut  = State(initialValue: existing?.shortcut   ?? "")
        _expansion = State(initialValue: existing?.expansion  ?? "")
        _label     = State(initialValue: existing?.label      ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(existing == nil ? "New Shortcut" : "Edit Shortcut")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(.white.opacity(0.85))

            field("Shortcut", text: $shortcut, placeholder: ";em")
            field("Expands to", text: $expansion, placeholder: "trevonbarbour@gmail.com")
            field("Label (optional)", text: $label, placeholder: "Work email")

            HStack {
                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundColor(.white.opacity(0.4))
                Spacer()
                Button(existing == nil ? "Add" : "Save") { save() }
                    .buttonStyle(.plain)
                    .foregroundColor(DS.Colors.accent)
                    .disabled(shortcut.isEmpty || expansion.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 300)
        .background(Color(red: 0.1, green: 0.1, blue: 0.12))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.white.opacity(0.4))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 7))
        }
    }

    private func save() {
        let exp = TextExpansion(
            id:        existing?.id ?? UUID(),
            shortcut:  shortcut.trimmingCharacters(in: .whitespaces),
            expansion: expansion,
            label:     label.isEmpty ? nil : label
        )
        if existing != nil { TextExpansionService.shared.update(exp) }
        else               { TextExpansionService.shared.add(exp) }
        dismiss()
    }
}

// MARK: - Queue sub-tab

private struct QueueLabsView: View {
    @ObservedObject private var queue = MultiCopyQueueService.shared

    var body: some View {
        VStack(spacing: 0) {
            queueHeader
            if queue.isEmpty {
                emptyQueue
            } else {
                queueList
            }
        }
    }

    private var queueHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Multi-Copy Queue")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                if !queue.isEmpty {
                    Text("Next: \(queue.nextPreview ?? "")")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.35))
                        .lineLimit(1)
                }
            }
            Spacer()
            if !queue.isEmpty {
                HStack(spacing: 6) {
                    Button { queue.pasteNext() } label: {
                        Label("Paste Next", systemImage: "arrow.right.circle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DS.Colors.accent)
                            .clipShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    Button { queue.clear() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 12))
                            .foregroundColor(.white.opacity(0.3))
                    }
                    .buttonStyle(.plain)
                    .help("Clear queue")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var queueList: some View {
        ScrollView(showsIndicators: false) {
            LazyVStack(spacing: 3) {
                ForEach(Array(queue.queue.enumerated()), id: \.element.id) { index, item in
                    QueueRow(item: item, position: index + 1)
                }
                .onMove { from, to in queue.move(from: from, to: to) }
                .onDelete { queue.dequeue(id: queue.queue[$0.first!].id) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var emptyQueue: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "list.number")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text("Queue is empty")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
            Text("Right-click any clip and choose \"Add to Queue\" to build a paste sequence.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.2))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct QueueRow: View {
    let item: ClipboardItem
    let position: Int
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text("\(position)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundColor(DS.Colors.accent.opacity(0.7))
                .frame(width: 20, alignment: .center)

            if item.kind == .image, let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.4))
                    .frame(width: 26, height: 26)
            }

            Text(item.displayTitle)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.75))
                .lineLimit(1)

            Spacer()

            if hovering {
                Button { MultiCopyQueueService.shared.dequeue(id: item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Color.white.opacity(0.05) : Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .onHover { hovering = $0 }
    }
}

// MARK: - Reminders sub-tab

private struct RemindersLabsView: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared

    private var remindedItems: [ClipboardItem] {
        monitor.history.filter { $0.reminderDate != nil }.sorted {
            ($0.reminderDate ?? .distantFuture) < ($1.reminderDate ?? .distantFuture)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            remindersHeader
            if remindedItems.isEmpty {
                emptyReminders
            } else {
                remindersList
            }
        }
    }

    private var remindersHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clip Reminders")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white.opacity(0.7))
                Text("Get notified when it's time to paste")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.3))
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var remindersList: some View {
        ScrollView(showsIndicators: false) {
            VStack(spacing: 4) {
                ForEach(remindedItems) { item in
                    ReminderRow(item: item)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private var emptyReminders: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 28))
                .foregroundColor(.white.opacity(0.1))
            Text("No reminders set")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.25))
            Text("Right-click any clip and choose \"Remind Me…\" to schedule a reminder.")
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.2))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }
}

private struct ReminderRow: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared
    let item: ClipboardItem
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                    .frame(width: 34, height: 34)
                Image(systemName: "bell.fill")
                    .font(.system(size: 13))
                    .foregroundColor(.orange.opacity(0.8))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if let date = item.reminderDate {
                    (
                        Text(date, style: .relative)
                            .foregroundColor(date < Date() ? .red.opacity(0.7) : .white.opacity(0.4))
                        + Text("  ·  " + date.formatted(date: .abbreviated, time: .shortened))
                            .foregroundColor(.white.opacity(0.25))
                    )
                    .font(.system(size: 10))
                }
            }

            Spacer()

            if hovering {
                Button { monitor.setReminder(nil, for: item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                        .frame(width: 22, height: 22)
                        .background(Color.white.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
                .help("Clear reminder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(hovering ? Color.white.opacity(0.04) : Color.white.opacity(0.025))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onHover { hovering = $0 }
    }
}

// MARK: - Cocoa-native drag handler
//
// SwiftUI's .onDrag doesn't cross app boundaries from a floating NSPanel (.nonactivatingPanel).
// DragProxyNSView uses beginDraggingSession which is the Cocoa API that works correctly.
// It also hides the island window when a drag begins so the destination window is visible.

struct ClipDragHandler: NSViewRepresentable {
    let item:          ClipboardItem
    let onPaste:       () -> Void
    let onHoverChange: (Bool) -> Void
    let onAskReminder: () -> Void

    func makeNSView(context: Context) -> DragProxyNSView {
        let v = DragProxyNSView()
        configure(v)
        return v
    }
    func updateNSView(_ v: DragProxyNSView, context: Context) { configure(v) }

    private func configure(_ v: DragProxyNSView) {
        v.item = item; v.onPaste = onPaste; v.onHoverChange = onHoverChange
        v.onAskReminder = onAskReminder
    }
}

final class DragProxyNSView: NSView, NSDraggingSource, NSFilePromiseProviderDelegate {
    var item:          ClipboardItem?
    var onPaste:       (() -> Void)?
    var onHoverChange: ((Bool) -> Void)?
    var onAskReminder: (() -> Void)?

    private var downPt:        NSPoint?
    private var didDrag        = false
    private weak var srcWindow: NSWindow?
    private var trackingArea:  NSTrackingArea?

    // MARK: Hover tracking

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        let ta = NSTrackingArea(rect: bounds,
                                options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    override func mouseEntered(with event: NSEvent) { onHoverChange?(true) }
    override func mouseExited(with event: NSEvent)  { onHoverChange?(false) }

    // MARK: Tap (mouseDown + mouseUp without drag movement)

    override func mouseDown(with event: NSEvent) {
        downPt  = convert(event.locationInWindow, from: nil)
        didDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        if !didDrag { onPaste?() }
        downPt = nil
    }

    // MARK: Drag initiation via Cocoa beginDraggingSession

    override func mouseDragged(with event: NSEvent) {
        guard let item, let start = downPt else { return }
        let cur = convert(event.locationInWindow, from: nil)
        guard hypot(cur.x - start.x, cur.y - start.y) > 4 else { return }
        didDrag = true
        guard let dragItems = buildDragItems(for: item) else { return }
        srcWindow = window
        let session = beginDraggingSession(with: dragItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    // MARK: NSDraggingSource

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }

    // Hide the island when drag starts so the destination window is fully visible
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        srcWindow?.orderOut(nil)
    }

    // Restore the island when drag ends (drop or cancel)
    func draggingSession(_ session: NSDraggingSession,
                         endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        srcWindow?.orderFrontRegardless()
    }

    // MARK: Right-click context menu (replaces SwiftUI .contextMenu)

    override func rightMouseDown(with event: NSEvent) {
        guard let item else { return }
        // Pin the island so hover-exit doesn't collapse it while the menu is open.
        // NSMenu.popUpContextMenu is synchronous, so unpin lands right after it closes.
        NotificationCenter.default.post(name: .miraPinIsland, object: nil, userInfo: ["pinned": true])
        let menu = NSMenu()

        addItem(to: menu, title: "Paste",  symbol: "doc.on.clipboard") { [weak self] in self?.onPaste?() }
        addItem(to: menu, title: "Copy",   symbol: "doc.on.doc")       { ClipboardMonitorService.shared.copyToPasteboard(item) }
        menu.addItem(.separator())
        addItem(to: menu, title: "Add to Queue", symbol: "list.number") { MultiCopyQueueService.shared.enqueue(item) }
        menu.addItem(.separator())
        addItem(to: menu,
                title:  item.isPinned ? "Unpin" : "Pin",
                symbol: item.isPinned ? "pin.slash" : "pin") { ClipboardMonitorService.shared.togglePin(item) }
        addItem(to: menu, title: "Label…", symbol: "tag") { [weak self] in self?.askLabel(for: item) }

        // Remind Me — submenu with quick presets + custom picker
        let remindParent = NSMenuItem(title: item.reminderDate != nil ? "Change Reminder…" : "Remind Me…",
                                      action: nil, keyEquivalent: "")
        remindParent.image = NSImage(systemSymbolName: "bell", accessibilityDescription: nil)
        let remindSub = NSMenu()
        let cal = Calendar.current
        let today   = cal.startOfDay(for: Date())
        let tmrw    = cal.date(byAdding: .day, value: 1, to: today) ?? today
        let at9     = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tmrw) ?? tmrw
        addQuickReminder(to: remindSub, title: "In 30 minutes",   date: Date().addingTimeInterval(30 * 60),   item: item)
        addQuickReminder(to: remindSub, title: "In 1 hour",        date: Date().addingTimeInterval(3600),       item: item)
        addQuickReminder(to: remindSub, title: "In 3 hours",       date: Date().addingTimeInterval(3 * 3600),  item: item)
        addQuickReminder(to: remindSub, title: "Tomorrow at 9 am", date: at9,                                  item: item)
        remindSub.addItem(.separator())
        addItem(to: remindSub, title: "Custom…", symbol: "calendar") { [weak self] in self?.onAskReminder?() }
        remindParent.submenu = remindSub
        menu.addItem(remindParent)

        if item.reminderDate != nil {
            addItem(to: menu, title: "Clear Reminder", symbol: "bell.slash") {
                ClipboardMonitorService.shared.setReminder(nil, for: item)
            }
        }
        menu.addItem(.separator())
        let del = addItem(to: menu, title: "Delete", symbol: "trash") {
            ClipboardMonitorService.shared.delete(item)
        }
        del.attributedTitle = NSAttributedString(
            string: "Delete",
            attributes: [.foregroundColor: NSColor.systemRed])
        NSMenu.popUpContextMenu(menu, with: event, for: self)
        NotificationCenter.default.post(name: .miraPinIsland, object: nil, userInfo: ["pinned": false])
    }

    @discardableResult
    private func addQuickReminder(to menu: NSMenu, title: String, date: Date,
                                   item: ClipboardItem) -> NSMenuItem {
        addItem(to: menu, title: title, symbol: "clock") {
            ClipboardMonitorService.shared.setReminder(date, for: item)
        }
    }

    @discardableResult
    private func addItem(to menu: NSMenu, title: String, symbol: String,
                         action: @escaping () -> Void) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        mi.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        mi.representedObject = action
        mi.target = self
        menu.addItem(mi)
        return mi
    }

    @objc private func runAction(_ sender: NSMenuItem) {
        (sender.representedObject as? () -> Void)?()
    }

    // MARK: Label / reminder dialogs

    private func askLabel(for item: ClipboardItem) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Label this clip"
            alert.addButton(withTitle: "Save")
            alert.addButton(withTitle: "Cancel")
            let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
            tf.stringValue       = item.label ?? ""
            tf.placeholderString = "e.g. Work email, API key…"
            alert.accessoryView  = tf
            if alert.runModal() == .alertFirstButtonReturn {
                ClipboardMonitorService.shared.setLabel(tf.stringValue, for: item)
            }
        }
    }

    // MARK: NSFilePromiseProviderDelegate (for image file-promise drags)

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              fileNameForType type: String) -> String {
        "mira_clip_\(Int.random(in: 100_000...999_999)).png"
    }

    func filePromiseProvider(_ provider: NSFilePromiseProvider,
                              writePromiseTo url: URL,
                              completionHandler: @escaping (Error?) -> Void) {
        if let data = (provider.userInfo as? Data) {
            do    { try data.write(to: url); completionHandler(nil) }
            catch { completionHandler(error) }
        } else {
            completionHandler(CocoaError(.fileNoSuchFile))
        }
    }

    // MARK: Build dragging items

    private func buildDragItems(for item: ClipboardItem) -> [NSDraggingItem]? {
        switch item.kind {

        case .text, .code:
            let di = NSDraggingItem(pasteboardWriter: (item.text ?? "") as NSString)
            di.setDraggingFrame(bounds, contents: textPreview(item))
            return [di]

        case .url:
            if let str = item.text, let url = URL(string: str) {
                let di = NSDraggingItem(pasteboardWriter: url as NSURL)
                di.setDraggingFrame(bounds, contents: textPreview(item))
                return [di]
            }
            let di = NSDraggingItem(pasteboardWriter: (item.text ?? "") as NSString)
            di.setDraggingFrame(bounds, contents: textPreview(item))
            return [di]

        case .color:
            let di = NSDraggingItem(pasteboardWriter: (item.text ?? "") as NSString)
            di.setDraggingFrame(bounds, contents: colorPreview(item))
            return [di]

        case .image:
            guard let data = item.imageData else { return nil }
            // Write to temp file immediately — avoids NSFilePromiseProvider delegate-lifetime issues
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("mira_drag_\(UUID().uuidString).png")
            try? data.write(to: tmp)
            let di = NSDraggingItem(pasteboardWriter: tmp as NSURL)
            if let img = NSImage(data: data) {
                let sz = NSSize(width: min(bounds.width, 160), height: min(bounds.height, 110))
                let preview = NSImage(size: sz)
                preview.lockFocus()
                img.draw(in: NSRect(origin: .zero, size: sz),
                         from: .zero, operation: .copy, fraction: 1)
                preview.unlockFocus()
                di.setDraggingFrame(NSRect(origin: .zero, size: sz), contents: preview)
            }
            return [di]

        case .file:
            guard let paths = item.filePaths else { return nil }
            let items = paths.compactMap { path -> NSDraggingItem? in
                guard FileManager.default.fileExists(atPath: path) else { return nil }
                let url = URL(fileURLWithPath: path)
                let di  = NSDraggingItem(pasteboardWriter: url as NSURL)
                di.setDraggingFrame(bounds, contents: NSWorkspace.shared.icon(forFile: path))
                return di
            }
            return items.isEmpty ? nil : items
        }
    }

    // MARK: Drag preview images

    private func textPreview(_ item: ClipboardItem) -> NSImage {
        NSImage(size: NSSize(width: 160, height: 80), flipped: false) { rect in
            NSColor(white: 0.1, alpha: 0.92).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            NSAttributedString(
                string: item.displayTitle,
                attributes: [.foregroundColor: NSColor.white.withAlphaComponent(0.85),
                             .font: NSFont.systemFont(ofSize: 11)]
            ).draw(in: rect.insetBy(dx: 8, dy: 8))
            return true
        }
    }

    private func colorPreview(_ item: ClipboardItem) -> NSImage {
        NSImage(size: NSSize(width: 60, height: 60), flipped: false) { [self] rect in
            self.nsColor(hex: item.text ?? "#888888").setFill()
            NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10).fill()
            return true
        }
    }

    private func nsColor(hex: String) -> NSColor {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var rgb: UInt64 = 0
        Scanner(string: h).scanHexInt64(&rgb)
        return NSColor(red:   CGFloat((rgb >> 16) & 0xFF) / 255,
                       green: CGFloat((rgb >> 8)  & 0xFF) / 255,
                       blue:  CGFloat( rgb        & 0xFF) / 255,
                       alpha: 1)
    }

    override var acceptsFirstResponder: Bool { true }
}

// MARK: - Image + OCR detail overlay

struct ImageDetailOverlay: View {
    let item:      ClipboardItem
    let onDismiss: () -> Void
    let onPaste:   () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Header
                HStack {
                    Text(item.sourceApp ?? "Image")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.white.opacity(0.65))
                    Spacer()
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

                // Image preview
                if let data = item.imageData, let img = NSImage(data: data) {
                    Image(nsImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .padding(.horizontal, 14)
                }

                // Action buttons
                HStack(spacing: 8) {
                    detailBtn("Paste Image", icon: "doc.on.clipboard.fill") {
                        onPaste(); onDismiss()
                    }
                    if let text = item.ocrText {
                        detailBtn("Copy Text", icon: "character.cursor.ibeam") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                            onDismiss()
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                // Recognized text
                if let ocr = item.ocrText {
                    Divider().opacity(0.1)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 4) {
                            Image(systemName: "text.viewfinder")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.35))
                            Text("Recognized text")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundColor(.white.opacity(0.35))
                        }
                        ScrollView(showsIndicators: false) {
                            Text(ocr)
                                .font(.system(size: 11))
                                .foregroundColor(.white.opacity(0.75))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                        .frame(maxHeight: 110)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
        }
    }

    private func detailBtn(_ label: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11))
                Text(label).font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(.white.opacity(0.85))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Reminder date/time picker (Supaste-style)

struct ReminderPickerView: View {
    let item:      ClipboardItem
    let onDismiss: () -> Void

    @State private var selectedDay: Date
    @State private var hour:        Int
    @State private var minute:      Int

    private let days: [Date]

    init(item: ClipboardItem, onDismiss: @escaping () -> Void) {
        self.item      = item
        self.onDismiss = onDismiss

        let cal   = Calendar.current
        let today = cal.startOfDay(for: Date())
        let tmrw  = cal.date(byAdding: .day, value: 1, to: today) ?? today

        self.days = (0..<7).compactMap { cal.date(byAdding: .day, value: $0, to: today) }

        let defaultDate: Date
        if let existing = item.reminderDate {
            defaultDate = existing
        } else {
            defaultDate = cal.date(bySettingHour: 9, minute: 0, second: 0, of: tmrw) ?? tmrw
        }

        let comps = cal.dateComponents([.hour, .minute], from: defaultDate)
        _hour        = State(initialValue: comps.hour   ?? 9)
        _minute      = State(initialValue: comps.minute ?? 0)
        _selectedDay = State(initialValue: cal.startOfDay(for: defaultDate))
    }

    private var reminderDate: Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: selectedDay) ?? selectedDay
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.7)
                .onTapGesture { onDismiss() }

            VStack(spacing: 0) {
                // Header with cancel / title / confirm
                HStack {
                    Button { onDismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white.opacity(0.5))
                            .frame(width: 28, height: 28)
                            .background(Color.white.opacity(0.1))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    VStack(spacing: 2) {
                        Text("Pick date & time")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white.opacity(0.9))
                        Text(item.displayTitle)
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.35))
                            .lineLimit(1)
                    }

                    Spacer()

                    Button {
                        ClipboardMonitorService.shared.setReminder(reminderDate, for: item)
                        onDismiss()
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 28, height: 28)
                            .background(DS.Colors.accent)
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)

                Divider().opacity(0.1)

                // Horizontal day strip
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(days, id: \.self) { day in dayChip(day) }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }

                Divider().opacity(0.1)

                // Hour : Minute steppers
                HStack(spacing: 4) {
                    Spacer()
                    timeStepper(value: $hour,   range: 0...23, format: { String(format: "%02d", $0) })
                    Text(":")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                    timeStepper(value: $minute, range: 0...59, step: 5, format: { String(format: "%02d", $0) })
                    Spacer()
                }
                .padding(.vertical, 14)
            }
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.10, blue: 0.13))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.6), radius: 24, y: 8)
            .padding(.horizontal, 10)
            .padding(.vertical, 16)
        }
    }

    private func dayChip(_ day: Date) -> some View {
        let cal        = Calendar.current
        let isSelected = cal.isDate(day, inSameDayAs: selectedDay)
        let label: String = {
            if cal.isDateInToday(day)     { return "Today" }
            if cal.isDateInTomorrow(day)  { return "Tmrw"  }
            return day.formatted(.dateTime.weekday(.abbreviated))
        }()
        let num = day.formatted(.dateTime.day())

        return Button { selectedDay = day } label: {
            VStack(spacing: 2) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.4))
                Text(num)
                    .font(.system(size: 13, weight: isSelected ? .bold : .regular, design: .rounded))
                    .foregroundColor(isSelected ? .white : .white.opacity(0.65))
            }
            .frame(width: 50, height: 46)
            .background(isSelected ? DS.Colors.accent : Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func timeStepper(value: Binding<Int>, range: ClosedRange<Int>,
                              step: Int = 1, format: @escaping (Int) -> String) -> some View {
        HStack(spacing: 10) {
            Button {
                let n = value.wrappedValue - step
                value.wrappedValue = n < range.lowerBound ? range.upperBound : n
            } label: {
                Image(systemName: "minus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)

            Text(format(value.wrappedValue))
                .font(.system(size: 28, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .frame(width: 48, alignment: .center)

            Button {
                let n = value.wrappedValue + step
                value.wrappedValue = n > range.upperBound ? range.lowerBound : n
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(Color.white.opacity(0.08))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
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
