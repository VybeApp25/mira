import Foundation
import WebKit
import AppKit

// Renders HTML to an NSImage using an offscreen WKWebView.
// All work happens on the main actor (WKWebView requirement).

@MainActor
final class OffscreenRenderer: NSObject {

    private var webView: WKWebView?
    private var continuation: CheckedContinuation<NSImage?, Never>?

    static func capture(html: String, size: CGSize = CGSize(width: 1440, height: 900)) async -> NSImage? {
        let renderer = OffscreenRenderer()
        return await renderer.render(html: html, size: size)
    }

    private func render(html: String, size: CGSize) async -> NSImage? {
        return await withCheckedContinuation { continuation in
            self.continuation = continuation

            let config = WKWebViewConfiguration()
            config.suppressesIncrementalRendering = true

            let wv = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: config)
            wv.navigationDelegate = self
            self.webView = wv
            wv.loadHTMLString(html, baseURL: nil)

            // Safety timeout — resumes with nil if navigation never completes
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard let self, self.continuation != nil else { return }
                self.continuation?.resume(returning: nil)
                self.continuation = nil
            }
        }
    }

    private func takeSnapshot() {
        guard let wv = webView else {
            continuation?.resume(returning: nil)
            continuation = nil
            return
        }
        // Brief delay lets CSS paint and font swap complete
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self, let wv = self.webView else {
                self?.continuation?.resume(returning: nil)
                self?.continuation = nil
                return
            }
            let config = WKSnapshotConfiguration()
            config.rect = wv.bounds
            wv.takeSnapshot(with: config) { [weak self] image, _ in
                self?.continuation?.resume(returning: image)
                self?.continuation = nil
            }
        }
    }
}

extension OffscreenRenderer: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        takeSnapshot()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(returning: nil)
        continuation = nil
    }
}
