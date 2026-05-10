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

        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var lastHTML: String?
        var cidHandler: CIDSchemeHandler?

        // Block external navigation — links open in system browser
        func webView(
            _ webView: WKWebView,
            decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .linkActivated,
               let url = action.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
