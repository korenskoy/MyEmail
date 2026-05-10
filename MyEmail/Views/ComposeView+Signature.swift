//
//  ComposeView+Signature.swift
//  MyEmail
//
//  Signature apply/swap logic. Signatures are tagged with
//  `RichTextSupport.signatureKey` so the swap helper can locate them by
//  attribute rather than fragile suffix matching.
//

import AppKit
import Foundation
import GRDB
import SwiftUI

extension ComposeView {

    static let signatureSeparator = "\n\n-- \n"

    /// Fetch default signature for an account from GRDB.
    func defaultSignature(for accountID: UUID) -> Signature? {
        try? DatabaseService.shared.pool.read { db in
            try Signature
                .filter(Column("account_id") == accountID)
                .filter(Column("is_default") == true)
                .fetchOne(db)
        }
    }

    /// Attributes used to tag the signature range so swap can locate it
    /// independently of its visible text (survives user edits around it).
    private func signatureAttributes() -> [NSAttributedString.Key: Any] {
        var attrs = RichTextSupport.defaultTypingAttributes
        attrs[RichTextSupport.signatureKey] = true
        return attrs
    }

    /// Append default signature on initial appear.
    func applySignature(for accountID: UUID) {
        guard let sig = defaultSignature(for: accountID) else { return }
        let sigString = Self.signatureSeparator + sig.body
        let sigAttr = NSAttributedString(string: sigString, attributes: signatureAttributes())
        let merged = NSMutableAttributedString(attributedString: attributedBody)
        merged.append(sigAttr)
        attributedBody = merged
    }

    /// Swap signature when user changes the From account. Located via the
    /// `signatureKey` attribute marker rather than a suffix match — resilient
    /// to rich formatting. The new signature is always appended at the end;
    /// if the user moved the previous one mid-body it is relocated.
    func swapSignature(from oldAccountID: UUID, to newAccountID: UUID) {
        let merged = NSMutableAttributedString(attributedString: attributedBody)
        let ranges = signatureRanges(in: merged)
        for range in ranges.reversed() {
            merged.deleteCharacters(in: range)
        }
        if let newSig = defaultSignature(for: newAccountID) {
            let sigString = Self.signatureSeparator + newSig.body
            merged.append(NSAttributedString(string: sigString, attributes: signatureAttributes()))
        }
        attributedBody = merged
    }

    private func signatureRanges(in attr: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        attr.enumerateAttribute(
            RichTextSupport.signatureKey,
            in: NSRange(location: 0, length: attr.length),
            options: []
        ) { value, range, _ in
            if value as? Bool == true {
                ranges.append(range)
            }
        }
        return ranges
    }
}
