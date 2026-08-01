// DropActionsModule.swift
// MacNotch's Drop Actions: drop files on the notch and pick what happens —
// Shelf, AirDrop, zip, unzip, image convert, move, copy, trash, eject, Music,
// open with. The parity audit scored Mira 🟡 here: FileShelfService already
// handles drop-to-shelf and AirDrop, so this is an expansion of one action into
// a grid, not a build from zero.
//
// Everything runs on the files most recently dropped or already on the shelf, so
// the module is useful whether or not a drag is in flight — MacNotch's version
// only exists mid-drag, which means you cannot zip something you dropped a
// moment ago without dragging it again.
//
// Destructive actions are deliberately conservative: trash uses NSWorkspace's
// recycle (recoverable), and nothing overwrites an existing file — collisions
// get a numbered suffix instead. A file manager that can silently destroy work
// is not worth the convenience.

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Combine

// MARK: - Actions

enum DropAction: String, CaseIterable, Identifiable {
    case shelf, airdrop, zip, unzip
    case toPNG, toJPEG
    case copyPath, revealInFinder
    case openWith, trash

    var id: String { rawValue }

    var label: String {
        switch self {
        case .shelf:          return "Shelf"
        case .airdrop:        return "AirDrop"
        case .zip:            return "Zip"
        case .unzip:          return "Unzip"
        case .toPNG:          return "To PNG"
        case .toJPEG:         return "To JPEG"
        case .copyPath:       return "Copy Path"
        case .revealInFinder: return "Reveal"
        case .openWith:       return "Open"
        case .trash:          return "Trash"
        }
    }

    var icon: String {
        switch self {
        case .shelf:          return "tray.full"
        case .airdrop:        return "wifi"
        case .zip:            return "doc.zipper"
        case .unzip:          return "arrow.up.bin"
        case .toPNG:          return "photo"
        case .toJPEG:         return "photo.on.rectangle"
        case .copyPath:       return "doc.on.clipboard"
        case .revealInFinder: return "folder"
        case .openWith:       return "arrow.up.forward.app"
        case .trash:          return "trash"
        }
    }

    var isDestructive: Bool { self == .trash }
}

// MARK: - Service

@MainActor
final class DropActionsService: ObservableObject {

    static let shared = DropActionsService()

    /// Files the actions operate on: the most recent drop, falling back to the
    /// shelf so the grid is never pointed at nothing.
    @Published private(set) var targets: [URL] = []
    @Published private(set) var lastResult: String?

    private var resultClear: DispatchWorkItem?
    private init() {}

    func setTargets(_ urls: [URL]) {
        targets = urls
    }

    var effectiveTargets: [URL] {
        targets.isEmpty ? FileShelfService.shared.items : targets
    }

    // MARK: Perform

    func perform(_ action: DropAction) {
        let files = effectiveTargets
        guard !files.isEmpty else {
            report("Nothing to act on")
            return
        }

        switch action {
        case .shelf:
            FileShelfService.shared.add(files)
            report("Added \(files.count) to Shelf")

        case .airdrop:
            NSSharingService(named: .sendViaAirDrop)?.perform(withItems: files)
            report("AirDrop opened")

        case .zip:
            zip(files)

        case .unzip:
            unzip(files)

        case .toPNG:
            convert(files, to: .png, ext: "png")

        case .toJPEG:
            convert(files, to: .jpeg, ext: "jpg")

        case .copyPath:
            let joined = files.map(\.path).joined(separator: "\n")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(joined, forType: .string)
            report("Copied \(files.count) path\(files.count == 1 ? "" : "s")")

        case .revealInFinder:
            NSWorkspace.shared.activateFileViewerSelecting(files)
            report("Revealed in Finder")

        case .openWith:
            files.forEach { NSWorkspace.shared.open($0) }
            report("Opened \(files.count)")

        case .trash:
            var moved = 0
            for f in files {
                // recycle() moves to Trash and is recoverable. Never unlink.
                do { try FileManager.default.trashItem(at: f, resultingItemURL: nil); moved += 1 }
                catch { NSLog("[Mira] trash failed: %@", error.localizedDescription) }
            }
            files.forEach { FileShelfService.shared.remove($0) }
            targets.removeAll()
            report("Moved \(moved) to Trash")
        }
    }

    // MARK: Implementations

