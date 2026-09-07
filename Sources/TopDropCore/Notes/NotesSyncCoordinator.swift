import Combine
import Foundation

/// UI selection is never used as the destination of an asynchronous operation.
@MainActor public final class NotesSyncCoordinator: ObservableObject {
    @Published public private(set) var notes: [NotesNote] = []
    @Published public private(set) var selected: NotesIdentity?
    @Published public private(set) var entries: [NotesIdentity: NotesJournalEntry] = [:]
    @Published public private(set) var unreadable: Set<NotesIdentity> = []
    @Published public var message: String?
    @Published public private(set) var isRefreshing = false
    public private(set) var accountID: String?
    public private(set) var folderID: String?
    private let provider: any NotesProvider
    private let journal: any NotesDraftPersisting
    private let debounce: Duration
    private var generation: UInt64 = 0
    private var epochs: [NotesIdentity: UInt64] = [:]
    private var revision: UInt64 = 0
    private var acknowledged: Set<NotesIdentity> = []
    private var journalRevision: UInt64 = 0
    private var persistedRevision: UInt64 = 0
    private var journalWriting = false
    private var journalWaiters: [CheckedContinuation<Void, Never>] = []
    private var journalLoaded = false
    private var journalTask: Task<Void, Never>?
    private var timers: [NotesIdentity: Task<Void, Never>] = [:]
    private var inFlight: Set<NotesIdentity> = []
    private var retryCounts: [NotesIdentity: Int] = [:]
    private var visibleTimer: Task<Void, Never>?
    private var refreshRetry: Task<Void, Never>?
    private var refreshFailures = 0
    private var stopped = false
    private var visible = false
    private static let retrySeconds = [2, 5, 15, 30, 60]

