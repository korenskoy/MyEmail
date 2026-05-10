//
//  DatabaseService+Schema.swift
//  MyEmail
//
//  Single-shot schema bootstrap (v1.1). No DatabaseMigrator — historic v1..v11
//  migrations were rolled into the canonical schema below. Single-user app:
//  legacy db.sqlite is wiped on upgrade (see DatabaseService.init).
//
//  If a future schema change is needed, add a NEW `CREATE ... IF NOT EXISTS`
//  here AND wipe the DB again (bump WIPE_VERSION_KEY in DatabaseService).
//

import Foundation
import GRDB

extension DatabaseService {

    static func createSchema(on pool: DatabasePool) throws {
        try pool.write { db in
            try db.execute(sql: Self.schemaSQL)

            // Idempotent column upgrades for pre-existing mail_rules tables.
            // SQLite has no "ADD COLUMN IF NOT EXISTS" — `try?` swallows the
            // "duplicate column" error and lets the schema evolve without a
            // DatabaseMigrator or DB wipe (single-user app, Codable JSON
            // backward-compat for the row data).
            try? db.execute(sql:
                "ALTER TABLE mail_rules ADD COLUMN run_on_incoming INTEGER NOT NULL DEFAULT 1")
            try? db.execute(sql:
                "ALTER TABLE mail_rules ADD COLUMN run_on_manual INTEGER NOT NULL DEFAULT 1")
            try? db.execute(sql:
                "ALTER TABLE mail_rules ADD COLUMN folder_paths TEXT NOT NULL DEFAULT '[]'")
            try? db.execute(sql:
                "ALTER TABLE messages ADD COLUMN user_agent TEXT")

            // FTS5 virtual table — system SQLite on macOS 15+ supports it.
            // `synchronize(withTable:)` installs AFTER INSERT/UPDATE/DELETE
            // triggers that mirror `messages` rows into `messages_fts`.
            // Column order below MUST match bm25() weights in SyncService+Search.
            //
            // `to_search`/`cc_search`/`bcc_search` are denormalized plain-text
            // mirrors of the JSON address arrays, populated in persistHeaders.
            // `list_id` stores the List-ID / List-Post header for mailing-list
            // filtering (`list:` operator). `prefix='2 3 4 5'` builds indexes
            // for 2..5-char prefix matches — lets typing "ant" match "anton"
            // incrementally without wildcards.
            try db.create(virtualTable: "messages_fts", ifNotExists: true, using: FTS5()) { t in
                t.synchronize(withTable: "messages")
                // `.remove` = remove_diacritics=2 — strips combining marks
                // across full Unicode range (e.g. ё→е, ü→u, café→cafe).
                t.tokenizer = .unicode61(diacritics: .remove)
                t.prefixes = [2, 3, 4, 5]
                t.column("subject")
                t.column("from_name")
                t.column("from_address")
                t.column("to_search")
                t.column("cc_search")
                t.column("bcc_search")
                t.column("list_id")
                t.column("preview")
                t.column("body_text")
            }
        }
    }

    // MARK: - Schema (canonical)
    //
    // Final shape after collapsing v1..v11:
    //   • accounts.sender_name
    //   • folders.highest_mod_sequence
    //   • messages.is_encrypted, has_attachments
    //   • pending_actions.source_uid_validity
    //   • trusted_senders without legacy `name` column
    //   • recently_moved_by_rule table
    //   • folders.unread_count maintained by triggers

