import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - FileShelfService
//
// Utility #2 of the "5 Mac apps" set: a drag-and-drop file shelf, surfaced as a
// Dock widget. Hold files temporarily, drag them back out, or (Ultra) AirDrop
// them. Plan-gated: Free = locked, Pro = up to 5 items, Ultra = unlimited + AirDrop.

@MainActor
final class FileShelfService: ObservableObject {
    static let shared = FileShelfService()
    private init() { loadExisting() }

    @Published private(set) var items: [URL] = []

    static let proLimit = 5

    var limit: Int { EntitlementService.shared.plan == .ultra ? .max : Self.proLimit }
    var atLimit: Bool { items.count >= limit }

    /// ~/Documents/Shelf — dropped files are copied here so the shelf is a real,
    /// persistent folder the user can open in Finder, not just in-memory references.
    static var shelfDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return docs.appendingPathComponent("Shelf", isDirectory: true)
    }

    func add(_ urls: [URL]) {
        ensureShelfDirectory()
        for src in urls {
            guard items.count < limit else { break }
            guard let dest = copyIntoShelf(src) else { continue }
            if !items.contains(dest) { items.append(dest) }
        }
        MiraDebugLog.log("[Shelf] add complete, items=\(items.count) dir=\(Self.shelfDirectory.path)")
    }

    func remove(_ url: URL) {
        // Remove the physical copy too — the shelf folder mirrors the shelf list.
        if url.path.hasPrefix(Self.shelfDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll { $0 == url }
    }

    func clear() {
        for url in items where url.path.hasPrefix(Self.shelfDirectory.path) {
            try? FileManager.default.removeItem(at: url)
        }
        items.removeAll()
    }

    func openShelfFolder() {
        ensureShelfDirectory()
        NSWorkspace.shared.open(Self.shelfDirectory)
    }

    // MARK: - Private

    private func ensureShelfDirectory() {
        try? FileManager.default.createDirectory(at: Self.shelfDirectory,
                                                 withIntermediateDirectories: true)
    }

    /// Copy `src` into the Shelf folder, disambiguating name collisions. Returns the
    /// destination URL (or the existing one if an identical path is already there).
    private func copyIntoShelf(_ src: URL) -> URL? {
        let fm = FileManager.default
        let dest = uniqueDestination(for: src.lastPathComponent)
        do {
            try fm.copyItem(at: src, to: dest)
            MiraDebugLog.log("[Shelf] copied \(src.lastPathComponent) → \(dest.path)")
            return dest
        } catch {
            MiraDebugLog.log("[Shelf] COPY FAILED \(src.lastPathComponent): \(error.localizedDescription)")
            return nil
        }
    }

    private func uniqueDestination(for name: String) -> URL {
        let dir  = Self.shelfDirectory
        var dest = dir.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: dest.path) else { return dest }
        let base = (name as NSString).deletingPathExtension
        let ext  = (name as NSString).pathExtension
        var n = 2
        repeat {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            dest = dir.appendingPathComponent(candidate)
            n += 1
        } while FileManager.default.fileExists(atPath: dest.path)
        return dest
    }

    /// Rehydrate the shelf from whatever is already in ~/Documents/Shelf so drops
    /// survive relaunches.
    private func loadExisting() {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(
            at: Self.shelfDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        items = contents.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return a < b
        }
    }
}

// MARK: - Labs tab view (drop zone + items)

struct FileShelfLabsView: View {
    @ObservedObject private var shelf = FileShelfService.shared
    @ObservedObject private var ent   = EntitlementService.shared
    @State private var targeted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("File Shelf").font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                Spacer()
                if ent.plan == .ultra, !shelf.items.isEmpty {
                    Button { airdrop() } label: {
                        Image(systemName: "paperplane.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.7)).help("AirDrop")
                }
                Button { shelf.openShelfFolder() } label: {
                    Image(systemName: "folder").font(.system(size: 12))
                }
                .buttonStyle(.plain).foregroundColor(.white.opacity(0.7)).help("Open Shelf folder in Finder")
                if !shelf.items.isEmpty {
                    Button("Clear") { shelf.clear() }
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4)).buttonStyle(.plain)
                }
            }

            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                .foregroundColor(targeted ? .accentColor : .white.opacity(0.22))
                .frame(height: 52)
                .overlay(
                    Text(shelf.atLimit ? "Shelf full" : "Drop files here")
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.4))
                )
                .onDrop(of: [.fileURL], isTargeted: $targeted) { handleDrop($0) }

            ForEach(shelf.items, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                        .resizable().frame(width: 18, height: 18)
                    Text(url.lastPathComponent)
                        .font(.system(size: 11)).foregroundColor(.white.opacity(0.85)).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { shelf.remove(url) } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 12))
                    }
                    .buttonStyle(.plain).foregroundColor(.white.opacity(0.3))
                }
                .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
            }

            if ent.plan == .pro {
                Text("\(shelf.items.count)/\(FileShelfService.proLimit) · Ultra for unlimited + AirDrop")
                    .font(.system(size: 9)).foregroundColor(.white.opacity(0.35))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        MiraDebugLog.log("[Shelf] handleDrop providers=\(providers.count)")
        let group = DispatchGroup()
        let lock  = NSLock()
        var urls: [URL] = []
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, error in
                if let url, url.isFileURL {
                    lock.lock(); urls.append(url); lock.unlock()
                } else {
                    MiraDebugLog.log("[Shelf] loadObject failed url=\(url?.absoluteString ?? "nil") error=\(String(describing: error))")
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            MiraDebugLog.log("[Shelf] adding \(urls.count) url(s) to shelf")
            FileShelfService.shared.add(urls)
        }
        return true
    }

    private func airdrop() {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shelf.items)
    }
}
