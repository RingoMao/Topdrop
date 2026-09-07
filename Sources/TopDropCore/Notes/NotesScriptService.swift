import AppKit
import CoreServices
import Foundation
import OSLog

/// Apple Notes implementation of `NotesProvider`.
///
/// Used only inside the bundled worker. Script objects and descriptor parsing stay on
/// its main thread; the app communicates through Codable pipe messages, not shared objects.
@MainActor public final class NotesScriptService: NotesProvider {
    public static let notesBundleIdentifier = "com.apple.Notes"
    public static let defaultFolderName = "TopDrop"
    public static let defaultAutosaveDebounceMilliseconds: UInt64 = 650

    private let explicitScriptDirectory: URL?
    private var cachedNotes: [String: NotesNote] = [:]
    private var autosaveGenerations: [String: UInt64] = [:]
    private var permissionWasGranted = false
    private let logger = Logger(subsystem: "com.personal.TopDrop", category: "AppleNotes")

    /// - Parameter scriptDirectory: An optional directory containing the bundled
    ///   `Notes*.applescript` files. Packaged apps can omit it; passing
    ///   `Bundle.module.resourceURL` from the app target is also supported.
    public init(scriptDirectory: URL? = nil) {
        self.explicitScriptDirectory = scriptDirectory
    }

    public func automationPermission(promptIfNeeded: Bool) async -> NotesAutomationPermission {
        var status = rawAutomationStatus(askUserIfNeeded: promptIfNeeded)

        // AEDeterminePermissionToAutomateTarget cannot query a bundle-ID target while the
        // application is not running (it returns procNotFound). During the explicit onboarding
        // preflight, launch Notes in the background and retry so macOS can present the real TCC
        // prompt. Background checks may launch Notes without activating it, but never prompt.
        if status == OSStatus(procNotFound) {
            let launched = await Self.launchNotesWithoutActivation()
            if launched {
                for _ in 0..<200 {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    status = rawAutomationStatus(askUserIfNeeded: promptIfNeeded)
                    if status != OSStatus(procNotFound) { break }
                }
            }
        }

        let permission = mapAutomationStatus(status)
        if permission == .allowed {
            permissionWasGranted = true
        }
        logger.debug("Apple Notes automation preflight result: \(permission.rawValue, privacy: .public)")
        return permission
    }

