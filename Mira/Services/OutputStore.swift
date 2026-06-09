import Foundation
import AppKit

// Persistent catalog of all agent-created outputs (websites, research, documents).
// Jobs are temporary execution records; OutputEntries are the permanent system of record.

@MainActor
final class OutputStore: ObservableObject {
    static let shared = OutputStore()

    @Published private(set) var entries: [OutputEntry] = []

    private let storePath: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Mira", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("output-registry.json")
    }()

    private init() { load() }

    // MARK: - Registration

    func register(from job: AgentJob) {
        guard let result = job.result,
              let outputPath = result.outputPath,
              !entries.contains(where: { $0.sourceJobId == job.id }) else { return }

        let type: OutputType
        switch job.type {
        case .websiteBuilder:    type = .website
        case .deepResearch:      type = .research
        case .contentGeneration: type = .document
        default: return
        }

        let name = result.metadata["siteName"]
            ?? result.metadata["title"]
            ?? String(job.prompt.prefix(45))
        let dir = (outputPath as NSString).deletingLastPathComponent

        // Store source prompt in metadata for provenance display
        var enrichedMetadata = result.metadata
        enrichedMetadata["sourcePrompt"] = job.prompt

        let v1 = OutputVersion(
            id: UUID(),
            createdAt: job.completedAt ?? Date(),
            label: "Version 1",
            filePath: outputPath,
            sourceJobId: job.id,
            editPrompt: nil,
            createdByAgent: type.agentName
        )

        let entry = OutputEntry(
            id: UUID(),
            type: type,
            name: name,
            primaryFilePath: outputPath,
            outputDirectory: dir,
            previewImagePath: result.previewImagePath,
            sourceJobId: job.id,
            createdAt: job.completedAt ?? Date(),
            metadata: enrichedMetadata,
            lastOpenedAt: nil,
            openCount: 0,
            favorite: false,
            versions: [v1],
            editHistory: [],
            projectSummary: nil,
            summaryVersionCount: 0,
            publishedUrl: nil,
            publishedAt: nil,
            deploymentProvider: nil,
            deploymentStatus: nil
        )
        entries.insert(entry, at: 0)
        save()
    }

    // MARK: - Usage tracking

    func markOpened(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].lastOpenedAt = Date()
        entries[idx].openCount += 1
        save()
    }

    func toggleFavorite(id: UUID) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].favorite.toggle()
        save()
    }

    // MARK: - Mutations

    func rename(id: UUID, to name: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        entries[idx].name = name
        save()
    }

    func delete(id: UUID, removeFiles: Bool = false) {
        guard let entry = entries.first(where: { $0.id == id }) else { return }
        if removeFiles {
            try? FileManager.default.removeItem(atPath: entry.outputDirectory)
        }
        entries.removeAll { $0.id == id }
        save()
    }

    @discardableResult
    func duplicate(id: UUID) -> OutputEntry? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        let newId = UUID()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let newDir = support.appendingPathComponent(
            "Mira/Projects/\(entry.type.folderName)/\(newId.uuidString)"
        )

        do {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: entry.outputDirectory),
                to: newDir
            )
        } catch {
            return nil
        }

        let primaryFile = URL(fileURLWithPath: entry.primaryFilePath).lastPathComponent
        let newPrimaryPath = newDir.appendingPathComponent(primaryFile).path

        var previewPath: String? = nil
        if let oldPreview = entry.previewImagePath {
            let previewFile = URL(fileURLWithPath: oldPreview).lastPathComponent
            previewPath = newDir.appendingPathComponent(previewFile).path
        }

        let v1 = OutputVersion(
            id: UUID(), createdAt: Date(), label: "Version 1",
            filePath: newPrimaryPath, sourceJobId: nil,
            editPrompt: nil, createdByAgent: entry.type.agentName
        )

        let newEntry = OutputEntry(
            id: newId,
            type: entry.type,
            name: "\(entry.name) Copy",
            primaryFilePath: newPrimaryPath,
            outputDirectory: newDir.path,
            previewImagePath: previewPath,
            sourceJobId: entry.sourceJobId,
            createdAt: Date(),
            metadata: entry.metadata,
            lastOpenedAt: nil,
            openCount: 0,
            favorite: false,
            versions: [v1],
            editHistory: [],
            projectSummary: nil,
            summaryVersionCount: 0,
            publishedUrl: nil,
            publishedAt: nil,
            deploymentProvider: nil,
            deploymentStatus: nil
        )
        entries.insert(newEntry, at: 0)
        save()
        return newEntry
    }

    // MARK: - Export ZIP

    func exportZIP(id: UUID) async -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else { return nil }
        let outputDirectory = entry.outputDirectory
        let name = entry.name.replacingOccurrences(of: "/", with: "-")

        return await Task.detached {
            let outputURL = URL(fileURLWithPath: outputDirectory)
            let coordinator = NSFileCoordinator()
            var result: URL? = nil
            var coordError: NSError?
            coordinator.coordinate(readingItemAt: outputURL, options: .forUploading, error: &coordError) { zipURL in
                let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
                let dest = downloads.appendingPathComponent("\(name).zip")
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: zipURL, to: dest)) != nil {
                    result = dest
                }
            }
            return result
        }.value
    }

    // MARK: - Version Management

    // MARK: - Conversation History

    @discardableResult
    func addUserMessage(entryId: UUID, content: String) -> UUID {
        let msg = EditMessage(id: UUID(), createdAt: Date(), role: .user, content: content, linkedVersionId: nil)
        if let idx = entries.firstIndex(where: { $0.id == entryId }) {
            entries[idx].editHistory.append(msg)
            save()
        }
        return msg.id
    }

    func addAssistantMessage(entryId: UUID, content: String, linkedVersionId: UUID?) {
        let msg = EditMessage(id: UUID(), createdAt: Date(), role: .assistant, content: content, linkedVersionId: linkedVersionId)
        if let idx = entries.firstIndex(where: { $0.id == entryId }) {
            entries[idx].editHistory.append(msg)
            // Link the most recent un-linked user message to this version as well
            if let versionId = linkedVersionId,
               let lastUserIdx = entries[idx].editHistory.indices.last(where: { entries[idx].editHistory[$0].role == .user && entries[idx].editHistory[$0].linkedVersionId == nil }) {
                entries[idx].editHistory[lastUserIdx].linkedVersionId = versionId
            }
            save()
        }
    }

    // MARK: - Version Management

    /// Restores a past version by creating a new version from its archived HTML.
    /// Archive naming convention: version at index i → history/v{i+1}.html (set by addVersion).
    @discardableResult
    func restoreVersion(entryId: UUID, versionIndex: Int) -> Bool {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return false }
        let entry = entries[idx]
        guard versionIndex < entry.versions.count - 1 else { return false }

        let archiveURL = URL(fileURLWithPath: entry.outputDirectory)
            .appendingPathComponent("history")
            .appendingPathComponent("v\(versionIndex + 1).html")

        guard let html = try? String(contentsOf: archiveURL, encoding: .utf8) else { return false }

        let restoredFromLabel = entry.versions[versionIndex].label
        let newLabel = "Version \(entry.versions.count + 1)"

        let succeeded = addVersion(
            entryId: entryId,
            html: html,
            label: newLabel,
            sourceJobId: nil,
            editPrompt: "Restored from \(restoredFromLabel)",
            createdByAgent: "Restore",
            previewImage: nil
        ) != nil
        if succeeded {
            TelemetryService.shared.track(.versionRestored(entryId: entryId))
        }
        return succeeded
    }

    /// Saves `html` as the new primary file, archives the previous version, registers the new OutputVersion.
    /// Returns the new version's UUID on success, nil on failure.
    func addVersion(entryId: UUID, html: String, label: String, sourceJobId: UUID?,
                    editPrompt: String? = nil, createdByAgent: String? = nil,
                    previewImage: NSImage?) -> UUID? {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return nil }
        let entry = entries[idx]
        let outputDir = URL(fileURLWithPath: entry.outputDirectory)

        // Archive current primary file into history/
        let historyDir = outputDir.appendingPathComponent("history")
        try? FileManager.default.createDirectory(at: historyDir, withIntermediateDirectories: true)
        let archiveName = "v\(entry.versions.count).html"
        let archiveURL = historyDir.appendingPathComponent(archiveName)
        try? FileManager.default.copyItem(at: URL(fileURLWithPath: entry.primaryFilePath), to: archiveURL)

        // Write new HTML as the primary file
        do {
            try html.write(toFile: entry.primaryFilePath, atomically: true, encoding: .utf8)
        } catch {
            return nil
        }

        // Save updated preview
        if let image = previewImage,
           let tiff = image.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let png = bitmap.representation(using: .png, properties: [:]) {
            let previewPath = outputDir.appendingPathComponent("preview.png").path
            try? png.write(to: URL(fileURLWithPath: previewPath))
            entries[idx].previewImagePath = previewPath
        }

        let newVersion = OutputVersion(
            id: UUID(), createdAt: Date(), label: label,
            filePath: entry.primaryFilePath, sourceJobId: sourceJobId,
            editPrompt: editPrompt, createdByAgent: createdByAgent
        )
        entries[idx].versions.append(newVersion)
        save()
        return newVersion.id
    }

    func updatePublishing(entryId: UUID, url: String, provider: String, status: String) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].publishedUrl = url
        entries[idx].publishedAt = Date()
        entries[idx].deploymentProvider = provider
        entries[idx].deploymentStatus = status
        save()
    }

    func setProjectSummary(entryId: UUID, summary: String, versionCount: Int) {
        guard let idx = entries.firstIndex(where: { $0.id == entryId }) else { return }
        entries[idx].projectSummary = summary
        entries[idx].summaryVersionCount = versionCount
        save()
    }

    func setHealthReport(id: UUID, report: WebsiteHealthReport) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].healthReport = report
        save()
    }

    func setAnalyticsConfig(id: UUID, provider: String, propertyId: String) {
        guard let idx = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[idx].analyticsProvider = provider
        entries[idx].analyticsPropertyId = propertyId
        save()
    }

    // MARK: - Queries

    var favorites: [OutputEntry] { entries.filter(\.favorite) }
    var websites:  [OutputEntry] { entries.filter { $0.type == .website } }
    var research:  [OutputEntry] { entries.filter { $0.type == .research } }
    var documents: [OutputEntry] { entries.filter { $0.type == .document } }

    func entries(for type: OutputType) -> [OutputEntry] {
        entries.filter { $0.type == type }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storePath, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let decoded = try? JSONDecoder().decode([OutputEntry].self, from: data) else { return }
        entries = decoded.filter {
            FileManager.default.fileExists(atPath: $0.primaryFilePath)
        }
    }
}
