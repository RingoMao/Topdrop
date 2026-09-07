import Foundation

/// The result of checking whether TopDrop may automate Apple Notes.
public enum NotesAutomationPermission: String, Codable, Sendable, Equatable {
    /// Apple Events can be sent to Notes.
    case allowed
    /// Access has not been decided. Calling the preflight with prompting enabled can show the system prompt.
    case promptRequired
    /// The user has denied access in System Settings.
    case denied
    /// Notes is unavailable or the permission state could not be determined.
    case unavailable
}

/// An account advertised by Apple Notes' public scripting interface.
public struct NotesAccount: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let isICloud: Bool
    public let isUpgraded: Bool

    public init(id: String, name: String, isICloud: Bool? = nil, isUpgraded: Bool) {
        self.id = id
        self.name = name
        // Notes does not expose an account service type through AppleScript. Its iCloud
        // account is consistently branded "iCloud", including on localized systems.
        self.isICloud = isICloud ?? name.localizedCaseInsensitiveContains("icloud")
        self.isUpgraded = isUpgraded
    }
}

/// A folder advertised by Apple Notes' public scripting interface.
public struct NotesFolder: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let accountID: String
    public let name: String
    public let isShared: Bool
    public var path: String?

    public init(id: String, accountID: String, name: String, isShared: Bool, path: String? = nil) {
        self.id = id
        self.accountID = accountID
        self.name = name
        self.isShared = isShared
        self.path = path
    }
}

/// Resolves every folder that belongs to a configured TopDrop lineage. Older
/// builds could leave more than one same-named folder after an iCloud ID
/// refresh. Reading all same-named folders preserves access to those notes
/// without copying or moving anything in Apple Notes.
public enum NotesFolderCompatibilityResolver {
    public static func folderIDs(
        configuredFolderID: String,
        configuredFolderName: String,
        availableFolders: [NotesFolder]
    ) -> [String] {
        let normalizedName = configuredFolderName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        var orderedIDs: [String] = [configuredFolderID]
        for folder in availableFolders
        where
            !normalizedName.isEmpty
            && folder.name.compare(
                normalizedName,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) == .orderedSame
        {
            if !orderedIDs.contains(folder.id) {
                orderedIDs.append(folder.id)
            }
        }
        return orderedIDs
    }
}

/// A plain-text Apple Note. TopDrop never persists `title` or `body` to its metadata store.
public struct NotesNote: Identifiable, Codable, Sendable, Hashable {
    public let id: String
    public let accountID: String
    public let folderID: String
    public var title: String
    public var body: String
    public let creationDate: Date
    public let modificationDate: Date
    public let isLocked: Bool
    public let isShared: Bool
    public let hasAttachments: Bool

    public init(
        id: String,
        accountID: String,
        folderID: String,
        title: String,
        body: String,
        creationDate: Date,
        modificationDate: Date,
        isLocked: Bool,
        isShared: Bool,
        hasAttachments: Bool
    ) {
        self.id = id
        self.accountID = accountID
        self.folderID = folderID
        self.title = title
        self.body = body
        self.creationDate = creationDate
        self.modificationDate = modificationDate
        self.isLocked = isLocked
        self.isShared = isShared
        self.hasAttachments = hasAttachments
    }

    public var isReadOnly: Bool {
        isLocked || isShared || hasAttachments
    }

    public var readOnlyReasons: [NotesReadOnlyReason] {
        var reasons: [NotesReadOnlyReason] = []
        if isLocked { reasons.append(.locked) }
        if isShared { reasons.append(.shared) }
        if hasAttachments { reasons.append(.containsAttachments) }
        return reasons
    }

    public var plainText: String {
        NotesTextConverter.join(title: title, body: body)
    }
}

public enum NotesReadOnlyReason: String, Codable, Sendable, CaseIterable, Hashable {
    case locked
    case shared
    case containsAttachments
}

/// User-authored plain text waiting to be created or saved.
public struct NotesDraft: Codable, Sendable, Hashable {
    public var title: String
    public var body: String

    public init(title: String, body: String) {
        self.title = title
        self.body = body
    }

    public var plainText: String {
        NotesTextConverter.join(title: title, body: body)
    }
}

public enum NotesSaveOutcome: Codable, Sendable, Equatable {
    case saved(NotesNote)
    case readOnly(NotesNote)
}

public enum NotesDeleteOutcome: Codable, Sendable, Equatable {
    case deleted
    case readOnly(NotesNote)
}

