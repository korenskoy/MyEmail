//
//  MailboxSelection+ModSeq.swift
//  MyEmail
//
//  Isolated so the NIOIMAPCore import stays out of the service files:
//  SwiftMail and NIOIMAPCore both declare UID, SequenceNumber, UIDValidity
//  and IMAPServer, so importing it anywhere those names appear is ambiguous.
//

import NIOIMAPCore
import SwiftMail

extension Mailbox.Selection {
    /// HIGHESTMODSEQ as the sync engine and `folders.highest_mod_sequence`
    /// speak it. SwiftMail reports it as NIOIMAPCore's opaque
    /// `ModificationSequenceValue`, whose raw value is internal; RFC 7162
    /// §3.1.1 defines it as a 63-bit unsigned integer, so widening is total.
    var modSeqWatermark: UInt64? { highestModSequence.map(UInt64.init) }
}
