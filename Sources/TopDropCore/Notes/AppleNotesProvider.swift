import Foundation

public enum NotesWorkerOperation: String, Codable, Sendable {
    case permission, accounts, folders, prepare, fetch, read, create, save, delete, open, diagnostics
    public var isMutation: Bool { self == .prepare || self == .create || self == .save || self == .delete }
}
public struct NotesWorkerRequest: Codable, Sendable {
    public var operation: NotesWorkerOperation
    public var accountID: String = ""
    public var folderID: String = ""
    public var folderName: String = ""
    public var note: NotesNote?
    public var draft: NotesDraft?
    public var prompt = false
    public var scriptDirectory: URL?
    public init(operation: NotesWorkerOperation) { self.operation = operation }
}
public struct NotesWorkerResponse: Codable, Sendable {
    public var permission: NotesAutomationPermission?
    public var accounts: [NotesAccount]?
    public var folders: [NotesFolder]?
    public var folder: NotesFolder?
    public var fetch: NotesFetchResult?
    public var note: NotesNote?
    public var saved: NotesSaveOutcome?
    public var deleted: NotesDeleteOutcome?
    public var error: NotesProviderError?
    public var mainThread: Bool?
    public init() {}
}

public protocol NotesWorkerTransporting: Sendable {
    func perform(_ request: NotesWorkerRequest) async throws -> NotesWorkerResponse
}

/// The transport's serial queue, not actor reentrancy, owns operation serialization.
public actor AppleNotesProvider: NotesProvider {
    public static let notesBundleIdentifier = "com.apple.Notes"
    public static let defaultFolderName = "TopDrop"
    public static let defaultAutosaveDebounceMilliseconds: UInt64 = 650
    private let transport: any NotesWorkerTransporting
    private let scriptDirectory: URL?
    public init(scriptDirectory: URL? = nil, transport: any NotesWorkerTransporting = NotesWorkerTransport()) {
        self.scriptDirectory = scriptDirectory; self.transport = transport
    }
    private func call(
        _ operation: NotesWorkerOperation, account: String = "", folder: String = "", name: String = "",
        note: NotesNote? = nil, draft: NotesDraft? = nil, prompt: Bool = false
    ) async throws -> NotesWorkerResponse {
        var request = NotesWorkerRequest(operation: operation)
        request.accountID = account; request.folderID = folder; request.folderName = name
        request.note = note; request.draft = draft; request.prompt = prompt; request.scriptDirectory = scriptDirectory
        let response = try await transport.perform(request)
        if let error = response.error { throw error }
        return response
    }
    private func required<T>(_ value: T?) throws -> T {
        guard let value else { throw NotesProviderError.incompleteRead }; return value
    }
    public func automationPermission(promptIfNeeded: Bool) async -> NotesAutomationPermission {
        do { return try await call(.permission, prompt: promptIfNeeded).permission ?? .unavailable } catch {
            return .unavailable
        }
    }
    public func listAccounts() async throws -> [NotesAccount] { try required(await call(.accounts).accounts) }
    public func listFolders(accountID: String) async throws -> [NotesFolder] {
        try required(await call(.folders, account: accountID).folders)
    }
    public func prepareTopDropFolder(accountID: String, folderName: String) async throws -> NotesFolder {
        try required(await call(.prepare, account: accountID, name: folderName).folder)
    }
    public func fetch(accountID: String, folderID: String) async throws -> NotesFetchResult {
        try required(await call(.fetch, account: accountID, folder: folderID).fetch)
    }
    public func listNotes(accountID: String, folderID: String) async throws -> [NotesNote] {
        try await fetch(accountID: accountID, folderID: folderID).notes
    }
    public func refresh(accountID: String, folderID: String) async throws -> [NotesNote] {
        try await listNotes(accountID: accountID, folderID: folderID)
    }
    public func read(_ note: NotesNote) async throws -> NotesNote { try required(await call(.read, note: note).note) }
    public func search(query: String, accountID: String, folderID: String) async throws -> [NotesNote] {
        try await listNotes(accountID: accountID, folderID: folderID).filter {
            query.isEmpty || $0.plainText.localizedCaseInsensitiveContains(query)
        }
    }
    public func create(_ draft: NotesDraft, accountID: String, folderID: String) async throws -> NotesNote {
        try required(await call(.create, account: accountID, folder: folderID, draft: draft).note)
    }
    public func save(_ draft: NotesDraft, replacing note: NotesNote) async throws -> NotesSaveOutcome {
        try required(await call(.save, note: note, draft: draft).saved)
    }
    public func autosave(_ draft: NotesDraft, replacing note: NotesNote, debounceMilliseconds: UInt64) async throws
        -> NotesSaveOutcome
    {
        try await Task.sleep(for: .milliseconds(min(debounceMilliseconds, 60_000)))
        try Task.checkCancellation()
        return try await save(draft, replacing: note)
    }
    public func delete(_ note: NotesNote) async throws -> NotesDeleteOutcome {
        try required(await call(.delete, note: note).deleted)
    }
    public func openInAppleNotes(_ note: NotesNote) async throws { _ = try await call(.open, note: note) }
}
