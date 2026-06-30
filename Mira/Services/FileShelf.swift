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
    private init() {}

    @Published private(set) var items: [URL] = []

    static let proLimit = 5

    var limit: Int { EntitlementService.shared.plan == .ultra ? .max : Self.proLimit }
    var atLimit: Bool { items.count >= limit }

    func add(_ urls: [URL]) {
        for url in urls where !items.contains(url) {
            guard items.count < limit else { break }
            items.append(url)
        }
    }

    func remove(_ url: URL) { items.removeAll { $0 == url } }
    func clear() { items.removeAll() }
}

// MARK: - Dock widget (compact)

struct FileShelfWidget: View {
    @ObservedObject private var shelf = FileShelfService.shared
    @ObservedObject private var ent   = EntitlementService.shared

    var body: some View {
        Group {
            if ent.plan == .free {
                VStack(spacing: 3) {
                    Image(systemName: "lock.fill").font(.system(size: 12)).foregroundColor(.yellow)
                    Text("Shelf").font(.system(size: 9, weight: .medium)).foregroundColor(.white.opacity(0.7))
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: shelf.items.isEmpty ? "tray" : "tray.full.fill")
                        .font(.system(size: 16)).foregroundColor(.white.opacity(0.85))
                    Text(shelf.items.isEmpty ? "Shelf" : "\(shelf.items.count)")
                        .font(.system(size: 9, weight: .semibold)).foregroundColor(.white.opacity(0.6))
                }
            }
        }
        .frame(width: 60)
    }
}

// MARK: - Detail popover (drop zone + items)

struct FileShelfDetailPanel: View {
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
        .frame(width: 264)
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        for p in providers where p.canLoadObject(ofClass: URL.self) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url, url.isFileURL { urls.append(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { FileShelfService.shared.add(urls) }
        return true
    }

    private func airdrop() {
        NSSharingService(named: .sendViaAirDrop)?.perform(withItems: shelf.items)
    }
}
