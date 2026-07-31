// ShelfModule.swift
// MacNotch's Shelf: a carousel stash for files — drop in, drag out.
//
// Scored 🟡 in the parity audit. FileShelfService already did the hard part
// (real copies into ~/Documents/Shelf, verified working) and there was a tab
// listing them vertically. What was missing was the shape and the verbs: a
// horizontal carousel, multi-select, and Move / Copy / trash on the selection.
//
// This is a panel over the existing service, not a second shelf. Every write
// still goes through FileShelfService so the notch drop zone, the Drop Actions
// grid, the Labs tab and this module can't disagree about what's on the shelf.

import SwiftUI
import AppKit
import Combine
import QuickLookThumbnailing

@MainActor
final class ShelfModule: NotchModule, ObservableObject {

    let id    = "shelfmodule"
    let title = "Shelf"
    let icon  = "tray.full"

    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = true

    private let shelf = FileShelfService.shared
    private var cancellables = Set<AnyCancellable>()

    /// Multi-select. Empty means the header shows the plain actions.
    @Published var selection: Set<URL> = []

    var subtitle: NotchHeaderSubtitle? {
        if !selection.isEmpty {
            return NotchHeaderSubtitle(text: "\(selection.count) selected", isPill: true)
        }
        let count = shelf.items.count
        return NotchHeaderSubtitle(text: count == 1 ? "1 file" : "\(count) files")
    }

    var headerAccessories: [NotchHeaderAccessory] {
        var out: [NotchHeaderAccessory] = []

        if !shelf.items.isEmpty {
            out.append(NotchHeaderAccessory(
                id: "selectAll",
                systemImage: selection.count == shelf.items.count
                    ? "checklist.checked" : "checklist",
                label: selection.count == shelf.items.count ? "Deselect all" : "Select all"
            ) { [weak self] in
                guard let self else { return }
                self.selection = self.selection.count == self.shelf.items.count
                    ? [] : Set(self.shelf.items)
            })
        }

        out.append(NotchHeaderAccessory(id: "folder",
                                        systemImage: "folder",
                                        label: "Open the Shelf folder in Finder") { [weak self] in
            self?.shelf.openShelfFolder()
        })

        if !shelf.items.isEmpty {
            out.append(NotchHeaderAccessory(id: "clear",
                                            systemImage: "xmark.bin",
                                            label: "Clear the shelf") { [weak self] in
                self?.shelf.clear()
                self?.selection.removeAll()
            })
        }
        return out
    }

    init() {
        shelf.objectWillChange
            .sink { [weak self] _ in
                guard let self else { return }
                self.objectWillChange.send()
                // Drop selections for files that are no longer on the shelf,
                // or the count in the header outlives the things it counted.
                DispatchQueue.main.async {
                    let present = Set(self.shelf.items)
                    self.selection = self.selection.intersection(present)
                }
            }
            .store(in: &cancellables)
    }

    func didDisappear() { selection.removeAll() }

    // MARK: Actions on the selection

    var selectedURLs: [URL] { shelf.items.filter { selection.contains($0) } }

    func airdropSelection() {
        let urls = selectedURLs.isEmpty ? shelf.items : selectedURLs
        guard !urls.isEmpty else { return }
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: urls)
    }

    func trashSelection() {
        for url in selectedURLs { shelf.remove(url) }
        selection.removeAll()
    }

    func move() { transfer(copying: false) }
    func copy() { transfer(copying: true) }

    /// Move or copy the selection to a folder the user picks.
    ///
    /// The open panel is bracketed with the modal suspend notifications for the
    /// reason recorded when Sparkle's dialog hit this: the island sits above
    /// normal windows and hides the cursor, so a panel opened without stepping
    /// it down appears behind the notch with no visible pointer.
    private func transfer(copying: Bool) {
        let urls = selectedURLs
        guard !urls.isEmpty else { return }

        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .miraSuspendForModal, object: nil)

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = copying ? "Copy Here" : "Move Here"
        panel.message = copying
            ? "Choose where to copy \(urls.count) file\(urls.count == 1 ? "" : "s")."
            : "Choose where to move \(urls.count) file\(urls.count == 1 ? "" : "s")."

        let response = panel.runModal()
        NotificationCenter.default.post(name: .miraResumeFromModal, object: nil)

        guard response == .OK, let destination = panel.url else { return }

        let fm = FileManager.default
        for url in urls {
            let target = Self.uniqueDestination(for: url.lastPathComponent, in: destination)
            do {
                if copying {
                    try fm.copyItem(at: url, to: target)
                } else {
                    try fm.moveItem(at: url, to: target)
                    // Only drop it from the shelf once the move actually
                    // succeeded — removing first would lose the file if the
                    // destination were read-only.
                    shelf.remove(url)
                }
            } catch {
                NSSound.beep()
            }
        }
        selection.removeAll()
    }

    /// Never overwrite something already at the destination.
    static func uniqueDestination(for name: String, in directory: URL) -> URL {
        let fm = FileManager.default
        var candidate = directory.appendingPathComponent(name)
        guard fm.fileExists(atPath: candidate.path) else { return candidate }

        let base = (name as NSString).deletingPathExtension
        let ext  = (name as NSString).pathExtension
        var index = 2
        repeat {
            let suffixed = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = directory.appendingPathComponent(suffixed)
            index += 1
        } while fm.fileExists(atPath: candidate.path)
        return candidate
    }

    func makeContent() -> AnyView {
        AnyView(ShelfModuleView(module: self, shelf: shelf))
    }
}

