//
//  HTMLHeadInjector.swift
//  MyEmail
//
//  All HTML modifications BEFORE loadHTMLString. No WKUserScript (§ hard rule).
//  Nonisolated value type — called from MessageDetailView.
//

import Foundation

enum HTMLHeadInjector {

    // MARK: - CSP meta tag (remote content blocked by default)

    // §24: no `file:` in img-src — inline images are served via the
    // `myemail-cid:` scheme handler and `data:`; allowing `file:` would let
    // crafted HTML probe the local filesystem.
    static let restrictiveCSP = """
        <meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; img-src 'self' data: myemail-cid:; \
        style-src 'unsafe-inline'; font-src data:; \
        base-uri 'none'; form-action 'none';">
        """

    static let permissiveCSP = """
        <meta http-equiv="Content-Security-Policy" \
        content="default-src 'none'; img-src * data: myemail-cid:; \
        style-src 'unsafe-inline'; font-src data: *; \
        base-uri 'none'; form-action 'none';">
        """

    // MARK: - Dark mode CSS

    private static let darkModeCSS = """
        <style>
        @media (prefers-color-scheme: dark) {
            body { color: #e0e0e0; background: #1e1e1e; }
            a { color: #6cb4ee; }
            blockquote { border-left-color: #555; }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 14px;
            line-height: 1.5;
            padding: 12px;
            word-wrap: break-word;
            overflow-wrap: break-word;
        }
        img { max-width: 100%; height: auto; }
        </style>
        """

    // MARK: - Prepare HTML for rendering

    /// Regex matching remote URLs in resource-loading attributes only.
    /// `href` is intentionally excluded — links don't fetch until clicked,
    /// and clicks are intercepted by WKNavigationDelegate (opens in system browser).
    /// Handles all three HTML5 attribute-value forms: double-quoted, single-quoted,
    /// and unquoted (common in quoted-printable decoded mail — `src=https://…`).
    // swiftlint:disable:next force_try
    private static let remoteURLPattern = try! NSRegularExpression(
        pattern: #"(src|background|srcset|poster|data)\s*=\s*(?:"(?:https?:)?//[^"]+"|'(?:https?:)?//[^']+'|(?:https?:)?//[^\s>]+)"#,
        options: .caseInsensitive
    )

    /// Regex matching CSS `url(...)` with remote schemes inside style attributes / <style> blocks.
    // swiftlint:disable:next force_try
    private static let cssRemoteURLPattern = try! NSRegularExpression(
        pattern: #"url\(\s*(?:"|')?\s*(?:https?:)?//[^)'"]+\s*(?:"|')?\s*\)"#,
        options: .caseInsensitive
    )

    /// §19: matches `<meta http-equiv="refresh" ...>`. CSP `default-src 'none'`
    /// does not cover meta-refresh navigation, so a crafted message could
    /// auto-redirect the WKWebView. Strip it before render.
    ///
    /// `[^>]` (not `[\s\S]`) bounds the match to the current tag — so a crafted
    /// `<meta charset>` immediately followed by a refresh meta isn't swallowed
    /// together (no collateral removal), while still tolerating newlines inside
    /// the tag and a missing closing `>` (`>?`) on a broken/split tag. `\b`
    /// anchors the `refresh` keyword so `http-equiv="content-type"` etc. don't
    /// match.
    // swiftlint:disable:next force_try
    private static let metaRefreshPattern = try! NSRegularExpression(
        pattern: #"<meta\b[^>]*?http-equiv\s*=\s*['"]?\s*refresh\b[^>]*>?"#,
        options: .caseInsensitive
    )