public enum NotesProviderError: Error, Codable, Sendable, Equatable {
    case resultUncertain
    case workerUnavailable
    case incompleteRead
    case automationPromptRequired
    case automationDenied
    case notesUnavailable
    case iCloudAccountRequired
    case accountNotFound
    case folderNotFound
    case noteNotFound
    case scriptMissing(String)
    case scriptCompilation(String)
    case scriptExecution(number: Int, message: String)
    case invalidScriptResponse(String)
}

extension NotesProviderError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .resultUncertain:
            "Apple Notes may have received this change. Its result is not yet confirmed; automatic writes are paused."
        case .workerUnavailable:
            "The bundled Notes worker could not start. Reinstall the complete TopDrop app."
        case .incompleteRead:
            "Apple Notes could not return a complete record. The last valid content has been preserved."
        case .automationPromptRequired:
            "TopDrop needs permission to control Apple Notes."
        case .automationDenied:
            "Apple Notes automation is denied. Enable TopDrop under System Settings > Privacy & Security > Automation."
        case .notesUnavailable:
            "Apple Notes is unavailable."
        case .iCloudAccountRequired:
            "Select the iCloud account in Apple Notes."
        case .accountNotFound:
            "The selected Apple Notes account no longer exists."
        case .folderNotFound:
            "The selected TopDrop folder no longer exists."
        case .noteNotFound:
            "The Apple Note no longer exists."
        case let .scriptMissing(name):
            "The bundled Apple Notes script \(name) is missing."
        case let .scriptCompilation(message):
            "A bundled Apple Notes script could not be compiled: \(message)"
        case let .scriptExecution(number, message):
            "Apple Notes automation failed (\(number)): \(message)"
        case let .invalidScriptResponse(operation):
            "Apple Notes returned an invalid response for \(operation)."
        }
    }
}

/// The internal boundary used by the Notes column and onboarding UI.
///
/// Apple Notes is the durable source of truth. While an editable note is open, TopDrop's
/// in-memory draft is authoritative for text writes; all CRUD still goes through Apple Events.
public protocol NotesProvider: Sendable {
    func fetch(accountID: String, folderID: String) async throws -> NotesFetchResult
    func read(_ note: NotesNote) async throws -> NotesNote
    func automationPermission(promptIfNeeded: Bool) async -> NotesAutomationPermission
    func listAccounts() async throws -> [NotesAccount]
    func listFolders(accountID: String) async throws -> [NotesFolder]
    func prepareTopDropFolder(accountID: String, folderName: String) async throws -> NotesFolder
    func listNotes(accountID: String, folderID: String) async throws -> [NotesNote]
    func refresh(accountID: String, folderID: String) async throws -> [NotesNote]
    func search(query: String, accountID: String, folderID: String) async throws -> [NotesNote]
    func create(_ draft: NotesDraft, accountID: String, folderID: String) async throws -> NotesNote
    func save(_ draft: NotesDraft, replacing note: NotesNote) async throws -> NotesSaveOutcome
    func autosave(
        _ draft: NotesDraft,
        replacing note: NotesNote,
        debounceMilliseconds: UInt64
    ) async throws -> NotesSaveOutcome
    func delete(_ note: NotesNote) async throws -> NotesDeleteOutcome
    func openInAppleNotes(_ note: NotesNote) async throws
}

public extension NotesProvider {
    func fetch(accountID: String, folderID: String) async throws -> NotesFetchResult {
        NotesFetchResult(notes: try await refresh(accountID: accountID, folderID: folderID), isComplete: true)
    }

    func read(_ note: NotesNote) async throws -> NotesNote {
        let result = try await fetch(accountID: note.accountID, folderID: note.folderID)
        guard let found = result.notes.first(where: { $0.id == note.id }) else {
            throw result.isComplete ? NotesProviderError.noteNotFound : NotesProviderError.incompleteRead
        }
        return found
    }
    func automationPermission() async -> NotesAutomationPermission {
        await automationPermission(promptIfNeeded: false)
    }

    func requestAutomationPermission() async -> NotesAutomationPermission {
        await automationPermission(promptIfNeeded: true)
    }

    func prepareTopDropFolder(accountID: String) async throws -> NotesFolder {
        try await prepareTopDropFolder(
            accountID: accountID,
            folderName: AppleNotesProvider.defaultFolderName
        )
    }

    func autosave(_ draft: NotesDraft, replacing note: NotesNote) async throws -> NotesSaveOutcome {
        try await autosave(
            draft,
            replacing: note,
            debounceMilliseconds: AppleNotesProvider.defaultAutosaveDebounceMilliseconds
        )
    }
}
