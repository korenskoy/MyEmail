//
//  ComposeAttachment.swift
//  MyEmail
//
//  Pending attachment for the compose window. File is kept on disk until
//  send time — data is loaded lazily via `loadData()` so that dragging in
//  a 200 MB file doesn't bloat the compose view's memory.
//

import Foundation
import UniformTypeIdentifiers

struct ComposeAttachment: Identifiable, Hashable, Sendable {
    let id: UUID
    let url: URL
    let filename: String
    let mimeType: String
    let size: Int64

    init(url: URL) throws {
        self.id = UUID()
        self.url = url
        self.filename = url.lastPathComponent
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
        self.size = Int64(values.fileSize ?? 0)
        self.mimeType = Self.mimeType(for: values.contentType, fallbackExtension: url.pathExtension)
    }

    func loadData() throws -> Data {
        try Data(contentsOf: url, options: .mappedIfSafe)
    }

    private static func mimeType(for utType: UTType?, fallbackExtension ext: String) -> String {
        if let mime = utType?.preferredMIMEType { return mime }
        if !ext.isEmpty, let mime = UTType(filenameExtension: ext)?.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }
}
