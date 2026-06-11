// WebhookServer.swift
// Phase 17 — Lightweight local HTTP server for receiving webhooks.
// Uses Network.NWListener (TCP). Parses minimal HTTP: headers + body.
// Default port 7777 — configurable in Settings. Needs ngrok/cloudflared to
// receive GitHub webhooks from the internet.

import Foundation
import Network

@MainActor
final class WebhookServer: ObservableObject {
    static let shared = WebhookServer()

    @Published private(set) var isRunning = false
    @Published private(set) var port: UInt16 = 7777
    @Published private(set) var lastEventAt: Date? = nil
    @Published private(set) var lastEventLabel: String? = nil

    private var listener: NWListener?
    private init() {}

    func start(port: UInt16 = 7777) {
        if isRunning && self.port == port { return }
        stop()
        self.port = port
        do {
            let params = NWParameters.tcp
            let ep = NWEndpoint.Port(rawValue: port)!
            let l = try NWListener(using: params, on: ep)
            self.listener = l
            l.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in self?.isRunning = (state == .ready) }
            }
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(connection: conn) }
            }
            l.start(queue: .main)
        } catch {
            print("[WebhookServer] Failed to start on port \(port): \(error)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    // MARK: - Connection handling

    private func handle(connection: NWConnection) {
        connection.start(queue: .main)
        readAll(connection: connection, accumulated: Data()) { [weak self] data in
            guard let self, let data, !data.isEmpty else { connection.cancel(); return }
            let raw = String(data: data, encoding: .utf8) ?? ""
            self.dispatch(rawRequest: raw)
            let ok = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nOK"
            connection.send(content: ok.data(using: .utf8),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func readAll(connection: NWConnection, accumulated: Data,
                         completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isDone, error in
            if error != nil { completion(nil); return }
            var buf = accumulated
            if let data { buf.append(data) }
            if isDone || self.hasFullRequest(buf) {
                completion(buf)
            } else {
                self.readAll(connection: connection, accumulated: buf, completion: completion)
            }
        }
    }

    private func hasFullRequest(_ data: Data) -> Bool {
        guard let sep = "\r\n\r\n".data(using: .utf8),
              let range = data.range(of: sep) else { return false }
        let headerPart = data[..<range.lowerBound]
        guard let headerStr = String(data: headerPart, encoding: .utf8) else { return false }
        if let clLine = headerStr.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("content-length:") }),
           let length = Int(clLine.components(separatedBy: ":").last?.trimmingCharacters(in: .whitespaces) ?? "") {
            let bodyStart = range.upperBound
            return data.count >= bodyStart + length
        }
        return true // no Content-Length = headers-only request
    }

    // MARK: - Dispatch

    private func dispatch(rawRequest: String) {
        let (headers, body) = splitRequest(rawRequest)
        let githubEvent = headerValue(headers, name: "X-GitHub-Event")
        let label = githubEvent.map { "\($0) event" } ?? "POST"
        lastEventAt    = Date()
        lastEventLabel = label

        let json = body.data(using: .utf8).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        let repoName = (json?["repository"] as? [String: Any])?["full_name"] as? String
        let refBranch = (json?["ref"] as? String)?.components(separatedBy: "/").last ?? ""

        for trigger in TriggerStore.shared.triggers where trigger.enabled {
            switch trigger.kind {
            case .webhook:
                ExternalTriggerRunner.shared.fire(triggerId: trigger.id, summary: "Webhook POST received")
            case .githubPush(let repo, let branch, _):
                let repoMatch   = repo.isEmpty || repoName == nil || repoName == repo
                let branchMatch = branch.isEmpty || refBranch.isEmpty || refBranch == branch
                let eventMatch  = githubEvent == nil || githubEvent == "push"
                if repoMatch && branchMatch && eventMatch {
                    let displayRepo   = repoName ?? repo
                    let displayBranch = refBranch.isEmpty ? branch : refBranch
                    ExternalTriggerRunner.shared.fire(
                        triggerId: trigger.id,
                        summary: "GitHub push: \(displayRepo) [\(displayBranch)]"
                    )
                }
            default:
                break
            }
        }
    }

    private func splitRequest(_ raw: String) -> (headers: String, body: String) {
        let parts = raw.components(separatedBy: "\r\n\r\n")
        return (parts.first ?? "", parts.dropFirst().joined(separator: "\r\n\r\n"))
    }

    private func headerValue(_ headers: String, name: String) -> String? {
        for line in headers.components(separatedBy: "\r\n") {
            let kv = line.components(separatedBy: ": ")
            if kv.count >= 2 && kv[0].lowercased() == name.lowercased() {
                return kv.dropFirst().joined(separator: ": ")
            }
        }
        return nil
    }
}
