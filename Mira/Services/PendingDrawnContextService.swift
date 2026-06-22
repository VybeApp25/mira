import AppKit
import Combine

// MARK: - DrawnContext
//
// The spatial context a user draws on their screen (ScreenDrawController), ready to
// hand to any lane: the realtime voice turn, a typed chat question, or an autonomy
// task. We keep BOTH a clean capture and the marks-burned-in capture, plus the marks
// normalized to 0–1 (top-left) so we can describe *where* the user pointed to the
// model in the same coordinate space it reasons about. This is the user-input mirror
// of CodexLiveOverlay (which draws where Mira is acting).

struct DrawnContext {
    let annotatedImage: NSImage      // full screen capture with the user's marks composited in
    let cleanImage: NSImage          // the same capture WITHOUT marks
    let normalizedMarks: [CGPoint]   // every stroke point, normalized 0–1, top-left origin
    let displayFrame: CGRect         // captured display frame (AppKit, bottom-left origin), points
    let createdAt = Date()

    /// Bounding rect of all marks in normalized 0–1 (top-left) space.
    var normalizedBoundingRect: CGRect {
        guard !normalizedMarks.isEmpty else { return CGRect(x: 0, y: 0, width: 1, height: 1) }
        let xs = normalizedMarks.map(\.x), ys = normalizedMarks.map(\.y)
        let minX = xs.min() ?? 0, maxX = xs.max() ?? 1
        let minY = ys.min() ?? 0, maxY = ys.max() ?? 1
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    /// Target region in logical screen POINTS (top-left origin) — the space the
    /// Claude computer-use loop is told the display is in (`displayWidth×displayHeight`).
    var logicalRegion: CGRect {
        let b = normalizedBoundingRect
        let w = displayFrame.width, h = displayFrame.height
        return CGRect(x: b.minX * w, y: b.minY * h, width: b.width * w, height: b.height * h)
    }

    /// Model-readable hint for VISION lanes (voice / chat) — normalized coordinates.
    var coordinateHint: String {
        let b = normalizedBoundingRect
        func f(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        return "The user drew on their screen to point at something (coordinates normalized 0–1, "
             + "top-left origin). Marked region: x \(f(b.minX))–\(f(b.maxX)), y \(f(b.minY))–\(f(b.maxY)); "
             + "center (\(f(b.midX)), \(f(b.midY))). Focus your answer on what is inside or nearest that region."
    }

    /// Model-readable hint for the COMPUTER-USE lane — logical screen points, the
    /// same space the orchestrator declares the display in, so a click can land.
    var computerUseHint: String {
        let r = logicalRegion
        func i(_ v: CGFloat) -> String { String(Int(v.rounded())) }
        return "The user drew on the screen to mark WHERE to act. Marked region in screen points "
             + "(top-left origin): x=\(i(r.minX)), y=\(i(r.minY)), width=\(i(r.width)), height=\(i(r.height)); "
             + "center (\(i(r.midX)), \(i(r.midY))). Act on the element at or nearest that region."
    }

    /// Downscaled-to-pixels JPEG of the annotated capture. Everything that UPLOADS
    /// the marks goes through this. A full-res screen PNG is ~14 MB of base64 —
    /// Anthropic rejects any image over ~5 MB with HTTP 400 — and NSImage lockFocus
    /// composites at the Retina 2× backing scale, so "resize to 1400 pt" still yields
    /// a 2800 px PNG. miraDownscaledJPEG resizes the true pixels + JPEG-encodes →
    /// ~200 KB, matching the ~1280 px cap used elsewhere.
    func annotatedJPEGData(maxWidth: CGFloat = 1280, quality: CGFloat = 0.6) -> Data? {
        annotatedImage.miraDownscaledJPEG(maxWidth: maxWidth, quality: quality)
    }

    /// Base64 of the downscaled JPEG, for the chat/autonomy image content blocks.
    func annotatedJPEGBase64(maxWidth: CGFloat = 1280, quality: CGFloat = 0.6) -> String? {
        annotatedJPEGData(maxWidth: maxWidth, quality: quality)?.base64EncodedString()
    }

    /// A tight, padded JPEG CROP around just the marked region (with the ink visible).
    /// The token-efficient path for "what is this?" questions — sending the whole
    /// screen is wasteful (HeyClicky's founder: "we built an in-house system that's
    /// efficiently interacting with models"). A focused crop is a fraction of the
    /// tokens AND sharper, since the model sees exactly what was circled. Falls back
    /// to the full downscaled frame if the crop can't be computed.
    func markedCropJPEGBase64(padding: CGFloat = 0.10, maxWidth: CGFloat = 1000, quality: CGFloat = 0.6) -> String? {
        guard let cg = annotatedImage.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return annotatedJPEGBase64()
        }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)
        let b = normalizedBoundingRect
        let minX = max(0, b.minX - padding), minY = max(0, b.minY - padding)
        let maxX = min(1, b.maxX + padding), maxY = min(1, b.maxY + padding)
        // CGImage origin is top-left, matching our normalized (top-left) marks.
        let crop = CGRect(x: minX * W, y: minY * H, width: (maxX - minX) * W, height: (maxY - minY) * H)
        guard crop.width >= 8, crop.height >= 8, let cropped = cg.cropping(to: crop) else {
            return annotatedJPEGBase64()
        }
        let img = NSImage(cgImage: cropped, size: NSSize(width: cropped.width, height: cropped.height))
        return img.miraDownscaledJPEG(maxWidth: maxWidth, quality: quality)?.base64EncodedString()
    }

