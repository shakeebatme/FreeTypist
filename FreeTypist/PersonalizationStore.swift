import CryptoKit
import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Encrypted, local store of what the user writes, used to make completions
/// sound like them.
///
/// Everything here is treated as sensitive. Text is sealed with AES-GCM under a
/// key held in the Keychain, and vocabulary terms are addressed by HMAC rather
/// than stored in the clear — otherwise anyone with read access to the database
/// file could recover a user's names, projects and turns of phrase without the
/// key. Nothing in this file is ever logged.
actor PersonalizationStore {
    struct Snapshot: Sendable {
        var recentPhrasing: [String]
        var vocabulary: [String: Int]
    }

    struct Stats: Sendable {
        var snippets: Int
        var terms: Int
        var isEmpty: Bool { snippets == 0 && terms == 0 }
    }

    private var database: OpaquePointer?
    private var key: SymmetricKey?
    private var opened = false

    /// Bounds so the store cannot grow without limit.
    private let maxSnippets = 2_000
    private let maxSnippetLength = 600
    private let phrasingSampleSize = 6

    // MARK: - Lifecycle

    /// Overridable so tests never touch the real store.
    private let directoryOverride: URL?

    init(directoryOverride: URL? = nil) {
        self.directoryOverride = directoryOverride
    }

    private var fileURL: URL {
        if let directoryOverride {
            return directoryOverride.appendingPathComponent("personalization.sqlite")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("FreeTypist/personalization.sqlite")
    }

    private func open() -> Bool {
        if opened { return database != nil }
        opened = true

        let url = fileURL
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )

        var handle: OpaquePointer?
        guard sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        ) == SQLITE_OK else {
            sqlite3_close(handle)
            return false
        }
        database = handle

        exec("""
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS snippets (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            app TEXT NOT NULL,
            sealed BLOB NOT NULL,
            created_at REAL NOT NULL
        );
        CREATE TABLE IF NOT EXISTS vocabulary (
            term_hmac TEXT PRIMARY KEY,
            sealed BLOB NOT NULL,
            count INTEGER NOT NULL,
            last_seen REAL NOT NULL
        );
        """)

        key = KeyStore.loadOrCreate()
        restrictPermissions()
        return database != nil && key != nil
    }

    /// SQLite creates the `-wal` and `-shm` siblings itself, with default
    /// permissions. Their contents are encrypted like everything else, but there
    /// is no reason for them to be world-readable when the main file is not.
    private func restrictPermissions() {
        let url = fileURL
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path + suffix
            )
        }
    }

    private func exec(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    // MARK: - Writing

    /// Records one piece of writing. Callers are responsible for the policy
    /// checks (recording enabled, app not excluded, not a password field).
    ///
    /// `ourOwnText` is everything FreeTypist inserted into this piece of
    /// writing. It is deliberately *not* subtracted from the snippet: the
    /// snippet is what the user sent, and they read and accepted every word of
    /// it. It is subtracted from the vocabulary, which is a different claim —
    /// vocabulary drives a logit bias, so counting our own suggestions there
    /// would put a thumb on the scale for generating them again. Those counts
    /// also never decay, so the thumb would never lift.
    ///
    /// A word we suggested is skipped for this piece of writing even if the
    /// user also typed it themselves; spans are not tracked finely enough to
    /// tell. That errs toward not crediting ourselves, and a word the user
    /// really uses will be counted the next time they type it unprompted.
    func record(text: String, app: String, ourOwnText: String = "") {
        guard open(), let database, let key else { return }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12 else { return }
        let bounded = String(trimmed.suffix(maxSnippetLength))

        guard let sealed = seal(bounded, key: key) else { return }

        var statement: OpaquePointer?
        if sqlite3_prepare_v2(
            database,
            "INSERT INTO snippets (app, sealed, created_at) VALUES (?, ?, ?);",
            -1, &statement, nil
        ) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, app, -1, sqliteTransient)
            sealed.withUnsafeBytes { buffer in
                _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
            }
            sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)

        recordVocabulary(in: bounded, excluding: Self.terms(in: ourOwnText), key: key)
        trimToLimit()
        restrictPermissions()
    }

    /// Distinctive words only: names, product names, jargon. Common words add
    /// nothing to a bias that already reflects the language model.
    ///
    /// Shared by recording and by the exclusion set, so both sides of the
    /// subtraction split words the same way.
    private static func terms(in text: String) -> Set<String> {
        let split = text
            .split(whereSeparator: { !$0.isLetter && $0 != "-" && $0 != "'" })
            .map(String.init)
            .filter { $0.count >= 4 && $0.count <= 32 }
            .filter { !stopWords.contains($0.lowercased()) }
        return Set(split)
    }

    private func recordVocabulary(in text: String, excluding ours: Set<String>, key: SymmetricKey) {
        guard let database else { return }

        // Case-folded, because a term is stored under the HMAC of its lowercase
        // form: "Kubernetes" and "kubernetes" are one row, so they must also be
        // one entry on the excluded side.
        let excluded = Set(ours.map { $0.lowercased() })

        for term in Self.terms(in: text) where !excluded.contains(term.lowercased()) {
            guard let hmac = self.hmac(term.lowercased(), key: key),
                  let sealed = seal(term, key: key) else { continue }

            var statement: OpaquePointer?
            if sqlite3_prepare_v2(
                database,
                """
                INSERT INTO vocabulary (term_hmac, sealed, count, last_seen)
                VALUES (?, ?, 1, ?)
                ON CONFLICT(term_hmac) DO UPDATE SET
                    count = count + 1, last_seen = excluded.last_seen;
                """,
                -1, &statement, nil
            ) == SQLITE_OK {
                sqlite3_bind_text(statement, 1, hmac, -1, sqliteTransient)
                sealed.withUnsafeBytes { buffer in
                    _ = sqlite3_bind_blob(statement, 2, buffer.baseAddress, Int32(buffer.count), sqliteTransient)
                }
                sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
                sqlite3_step(statement)
            }
            sqlite3_finalize(statement)
        }
    }

    private func trimToLimit() {
        exec("""
        DELETE FROM snippets WHERE id NOT IN (
            SELECT id FROM snippets ORDER BY created_at DESC LIMIT \(maxSnippets)
        );
        """)
    }

    // MARK: - Reading

    /// Recent phrasing plus learned vocabulary, for the completion prompt.
    func snapshot(app: String?, vocabularyLimit: Int = 120) -> Snapshot {
        guard open(), let database, let key else {
            return Snapshot(recentPhrasing: [], vocabulary: [:])
        }

        var phrasing: [String] = []
        var statement: OpaquePointer?
        let sql = app == nil
            ? "SELECT sealed FROM snippets ORDER BY created_at DESC LIMIT ?;"
            : "SELECT sealed FROM snippets WHERE app = ? ORDER BY created_at DESC LIMIT ?;"
        if sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK {
            if let app {
                sqlite3_bind_text(statement, 1, app, -1, sqliteTransient)
                sqlite3_bind_int(statement, 2, Int32(phrasingSampleSize))
            } else {
                sqlite3_bind_int(statement, 1, Int32(phrasingSampleSize))
            }
            while sqlite3_step(statement) == SQLITE_ROW {
                if let text = openSealed(column: 0, statement: statement, key: key) {
                    phrasing.append(text)
                }
            }
        }
        sqlite3_finalize(statement)

        var vocabulary: [String: Int] = [:]
        statement = nil
        if sqlite3_prepare_v2(
            database,
            "SELECT sealed, count FROM vocabulary ORDER BY count DESC, last_seen DESC LIMIT ?;",
            -1, &statement, nil
        ) == SQLITE_OK {
            sqlite3_bind_int(statement, 1, Int32(vocabularyLimit))
            while sqlite3_step(statement) == SQLITE_ROW {
                if let term = openSealed(column: 0, statement: statement, key: key) {
                    vocabulary[term] = Int(sqlite3_column_int(statement, 1))
                }
            }
        }
        sqlite3_finalize(statement)

        return Snapshot(recentPhrasing: phrasing, vocabulary: vocabulary)
    }

    func stats() -> Stats {
        guard open(), let database else { return Stats(snippets: 0, terms: 0) }
        return Stats(snippets: count(in: "snippets", database), terms: count(in: "vocabulary", database))
    }

    private func count(in table: String, _ database: OpaquePointer) -> Int {
        var statement: OpaquePointer?
        var result = 0
        if sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM \(table);", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW {
            result = Int(sqlite3_column_int(statement, 0))
        }
        sqlite3_finalize(statement)
        return result
    }

    // MARK: - Deletion

    /// Removes every recorded byte, the database file, and the key. Deliberately
    /// thorough: a delete that leaves recoverable text behind is worse than not
    /// offering one.
    func deleteEverything() {
        if let database {
            sqlite3_exec(database, "DELETE FROM snippets; DELETE FROM vocabulary;", nil, nil, nil)
            sqlite3_close(database)
        }
        database = nil
        opened = false
        key = nil

        let url = fileURL
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }
        KeyStore.delete()
    }

    func deleteRecords(forApp app: String) {
        guard open(), let database else { return }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(database, "DELETE FROM snippets WHERE app = ?;", -1, &statement, nil) == SQLITE_OK {
            sqlite3_bind_text(statement, 1, app, -1, sqliteTransient)
            sqlite3_step(statement)
        }
        sqlite3_finalize(statement)
    }

    // MARK: - Crypto

    private func seal(_ text: String, key: SymmetricKey) -> Data? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? AES.GCM.seal(data, using: key).combined
    }

    private func openSealed(column: Int32, statement: OpaquePointer?, key: SymmetricKey) -> String? {
        guard let bytes = sqlite3_column_blob(statement, column) else { return nil }
        let length = Int(sqlite3_column_bytes(statement, column))
        guard length > 0 else { return nil }
        let data = Data(bytes: bytes, count: length)
        guard let box = try? AES.GCM.SealedBox(combined: data),
              let opened = try? AES.GCM.open(box, using: key) else { return nil }
        return String(data: opened, encoding: .utf8)
    }

    /// Keyed hash, so the index cannot be reversed without the Keychain secret.
    private func hmac(_ text: String, key: SymmetricKey) -> String? {
        guard let data = text.data(using: .utf8) else { return nil }
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: key)).base64EncodedString()
    }

    private static let stopWords: Set<String> = [
        "this", "that", "with", "have", "from", "they", "will", "would", "there",
        "their", "what", "about", "which", "when", "make", "like", "time", "just",
        "know", "take", "into", "year", "your", "some", "could", "them", "than",
        "then", "look", "only", "come", "over", "also", "back", "after", "work",
        "first", "well", "even", "want", "because", "these", "give", "most",
        "thanks", "please", "hello", "regards", "best",
    ]
}

/// The AES key, held in the Keychain rather than on disk beside the data.
private enum KeyStore {
    private static let service = "com.freetypist.app.personalization"
    private static let account = "aes-gcm-key"

    static func loadOrCreate() -> SymmetricKey? {
        if let existing = load() { return existing }
        let fresh = SymmetricKey(size: .bits256)
        return store(fresh) ? fresh : nil
    }

    private static func load() -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    private static func store(_ key: SymmetricKey) -> Bool {
        let data = key.withUnsafeBytes { Data($0) }
        let attributes: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            // Never leaves this Mac and is unavailable before first unlock.
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        SecItemDelete(attributes as CFDictionary)
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
