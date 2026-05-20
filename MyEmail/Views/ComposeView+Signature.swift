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

    /// Attributes used to tag the signature range so swap can locate it
    /// independently of its visible text (survives user edits around it).
    private func signatureAttributes() -> [NSAttributedString.Key: Any] {
        var attrs = RichTextSupport.defaultTypingAttributes
        attrs[RichTextSupport.signatureKey] = true
        return attrs
    }

    /// Refresh signatures available for the current From account.
    func reloadSignatures() {
        let accountID = selectedAccountID
        availableSignatures = (try? DatabaseService.shared.pool.read { db in
            try Signature
                .filter(Column("account_id") == accountID)
                .order(Column("name"))
                .fetchAll(db)
        }) ?? []
    }

    /// Apply whichever signature `selectedSignatureID` currently points at
    /// (or remove any existing signature when nil).
    func applySelectedSignature() {
        let signature = availableSignatures.first { $0.id == selectedSignatureID }
        setSignature(to: signature)
    }

    /// Replace any existing signature in the body with `signature` (or remove
    /// when nil). Located via the `signatureKey` attribute marker — resilient
    /// to rich formatting and user edits around it.
    func setSignature(to signature: Signature?) {
        let merged = NSMutableAttributedString(attributedString: attributedBody)
        for range in signatureRanges(in: merged).reversed() {
            merged.deleteCharacters(in: range)
        }
        if let signature {
            let sigString = Self.signatureSeparator + signature.body
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