    public init(provider: any NotesProvider, journal: any NotesDraftPersisting, debounce: Duration = .milliseconds(650))
    {
        self.provider = provider; self.journal = journal; self.debounce = debounce
    }
    deinit {
        journalTask?.cancel(); visibleTimer?.cancel(); refreshRetry?.cancel()
        for timer in timers.values { timer.cancel() }
    }
    public var selectedNote: NotesNote? {
        guard let selected else { return nil }
        return entries[selected]?.base ?? notes.first { NotesIdentity($0) == selected }
    }
    public var draft: NotesDraft {
        if let selected, let entry = entries[selected] { return entry.draft }
        return selectedNote.map { NotesDraft(title: $0.title, body: $0.body) } ?? NotesDraft(title: "", body: "")
    }
    public var selectedIsReadOnly: Bool {
        guard let selected, let note = selectedNote else { return true }
        return note.isReadOnly || unreadable.contains(selected) || entries[selected]?.deleteRequested == true
    }
    public var status: String {
        guard let selected else { return "Read from Apple Notes" }
        guard let entry = entries[selected] else {
            return acknowledged.contains(selected) ? "Saved to Apple Notes" : "Read from Apple Notes"
        }
        switch entry.state {
        case .memoryOnly: return "Unsaved draft — in memory only"
        case .protectedLocally: return "Draft protected on this Mac"
        case .saving: return "Saving to Apple Notes…"
        case .retrying: return "Waiting to retry — draft retained"
        case .uncertain: return "Write not confirmed — draft retained"
        case .blocked: return "Needs attention — draft retained"
        }
    }
    public func configure(accountID: String, folderID: String) {
        guard self.accountID != accountID || self.folderID != folderID else { return }
        generation &+= 1; self.accountID = accountID; self.folderID = folderID
        selected = nil; notes = []; unreadable = []; isRefreshing = false
        refreshRetry?.cancel(); refreshRetry = nil
        showRecoveryRows()
    }
    public func restore() async {
        guard !journalLoaded else { return }
        journalLoaded = true
        do {
            for var entry in try await journal.load() {
                // A crash between submission and acknowledgement is an uncertain write.
                if entry.state == .saving { entry.state = .uncertain }
                if entries[entry.key] == nil { entries[entry.key] = entry }
                revision = max(revision, entry.revision)
            }
            showRecoveryRows()
        } catch {
            message =
                "Recovery archive could not be unlocked. It has not been overwritten; new drafts are memory-only until access is restored."
        }
    }
    private func showRecoveryRows() {
        for entry in entries.values where entry.base.accountID == accountID && entry.base.folderID == folderID {
            upsert(entry.base)
        }
    }
    public func retryRecoveryAccess() async {
        while journalWriting { await withCheckedContinuation { journalWaiters.append($0) } }
        journalLoaded = false
        await restore()
        changedJournal()
        _ = await protectDrafts()
        await refresh()
    }
    public func resumeRecovery() async {
        for snapshot in Array(entries.values) {
            let key = snapshot.key
            guard !stopped, !inFlight.contains(key), snapshot.deleteRequested != true else { continue }
            if snapshot.isNew {
                if snapshot.state != .uncertain { schedule(key, after: debounce) }
                continue
            }
            do {
                let remote = try await provider.read(snapshot.base)
                guard !stopped, !inFlight.contains(key), let current = entries[key] else { continue }
                if current.state == .uncertain {
                    if let submitted = current.submitted, let sentRevision = current.submittedRevision,
                        NotesTextConverter.matchesReadback(remote.plainText, expected: submitted.plainText)
                    {
                        acknowledge(key, revision: sentRevision, note: remote)
                    }
                } else if remote.isReadOnly {
                    entries[key]?.base = remote; entries[key]?.state = .blocked
                } else {
                    entries[key]?.base = remote; entries[key]?.state = .memoryOnly
                    schedule(key, after: debounce)
                }
            } catch {
                if entries[key]?.state != .uncertain { entries[key]?.state = .blocked }
            }
        }
        changedJournal(); _ = await protectDrafts()
    }
    public func select(_ note: NotesNote?) {
        selected = note.map(NotesIdentity.init)
        Task { [weak self] in await self?.protectDrafts() }
    }
    public func edit(title: String, body: String) {
        guard let note = selectedNote, !selectedIsReadOnly else { return }
        let key = NotesIdentity(note), text = NotesDraft(title: title, body: body)
        guard text != draft else { return }
        let first = entries[key] == nil
        revision &+= 1; epochs[key] = revision
        var entry = entries[key] ?? NotesJournalEntry(base: note, draft: text, revision: revision, state: .memoryOnly)
        entry.draft = text; entry.revision = revision
        if entry.state != .uncertain && entry.state != .blocked { entry.state = .memoryOnly }
        entries[key] = entry; changedJournal()
        journalTask?.cancel()
        journalTask = Task { [weak self] in
            if !first { do { try await Task.sleep(for: .milliseconds(250)) } catch { return } }
            await self?.protectDrafts()
        }
        schedule(key, after: debounce)
    }
    private func changedJournal() { journalRevision &+= 1 }
    @discardableResult public func protectDrafts() async -> Bool {
        while journalWriting { await withCheckedContinuation { journalWaiters.append($0) } }
        guard persistedRevision != journalRevision else { return true }
        journalWriting = true
        defer {
            journalWriting = false
            let waiters = journalWaiters; journalWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }
        do {
            repeat {
                let capturedRevision = journalRevision
                let snapshot = Array(entries.values)
                try await journal.save(snapshot)
                persistedRevision = capturedRevision
                for entry in snapshot
                where entries[entry.key]?.revision == entry.revision && entries[entry.key]?.state == .memoryOnly {
                    entries[entry.key]?.state = .protectedLocally
                }
            } while persistedRevision != journalRevision
            return true
        } catch {
            message =
                "Draft recovery could not be saved securely. Drafts remain in memory; the existing archive was preserved."
            return false
        }
    }
    private func schedule(_ key: NotesIdentity, after delay: Duration) {
        guard !stopped else { return }
        timers[key]?.cancel()
        timers[key] = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.timers[key] = nil
            await self?.save(key)
        }
    }
    public func flush() async {
        journalTask?.cancel()
        _ = await protectDrafts()
        let keys = entries.keys.sorted { $0.noteID < $1.noteID }
        for key in keys { timers[key]?.cancel(); timers[key] = nil; await save(key) }
        _ = await protectDrafts()
    }
    private func save(_ originalKey: NotesIdentity) async {
        var key = originalKey
        guard !inFlight.contains(key), var entry = entries[key],
            entry.state != .uncertain, entry.state != .blocked, entry.deleteRequested != true,
            !unreadable.contains(key)
        else { return }
        inFlight.insert(key)
        defer { inFlight.remove(key); inFlight.remove(originalKey) }
        // Revalidate revision after persistence; edits may have advanced while awaiting Keychain.
        _ = await protectDrafts()
        guard let current = entries[key] else { return }
        entry = current
        entries[key]?.state = .saving
        entries[key]?.submitted = entry.draft; entries[key]?.submittedRevision = entry.revision
        changedJournal(); _ = await protectDrafts()
        do {
            let result: NotesNote
            if entry.isNew {
                result = try await provider.create(
                    entry.draft, accountID: entry.base.accountID, folderID: entry.base.folderID)
                // Persist the returned identity before a separate verification can fail.
                let newKey = NotesIdentity(result)
                if var pending = entries.removeValue(forKey: key) {
                    pending.base = result; pending.isNew = false
                    entries[newKey] = pending
                    if selected == key { selected = newKey }
                    notes.removeAll { NotesIdentity($0) == key }
                    key = newKey; inFlight.insert(key); upsert(result)
                    changedJournal(); _ = await protectDrafts()
                }
            } else {
                switch try await provider.save(entry.draft, replacing: entry.base) {
                case let .saved(note): result = note
                case let .readOnly(remote):
                    entries[key]?.base = remote; upsert(remote)
                    entries[key]?.state = .blocked; changedJournal()
                    message = "This note is now protected in Apple Notes. Your unsaved draft was retained."
                    _ = await protectDrafts(); return
                }
            }
            // Readback is a separate request; a successful mutation response is not a durable acknowledgement.
            let verified: NotesNote
            do { verified = try await provider.read(result) } catch { throw NotesProviderError.resultUncertain }
            guard NotesTextConverter.matchesReadback(verified.plainText, expected: entry.draft.plainText) else {
                throw NotesProviderError.resultUncertain
            }
            acknowledge(key, revision: entry.revision, note: verified)
            retryCounts[key] = nil
            message = "Saved to Apple Notes. iCloud delivery is managed by Apple Notes."
        } catch {
            let error = error as? NotesProviderError
            // Unknown errors after entering a mutation are also uncertain, never blind-retried.
            switch error {
            case .automationDenied, .automationPromptRequired, .noteNotFound, .folderNotFound, .accountNotFound,
                .incompleteRead:
                entries[key]?.state = .blocked
            case .workerUnavailable, .notesUnavailable:
                entries[key]?.state = .retrying
                let count = retryCounts[key, default: 0]; retryCounts[key] = count + 1
                schedule(key, after: .seconds(Self.retrySeconds[min(count, 4)]))
            default: entries[key]?.state = .uncertain
            }
            message = error?.errorDescription ?? "Apple Notes write could not be confirmed. Your draft was retained."
            changedJournal()
        }
        _ = await protectDrafts()
        if let pending = entries[key], pending.state == .memoryOnly || pending.state == .protectedLocally {
            schedule(key, after: .zero)
        }
    }
    private func acknowledge(_ key: NotesIdentity, revision: UInt64, note: NotesNote) {
        let newKey = NotesIdentity(note)
        acknowledged.insert(newKey)
        let pending = entries[key]
        if let pending, pending.revision > revision {
            var next = pending; next.base = note; next.isNew = false
            next.state = .memoryOnly; next.submitted = nil; next.submittedRevision = nil
            entries.removeValue(forKey: key); entries[newKey] = next
            if newKey != key { schedule(newKey, after: .zero) }
        } else {
            entries.removeValue(forKey: key)
        }
        if selected == key { selected = newKey }
        if newKey != key { notes.removeAll { NotesIdentity($0) == key } }
        epochs[newKey] = self.revision &+ 1; self.revision &+= 1
        upsert(note); changedJournal()
    }
    private func upsert(_ note: NotesNote) {
        guard note.accountID == accountID && note.folderID == folderID else { return }
        if let i = notes.firstIndex(where: { NotesIdentity($0) == NotesIdentity(note) }) {
            notes[i] = note
        } else {
            notes.append(note)
        }
        notes.sort { $0.modificationDate > $1.modificationDate }
    }
    public func refresh() async {
        guard !stopped, !isRefreshing, let accountID, let folderID else { return }
        let token = generation, startEpochs = epochs
        isRefreshing = true
        defer { if generation == token { isRefreshing = false } }
        do {
            let result = try await provider.fetch(accountID: accountID, folderID: folderID)
            guard generation == token, !stopped else { return }
            for remote in result.notes {
                let key = NotesIdentity(remote)
                guard epochs[key] == startEpochs[key] else { continue }
                unreadable.remove(key)
                if let entry = entries[key] {
                    if entry.deleteRequested == true { continue }
                    if entry.state == .uncertain, !entry.isNew,
                        let submitted = entry.submitted, let submittedRevision = entry.submittedRevision,
                        NotesTextConverter.matchesReadback(remote.plainText, expected: submitted.plainText)
                    {
                        acknowledge(key, revision: submittedRevision, note: remote)
                    } else if entry.state != .uncertain && !entry.isNew && !inFlight.contains(key) {
                        if remote.isReadOnly {
                            entries[key]?.base = remote; entries[key]?.state = .blocked
                        } else {
                            entries[key]?.state = .protectedLocally; schedule(key, after: debounce)
                        }
                    }
                } else {
                    upsert(remote)
                }
            }
            for id in result.failedNoteIDs {
                if let note = notes.first(where: { $0.id == id }) { unreadable.insert(NotesIdentity(note)) }
            }
            let fetched = Set(result.notes.map(NotesIdentity.init))
            if result.isComplete {
                for old in notes where !fetched.contains(NotesIdentity(old)) {
                    let key = NotesIdentity(old)
                    guard epochs[key] == startEpochs[key], entries[key]?.isNew != true else { continue }
                    do {
                        let found = try await provider.read(old)
                        guard generation == token else { return }
                        if entries[key] == nil && epochs[key] == startEpochs[key] { upsert(found) }
                    } catch {
                        guard generation == token, epochs[key] == startEpochs[key] else { continue }
                        if error as? NotesProviderError == .noteNotFound {
                            if entries[key]?.deleteRequested == true {
                                entries.removeValue(forKey: key); notes.removeAll { NotesIdentity($0) == key }
                                if selected == key { selected = nil }
                            } else if entries[key] != nil {
                                entries[key]?.state = .blocked
                            } else {
                                notes.removeAll { NotesIdentity($0) == key }; if selected == key { selected = nil }
                            }
                        } else {
                            unreadable.insert(key)
                        }
                    }
                }
            } else {
                for old in notes where !fetched.contains(NotesIdentity(old)) { unreadable.insert(NotesIdentity(old)) }
            }
            changedJournal(); _ = await protectDrafts()
            if result.isComplete { refreshFailures = 0 }
            if !result.isComplete {
                message = "Some notes could not be read. Previous records and folder selection were preserved.";
                scheduleRefreshRetry()
            }
        } catch {
            guard generation == token else { return }
            message =
                (error as? LocalizedError)?.errorDescription
                ?? "Apple Notes could not be refreshed. Previous records were retained."
            if error as? NotesProviderError != .automationDenied
                && error as? NotesProviderError != .automationPromptRequired
            {
                scheduleRefreshRetry()
            }
        }
    }
    private func scheduleRefreshRetry() {
        guard visible || !entries.isEmpty else { return }
        let delay = Self.retrySeconds[min(refreshFailures, 4)]; refreshFailures += 1
        refreshRetry?.cancel()
        refreshRetry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.refresh()
        }
    }
    public func setVisible(_ visible: Bool) {
        self.visible = visible; visibleTimer?.cancel(); visibleTimer = nil
        guard visible, !stopped else { if entries.isEmpty { refreshRetry?.cancel() }; return }
        visibleTimer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                do { try await Task.sleep(for: .seconds(15)) } catch { return }
            }
        }
    }
    public func create() {
        guard let accountID, let folderID else { return }
        let date = Date()
        let base = NotesNote(
            id: "local:\(UUID())", accountID: accountID, folderID: folderID,
            title: "New Note", body: "", creationDate: date, modificationDate: date,
            isLocked: false, isShared: false, hasAttachments: false)
        revision &+= 1
        var entry = NotesJournalEntry(
            base: base, draft: NotesDraft(title: base.title, body: base.body), revision: revision, state: .memoryOnly)
        entry.isNew = true; entries[entry.key] = entry; changedJournal()
        upsert(base); selected = entry.key
        Task { [weak self] in await self?.protectDrafts() }
        schedule(entry.key, after: debounce)
    }
    public func deleteSelected() async {
        guard let note = selectedNote else { return }
        let key = NotesIdentity(note)
        guard !inFlight.contains(key), entries[key]?.state != .uncertain else {
            message = "Wait for the outstanding write to be confirmed before deleting."; return
        }
        timers[key]?.cancel(); timers[key] = nil
        inFlight.insert(key); defer { inFlight.remove(key) }
        do {
            if entries[key]?.isNew != true {
                revision &+= 1
                var deletion =
                    entries[key]
                    ?? NotesJournalEntry(
                        base: note, draft: NotesDraft(title: note.title, body: note.body), revision: revision,
                        state: .saving)
                deletion.deleteRequested = true; deletion.state = .saving
                entries[key] = deletion; changedJournal(); _ = await protectDrafts()
                let outcome = try await provider.delete(note)
                guard outcome == .deleted else {
                    entries[key]?.deleteRequested = false; entries[key]?.state = .blocked
                    changedJournal(); _ = await protectDrafts()
                    message = "Protected note cannot be deleted. Draft retained."; return
                }
            }
            entries.removeValue(forKey: key); notes.removeAll { NotesIdentity($0) == key }
            if selected == key { selected = nil }
            revision &+= 1; epochs[key] = revision; changedJournal(); _ = await protectDrafts()
        } catch {
            entries[key]?.state = .uncertain; changedJournal(); _ = await protectDrafts()
            message = "Deletion was not confirmed. Draft retained; refresh before trying again."
        }
    }
    public func openSelected() async {
        guard let note = selectedNote else { return }
        let key = NotesIdentity(note)
        await save(key)
        guard !note.id.hasPrefix("local:") else {
            message = "Save this new draft before opening it in Apple Notes."; return
        }
        do { try await provider.openInAppleNotes(note) } catch {
            message = "Could not open the selected note in Apple Notes."
        }
    }
    public func retrySelected() async {
        guard let key = selected, let entry = entries[key] else { await refresh(); return }
        if entry.state == .uncertain || entry.deleteRequested == true { await refresh(); return }
        entries[key]?.state = .memoryOnly; unreadable.remove(key); await save(key)
    }
    /// Explicit recovery action only; never silently recreates a remotely deleted note.
    public func saveSelectedAsNew() {
        let text = draft
        create(); edit(title: text.title, body: text.body)
    }
    public func stop() {
        stopped = true; generation &+= 1; visibleTimer?.cancel(); refreshRetry?.cancel(); journalTask?.cancel()
        for timer in timers.values { timer.cancel() }; timers.removeAll()
    }
}
