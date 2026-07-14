// VisionStateVerifier.swift
// Teaching System — Learn-Along (LA-0). See docs/architecture/learn_along.md §3 WS1.
//
// Answers one question about a screenshot: "is <described visible outcome> now
// true on screen?" — returning a boolean verdict plus the model's confidence.
// This is what backs the `.visualState` success check, letting a lesson OBSERVE
// domain progress inside an arbitrary app (a DAW, an editor) instead of falling
// back to "tap Done".
//
// Honesty posture: this is a MODEL verdict, i.e. second-class evidence. The
// verifier never decides on its own that a step is done — it just reports
// (satisfied, confidence). The caller (TeachingEngine) applies the advance
// threshold and records the distinct `.visionObserved` provenance. A network/parse
// failure returns nil (unknown), never a false "yes".

import AppKit
import Foundation

@MainActor
final class VisionStateVerifier {

    static let shared = VisionStateVerifier()
    private init() {}

    /// A yes/no verdict about the screen, with the model's own confidence (0–1).
    struct Verdict { let satisfied: Bool; let confidence: Double }

    private var apiURL: URL { MiraBackend.anthropicMessagesURL }
    private let model  = "claude-sonnet-4-6"

    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest  = 15
        cfg.timeoutIntervalForResource = 20
        cfg.waitsForConnectivity = false
        cfg.urlCache = nil
        cfg.httpCookieStorage = nil
        return URLSession(configuration: cfg)
    }()

    /// Asks whether `description` is currently true on the given screenshot.
    /// Returns nil on any failure (network/HTTP/parse) — an unknown, never a guess.
    /// The caller decides whether the confidence clears its advance threshold.
    func verify(description: String, screenshotData: Data) async -> Verdict? {
        // Downscale to keep the vision call cheap; aspect is irrelevant for a yes/no
        // (no coordinates are returned), so a plain width cap is fine.
        let imageData = downscaledJPEG(screenshotData, maxWidth: 1280) ?? screenshotData
        let mediaType = imageData.first == 0x89 ? "image/png" : "image/jpeg"
        let b64       = imageData.base64EncodedString()

        let prompt = """
        You are verifying whether a specific, observable condition is TRUE in this \
        screenshot. The condition:

        "\(description)"

        Judge ONLY what is visibly present right now. Do not assume, infer intent, or \
        give the benefit of the doubt — if you cannot clearly see that the condition \
        holds, it is not satisfied. Reply with a single JSON object and nothing else:
        {"satisfied": true|false, "confidence": 0.0-1.0}
        where confidence is how certain you are of the verdict you gave.
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 64,
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mediaType, "data": b64]],
                    ["type": "text", "text": prompt],
                ]
            ]]
        ]

        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        MiraBackend.authorizeAnthropic(&req, directKey: AppSecrets.anthropicAPIKey)
        req.setValue("2023-06-01",       forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await MiraBackend.proxyData(for: req, using: session)
            guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
                NSLog("[VisionVerify] API error %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return nil
            }
            return parseVerdict(from: data)
        } catch {
            NSLog("[VisionVerify] request failed: %@", error.localizedDescription)
            return nil
        }
    }

    // MARK: - Parsing

    /// Pulls the first {"satisfied":…, "confidence":…} object out of the model's
    /// text reply. Tolerant of surrounding prose / code fences.
    private func parseVerdict(from data: Data) -> Verdict? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else { return nil }
        let text = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            .joined(separator: " ")
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let obj = try? JSONSerialization.jsonObject(
                with: Data(text[start...end].utf8)) as? [String: Any] else { return nil }

        // Accept bool or a "true"/"false" string; confidence as a number or numeric string.
        let satisfied: Bool
        if let b = obj["satisfied"] as? Bool { satisfied = b }
        else if let s = obj["satisfied"] as? String { satisfied = (s.lowercased() == "true") }
        else { return nil }

        let confidence: Double
        if let n = obj["confidence"] as? NSNumber { confidence = n.doubleValue }
        else if let s = obj["confidence"] as? String, let d = Double(s) { confidence = d }
        else { confidence = satisfied ? 0.5 : 0.0 }

        return Verdict(satisfied: satisfied, confidence: max(0, min(1, confidence)))
    }

    // MARK: - Image

    /// Retina-safe downscale to a max width, JPEG-encoded. Returns nil if the image
    /// is already within the cap (caller then sends it unchanged).
    private func downscaledJPEG(_ data: Data, maxWidth: Int) -> Data? {
        guard let rep0 = NSBitmapImageRep(data: data), rep0.pixelsWide > maxWidth else { return nil }
        let th = Int((Double(rep0.pixelsHigh) / Double(rep0.pixelsWide)) * Double(maxWidth))
        guard let original = NSImage(data: data),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: maxWidth, pixelsHigh: th,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = NSSize(width: maxWidth, height: th)
        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.imageInterpolation = .high
        original.draw(in: NSRect(x: 0, y: 0, width: maxWidth, height: th),
                      from: NSRect(origin: .zero, size: original.size),
                      operation: .copy, fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
