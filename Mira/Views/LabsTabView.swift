import SwiftUI
import AppKit

// MARK: - Labs tab entry point

struct LabsTabView: View {
    enum SubTab: String, CaseIterable {
        case clipboard = "Clipboard"
        case shortcuts = "Shortcuts"
        case queue     = "Queue"
        case reminders = "Reminders"

        var icon: String {
            switch self {
            case .clipboard: return "clipboard"
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

    var body: some View {
        VStack(spacing: 0) {
            searchBar
            filterChips
            Divider().opacity(0.08)
            if filtered.isEmpty {
                emptyState
            } else {
                clipList
            }
            footer
        }
    }

    // MARK: Search

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.3))
            TextField("Search clips…", text: $query)
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

    // MARK: Filter chips

    private var filterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip(label: "All", selected: filter == nil) { filter = nil }
                chip(label: "Text",   icon: "doc.text",     kind: .text)
                chip(label: "URLs",   icon: "link",         kind: .url)
                chip(label: "Code",   icon: "chevron.left.forwardslash.chevron.right", kind: .code)
                chip(label: "Images", icon: "photo",        kind: .image)
                chip(label: "Files",  icon: "folder",       kind: .file)
                chip(label: "Pinned", icon: "pin.fill", selected: false) {
                    // Toggle pinned filter specially
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
        }
    }

    private func chip(label: String, icon: String? = nil, kind: ClipboardItem.Kind? = nil, selected: Bool? = nil, action: (() -> Void)? = nil) -> some View {
        let isSelected = selected ?? (filter == kind)
        return Button {
            if let action { action() }
            else { withAnimation { filter = isSelected ? nil : kind } }
        } label: {
            HStack(spacing: 3) {
                if let icon {
                    Image(systemName: icon).font(.system(size: 9))
                }
                Text(label).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(isSelected ? .white : .white.opacity(0.4))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? DS.Colors.accent.opacity(0.3) : Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: List

    private var clipList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 1) {
                    ForEach(filtered) { item in
                        LabsClipRow(
                            item:         item,
                            isHighlighted: highlightID == item.id,
                            justPasted:   pastedIDs.contains(item.id),
                            inQueue:      queue.queue.contains { $0.id == item.id }
                        )
                        .id(item.id)
                        .contextMenu { clipContextMenu(for: item) }
                    }
                }
                .padding(.vertical, 4)
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
        Button {
            queue.enqueue(item)
        } label: {
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
            Button { monitor.clear(keepPinned: true) } label: {
                Text("Clear")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.35))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            pastedIDs.remove(item.id)
        }
        // Island is .nonactivatingPanel so ⌘V lands in the user's active app
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply { $0.flags = .maskCommand }
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
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

// MARK: - Clip row for Labs

private struct LabsClipRow: View {
    @ObservedObject private var monitor = ClipboardMonitorService.shared
    let item:          ClipboardItem
    let isHighlighted: Bool
    let justPasted:    Bool
    let inQueue:       Bool

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            thumbnail
            info
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(rowBG)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .padding(.horizontal, 6)
        .onHover { hovering = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var rowBG: Color {
        if isHighlighted { return DS.Colors.accent.opacity(0.15) }
        if hovering      { return Color.white.opacity(0.06) }
        return Color.clear
    }

    // MARK: Thumbnail

    private var thumbnail: some View {
        Group {
            if item.kind == .image, let data = item.imageData, let img = NSImage(data: data) {
                Image(nsImage: img)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } else {
                Image(systemName: item.icon)
                    .font(.system(size: 13))
                    .foregroundColor(kindColor)
                    .frame(width: 32, height: 32)
                    .background(kindColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
    }

    // MARK: Info

    private var info: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if item.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 7))
                        .foregroundColor(.white.opacity(0.35))
                }
                if inQueue {
                    Image(systemName: "list.number")
                        .font(.system(size: 7))
                        .foregroundColor(DS.Colors.accent.opacity(0.7))
                }
                if item.reminderDate != nil {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 7))
                        .foregroundColor(.orange.opacity(0.7))
                }
                if let label = item.label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
            Text(item.displayTitle)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.85))
                .lineLimit(1)
            if let snippet = item.snippet {
                Text(snippet)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.35))
                    .lineLimit(1)
            }
        }
    }

    // MARK: Actions (visible on hover or just-pasted)

    @ViewBuilder
    private var actions: some View {
        if justPasted {
            Text("Pasted ✓")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(DS.Colors.accent)
        } else if hovering {
            HStack(spacing: 4) {
                actionBtn(icon: "doc.on.clipboard.fill", tip: "Paste") {
                    pasteDirect()
                }
                actionBtn(icon: "list.number", tip: "Add to Queue") {
                    MultiCopyQueueService.shared.enqueue(item)
                }
                actionBtn(icon: item.isPinned ? "pin.slash" : "pin.fill", tip: item.isPinned ? "Unpin" : "Pin") {
                    monitor.togglePin(item)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                if let app = item.sourceApp {
                    Text(app)
                        .font(.system(size: 8))
                        .foregroundColor(.white.opacity(0.2))
                }
                Text(item.copiedAt, style: .relative)
                    .font(.system(size: 8))
                    .foregroundColor(.white.opacity(0.18))
            }
        }
    }

    private func actionBtn(icon: String, tip: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.65))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(tip)
    }

    private func pasteDirect() {
        ClipboardMonitorService.shared.copyToPasteboard(item)
        let src = CGEventSource(stateID: .combinedSessionState)
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)?.apply { $0.flags = .maskCommand }
        CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.apply { $0.flags = .maskCommand }
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
                            ExpansionRow(expansion: exp) {
                                editing = exp
                            }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
        .sheet(isPresented: $showAdd)      { ExpansionEditor(existing: nil) }
        .sheet(item: $editing)             { ExpansionEditor(existing: $0) }
    }

    private var shortcutsHeader: some View {
        HStack {
            Text("Text Shortcuts")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
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
            Text("Type `;em` → expand to your email. Add one to get started.")
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

    var body: some View {
        HStack(spacing: 10) {
            Text(expansion.shortcut)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(DS.Colors.accent)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(DS.Colors.accent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 5))

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
            Text("Clip Reminders")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.7))
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
            Image(systemName: "bell.fill")
                .font(.system(size: 12))
                .foregroundColor(.orange.opacity(0.7))
                .frame(width: 28, height: 28)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayTitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(.white.opacity(0.8))
                    .lineLimit(1)
                if let date = item.reminderDate {
                    Text(date, style: .relative)
                        .font(.system(size: 10))
                        .foregroundColor(date < Date() ? .red.opacity(0.6) : .white.opacity(0.35))
                    +
                    Text(" · " + date.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                }
            }

            Spacer()

            if hovering {
                Button { monitor.setReminder(nil, for: item) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .buttonStyle(.plain)
                .help("Clear reminder")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(hovering ? Color.white.opacity(0.04) : Color.white.opacity(0.02))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovering = $0 }
    }
}

// MARK: - CGEvent helper (shared with ClipboardHistoryView)

private extension CGEvent {
    func apply(_ block: (CGEvent) -> Void) {
        block(self)
        self.post(tap: .cgSessionEventTap)
    }
}