    nonisolated static func prepare(
        html: String,
        allowRemoteContent: Bool,
        inlineAttachments: [InlineRef] = []
    ) -> String {
        var result = html

        // §19: strip meta-refresh unconditionally — CSP default-src 'none' does
        // not stop it, and it arrives in WKNavigationDelegate as `.other`.
        let mrRange = NSRange(result.startIndex..., in: result)
        result = metaRefreshPattern.stringByReplacingMatches(
            in: result, range: mrRange, withTemplate: ""
        )

        // Rewrite cid: → myemail-cid: for custom URL scheme handler.
        // WKWebView + loadHTMLString blocks file:// from about:blank origin,
        // and data: URLs blow up memory on large images.
        // CIDSchemeHandler serves files directly from disk.
        for ref in inlineAttachments {
            if let cid = ref.contentID {
                let encoded = cid.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? cid
                result = result.replacingOccurrences(
                    of: "cid:\(cid)",
                    with: "myemail-cid:///\(encoded)"
                )
            }
        }

        // Strip remote URLs when blocked (more reliable than meta CSP in WKWebView)
        if !allowRemoteContent {
            var range = NSRange(result.startIndex..., in: result)
            result = remoteURLPattern.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: #"$1="about:blank""#
            )
            // CSS url(...) in inline styles and <style> blocks (bug: background-image loaded)
            range = NSRange(result.startIndex..., in: result)
            result = cssRemoteURLPattern.stringByReplacingMatches(
                in: result, range: range,
                withTemplate: "url(about:blank)"
            )
        }

        let csp = allowRemoteContent ? permissiveCSP : restrictiveCSP
        let head = "\(csp)\n\(darkModeCSS)"

        // Inject into <head> or prepend
        if let headRange = result.range(of: "<head>", options: .caseInsensitive) {
            result.insert(contentsOf: head, at: headRange.upperBound)
        } else if let htmlRange = result.range(of: "<html", options: .caseInsensitive) {
            let insertPoint = result[htmlRange.upperBound...].firstIndex(of: ">")
                .map { result.index(after: $0) } ?? htmlRange.upperBound
            result.insert(contentsOf: "<head>\(head)</head>", at: insertPoint)
        } else {
            result = "<html><head>\(head)</head><body>\(result)</body></html>"
        }

        return result
    }

    /// Plain text → minimal HTML wrapper with configurable typography and quote coloring.
    nonisolated static func wrapPlainText(
        _ text: String,
        fontSize: Int = 13,
        monospace: Bool = false,
        quoteColor1: String = "#7B5EA7",
        quoteColor2: String = "#1A9D7A",
        quoteColor3: String = "#28A745"
    ) -> String {
        // Normalize CRLF — \r\n → \r<br> would double every line break in pre.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        var lines = normalized.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }

        let fontFamily = monospace ? "Menlo, Monaco, monospace" : "-apple-system, sans-serif"
        let quoteColors = [quoteColor1, quoteColor2, quoteColor3]

        let body = buildPlainTextHTML(lines: lines, quoteColors: quoteColors)
        let wrap = "font-family:\(fontFamily);font-size:\(fontSize)px;line-height:1.4;margin:0;padding:0"
        return prepare(html: "<div style='\(wrap)'>\(body)</div>",
                       allowRemoteContent: false)
    }

    /// Builds nested HTML so each quote level is literally inside its parent —
    /// both border-left bars remain visible simultaneously (like Thunderbird).
    private nonisolated static func buildPlainTextHTML(lines: [String], quoteColors: [String]) -> String {
        var html = ""
        var openDepth = 0

        for line in lines {
            let (level, content) = plainTextQuoteLevel(line)
            let escaped = plainTextEscape(content)
            let cell = escaped.isEmpty ? "<br>" : escaped

            if level == 0 {
                while openDepth > 0 { html += "</div>"; openDepth -= 1 }
                html += "<div>\(cell)</div>"
            } else {
                while openDepth > level { html += "</div>"; openDepth -= 1 }
                while openDepth < level {
                    let c = quoteColors[openDepth % quoteColors.count]
                    html += "<div style='color:\(c);border-left:3px solid \(c);padding-left:8px;margin-top:4px;margin-bottom:4px'>"
                    openDepth += 1
                }
                html += "<div>\(cell)</div>"
            }
        }
        while openDepth > 0 { html += "</div>"; openDepth -= 1 }
        return html
    }

    private nonisolated static func plainTextQuoteLevel(_ line: String) -> (level: Int, content: Substring) {
        var s = line[...]
        var level = 0
        while s.hasPrefix(">") {
            level += 1
            s = s.dropFirst()
            if s.hasPrefix(" ") { s = s.dropFirst() }
        }
        return (level, s)
    }

    private nonisolated static func plainTextEscape(_ s: some StringProtocol) -> String {
        String(s)
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

// MARK: - InlineRef

struct InlineRef: Sendable {
    let contentID: String?
    let localPath: String
}