    static let schemaSQL: String = """
        CREATE TABLE IF NOT EXISTS accounts (
            id                          TEXT PRIMARY KEY,
            name                        TEXT NOT NULL,
            email                       TEXT NOT NULL,
            sender_name                 TEXT,
            imap_host                   TEXT NOT NULL,
            imap_port                   INTEGER NOT NULL,
            imap_security               TEXT NOT NULL,
            smtp_host                   TEXT NOT NULL,
            smtp_port                   INTEGER NOT NULL,
            smtp_security               TEXT NOT NULL,
            auth_type                   TEXT NOT NULL,
            auth_state                  TEXT NOT NULL DEFAULT 'ok',
            is_enabled                  INTEGER NOT NULL DEFAULT 1,
            sort_order                  INTEGER NOT NULL DEFAULT 0,
            sent_folder_path            TEXT,
            drafts_folder_path          TEXT,
            trash_folder_path           TEXT,
            junk_folder_path            TEXT,
            archive_root_path           TEXT,
            archive_subdivision         TEXT NOT NULL DEFAULT 'byMonthThunderbird',
            smtp_max_attachment_size_mb INTEGER NOT NULL DEFAULT 25
        );

        CREATE TABLE IF NOT EXISTS folders (
            id                   TEXT PRIMARY KEY,
            account_id           TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            path                 TEXT NOT NULL,
            name                 TEXT NOT NULL,
            display_name         TEXT NOT NULL,
            separator            TEXT NOT NULL DEFAULT '/',
            special_use          TEXT,
            subscribed           INTEGER NOT NULL DEFAULT 1,
            uid_validity         INTEGER,
            uid_next             INTEGER,
            total_count          INTEGER NOT NULL DEFAULT 0,
            unread_count         INTEGER NOT NULL DEFAULT 0,
            highest_mod_sequence INTEGER,
            visible_limit        INTEGER NOT NULL DEFAULT 200,
            more_messages        TEXT NOT NULL DEFAULT 'unknown',
            highest_known_uid    INTEGER,
            UNIQUE(account_id, path)
        );

        CREATE TABLE IF NOT EXISTS messages (
            id                 TEXT PRIMARY KEY,
            uid                INTEGER NOT NULL,
            message_id         TEXT,
            in_reply_to        TEXT,
            "references"       TEXT NOT NULL DEFAULT '[]',
            subject            TEXT NOT NULL DEFAULT '',
            from_name          TEXT,
            from_address       TEXT NOT NULL,
            to_addresses       TEXT NOT NULL DEFAULT '[]',
            cc_addresses       TEXT NOT NULL DEFAULT '[]',
            bcc_addresses      TEXT NOT NULL DEFAULT '[]',
            reply_to_addresses TEXT NOT NULL DEFAULT '[]',
            -- Denormalized search mirrors: space-joined lowercased address lists.
            -- Populated by persistHeaders so FTS5 `synchronize` can index them.
            to_search          TEXT NOT NULL DEFAULT '',
            cc_search          TEXT NOT NULL DEFAULT '',
            bcc_search         TEXT NOT NULL DEFAULT '',
            -- Mailing-list identifier (List-ID or List-Post header).
            list_id            TEXT,
            date               REAL NOT NULL,
            preview            TEXT NOT NULL DEFAULT '',
            is_read            INTEGER NOT NULL DEFAULT 0,
            is_flagged         INTEGER NOT NULL DEFAULT 0,
            is_answered        INTEGER NOT NULL DEFAULT 0,
            is_forwarded       INTEGER NOT NULL DEFAULT 0,
            is_draft           INTEGER NOT NULL DEFAULT 0,
            is_encrypted       INTEGER NOT NULL DEFAULT 0,
            has_attachments    INTEGER NOT NULL DEFAULT 0,
            size               INTEGER NOT NULL DEFAULT 0,
            thread_id          TEXT,
            interaction_score  INTEGER NOT NULL DEFAULT 0,
            body_text          TEXT,
            body_html          TEXT,
            download_state     TEXT NOT NULL DEFAULT 'envelope',
            user_agent         TEXT,
            folder_id          TEXT NOT NULL REFERENCES folders(id) ON DELETE CASCADE,
            account_id         TEXT NOT NULL,
            UNIQUE(folder_id, uid)
        );
        CREATE INDEX IF NOT EXISTS messages_folder_date ON messages(folder_id, date DESC);
        CREATE INDEX IF NOT EXISTS messages_thread      ON messages(thread_id);
        CREATE INDEX IF NOT EXISTS messages_message_id  ON messages(message_id);

        CREATE TABLE IF NOT EXISTS attachments (
            id          TEXT PRIMARY KEY,
            part_id     TEXT NOT NULL,
            filename    TEXT NOT NULL,
            mime_type   TEXT NOT NULL,
            size        INTEGER NOT NULL DEFAULT 0,
            content_id  TEXT,
            is_inline   INTEGER NOT NULL DEFAULT 0,
            local_path  TEXT,
            message_id  TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE
        );
        CREATE INDEX IF NOT EXISTS idx_attachments_message_id ON attachments(message_id);

        CREATE TABLE IF NOT EXISTS pending_actions (
            id                  TEXT PRIMARY KEY,
            type                TEXT NOT NULL,
            account_id          TEXT NOT NULL,
            source_folder_path  TEXT,
            target_folder_path  TEXT,
            message_uid         INTEGER,
            source_uid_validity INTEGER,
            payload             BLOB,
            status              TEXT NOT NULL DEFAULT 'pending',
            attempt_count       INTEGER NOT NULL DEFAULT 0,
            last_error          TEXT,
            created_at          REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS recipient_history (
            id        TEXT PRIMARY KEY,
            email     TEXT NOT NULL UNIQUE,
            name      TEXT,
            use_count INTEGER NOT NULL DEFAULT 1,
            last_used REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS mail_rules (
            id               TEXT PRIMARY KEY,
            account_id       TEXT REFERENCES accounts(id) ON DELETE CASCADE,
            name             TEXT NOT NULL,
            is_enabled       INTEGER NOT NULL DEFAULT 1,
            conditions       TEXT NOT NULL DEFAULT '[]',
            actions          TEXT NOT NULL DEFAULT '[]',
            match_all        INTEGER NOT NULL DEFAULT 1,
            sort_order       INTEGER NOT NULL DEFAULT 0,
            -- Thunderbird-aligned trigger + scope (§6.7.1 ext).
            -- `folder_paths` is a JSON array of folder paths; [] = "all inbox folders".
            run_on_incoming  INTEGER NOT NULL DEFAULT 1,
            run_on_manual    INTEGER NOT NULL DEFAULT 1,
            folder_paths     TEXT NOT NULL DEFAULT '[]'
        );

        CREATE TABLE IF NOT EXISTS signatures (
            id         TEXT PRIMARY KEY,
            account_id TEXT NOT NULL REFERENCES accounts(id) ON DELETE CASCADE,
            name       TEXT NOT NULL,
            body       TEXT NOT NULL,
            is_html    INTEGER NOT NULL DEFAULT 0,
            is_default INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS trusted_senders (
            id         TEXT PRIMARY KEY,
            email      TEXT NOT NULL UNIQUE,
            created_at REAL NOT NULL
        );

        CREATE TABLE IF NOT EXISTS recently_moved_by_rule (
            account_id TEXT NOT NULL,
            message_id TEXT NOT NULL,
            moved_at   REAL NOT NULL,
            PRIMARY KEY (account_id, message_id)
        );

        -- Sidecar flag: message row's subject was rewritten locally by a rule
        -- (rewriteSubject action). Resync / ResilientFetch MUST NOT overwrite
        -- the subject column when a row is present here, otherwise the server
        -- copy (or stale cache) clobbers the user-intended subject. Row is
        -- removed automatically via ON DELETE CASCADE when the message is deleted.
        CREATE TABLE IF NOT EXISTS message_subject_overrides (
            message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
            edited_at  REAL NOT NULL
        );

        -- folders.unread_count is maintained by triggers (insert/delete/flag/move).
        CREATE TRIGGER IF NOT EXISTS folders_unread_on_insert
        AFTER INSERT ON messages
        WHEN NEW.is_read = 0
        BEGIN
            UPDATE folders SET unread_count = unread_count + 1 WHERE id = NEW.folder_id;
        END;

        CREATE TRIGGER IF NOT EXISTS folders_unread_on_delete
        AFTER DELETE ON messages
        WHEN OLD.is_read = 0
        BEGIN
            UPDATE folders SET unread_count = unread_count - 1 WHERE id = OLD.folder_id;
        END;

        CREATE TRIGGER IF NOT EXISTS folders_unread_on_update
        AFTER UPDATE OF is_read, folder_id ON messages
        BEGIN
            UPDATE folders SET unread_count = unread_count - 1
                WHERE id = OLD.folder_id AND OLD.is_read = 0;
            UPDATE folders SET unread_count = unread_count + 1
                WHERE id = NEW.folder_id AND NEW.is_read = 0;
        END;
        """
}
