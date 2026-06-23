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

/// Typed result of a Point-and-Ask element detection.
///
/// Replaces a bare `CGPoint?`, which collapsed three very different outcomes
/// into `nil`: a real failure (network/HTTP/resize), the model legitimately
/// deciding there's nothing to point at, and a found coordinate. The evidence
/// funnel needs to tell "Mira correctly saw nothing" apart from "Mira broke",
/// so each is its own case.
enum GuidanceDetection {
    /// An element was located, at this AppKit point (global, bottom-left origin).
    case located(CGPoint)
    /// The call succeeded but the model said there's no specific element to point to.
    case noElement
    /// The detection could not complete. `reason` is a short stable tag for telemetry.
    case failed(reason: String)
}

@MainActor
final class ElementLocationDetector {

    static let shared = ElementLocationDetector()
    private init() {}

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
    ) async -> GuidanceDetection {
        let displayW = Int(displayFrame.width)
        let displayH = Int(displayFrame.height)

        // CRITICAL: send the screenshot at its TRUE aspect ratio and declare those
        // exact dimensions. Forcing it into a fixed bucket (e.g. 1280×800) distorts
        // the image vertically, and the Computer Use model — trained on undistorted
        // screenshots — then aims systematically off (consistently too low). Keep
        // aspect; only downscale if wider than the recommended max.
        guard let fit = fitForComputerUse(screenshotData) else {
            NSLog("[ElementDetector] fit failed")
            return .failed(reason: "resize")
        }

        switch await callComputerUseAPI(
            imageData: fit.data,
            userQuestion: userQuestion,
            declaredW: fit.w,
            declaredH: fit.h
        ) {
        case .failed(let reason):
            return .failed(reason: reason)

        case .noElement:
            return .noElement

        case .coordinate(let cuPoint):
            // Clamp to valid range — Claude occasionally returns slightly out-of-bounds values.
            let cx = max(0, min(cuPoint.x, CGFloat(fit.w)))
            let cy = max(0, min(cuPoint.y, CGFloat(fit.h)))

            // Scale from the (aspect-correct) image space → actual display points.
            let scaledX = (cx / CGFloat(fit.w)) * CGFloat(displayW)
            // CU uses top-left origin; AppKit uses bottom-left → flip Y.
            let scaledY = CGFloat(displayH) - (cy / CGFloat(fit.h)) * CGFloat(displayH)

            // Add display origin offset for multi-display setups.
            let appKit = CGPoint(x: displayFrame.minX + scaledX, y: displayFrame.minY + scaledY)
            return .located(appKit)
        }
    }

    /// Converts an AppKit point (display-local, bottom-left origin) to the
    /// normalized 0-1 top-left coordinate system PointToService expects.
    func normalizedPoint(_ appKitPt: CGPoint, displayFrame: CGRect) -> CGPoint {
        let nx =  (appKitPt.x - displayFrame.minX) / displayFrame.width
        let ny = 1.0 - (appKitPt.y - displayFrame.minY) / displayFrame.height
        return CGPoint(x: max(0, min(1, nx)), y: max(0, min(1, ny)))
    }

    // MARK: - Private

    /// Returns the image to send plus its actual pixel dimensions, preserving
    /// aspect ratio. If the image is already within the recommended max width it
    /// is sent UNCHANGED (no distortion); only wider images are downscaled, and
    /// even then aspect is preserved. The declared dims always equal the image's
    /// real dims, so the model's coordinate space matches what it sees.
    private func fitForComputerUse(_ data: Data, maxWidth: Int = 1280) -> (data: Data, w: Int, h: Int)? {
        guard let (w0, h0) = pixelSize(of: data) else { return nil }
        if w0 <= maxWidth { return (data, w0, h0) }
        let th = Int((Double(h0) / Double(w0)) * Double(maxWidth))
        guard let resized = resizeForComputerUse(imageData: data, targetWidth: maxWidth, targetHeight: th) else {
            return nil
        }
        return (resized, maxWidth, th)
    }

    /// Actual pixel dimensions of an encoded image (Retina-safe — reads the bitmap
    /// rep's pixel counts, not NSImage point size).
    private func pixelSize(of data: Data) -> (w: Int, h: Int)? {
        guard let rep = NSBitmapImageRep(data: data) else { return nil }
        return (rep.pixelsWide, rep.pixelsHigh)
    }

    /// Outcome of one Computer Use API call, before coordinate scaling.
    private enum CUResult {
        case coordinate(CGPoint)
        case noElement
        case failed(reason: String)
    }

    private func callComputerUseAPI(
        imageData: Data,
        userQuestion: String,
        declaredW: Int,
        declaredH: Int
    ) async -> CUResult {
        var req = URLRequest(url: apiURL)
        req.httpMethod = "POST"
        req.timeoutInterval = 15
        MiraBackend.authorizeAnthropic(&req, directKey: AppSecrets.anthropicAPIKey)
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
            let (data, response) = try await MiraBackend.proxyData(for: req, using: session)

            guard let http = response as? HTTPURLResponse,
                  (200...299).contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? -1
                NSLog("[ElementDetector] API error %d", code)
                return .failed(reason: "http_\(code)")
            }

            // A successful call with no coordinate means the model chose not to
            // point at anything — a valid outcome, not a failure.
            if let pt = parseCoordinate(from: data) {
                return .coordinate(pt)
            }
            return .noElement
        } catch {
            NSLog("[ElementDetector] request failed: %@", error.localizedDescription)
            return .failed(reason: "request")
        }
    }

    // MARK: - Diagnostics

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
