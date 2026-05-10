//
//  CIDSchemeHandler.swift
//  MyEmail
//
//  WKURLSchemeHandler serving inline CID attachments from disk.
//  Avoids file:// origin issues and data: URL memory bloat.
//
//  - Per-file NSCache so repeated loads (HTML re-rendering, remote-content toggle)
//    don't hit disk again.
//  - File I/O runs on a background queue; WKURLSchemeTask callbacks are dispatched
//    back to the thread that started the task (WebKit requires same-thread delivery).
//

import Foundation
import WebKit
import UniformTypeIdentifiers

final class CIDSchemeHandler: NSObject, WKURLSchemeHandler {

    /// CID → local file path mapping, set before loading HTML.
    var cidMap: [String: String] = [:]

    private let fileCache = NSCache<NSString, NSData>()
    private var stopped: Set<ObjectIdentifier> = []
    private let ioQueue = DispatchQueue(label: "ru.korenskoy.MyEmail.cidIO",
                                        qos: .userInitiated,
                                        attributes: .concurrent)

    override init() {
        super.init()
        // 32 MB soft cap — auto-evicts on memory pressure.
        fileCache.totalCostLimit = 32 * 1024 * 1024
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            urlSchemeTask.didFailWithError(URLError(.badURL))
            return
        }

        // CID is in path: myemail-cid:///CID_VALUE — strip leading "/"
        let rawPath = url.path
        let cid = rawPath.hasPrefix("/") ? String(rawPath.dropFirst()) : rawPath
        let decodedCID = cid.removingPercentEncoding ?? cid

        guard let filePath = cidMap[decodedCID] else {
            LogService.log(.warning, .sync, "CID scheme: unknown CID", detail: decodedCID)
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }

        let taskID = ObjectIdentifier(urlSchemeTask as AnyObject)
        let cacheKey = filePath as NSString

        // Fast path: memory cache hit — no disk I/O, no queue hop.
        if let cached = fileCache.object(forKey: cacheKey) {
            deliver(data: cached as Data, for: url, mime: Self.mimeType(for: (filePath as NSString).pathExtension),
                    task: urlSchemeTask)
            return
        }

        // Slow path: read off main (WebKit URL-resource thread), hop back to deliver.
        ioQueue.async { [weak self] in
            guard let self else { return }
            let fileURL = URL(fileURLWithPath: filePath)
            let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe)
            DispatchQueue.main.async {
                // Task may have been cancelled (user closed view / navigated away).
                if self.stopped.remove(taskID) != nil { return }
                guard let data else {
                    LogService.log(.warning, .sync, "CID scheme: file not found", detail: filePath)
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                self.fileCache.setObject(data as NSData, forKey: cacheKey, cost: data.count)
                self.deliver(data: data, for: url,
                             mime: Self.mimeType(for: (filePath as NSString).pathExtension),
                             task: urlSchemeTask)
            }
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {
        stopped.insert(ObjectIdentifier(urlSchemeTask as AnyObject))
    }

    private func deliver(data: Data, for url: URL, mime: String, task: any WKURLSchemeTask) {
        let response = URLResponse(
            url: url, mimeType: mime,
            expectedContentLength: data.count, textEncodingName: nil
        )
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    private static func mimeType(for ext: String) -> String {
        if let utType = UTType(filenameExtension: ext) {
            return utType.preferredMIMEType ?? "application/octet-stream"
        }
        return "application/octet-stream"
    }
}
