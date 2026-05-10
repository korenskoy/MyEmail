//
//  QuickLookCoordinator.swift
//  MyEmail
//
//  QLPreviewPanel data source for attachment Quick Look.
//

import Quartz

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource {
    private var urls: [URL] = []

    func show(urls: [URL], selectedIndex: Int) {
        guard let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        panel.dataSource = self
        panel.currentPreviewItemIndex = selectedIndex
        if panel.isVisible {
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated { urls[index] as NSURL }
    }
}
