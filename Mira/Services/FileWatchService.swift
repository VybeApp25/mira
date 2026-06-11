// FileWatchService.swift
// Phase 17 — FSEvents-lite file and directory watcher.
// Uses DispatchSource kqueue (O_EVTONLY) — no entitlement required.
// Mutually exclusive with triggers that reference the same path: last rebuild wins.

import Foundation

@MainActor
final class FileWatchService {
    static let shared = FileWatchService()

    // keyed by ExternalTrigger.id
    private var sources: [UUID: DispatchSourceFileSystemObject] = [:]

    private init() {}

    // Called by ExternalTriggerRunner whenever the trigger list changes.
    func rebuild(triggers: [ExternalTrigger]) {
        sources.values.forEach { $0.cancel() }
        sources.removeAll()

        for trigger in triggers where trigger.enabled {
            guard case .fileChange(let path) = trigger.kind else { continue }
            startWatching(path: path, triggerId: trigger.id)
        }
    }

    private func startWatching(path: String, triggerId: UUID) {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            print("[FileWatchService] Cannot open \(path) — trigger \(triggerId.uuidString.prefix(8))")
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename, .delete, .extend, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor in
                self?.fire(triggerId: triggerId, path: path)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        sources[triggerId] = source
    }

    private func fire(triggerId: UUID, path: String) {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        ExternalTriggerRunner.shared.fire(triggerId: triggerId, summary: "Changed: \(filename)")
    }
}
