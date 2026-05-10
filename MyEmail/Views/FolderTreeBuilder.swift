//
//  FolderTreeBuilder.swift
//  MyEmail
//
//  Builds a tree from flat [Folder] using path separators.
//  Used by SidebarView for nested folder hierarchy (DESIGN.md §4.3).
//

import Foundation

struct FolderNode: Identifiable {
    let folder: Folder
    var children: [FolderNode]?

    var id: UUID { folder.id }
}

enum FolderTreeBuilder {
    /// Build tree from flat folder list for one account.
    /// Roots are sorted special-use first (inbox/drafts/sent/junk/trash/archive),
    /// then regular roots alphabetically. Children nest by IMAP path separator
    /// regardless of special-use — so `Archive/2025/2025-02` nests under `Archive`.
    static func build(from folders: [Folder]) -> [FolderNode] {
        guard !folders.isEmpty else { return [] }

        let paths = Set(folders.map { $0.path })

        // A folder is a root when its parent path is not part of the list
        // (either no separator at all, or parent folder missing from IMAP).
        let roots = folders.filter { folder in
            let sep = folder.separator.isEmpty ? "/" : folder.separator
            guard let lastSep = folder.path.range(of: sep, options: .backwards) else {
                return true
            }
            let parentPath = String(folder.path[..<lastSep.lowerBound])
            return !paths.contains(parentPath)
        }

        return roots
            .sorted { lhs, rhs in
                let a = sortOrder(lhs.specialUse)
                let b = sortOrder(rhs.specialUse)
                if a != b { return a < b }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName)
                    == .orderedAscending
            }
            .map { buildNode(folder: $0, allFolders: folders) }
    }

    // MARK: - Private

    private static func buildNode(folder: Folder, allFolders: [Folder]) -> FolderNode {
        let sep = folder.separator.isEmpty ? "/" : folder.separator
        let prefix = folder.path + sep

        let directChildren = allFolders.filter { child in
            guard child.path.hasPrefix(prefix) else { return false }
            let remainder = child.path.dropFirst(prefix.count)
            return !remainder.contains(sep)
        }

        let children = directChildren
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            .map { buildNode(folder: $0, allFolders: allFolders) }

        return FolderNode(folder: folder, children: children.isEmpty ? nil : children)
    }

    private static func sortOrder(_ use: SpecialUse?) -> Int {
        switch use {
        case .inbox:   return 0
        case .drafts:  return 1
        case .sent:    return 2
        case .junk:    return 3
        case .trash:   return 4
        case .archive: return 5
        case .all:     return 99
        case nil:      return 10
        }
    }
}