    /// Write the annotated capture to a temp PNG for the Codex CLI lane (which can
    /// only take string args, not image bytes). Returns the file path, or nil.
    func writeTempPNG() -> String? {
        guard let tiff = annotatedImage.tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff),
              let png  = rep.representation(using: .png, properties: [:]) else { return nil }
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mira-marks-\(UUID().uuidString).png")
        do { try png.write(to: url); return url.path } catch { return nil }
    }
}

// MARK: - PendingDrawnContextService

/// Holds the most-recently-drawn `DrawnContext` until a lane consumes it. Decouples
/// *drawing* (ScreenDrawController) from *which lane uses it* (voice / chat / autonomy).
/// `@Published hasPending` lets the chat composer and Control tab show a "marks
/// attached" chip.
@MainActor
final class PendingDrawnContextService: ObservableObject {
    static let shared = PendingDrawnContextService()
    private init() {}

    @Published private(set) var pending: DrawnContext?
    var hasPending: Bool { pending != nil }

    func set(_ ctx: DrawnContext) { pending = ctx }

    /// Take the pending context and clear it (single-consumer).
    func pop() -> DrawnContext? {
        let c = pending
        pending = nil
        return c
    }

    func clear() { pending = nil }
}

// MARK: - NSImage JPEG helper

extension NSImage {
    /// JPEG encoding (NSImage has no built-in). `pngBase64()` already lives in
    /// ClaudeService; this is the JPEG sibling used for the realtime image data URL.
    func miraJPEGData(compression: CGFloat = 0.7) -> Data? {
        guard let tiff = tiffRepresentation,
              let rep  = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: compression])
    }

    /// Downscale by TRUE pixels (not points) and JPEG-encode. Avoids NSImage
    /// lockFocus's Retina 2× inflation and PNG's huge size, so the result is a
    /// small upload (~200 KB) that stays under Anthropic's 5 MB/image limit.
    func miraDownscaledJPEG(maxWidth: CGFloat = 1280, quality: CGFloat = 0.6) -> Data? {
        guard let cg = cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return miraJPEGData(compression: quality)
        }
        let srcW = CGFloat(cg.width), srcH = CGFloat(cg.height)
        guard srcW > 0, srcH > 0 else { return nil }
        let scale = min(1, maxWidth / srcW)
        let w = max(1, Int(srcW * scale)), h = max(1, Int(srcH * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: out).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }
}
