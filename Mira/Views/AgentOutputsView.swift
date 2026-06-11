import SwiftUI
import AppKit

private let surface  = Color(red: 0.11, green: 0.11, blue: 0.13)
private let surface2 = Color(red: 0.14, green: 0.14, blue: 0.17)
private let accent   = DS.Colors.accent
private let green    = Color(red: 0.20, green: 0.84, blue: 0.29)
private let amber    = Color(red: 1.0,  green: 0.78, blue: 0.20)
private let red      = Color(red: 1.0,  green: 0.35, blue: 0.35)

// MARK: - Main View

struct AgentOutputsView: View {
    @StateObject private var store = OutputStore.shared
    @State private var filter: OutputType? = nil
    @State private var selectedEntry: OutputEntry? = nil
    @State private var detailEntry: OutputEntry? = nil
    @State private var renamingEntry: OutputEntry? = nil
    @State private var renameText = ""
    @State private var confirmDelete: OutputEntry? = nil

    private var visible: [OutputEntry] {
        filter == nil ? store.entries : store.entries(for: filter!)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.07)).frame(height: 0.5)
            filterBar
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)

            if visible.isEmpty {
                emptyState
            } else {
                ScrollView(showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(visible) { entry in
                            OutputRowView(
                                entry: entry,
                                onOpen:    { openEntry(entry) },
                                onReveal:  { revealEntry(entry) },
                                onRename:  { startRename(entry) },
                                onDelete:  { confirmDelete = entry },
                                onDetail:  { detailEntry = entry },
                                onAnalyze: { analyzeEntry(entry) }
                            )
                            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 0.5)
                        }
                    }
                }
            }
        }
        .sheet(item: $detailEntry) { entry in
            OutputDetailView(entryId: entry.id, store: store)
                .frame(width: 480, height: 620)
        }
        .sheet(item: $renamingEntry) { entry in
            renameSheet(entry)
        }
        .alert("Delete \(confirmDelete?.name ?? "this item")?",
               isPresented: Binding(get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
            Button("Cancel", role: .cancel) { confirmDelete = nil }
            Button("Delete", role: .destructive) {
                if let e = confirmDelete { store.delete(id: e.id, removeFiles: true) }
                confirmDelete = nil
            }
        } message: {
            Text("The output files will be permanently deleted.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Library")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white.opacity(0.50))
            if !store.entries.isEmpty {
                Text("\(store.entries.count)")
                    .font(.system(size: 10))
                    .foregroundColor(accent.opacity(0.70))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                filterChip(label: "All", type: nil)
                ForEach(OutputType.allCases, id: \.self) { type in
                    let count = store.entries(for: type).count
                    if count > 0 {
                        filterChip(label: type.rawValue, type: type, count: count)
                    }
                }
            }
            .padding(.horizontal, 14)
        }
        .frame(height: 34)
    }

    private func filterChip(label: String, type: OutputType?, count: Int? = nil) -> some View {
        let selected = filter == type
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { filter = type }
        } label: {
            HStack(spacing: 4) {
                if let t = type {
                    Image(systemName: t.icon)
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(label)
                    .font(.system(size: 10, weight: selected ? .semibold : .regular))
                if let c = count {
                    Text("\(c)")
                        .font(.system(size: 9))
                        .foregroundColor(selected ? .white.opacity(0.5) : .white.opacity(0.28))
                }
            }
            .foregroundColor(selected ? .white : .white.opacity(0.42))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(selected ? Color.white.opacity(0.12) : Color.clear)
            .clipShape(Capsule())
            .overlay(
                Capsule().stroke(selected ? Color.white.opacity(0.18) : Color.clear, lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "folder")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.10))
            Text(filter == nil ? "No outputs yet" : "No \(filter!.rawValue.lowercased())s yet")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.28))
            Text("Completed agent jobs will appear here")
                .font(.system(size: 11))
                .foregroundColor(.white.opacity(0.18))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Rename sheet

    private func renameSheet(_ entry: OutputEntry) -> some View {
        VStack(spacing: 14) {
            Text("Rename")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.90))
            TextField("Name", text: $renameText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundColor(.white)
                .padding(8)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 7))
            HStack(spacing: 8) {
                Button("Cancel") { renamingEntry = nil }
                    .foregroundColor(.white.opacity(0.40))
                    .buttonStyle(.plain)
                Spacer()
                Button("Save") {
                    store.rename(id: entry.id, to: renameText)
                    renamingEntry = nil
                }
                .foregroundColor(accent)
                .buttonStyle(.plain)
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 280)
        .background(Color(red: 0.10, green: 0.10, blue: 0.12))
        .onAppear { renameText = entry.name }
    }

    // MARK: - Actions

    private func openEntry(_ entry: OutputEntry) {
        NSWorkspace.shared.open(URL(fileURLWithPath: entry.primaryFilePath))
    }

    private func revealEntry(_ entry: OutputEntry) {
        NSWorkspace.shared.activateFileViewerSelecting(
            [URL(fileURLWithPath: entry.primaryFilePath)]
        )
    }

    private func startRename(_ entry: OutputEntry) {
        renamingEntry = entry
    }

    private func analyzeEntry(_ entry: OutputEntry) {
        let apiKey = UserDefaults.standard.string(forKey: "mira_api_key") ?? ""
        guard !apiKey.isEmpty else { return }
        AgentJobStore.shared.submitHealthJob(outputEntryId: entry.id, apiKey: apiKey)
    }
}

// MARK: - Output Row

private struct OutputRowView: View {
    let entry: OutputEntry
    let onOpen:    () -> Void
    let onReveal:  () -> Void
    let onRename:  () -> Void
    let onDelete:  () -> Void
    let onDetail:  () -> Void
    let onAnalyze: () -> Void

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            // Preview or icon
            Group {
                if let previewPath = entry.previewImagePath,
                   let img = NSImage(contentsOfFile: previewPath) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    ZStack {
                        Color.white.opacity(0.06)
                        Image(systemName: entry.type.icon)
                            .font(.system(size: 14))
                            .foregroundColor(.white.opacity(0.25))
                    }
                }
            }
            .frame(width: 56, height: 36)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.white.opacity(0.08), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.88))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(entry.type.rawValue)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.32))
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.15))
                    Text(entry.relativeTime)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.25))
                }
            }

            Spacer()

            // Health score badge
            if let report = entry.healthReport {
                Text("\(report.overallScore)")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(healthColor(report.overallScore))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(healthColor(report.overallScore).opacity(0.12))
                    .clipShape(Capsule())
            }

            // Action buttons (revealed on hover)
            if hovered {
                HStack(spacing: 4) {
                    iconButton("arrow.up.right.square", action: onOpen)
                    iconButton("folder", action: onReveal)
                    iconButton("pencil", action: onRename)
                    iconButton("heart.text.square", action: onAnalyze)
                    iconButton("trash", color: red, action: onDelete)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onTapGesture { onDetail() }
    }

    private func healthColor(_ score: Int) -> Color {
        if score >= 80 { return Color(red: 0.20, green: 0.84, blue: 0.29) }
        if score >= 60 { return Color(red: 1.0,  green: 0.78, blue: 0.20) }
        return Color(red: 1.0, green: 0.35, blue: 0.35)
    }

    private func iconButton(_ icon: String, color: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundColor(color.opacity(0.50))
                .frame(width: 26, height: 26)
                .background(Color.white.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }
}