    public func listAccounts() async throws -> [NotesAccount] {
        try requireAutomationPermission()
        let response = try execute(.listAccounts)
        let rows = response.listItems
        let accounts = try rows.map { row -> NotesAccount in
            guard row.numberOfItems >= 3 else {
                throw NotesProviderError.invalidScriptResponse(NotesScript.listAccounts.rawValue)
            }
            let id = try row.requiredString(at: 1, operation: NotesScript.listAccounts.rawValue)
            let name = try row.requiredString(at: 2, operation: NotesScript.listAccounts.rawValue)
            let upgraded = row.boolean(at: 3)
            return NotesAccount(id: id, name: name, isUpgraded: upgraded)
        }
        logger.debug("Listed \(accounts.count, privacy: .public) Apple Notes accounts")
        return accounts.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func listFolders(accountID: String) async throws -> [NotesFolder] {
        try requireAutomationPermission()
        let response = try execute(.listFolders, arguments: [.string(accountID)])
        let folders = try response.listItems.map {
            try decodeFolder($0, accountID: accountID, operation: NotesScript.listFolders.rawValue)
        }
        logger.debug("Listed \(folders.count, privacy: .public) folders in the selected Notes account")
        return folders.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    public func prepareTopDropFolder(
        accountID: String,
        folderName: String = AppleNotesProvider.defaultFolderName
    ) async throws -> NotesFolder {
        let accounts = try await listAccounts()
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw NotesProviderError.accountNotFound
        }
        guard account.isICloud else {
            throw NotesProviderError.iCloudAccountRequired
        }

        let safeName = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        let selectedName = safeName.isEmpty ? Self.defaultFolderName : safeName
        let response = try execute(
            .ensureFolder,
            arguments: [.string(accountID), .string(selectedName)]
        )
        let folder = try decodeFolder(
            response,
            accountID: accountID,
            operation: NotesScript.ensureFolder.rawValue
        )
        logger.notice("Prepared the dedicated Apple Notes folder")
        return folder
    }

    public func listNotes(accountID: String, folderID: String) async throws -> [NotesNote] {
        try await fetch(accountID: accountID, folderID: folderID).notes
    }

    public func fetch(accountID: String, folderID: String) async throws -> NotesFetchResult {
        try requireAutomationPermission()
        let response = try execute(
            .listNotes,
            arguments: [.string(accountID), .string(folderID)]
        )
        var notes: [NotesNote] = []
        var invalidRows = 0
        guard response.numberOfItems == 3, let rows = response.descriptor(at: 1) else {
            throw NotesProviderError.incompleteRead
        }
        for row in rows.listItems {
            do {
                notes.append(
                    try decodeNote(
                        row,
                        accountID: accountID,
                        folderID: folderID,
                        operation: NotesScript.listNotes.rawValue
                    ))
            } catch {
                invalidRows += 1
                logger.error("Skipped one malformed Apple Notes record during refresh")
            }
        }
        for note in notes { cachedNotes[note.id] = note }
        logger.debug("Refreshed \(notes.count, privacy: .public) Apple Notes records")
        if invalidRows > 0 {
            logger.notice("Skipped \(invalidRows, privacy: .public) malformed Apple Notes records")
        }
        return NotesFetchResult(
            notes: notes.sorted { $0.modificationDate > $1.modificationDate },
            isComplete: response.boolean(at: 3) && invalidRows == 0,
            failedNoteIDs: response.descriptor(at: 2)?.listItems.compactMap(\.stringValue) ?? [])
    }

    public func refresh(accountID: String, folderID: String) async throws -> [NotesNote] {
        try await listNotes(accountID: accountID, folderID: folderID)
    }

    public func search(query: String, accountID: String, folderID: String) async throws -> [NotesNote] {
        let notes = try await listNotes(accountID: accountID, folderID: folderID)
        let searchText = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searchText.isEmpty else { return notes }

        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return notes.filter {
            $0.title.range(of: searchText, options: options) != nil
                || $0.body.range(of: searchText, options: options) != nil
        }
    }

    public func create(
        _ draft: NotesDraft,
        accountID: String,
        folderID: String
    ) async throws -> NotesNote {
        try requireAutomationPermission()
        let html = NotesTextConverter.minimalHTML(title: draft.title, body: draft.body)
        let response = try execute(
            .createNote,
            arguments: [.string(accountID), .string(folderID), .string(html)]
        )
        let note = try decodeNote(
            response,
            accountID: accountID,
            folderID: folderID,
            operation: NotesScript.createNote.rawValue
        )
        cachedNotes[note.id] = note
        logger.notice("Created an Apple Note in the TopDrop folder")
        return note
    }

    public func save(
        _ draft: NotesDraft,
        replacing note: NotesNote
    ) async throws -> NotesSaveOutcome {
        try requireAutomationPermission()
        let remote = try fetchNote(
            noteID: note.id,
            accountID: note.accountID,
            folderID: note.folderID
        )
        cachedNotes[remote.id] = remote

        switch NotesWritePolicy.decision(
            expectedModificationDate: note.modificationDate,
            remote: remote,
            local: draft
        ) {
        case .readOnly:
            return .readOnly(remote)
        case .alreadyMatches:
            // Avoid touching Notes (and bumping its modification date) when both sides match.
            return .saved(remote)
        case let .writeTopDropDraft(remoteChanged):
            if remoteChanged {
                logger.notice("Apple Notes changed during editing; applying the authoritative TopDrop draft")
            }
        }

        // The script rechecks protection immediately before assigning the body. Modification-date
        // changes never reject this write: TopDrop is intentionally authoritative for temporary
        // notes and must not interrupt the user with version choices.
        let update = try execute(
            .updateNote,
            arguments: [
                .string(note.accountID),
                .string(note.folderID),
                .string(note.id),
                .string(NotesTextConverter.minimalHTML(title: draft.title, body: draft.body)),
            ]
        )
        let outcome = try decodeMutationResponse(
            update,
            accountID: note.accountID,
            folderID: note.folderID,
            operation: NotesScript.updateNote.rawValue
        )

        switch outcome {
        case let .saved(updated):
            cachedNotes[updated.id] = updated
            logger.notice("Updated an Apple Note using the authoritative TopDrop draft policy")
            return .saved(updated)
        case let .readOnly(latest):
            cachedNotes[latest.id] = latest
            return .readOnly(latest)
        }
    }

    /// Waits for a quiet editing interval. A newer call for the same note invalidates an older
    /// call while it is sleeping, giving callers a cancellation result instead of an old write.
    public func autosave(
        _ draft: NotesDraft,
        replacing note: NotesNote,
        debounceMilliseconds: UInt64 = AppleNotesProvider.defaultAutosaveDebounceMilliseconds
    ) async throws -> NotesSaveOutcome {
        let generation = (autosaveGenerations[note.id] ?? 0) &+ 1
        autosaveGenerations[note.id] = generation
        let cappedMilliseconds = min(debounceMilliseconds, 60_000)
        try await Task.sleep(nanoseconds: cappedMilliseconds * 1_000_000)
        try Task.checkCancellation()
        guard autosaveGenerations[note.id] == generation else {
            throw CancellationError()
        }

        defer {
            if autosaveGenerations[note.id] == generation {
                autosaveGenerations.removeValue(forKey: note.id)
            }
        }
        return try await save(draft, replacing: note)
    }

    public func delete(_ note: NotesNote) async throws -> NotesDeleteOutcome {
        try requireAutomationPermission()
        let remote = try fetchNote(
            noteID: note.id,
            accountID: note.accountID,
            folderID: note.folderID
        )
        guard !remote.isReadOnly else { return .readOnly(remote) }

        let response = try execute(
            .deleteNote,
            arguments: [
                .string(note.accountID),
                .string(note.folderID),
                .string(note.id),
            ]
        )
        let applied = response.boolean(at: 1)
        let state = response.string(at: 2) ?? ""
        if applied, state == "deleted" {
            cachedNotes.removeValue(forKey: note.id)
            logger.notice("Deleted an editable Apple Note from the TopDrop folder")
            return .deleted
        }

        guard let row = response.descriptor(at: 3) else {
            throw NotesProviderError.invalidScriptResponse(NotesScript.deleteNote.rawValue)
        }
        let latest = try decodeNote(
            row,
            accountID: note.accountID,
            folderID: note.folderID,
            operation: NotesScript.deleteNote.rawValue
        )
        cachedNotes[latest.id] = latest
        if state == "readonly" { return .readOnly(latest) }
        throw NotesProviderError.invalidScriptResponse(NotesScript.deleteNote.rawValue)
    }

    public func openInAppleNotes(_ note: NotesNote) async throws {
        try requireAutomationPermission()
        _ = try execute(
            .openNote,
            arguments: [.string(note.accountID), .string(note.folderID), .string(note.id)]
        )
        logger.debug("Opened an Apple Note in Notes")
    }

    private func fetchNote(noteID: String, accountID: String, folderID: String) throws -> NotesNote {
        let response = try execute(
            .getNote,
            arguments: [.string(accountID), .string(folderID), .string(noteID)]
        )
        return try decodeNote(
            response,
            accountID: accountID,
            folderID: folderID,
            operation: NotesScript.getNote.rawValue
        )
    }

    public func read(_ note: NotesNote) async throws -> NotesNote {
        try requireAutomationPermission()
        return try fetchNote(noteID: note.id, accountID: note.accountID, folderID: note.folderID)
    }

    private func decodeFolder(
        _ descriptor: NSAppleEventDescriptor,
        accountID: String,
        operation: String
    ) throws -> NotesFolder {
        guard descriptor.numberOfItems >= 3 else {
            throw NotesProviderError.invalidScriptResponse(operation)
        }
        return NotesFolder(
            id: try descriptor.requiredString(at: 1, operation: operation),
            accountID: accountID,
            name: try descriptor.requiredString(at: 2, operation: operation),
            isShared: descriptor.boolean(at: 3),
            path: descriptor.string(at: 4)
        )
    }

    private func decodeNote(
        _ descriptor: NSAppleEventDescriptor,
        accountID: String,
        folderID: String,
        operation: String
    ) throws -> NotesNote {
        guard descriptor.numberOfItems >= 9 else {
            throw NotesProviderError.invalidScriptResponse(operation)
        }

        guard let plaintext = descriptor.string(at: 3),
            let creationDate = descriptor.date(at: 4),
            let modificationDate = descriptor.date(at: 5)
        else { throw NotesProviderError.incompleteRead }
        let fields = NotesTextConverter.split(plaintext)
        return NotesNote(
            id: try descriptor.requiredString(at: 1, operation: operation),
            accountID: accountID,
            folderID: folderID,
            title: fields.title,
            body: fields.body,
            creationDate: creationDate,
            modificationDate: modificationDate,
            isLocked: descriptor.boolean(at: 6),
            isShared: descriptor.boolean(at: 7) || descriptor.boolean(at: 9),
            hasAttachments: descriptor.int(at: 8) > 0
        )
    }

    private enum MutationResponse {
        case saved(NotesNote)
        case readOnly(NotesNote)
    }

    private func decodeMutationResponse(
        _ response: NSAppleEventDescriptor,
        accountID: String,
        folderID: String,
        operation: String
    ) throws -> MutationResponse {
        guard response.numberOfItems >= 3,
            let row = response.descriptor(at: 3)
        else {
            throw NotesProviderError.invalidScriptResponse(operation)
        }
        let note = try decodeNote(
            row,
            accountID: accountID,
            folderID: folderID,
            operation: operation
        )
        let applied = response.boolean(at: 1)
        let state = response.string(at: 2) ?? ""
        if applied, state == "saved" { return .saved(note) }
        if state == "readonly" { return .readOnly(note) }
        throw NotesProviderError.invalidScriptResponse(operation)
    }

    private func requireAutomationPermission() throws {
        let status = rawAutomationStatus(askUserIfNeeded: false)
        switch mapAutomationStatus(status) {
        case .allowed:
            permissionWasGranted = true
        case .unavailable where status == OSStatus(procNotFound) && permissionWasGranted:
            // Notes was quit after a successful onboarding check. The actual operation may
            // launch it, and TCC has already granted this process automation access.
            break
        case .promptRequired:
            throw NotesProviderError.automationPromptRequired
        case .denied:
            throw NotesProviderError.automationDenied
        case .unavailable:
            throw NotesProviderError.notesUnavailable
        }
    }

    private func rawAutomationStatus(askUserIfNeeded: Bool) -> OSStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: Self.notesBundleIdentifier)
        guard let address = target.aeDesc else { return OSStatus(paramErr) }
        return AEDeterminePermissionToAutomateTarget(
            address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            askUserIfNeeded
        )
    }

    private func mapAutomationStatus(_ status: OSStatus) -> NotesAutomationPermission {
        switch status {
        case noErr:
            return .allowed
        case OSStatus(errAEEventWouldRequireUserConsent):
            return .promptRequired
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(procNotFound):
            return .unavailable
        default:
            return .unavailable
        }
    }

    @MainActor
    private static func launchNotesWithoutActivation() async -> Bool {
        guard
            let applicationURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: notesBundleIdentifier
            )
        else {
            return false
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = false
        return await withCheckedContinuation { continuation in
            NSWorkspace.shared.openApplication(
                at: applicationURL,
                configuration: configuration
            ) { application, error in
                continuation.resume(returning: application != nil && error == nil)
            }
        }
    }

    nonisolated private static var notesApplicationIsInstalled: Bool {
        FileManager.default.fileExists(atPath: "/System/Applications/Notes.app")
            || FileManager.default.fileExists(atPath: "/Applications/Notes.app")
    }

    private enum NotesScript: String {
        case listAccounts = "NotesListAccounts"
        case listFolders = "NotesListFolders"
        case ensureFolder = "NotesEnsureFolder"
        case listNotes = "NotesListNotes"
        case getNote = "NotesGetNote"
        case createNote = "NotesCreateNote"
        case updateNote = "NotesUpdateNote"
        case deleteNote = "NotesDeleteNote"
        case openNote = "NotesOpenNote"

        var missingObjectError: NotesProviderError {
            switch self {
            case .listFolders, .ensureFolder:
                .accountNotFound
            case .listNotes, .createNote:
                .folderNotFound
            case .getNote, .updateNote, .deleteNote, .openNote:
                .noteNotFound
            case .listAccounts:
                .notesUnavailable
            }
        }
    }

    private enum ScriptArgument {
        case string(String)
        case date(Date)

        var descriptor: NSAppleEventDescriptor {
            switch self {
            case let .string(value): NSAppleEventDescriptor(string: value)
            case let .date(value): NSAppleEventDescriptor(date: value)
            }
        }
    }

    private func execute(
        _ scriptName: NotesScript,
        arguments: [ScriptArgument] = []
    ) throws -> NSAppleEventDescriptor {
        precondition(Thread.isMainThread, "Notes scripts must run on the worker main thread")
        guard
            let scriptURL = NotesScriptLocator.url(
                named: scriptName.rawValue,
                explicitDirectory: explicitScriptDirectory
            )
        else {
            throw NotesProviderError.scriptMissing(scriptName.rawValue)
        }

        let source: String
        do {
            source = try String(contentsOf: scriptURL, encoding: .utf8)
        } catch {
            throw NotesProviderError.scriptMissing(scriptName.rawValue)
        }

        var compilationError: NSDictionary?
        guard let script = NSAppleScript(source: source) else {
            throw NotesProviderError.scriptCompilation(scriptName.rawValue)
        }
        if !script.compileAndReturnError(&compilationError) {
            let message = Self.appleScriptErrorMessage(compilationError) ?? scriptName.rawValue
            throw NotesProviderError.scriptCompilation(message)
        }

        let argumentList = NSAppleEventDescriptor.list()
        for (offset, argument) in arguments.enumerated() {
            argumentList.insert(argument.descriptor, at: offset + 1)
        }
        let event = NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
        event.setParam(argumentList, forKeyword: AEKeyword(keyDirectObject))

        var executionError: NSDictionary?
        let result = script.executeAppleEvent(event, error: &executionError)
        if executionError != nil {
            let number = Self.appleScriptErrorNumber(executionError)
            if number == Int(errAEEventNotPermitted) {
                permissionWasGranted = false
                throw NotesProviderError.automationDenied
            }
            if number == Int(errAEEventWouldRequireUserConsent) {
                throw NotesProviderError.automationPromptRequired
            }
            if number == -1700 { throw NotesProviderError.incompleteRead }
            if number == -1712 { throw NotesProviderError.resultUncertain }
            if number == -1728 {
                throw scriptName.missingObjectError
            }
            logger.error(
                "Apple Notes operation \(scriptName.rawValue, privacy: .public) failed with code \(number, privacy: .public)"
            )
            throw NotesProviderError.scriptExecution(number: number, message: "Apple Notes automation failed")
        }
        logger.debug("Apple Notes operation \(scriptName.rawValue, privacy: .public) completed")
        return result
    }

    private nonisolated static func appleScriptErrorNumber(_ dictionary: NSDictionary?) -> Int {
        if let number = dictionary?["NSAppleScriptErrorNumber"] as? NSNumber {
            return number.intValue
        }
        if let number = dictionary?["NSAppleScriptErrorNumber"] as? Int {
            return number
        }
        return 0
    }

    private nonisolated static func appleScriptErrorMessage(_ dictionary: NSDictionary?) -> String? {
        dictionary?["NSAppleScriptErrorMessage"] as? String
    }
}

