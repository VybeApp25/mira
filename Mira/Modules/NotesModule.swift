// NotesModule.swift
// MacNotch's Notes module: a scratchpad in the notch for quick capture.
// The parity audit scored this ❌ — Mira had nothing like it.
//
// Two-column layout (note list + editor), the same index-plus-detail grammar
// Calendar uses and the pattern MacNotch applies to nearly every panel.
//
// Storage is a JSON file next to Mira's other stores, matching AgentJobStore's
// convention. Deliberately NOT Apple Notes: its scripting bridge is slow enough
// to be felt on every keystroke in a panel this small, and a scratchpad you open
// for five seconds shouldn't wait on AppleScript. Reminders was worth binding to
// because sync across devices IS the feature; a notch scratchpad isn't that.
//
// Deviation from MacNotch worth stating: its editor has a rich-text toolbar
// (bold/italic/strike/code/list/number/heading). This is plain text. A faithful
// rich-text editor means an NSAttributedString pipeline and its own persistence
// format, which is a disproportionate build for a scratchpad — but it does mean
// this module is not at parity, only at feature-presence.

import SwiftUI
import Combine

// MARK: - Model

struct Note: Identifiable, Codable, Equatable {
    let id: UUID
    var body: String
    var updatedAt: Date

    init(id: UUID = UUID(), body: String = "", updatedAt: Date = Date()) {
        self.id = id
        self.body = body
        self.updatedAt = updatedAt
    }

    /// First non-empty line, for the list. Falls back so an empty note is still
    /// selectable rather than rendering as a blank row.
    var title: String {
        let first = body
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespaces)
        let t = first ?? ""
        return t.isEmpty ? "New Note" : t
    }

    var preview: String {
        body.split(separator: "\n", omittingEmptySubsequences: true)
            .dropFirst().first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
    }
}

// MARK: - Service

@MainActor
final class NotesService: ObservableObject {

    static let shared = NotesService()

    @Published private(set) var notes: [Note] = []
    @Published var selectedID: UUID?

    private let fileURL: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = support.appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("notes.json")
    }()

    /// Writes are debounced: persisting on every keystroke would hit disk dozens
    /// of times a second while typing.
    private var saveWork: DispatchWorkItem?

    private init() {
        load()
        if selectedID == nil { selectedID = notes.first?.id }
    }

    // MARK: CRUD

    @discardableResult
    func create() -> Note {
        let note = Note()
        notes.insert(note, at: 0)
        selectedID = note.id
        scheduleSave()
        return note
    }

    func update(id: UUID, body: String) {
        guard let i = notes.firstIndex(where: { $0.id == id }) else { return }
        notes[i].body = body
        notes[i].updatedAt = Date()
        scheduleSave()
    }

    func delete(id: UUID) {
        notes.removeAll { $0.id == id }
        if selectedID == id { selectedID = notes.first?.id }
        scheduleSave()
    }

    var selected: Note? {
        guard let selectedID else { return nil }
        return notes.first { $0.id == selectedID }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func save() {
        do {
            let data = try JSONEncoder().encode(notes)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Mira] notes save failed: %@", error.localizedDescription)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([Note].self, from: data)
        else { return }
        notes = decoded.sorted { $0.updatedAt > $1.updatedAt }
    }
}

// MARK: - Module

@MainActor
final class NotesModule: NotchModule, ObservableObject {

    let id    = "notes"
    let title = "Notes"
    let icon  = "note.text"

    let heightLevel: NotchHeightLevel = .tall
    let allowsTallMode = false

    private let service = NotesService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        service.notes.isEmpty ? nil : NotchHeaderSubtitle(text: "\(service.notes.count)")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        [NotchHeaderAccessory(id: "new", systemImage: "square.and.pencil",
                              label: "New note", isProminent: true) { [weak self] in
            self?.service.create()
        }]
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func makeContent() -> AnyView { AnyView(NotesModuleView(service: service)) }
}

// MARK: - View

private struct NotesModuleView: View {

    @ObservedObject var service: NotesService
    @ObservedObject private var accentSvc = AccentColorService.shared

    private var accent: Color { accentSvc.color }

    var body: some View {
        HStack(spacing: 0) {
            list.frame(width: 190)
            Rectangle().fill(Color.white.opacity(0.07)).frame(width: 0.5)
            editor.frame(maxWidth: .infinity)
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .background(Color.black)
    }

    // MARK: Left: note list

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(service.notes) { note in
                    row(note)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .overlay {
            if service.notes.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "note.text")
                        .font(.system(size: 16))
                        .foregroundColor(.white.opacity(0.22))
                    Text("No notes")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
    }

    private func row(_ note: Note) -> some View {
        let isSelected = note.id == service.selectedID
        return Button {
            service.selectedID = note.id
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(note.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(0.90))
                    .lineLimit(1)
                if !note.preview.isEmpty {
                    Text(note.preview)
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.40))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? accent.opacity(0.20) : Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete", role: .destructive) { service.delete(id: note.id) }
        }
    }

    // MARK: Right: editor

    @ViewBuilder
    private var editor: some View {
        if let note = service.selected {
            VStack(spacing: 0) {
                TextEditor(text: Binding(
                    get: { note.body },
                    set: { service.update(id: note.id, body: $0) }
                ))
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.92))
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .padding(.horizontal, 10)
                .padding(.top, 8)

                HStack {
                    Text(note.updatedAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.30))
                    Spacer()
                    Button {
                        service.delete(id: note.id)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundColor(.white.opacity(0.30))
                    }
                    .buttonStyle(.plain)
                    .help("Delete note")
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 7)
            }
        } else {
            VStack(spacing: 8) {
                Text("No note selected")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.45))
                Button {
                    service.create()
                } label: {
                    Text("New Note")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(accent.opacity(0.16)))
                }
                .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