// MARK: - View

private struct ShelfModuleView: View {

    @ObservedObject var module: ShelfModule
    @ObservedObject var shelf: FileShelfService
    @ObservedObject private var accentSvc = AccentColorService.shared

    @State private var targeted = false

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if shelf.items.isEmpty { dropZone } else { carousel }
            if !module.selection.isEmpty { actionBar }
            Spacer(minLength: 0)
        }
        .padding(.top, NotchModuleShellView.headerHeight + 4)
        .padding(.horizontal, 14)
        .padding(.bottom, 10)
        .background(Color.black)
        // The whole panel is a drop target, not just the dashed box. Once there
        // are files on the shelf the box is gone, and having to hit a specific
        // rectangle to add another is a worse target than the panel itself.
        .onDrop(of: [.fileURL], isTargeted: $targeted) { handleDrop($0) }
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundColor(targeted ? accent : .white.opacity(0.20))
            .frame(height: 78)
            .overlay(
                VStack(spacing: 3) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.system(size: 15))
                        .foregroundColor(.white.opacity(0.35))
                    Text(shelf.atLimit ? "Shelf full" : "Drop files here")
                        .font(.system(size: 11))
                        .foregroundColor(.white.opacity(0.42))
                }
            )
            .frame(maxWidth: .infinity)
    }

    /// The carousel. Horizontal because that is the shape MacNotch uses and
    /// because a shelf is a row of things you can see at once, not a list you
    /// scroll to read.
    private var carousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(shelf.items, id: \.self) { url in
                    ShelfCard(url: url,
                              isSelected: module.selection.contains(url),
                              accent: accent,
                              onToggle: {
                                  if module.selection.contains(url) {
                                      module.selection.remove(url)
                                  } else {
                                      module.selection.insert(url)
                                  }
                              },
                              onRemove: { shelf.remove(url) })
                }

                // Trailing target so more files can be added without leaving
                // the carousel.
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.2, dash: [4]))
                    .foregroundColor(targeted ? accent : .white.opacity(0.16))
                    .frame(width: 76, height: 78)
                    .overlay(Image(systemName: "plus")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.28)))
            }
            .padding(.vertical, 1)
        }
        .frame(height: 82)
    }

    private var actionBar: some View {
        HStack(spacing: 7) {
            ActionButton(title: "Move",   systemImage: "arrow.right.doc.on.clipboard", accent: accent) { module.move() }
            ActionButton(title: "Copy",   systemImage: "doc.on.doc",                   accent: accent) { module.copy() }
            ActionButton(title: "AirDrop", systemImage: "paperplane",                  accent: accent) { module.airdropSelection() }
            Spacer(minLength: 0)
            ActionButton(title: "Remove", systemImage: "trash", accent: accent, destructive: true) {
                module.trashSelection()
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [URL] = []
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { FileShelfService.shared.add(urls) }
        return true
    }
}

// MARK: - Card

private struct ShelfCard: View {

    let url: URL
    let isSelected: Bool
    let accent: Color
    let onToggle: () -> Void
    let onRemove: () -> Void

    @State private var thumbnail: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .frame(width: 76, height: 54)
                    .overlay(preview)
                    .overlay(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isSelected ? accent : .clear, lineWidth: 1.5)
                    )

                if hovering || isSelected {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.75))
                            .background(Circle().fill(Color.black.opacity(0.6)))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }

            // Extension dropped and truncated from the TAIL over two lines.
            // One middle-truncated line rendered three different screenshots as
            // three identical "Scree…M.png" labels — middle truncation removes
            // precisely the date and time that tell them apart.
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(isSelected ? 0.9 : 0.55))
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
                .frame(width: 76)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onToggle)
        .onHover { hovering = $0 }
        // Drag out is the other half of "drop in, drag out" — the file leaves
        // for wherever you drop it without going through the shelf's own verbs.
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .help(url.lastPathComponent)
        .task(id: url) { await loadThumbnail() }
    }

    @ViewBuilder
    private var preview: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 76, height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        } else {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                .resizable()
                .frame(width: 26, height: 26)
        }
    }

    /// Real thumbnails where QuickLook can make one, so a shelf of screenshots
    /// is recognisable rather than eight identical PNG icons. Falls back to the
    /// file icon, which is why the icon is drawn first and simply replaced.
    private func loadThumbnail() async {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: 116, height: 108),
            scale: 2,
            representationTypes: .thumbnail)
        guard let rep = try? await QLThumbnailGenerator.shared
            .generateBestRepresentation(for: request) else { return }
        thumbnail = rep.nsImage
    }
}

// MARK: - Action button

private struct ActionButton: View {
    let title: String
    let systemImage: String
    let accent: Color
    var destructive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 9))
                Text(title).font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(destructive ? Color(red: 0.95, green: 0.5, blue: 0.45)
                                         : .white.opacity(0.85))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(Capsule().fill(destructive ? Color.white.opacity(0.08)
                                                   : accent.opacity(0.18)))
        }
        .buttonStyle(.plain)
    }
}
