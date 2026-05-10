//
//  SyncService+RulesPlan.swift
//  MyEmail
//
//  Pre-flight planner for rule actions. Merges flag changes + subject rewrite
//  + final disposition (move/delete/markJunk) into one ExecutionPlan so
//  rewriteSubject APPENDs directly into the target folder instead of bouncing
//  through INBOX (plan §E, fixes combo-rule paranoia).
//

import Foundation

extension SyncService {

    /// Final destination of a message after a single rule's actions are merged.
    enum Disposition: Sendable, Equatable {
        case keep                      // stays where it is
        case delete                    // delete (or move-to-Trash if account has trashFolderPath)
        case moveTo(path: String)      // move to named folder
    }

    /// Merged view over a rule's actions for a single message.
    /// `nil` fields mean "no change"; when we APPEND for subject rewrite, the
    /// seen/flagged values are baked into APPEND flags (no follow-up STORE).
    struct ExecutionPlan: Sendable {
        var seen: Bool?
        var flagged: Bool?
        /// Present iff rule contains `.rewriteSubject` with a non-empty pattern
        /// AND final disposition is not `.delete`. `target` is the folder path
        /// the APPEND should land in (current folder when rule has no move).
        var subjectRewrite: SubjectRewrite?
        var finalDisposition: Disposition

        struct SubjectRewrite: Sendable {
            var pattern: String
            var replacement: String
            var target: String
        }
    }

    /// Merge a rule's actions into a single plan. The order of `actions` in
    /// the array is preserved semantically: destructive actions win over
    /// subject rewrite, later move/markJunk overrides earlier move.
    func planActions(
        _ actions: [RuleAction],
        account: Account,
        folder: Folder
    ) -> ExecutionPlan {
        var plan = ExecutionPlan(finalDisposition: .keep)

        // Pass 1: collect disposition + flags.
        var hasDelete = false
        var moveTarget: String?
        var rewritePattern: String?
        var rewriteReplacement: String = ""

        for action in actions {
            switch action.type {
            case .markRead:
                plan.seen = true
            case .markFlagged:
                plan.flagged = true
            case .delete:
                hasDelete = true
            case .moveToFolder:
                if let path = action.value, !path.isEmpty {
                    moveTarget = path
                }
            case .markJunk:
                if let junk = account.junkFolderPath, !junk.isEmpty {
                    moveTarget = junk
                }
            case .rewriteSubject:
                if let pattern = action.value, !pattern.isEmpty {
                    rewritePattern = pattern
                    rewriteReplacement = action.replacement ?? ""
                }
            }
        }

        // Pass 2: resolve final disposition.
        if hasDelete {
            plan.finalDisposition = .delete
        } else if let target = moveTarget {
            plan.finalDisposition = .moveTo(path: target)
        }

        // Pass 3: subject rewrite target. Skip entirely if message is about
        // to be deleted — creating a copy just to nuke it is pointless.
        if let pattern = rewritePattern, plan.finalDisposition != .delete {
            let target: String
            if case .moveTo(let path) = plan.finalDisposition {
                target = path
            } else {
                target = folder.path
            }
            plan.subjectRewrite = ExecutionPlan.SubjectRewrite(
                pattern: pattern,
                replacement: rewriteReplacement,
                target: target
            )
        }

        return plan
    }
}
