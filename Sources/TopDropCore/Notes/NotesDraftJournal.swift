import CryptoKit
import Foundation

public struct NotesFetchResult: Codable, Sendable {
    public var notes: [NotesNote]
    public var isComplete: Bool
    public var failedNoteIDs: [String]
    public init(notes: [NotesNote], isComplete: Bool, failedNoteIDs: [String] = []) {
        self.notes = notes; self.isComplete = isComplete; self.failedNoteIDs = failedNoteIDs
    }
}

public struct NotesIdentity: Codable, Hashable, Sendable {
    public let accountID: String
    public let noteID: String
    public init(_ note: NotesNote) { accountID = note.accountID; noteID = note.id }
}

public enum NotesDraftState: String, Codable, Sendable {
    case memoryOnly, protectedLocally, saving, retrying, uncertain, blocked
}

public struct NotesJournalEntry: Codable, Sendable {
    public var base: NotesNote
    public var draft: NotesDraft
    public var revision: UInt64
    public var state: NotesDraftState
    /// The exact submitted snapshot is retained across an uncertain write.
    public var submitted: NotesDraft?
    public var submittedRevision: UInt64?
    public var isNew: Bool = false
    public var deleteRequested: Bool?
    public var key: NotesIdentity { NotesIdentity(base) }
    public init(base: NotesNote, draft: NotesDraft, revision: UInt64, state: NotesDraftState) {
        self.base = base; self.draft = draft; self.revision = revision; self.state = state
    }
}

public protocol NotesDraftPersisting: Sendable {
    func load() async throws -> [NotesJournalEntry]
    func save(_ entries: [NotesJournalEntry]) async throws
}

public actor MemoryNotesDraftJournal: NotesDraftPersisting {
    private var entries: [NotesJournalEntry] = []
    public init() {}
    public func load() -> [NotesJournalEntry] { entries }
    public func save(_ entries: [NotesJournalEntry]) { self.entries = entries }
}

/// Only unacknowledged drafts, never a mirror of the Apple Notes library.
public actor NotesDraftJournal: NotesDraftPersisting {
    private struct Archive: Codable { var version = 1; var entries: [NotesJournalEntry] }
    private let url: URL
    private let keyProvider: any ClipboardEncryptionKeyProviding
    private var loadFailed = false
    private let header = Data("TOPDROP-NOTES-DRAFTS-v1\0".utf8)
    public init(
        url: URL? = nil,
        keyProvider: any ClipboardEncryptionKeyProviding = KeychainClipboardKeyProvider(
            service: "com.personal.TopDrop.notes", account: "draft-key-v1")
    ) {
        self.url =
            url
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TopDrop/Notes/pending-drafts.enc")
        self.keyProvider = keyProvider
    }
    public func load() async throws -> [NotesJournalEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { loadFailed = false; return [] }
        do {
            let data = try Data(contentsOf: url)
            guard data.starts(with: header) else { throw NotesProviderError.incompleteRead }
            let key = try await keyProvider.encryptionKey()
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(header.count))
            let archive = try JSONDecoder().decode(Archive.self, from: AES.GCM.open(box, using: key))
            guard archive.version == 1 else { throw NotesProviderError.incompleteRead }
            loadFailed = false
            return archive.entries
        } catch { loadFailed = true; throw error }
    }
    public func save(_ entries: [NotesJournalEntry]) async throws {
        guard !loadFailed else { throw NotesProviderError.incompleteRead }
        do {
            let data = try JSONEncoder().encode(Archive(entries: entries))
            let key = try await keyProvider.encryptionKey()
            guard let encrypted = try AES.GCM.seal(data, using: key).combined else {
                throw NotesProviderError.incompleteRead
            }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // Set permissions on a sibling temporary file BEFORE its atomic replacement.
            let temporary = directory.appendingPathComponent(UUID().uuidString)
            guard
                FileManager.default.createFile(
                    atPath: temporary.path, contents: header + encrypted, attributes: [.posixPermissions: 0o600])
            else { throw CocoaError(.fileWriteUnknown) }
            defer { try? FileManager.default.removeItem(at: temporary) }
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: url)
            }
        } catch {
            // Do not repeatedly request Keychain access on every keystroke after denial.
            loadFailed = true
            throw error
        }
    }
}