private enum NotesScriptLocator {
    static func url(named name: String, explicitDirectory: URL?) -> URL? {
        let filename = "\(name).applescript"
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if let explicitDirectory {
            candidates.append(explicitDirectory.appendingPathComponent(filename))
            candidates.append(explicitDirectory.appendingPathComponent("Scripts").appendingPathComponent(filename))
        }

        func appendCandidates(from bundle: Bundle) {
            if let direct = bundle.url(forResource: name, withExtension: "applescript") {
                candidates.append(direct)
            }
            if let nested = bundle.url(
                forResource: name,
                withExtension: "applescript",
                subdirectory: "Scripts"
            ) {
                candidates.append(nested)
            }
            if let resourceURL = bundle.resourceURL {
                candidates.append(resourceURL.appendingPathComponent(filename))
                candidates.append(resourceURL.appendingPathComponent("Scripts").appendingPathComponent(filename))
            }
        }

        appendCandidates(from: .main)
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            appendCandidates(from: bundle)
        }

        // A conventionally assembled .app stores SwiftPM resource bundles in
        // Contents/Resources rather than beside the executable. Such bundles
        // are not necessarily present in Bundle.allBundles until loaded.
        if let resourceDirectory = Bundle.main.resourceURL,
            let resourceChildren = try? fileManager.contentsOfDirectory(
                at: resourceDirectory,
                includingPropertiesForKeys: nil
            )
        {
            for child in resourceChildren where child.pathExtension == "bundle" {
                if let bundle = Bundle(url: child) {
                    appendCandidates(from: bundle)
                }
                candidates.append(child.appendingPathComponent(filename))
                candidates.append(child.appendingPathComponent("Scripts").appendingPathComponent(filename))
                candidates.append(child.appendingPathComponent("Contents/Resources").appendingPathComponent(filename))
            }
        }

