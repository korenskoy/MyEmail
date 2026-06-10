//
//  HTMLMailView.swift
//  MyEmail
//
//  NSViewRepresentable wrapping WKWebView. JS fully disabled.
//  CSP injected via <meta> in HTMLHeadInjector BEFORE loadHTMLString.
//  No WKUserScript (hard rule from CLAUDE.md).
//

import SwiftUI
import WebKit

struct HTMLMailView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    var inlineRefs: [InlineRef] = []

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.defaultWebpagePreferences.allowsContentJavaScript = false

        // Register custom scheme for CID inline images
        let handler = CIDSchemeHandler()
        config.setURLSchemeHandler(handler, forURLScheme: "myemail-cid")
        context.coordinator.cidHandler = handler

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        // Transparent background for dark mode CSS to take effect
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        // Avoid redundant loads
        guard context.coordinator.lastHTML != html else { return }
        context.coordinator.lastHTML = html

        // Update CID mapping before loading HTML
        var cidMap: [String: String] = [:]
        for ref in inlineRefs {
            if let cid = ref.contentID {
                cidMap[cid] = ref.localPath
            }
        }
        context.coordinator.cidHandler?.cidMap = cidMap

        // §19: flag our own document load so decidePolicyFor allows exactly this
        // navigation. The web view is reused across messages, so `webView.url` is
        // non-nil from the 2nd message on and can't be used to detect our load.
        context.coordinator.isLoadingOwnContent = true
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var cidHandler: CIDSchemeHandler?

        /// True between our `loadHTMLString` call and the navigation decision for
        /// that load. The web view is reused across messages, so `webView.url` is
        /// non-nil after the first message — this flag (not the URL) marks our own
        /// document load so decidePolicyFor can allow it while still cancelling
        /// content-initiated navigation.
        var isLoadingOwnContent = false

        /// §20: schemes permitted to open in the system browser. Anything else
        /// (file:, javascript:, custom app schemes) is ignored.
        private static let allowedLinkSchemes: Set<String> = ["http", "https", "mailto"]

        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // User clicked a link → open in system browser if the scheme is safe.
            if action.navigationType == .linkActivated {
                if let url = action.request.url,
                   let scheme = url.scheme?.lowercased(),
                   Self.allowedLinkSchemes.contains(scheme) {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
                return
            }

            // §19: allow ONLY our own document load (flagged just before
            // loadHTMLString). Everything afterwards — meta-refresh, form posts,
            // scripted redirects, subframe navigation — is cancelled so the
            // message body can't navigate.
            if action.navigationType == .other, isLoadingOwnContent {
                isLoadingOwnContent = false
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }
    }
}
