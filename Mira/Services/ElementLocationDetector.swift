// ElementLocationDetector.swift
// Ported from farzaa/clicky (MIT license).
//
// Uses Claude's Computer Use API to detect the screen location of UI elements
// the user is asking about. When a voice question refers to a visible element,
// this returns AppKit coordinates so PointToService can animate to it.
//
// Aspect-ratio matching: instead of always resizing to 1024×768 (4:3), we pick
// the Anthropic-recommended resolution closest to the display's actual aspect
// ratio. Most Macs are 16:10 → 1280×800. This avoids distorting the image
// Claude sees, which significantly improves X-axis coordinate accuracy.

import AppKit
import Foundation

@MainActor
final class ElementLocationDetector {

    static let shared = ElementLocationDetector()
    private init() {}

    private let apiURL = URL(string: "https://api.anthropic.com/v1/messages")!
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

    // Anthropic-recommended Computer Use resolutions, ordered by aspect ratio.
    private static let cuResolutions: [(w: Int, h: Int, ratio: Double)] = [
        (1024, 768,  1024.0 / 768.0),   // 4:3
        (1280, 800,  1280.0 / 800.0),   // 16:10 — most MacBooks
        (1366, 768,  1366.0 / 768.0),   // ~16:9 — external monitors
    ]

    // MARK: - Public

    /// Detects the AppKit-coordinate location (bottom-left origin) of a UI element
    /// the user is asking about. Returns nil if no element found or on error.
    ///
    /// - Parameters:
    ///   - screenshotData: JPEG/PNG from ScreenCaptureKit
    ///   - userQuestion: The user's voice transcript
    ///   - displayFrame: The NSScreen.frame for the captured display (AppKit coords)
    func detectElementLocation(
        screenshotData: Data,
        userQuestion: String,
        displayFrame: CGRect
    ) async -> CGPoint? {
        let displayW = Int(displayFrame.width)
        let displayH = Int(displayFrame.height)

        let res = bestResolution(forDisplayWidth: displayW, displayHeight: displayH)

        guard let resizedData = resizeForComputerUse(
            imageData: screenshotData,
            targetWidth: res.w,
            targetHeight: res.h
        ) else {
            NSLog("[ElementDetector] resize failed")
            return nil
        }

        guard let cuPoint = await callComputerUseAPI(
            imageData: resizedData,
            userQuestion: userQuestion,
            declaredW: res.w,
            declaredH: res.h
        ) else {
            return nil
        }

        // Clamp to valid range — Claude occasionally returns slightly out-of-bounds values.
        let cx = max(0, min(cuPoint.x, CGFloat(res.w)))
        let cy = max(0, min(cuPoint.y, CGFloat(res.h)))

        // Scale from Computer Use resolution → actual display point dimensions.
        let scaledX = (cx / CGFloat(res.w)) * CGFloat(displayW)
        // CU uses top-left origin; AppKit uses bottom-left → flip Y.
        let scaledY = CGFloat(displayH) - (cy / CGFloat(res.h)) * CGFloat(displayH)

        // Add display origin offset for multi-display setups.
        return CGPoint(x: displayFrame.minX + scaledX,
                       y: displayFrame.minY + scaledY)
    }

    /// Converts an AppKit point (display-local, bottom-left origin) to the
    /// normalized 0-1 top-left coordinate system PointToService expects.
    func normalizedPoint(_ appKitPt: CGPoint, displayFrame: CGRect) -> CGPoint {
        let nx =  (appKitPt.x - displayFrame.minX) / displayFrame.width
        let ny = 1.0 - (appKitPt.y - displayFrame.minY) / displayFrame.height
        return CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
    }

    // MARK: - Private

    private func bestResolution(forDisplayWidth w: Int, displayHeight h: Int) -> (w: Int, h: Int) {
        let ratio = Double(w) / Double(max(1, h))
        return Self.cuResolutions
            .min(by: { abs($0.ratio - ratio) < abs($1.ratio - ratio) })
            .map { ($0.w, $0.h) } ?? (1280, 800)
    }

    private func callComputerUseAPI(
        imageData: Data,
        userQuestion: String,
        declaredW: Int,
        declaredH: Int
    ) async -> CGPoint? {
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        req.setValue(AppSecrets.anthropicAPIKey, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01",                forHTTPHeaderField: "anthropic-version")
        req.setValue("application/json",          forHTTPHeaderField: "Content-Type")
        req.setValue("computer-use-2025-11-24",   forHTTPHeaderField: "anthropic-beta")

        let mediaType  = imageData.first == 0x89 ? "image/png" : "image/jpeg"
        let b64        = imageData.base64EncodedString()

        let userPrompt = """
        The user asked this question while looking at their screen: "\(userQuestion)"

        Look at the screenshot. If there is a specific UI element (button, link, menu item, \
        text field, icon, etc.) that the user should interact with or is asking about, click \
        on that element.

        If the question is purely conceptual (e.g., "what does HTML mean?") and there's no \
        specific element to point to, respond with text saying "no specific element".
        """

        let body: [String: Any] = [
            "model": model,
            "max_tokens": 256,
            "tools": [[
                "type":              "computer_20251124",
                "name":              "computer",
                "display_width_px":  declaredW,
                "display_height_px": declaredH,
            ]],
            "messages": [[
                "role": "user",
                "content": [
                    ["type": "image",
                     "source": ["type": "base64", "media_type": mediaType, "data": b64]],
                    ["type": "text", "text": userPrompt],
                ]
            ]]
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await session.data(for: req)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                NSLog("[ElementDetector] API error %d", (response as? HTTPURLResponse)?.statusCode ?? -1)
                return nil
            }

            return parseCoordinate(from: data)
        } catch {
            NSLog("[ElementDetector] request failed: %@", error.localizedDescription)
            return nil
        }
    }

    private func parseCoordinate(from data: Data) -> CGPoint? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let blocks = json["content"] as? [[String: Any]] else { return nil }

        for block in blocks {
            guard block["type"] as? String == "tool_use",
                  let input = block["input"] as? [String: Any],
                  let coords = input["coordinate"] as? [NSNumber],
                  coords.count == 2 else { continue }

            return CGPoint(x: coords[0].doubleValue, y: coords[1].doubleValue)
        }
        return nil
    }

    // Uses NSBitmapImageRep directly to avoid Retina 2× scaling bug in NSImage.lockFocus.
    // lockFocus creates a 2× bitmap on Retina displays, so the JPEG sent to Claude would
    // be 2× larger than the resolution declared in the Computer Use tool, breaking coords.
    private func resizeForComputerUse(imageData: Data, targetWidth: Int, targetHeight: Int) -> Data? {
        guard let original = NSImage(data: imageData),
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide:  targetWidth,
                pixelsHigh:  targetHeight,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
              ) else { return nil }

        rep.size = NSSize(width: targetWidth, height: targetHeight)

        NSGraphicsContext.saveGraphicsState()
        let ctx = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current = ctx
        ctx?.imageInterpolation = .high
        original.draw(
            in:   NSRect(x: 0, y: 0, width: targetWidth, height: targetHeight),
            from: NSRect(origin: .zero, size: original.size),
            operation: .copy,
            fraction: 1.0
        )
        NSGraphicsContext.restoreGraphicsState()

        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
}