        // SwiftPM executable resources live in a sibling resource bundle. This also supports
        // ad-hoc app assembly where that bundle is copied beside the executable.
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent(),
            let children = try? fileManager.contentsOfDirectory(
                at: executableDirectory,
                includingPropertiesForKeys: nil
            )
        {
            for child in children where child.pathExtension == "bundle" {
                if let bundle = Bundle(url: child) {
                    appendCandidates(from: bundle)
                }
                candidates.append(child.appendingPathComponent(filename))
                candidates.append(child.appendingPathComponent("Scripts").appendingPathComponent(filename))
                candidates.append(child.appendingPathComponent("Contents/Resources").appendingPathComponent(filename))
                candidates.append(
                    child.appendingPathComponent("Contents/Resources/Scripts").appendingPathComponent(filename))
            }
        }

        return candidates.first { fileManager.isReadableFile(atPath: $0.path) }
    }
}

private extension NSAppleEventDescriptor {
    var listItems: [NSAppleEventDescriptor] {
        guard numberOfItems > 0 else { return [] }
        return (1...numberOfItems).compactMap { descriptor(at: $0) }
    }

    func descriptor(at index: Int) -> NSAppleEventDescriptor? {
        guard index > 0, index <= numberOfItems else { return nil }
        return atIndex(index)
    }

    func string(at index: Int) -> String? {
        descriptor(at: index)?.stringValue
    }

    func requiredString(at index: Int, operation: String) throws -> String {
        guard let value = string(at: index) else {
            throw NotesProviderError.invalidScriptResponse(operation)
        }
        return value
    }

    func boolean(at index: Int) -> Bool {
        descriptor(at: index)?.booleanValue ?? false
    }

    func int(at index: Int) -> Int {
        Int(descriptor(at: index)?.int32Value ?? 0)
    }

    func date(at index: Int) -> Date? {
        descriptor(at: index)?.dateValue
    }
}