    private func zip(_ files: [URL]) {
        guard let first = files.first else { return }

        // `ditto -c -k` accepts exactly ONE source — "ditto: Can't archive
        // multiple sources" — so a multi-file selection has to be staged into a
        // folder first and that folder archived. Verified both paths against the
        // real binary before wiring them up.
        let source: URL
        var staging: URL?
        if files.count == 1 {
            source = first
        } else {
            let dir = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("MiraZip-\(UUID().uuidString)/Files", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for f in files {
                    try? FileManager.default.copyItem(
                        at: f, to: dir.appendingPathComponent(f.lastPathComponent))
                }
            } catch {
                report("Zip failed: \(error.localizedDescription)")
                return
            }
            source = dir
            staging = dir.deletingLastPathComponent()
        }

        // Name the archive after the single file, or the containing folder when
        // zipping several.
        let baseName = files.count == 1
            ? first.deletingPathExtension().lastPathComponent
            : (first.deletingLastPathComponent().lastPathComponent.isEmpty
               ? "Archive" : first.deletingLastPathComponent().lastPathComponent)
        let dest = uniqueURL(first.deletingLastPathComponent()
            .appendingPathComponent(baseName)
            .appendingPathExtension("zip"))

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        // -c -k --sequesterRsrc produces a standard, Finder-compatible archive.
        p.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", source.path, dest.path]
        run(p, success: "Zipped to \(dest.lastPathComponent)")

        if let staging { try? FileManager.default.removeItem(at: staging) }
    }

    private func unzip(_ files: [URL]) {
        guard let archive = files.first(where: { $0.pathExtension.lowercased() == "zip" }) else {
            report("No .zip selected")
            return
        }
        let dest = uniqueURL(archive.deletingPathExtension())
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", archive.path, dest.path]
        run(p, success: "Unzipped to \(dest.lastPathComponent)")
    }

    private func convert(_ files: [URL], to type: NSBitmapImageRep.FileType, ext: String) {
        var done = 0
        for f in files {
            guard let image = NSImage(contentsOf: f),
                  let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: type, properties: [:])
            else { continue }
            let dest = uniqueURL(f.deletingPathExtension().appendingPathExtension(ext))
            do { try data.write(to: dest); done += 1 }
            catch { NSLog("[Mira] convert write failed: %@", error.localizedDescription) }
        }
        report(done == 0 ? "No convertible images" : "Converted \(done) to \(ext.uppercased())")
    }

    private func run(_ p: Process, success: String) {
        do {
            try p.run()
            p.waitUntilExit()
            report(p.terminationStatus == 0 ? success : "Failed (\(p.terminationStatus))")
        } catch {
            report("Failed: \(error.localizedDescription)")
        }
    }

    /// Never overwrite. Appends " 2", " 3"… the way Finder does.
    private func uniqueURL(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let base = url.deletingPathExtension()
        let ext = url.pathExtension
        for i in 2...999 {
            let candidate = ext.isEmpty
                ? URL(fileURLWithPath: "\(base.path) \(i)")
                : URL(fileURLWithPath: "\(base.path) \(i)").appendingPathExtension(ext)
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return url
    }

    private func report(_ message: String) {
        lastResult = message
        resultClear?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.lastResult = nil }
        resultClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: work)
    }
}

// MARK: - Module

@MainActor
final class DropActionsModule: NotchModule, ObservableObject {

    let id    = "drop"
    let title = "Drop Actions"
    let icon  = "square.and.arrow.down"

    let heightLevel: NotchHeightLevel = .compact
    let allowsTallMode = true

    private let service = DropActionsService.shared
    private var cancellables = Set<AnyCancellable>()

    var subtitle: NotchHeaderSubtitle? {
        if let result = service.lastResult {
            return NotchHeaderSubtitle(text: result, isPill: true)
        }
        let n = service.effectiveTargets.count
        guard n > 0 else { return nil }
        return NotchHeaderSubtitle(text: "\(n) file\(n == 1 ? "" : "s")")
    }

    init() {
        service.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        FileShelfService.shared.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    func makeContent() -> AnyView { AnyView(DropActionsModuleView(service: service)) }
}

// MARK: - View

private struct DropActionsModuleView: View {

    @ObservedObject var service: DropActionsService
    @ObservedObject private var accentSvc = AccentColorService.shared
    @State private var targeted = false

    private var accent: Color { accentSvc.color }

    var body: some View {
        VStack(spacing: 0) {
            grid
        }
        .padding(.top, NotchModuleShellView.headerHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            ZStack {
                Color.black
                if targeted { accent.opacity(0.10) }
            }
        )
        // Dropping straight onto the grid retargets the actions, so you can drop
        // and then choose — rather than choosing before you have dropped.
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            loadURLs(from: providers) { urls in
                guard !urls.isEmpty else { return }
                service.setTargets(urls)
            }
            return true
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 62), spacing: 6)], spacing: 6) {
            ForEach(DropAction.allCases) { action in
                tile(action)
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func tile(_ action: DropAction) -> some View {
        Button {
            service.perform(action)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: action.icon)
                    .font(.system(size: 13))
                    .foregroundColor(action.isDestructive
                                     ? Color(red: 1, green: 0.45, blue: 0.45)
                                     : accent)
                Text(action.label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.white.opacity(0.70))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.white.opacity(0.05))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(action.label)
        .accessibilityLabel(action.label)
    }

    /// NSItemProvider delivers asynchronously; collect then hand back once.
    private func loadURLs(from providers: [NSItemProvider],
                          completion: @escaping ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()
        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(urls) }
    }
}
