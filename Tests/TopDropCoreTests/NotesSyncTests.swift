import Foundation
import CryptoKit
import AppKit
import TopDropCore

actor AuditNotesProvider: NotesProvider {
    var records = [sample("A"), sample("B")]
    var gate: CheckedContinuation<Void, Never>?
    var block = false
    var partial = false
    var saveGate: CheckedContinuation<Void, Never>?
    var blockSave = false
    var saveError: NotesProviderError?
    var readError: NotesProviderError?
    var commitThenThrow = false
    var createCount = 0
    var writes: [(String, NotesDraft)] = []
    static func sample(_ id: String) -> NotesNote {
        NotesNote(
            id: id, accountID: "account", folderID: "folder", title: id,
            body: "original", creationDate: .distantPast, modificationDate: Date(),
            isLocked: false, isShared: false, hasAttachments: false)
    }
    func arm() { block = true }
    func waiting() -> Bool { gate != nil }
    func release() { gate?.resume(); gate = nil }
    func setPartial() { partial = true }
    func armSave() { blockSave = true }
    func saving() -> Bool { saveGate != nil }
    func releaseSave() { saveGate?.resume(); saveGate = nil }
    func failSave(_ error: NotesProviderError, commit: Bool = false) { saveError = error; commitThenThrow = commit }
    func failRead(_ error: NotesProviderError?) { readError = error }
    func clearFailures() { saveError = nil; readError = nil }
    func savedCount() -> Int { writes.count }
    func creations() -> Int { createCount }
    func removeA() { records.removeAll { $0.id == "A" } }
    func protectA() {
        let note = records.first { $0.id == "A" }!
        records.removeAll { $0.id == "A" }
        records.append(
            NotesNote(
                id: note.id, accountID: note.accountID, folderID: note.folderID,
                title: note.title, body: note.body, creationDate: note.creationDate,
                modificationDate: note.modificationDate, isLocked: true,
                isShared: false, hasAttachments: false))
    }
    func lastWrite() -> (String, NotesDraft)? { writes.last }
    func automationPermission(promptIfNeeded: Bool) async -> NotesAutomationPermission { .allowed }
    func listAccounts() async throws -> [NotesAccount] { [] }
    func listFolders(accountID: String) async throws -> [NotesFolder] { [] }
    func prepareTopDropFolder(accountID: String, folderName: String) async throws -> NotesFolder {
        NotesFolder(id: "folder", accountID: accountID, name: folderName, isShared: false)
    }
    func listNotes(accountID: String, folderID: String) async throws -> [NotesNote] { records }
    func refresh(accountID: String, folderID: String) async throws -> [NotesNote] { records }
    func fetch(accountID: String, folderID: String) async throws -> NotesFetchResult {
        let snapshot = records
        if block { block = false; await withCheckedContinuation { gate = $0 } }
        return NotesFetchResult(notes: partial ? [] : snapshot, isComplete: !partial)
    }
    func read(_ note: NotesNote) async throws -> NotesNote {
        if let readError { throw readError }
        guard let found = records.first(where: { $0.id == note.id }) else { throw NotesProviderError.noteNotFound }
        return found
    }
    func search(query: String, accountID: String, folderID: String) async throws -> [NotesNote] { records }
    func create(_ draft: NotesDraft, accountID: String, folderID: String) async throws -> NotesNote {
        createCount += 1
        var result = Self.sample("new"); result.title = draft.title; result.body = draft.body
        records.append(result)
        if let saveError { throw saveError }
        return result
    }
    func save(_ draft: NotesDraft, replacing note: NotesNote) async throws -> NotesSaveOutcome {
        if let remote = records.first(where: { $0.id == note.id }), remote.isReadOnly { return .readOnly(remote) }
        if blockSave { blockSave = false; await withCheckedContinuation { saveGate = $0 } }
        if let saveError, !commitThenThrow { throw saveError }
        var updated = note; updated.title = draft.title; updated.body = draft.body
        writes.append((note.id, draft))
        if let i = records.firstIndex(where: { $0.id == note.id }) { records[i] = updated }
        if let saveError { throw saveError }
        return .saved(updated)
    }
    func autosave(_ draft: NotesDraft, replacing note: NotesNote, debounceMilliseconds: UInt64) async throws
        -> NotesSaveOutcome
    {
        try await save(draft, replacing: note)
    }
    func delete(_ note: NotesNote) async throws -> NotesDeleteOutcome { .deleted }
    func openInAppleNotes(_ note: NotesNote) async throws {}
}

let notesSyncTests: [UnitTest] = [
    UnitTest("Notes becoming protected keeps draft and disables editing") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal(), debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder"); await sync.refresh()
        sync.select(sync.notes.first { $0.id == "A" }); sync.edit(title: "A", body: "keep my draft")
        await p.protectA(); await sync.flush()
        try expectEqual(sync.draft.body, "keep my draft")
        try expect(sync.selectedIsReadOnly)
        let writes = await p.savedCount(); try expectEqual(writes, 0)
        sync.stop()
    },
    UnitTest("Notes refresh preserves typing that began during await") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal(), debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder")
        await sync.refresh(); sync.select(sync.notes.first { $0.id == "A" })
        await p.arm(); let task = Task { await sync.refresh() }
        while !(await p.waiting()) { await Task.yield() }
        sync.edit(title: "A", body: "new typing")
        await p.release(); await task.value
        try expectEqual(sync.draft.body, "new typing")
        sync.stop()
    },
    UnitTest("Notes refresh cannot bind B's draft to A") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal(), debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder")
        await sync.refresh(); sync.select(sync.notes.first { $0.id == "A" })
        sync.edit(title: "A", body: "A edited")
        await p.arm(); let task = Task { await sync.refresh() }
        while !(await p.waiting()) { await Task.yield() }
        sync.select(sync.notes.first { $0.id == "B" })
        await p.release(); await task.value
        sync.edit(title: "B", body: "B edited"); await sync.flush()
        let last = await p.lastWrite()
        try expectEqual(last?.0, "B")
        try expectEqual(last?.1.body, "B edited")
        sync.stop()
    },
    UnitTest("Notes navigation retains independent latest drafts") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal(), debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder")
        await sync.refresh(); let a = sync.notes.first { $0.id == "A" }!
        sync.select(a); sync.edit(title: "A", body: "first")
        sync.edit(title: "A", body: "latest")
        sync.select(sync.notes.first { $0.id == "B" }); sync.select(a)
        try expectEqual(sync.draft.body, "latest")
        await sync.flush(); let last = await p.lastWrite()
        try expectEqual(last?.1.body, "latest")
        sync.stop()
    },
    UnitTest("Notes partial refresh preserves list and folder binding") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal())
        sync.configure(accountID: "account", folderID: "folder")
        await sync.refresh(); await p.setPartial(); await sync.refresh()
        try expectEqual(sync.notes.count, 2)
        try expectEqual(sync.folderID, "folder")
        try expect(sync.message != nil)
        sync.stop()
    },
    UnitTest("Notes save acknowledgement cannot remove a newer draft") { @MainActor in
        let p = AuditNotesProvider(), journal = MemoryNotesDraftJournal()
        let sync = NotesSyncCoordinator(provider: p, journal: journal, debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder"); await sync.refresh()
        sync.select(sync.notes.first { $0.id == "A" }); sync.edit(title: "A", body: "first")
        await p.armSave(); let flush = Task { await sync.flush() }
        while !(await p.saving()) { await Task.yield() }
        sync.edit(title: "A", body: "latest")
        sync.select(sync.notes.first { $0.id == "B" })
        await p.releaseSave(); await flush.value
        sync.select(sync.notes.first { $0.id == "A" })
        try expectEqual(sync.draft.body, "latest")
        await sync.flush()
        let records = await p.writes
        try expect(!records.contains { $0.0 == "B" && $0.1.title == "A" })
        sync.stop()
    },
    UnitTest("Notes ambiguous update reconciles without duplicate mutation") { @MainActor in
        let p = AuditNotesProvider(), journal = MemoryNotesDraftJournal()
        let sync = NotesSyncCoordinator(provider: p, journal: journal, debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder"); await sync.refresh()
        sync.select(sync.notes.first { $0.id == "A" }); sync.edit(title: "A", body: "sent")
        await p.failSave(.resultUncertain, commit: true); await sync.flush()
        try expectEqual(sync.entries.values.first?.state, .uncertain)
        await sync.flush(); let count = await p.savedCount(); try expectEqual(count, 1)
        await sync.refresh()
        try expect(sync.entries.isEmpty)
        let retained = await journal.load(); try expect(retained.isEmpty)
        sync.stop()
    },
    UnitTest("Notes ambiguous creation is never retried or matched by title") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal(), debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder")
        await p.failSave(.resultUncertain); sync.create(); await sync.flush(); await sync.refresh(); await sync.flush()
        let count = await p.creations(); try expectEqual(count, 1)
        try expectEqual(sync.entries.values.first?.state, .uncertain)
        sync.stop()
    },
    UnitTest("Notes known created ID survives readback failure") { @MainActor in
        let p = AuditNotesProvider(), journal = MemoryNotesDraftJournal()
        let sync = NotesSyncCoordinator(provider: p, journal: journal, debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder")
        sync.create(); await p.failRead(.incompleteRead); await sync.flush()
        let pending = await journal.load()
        try expectEqual(pending.first?.base.id, "new")
        try expectEqual(pending.first?.isNew, false)
        await p.clearFailures(); await sync.refresh(); try expect(sync.entries.isEmpty)
        let count = await p.creations(); try expectEqual(count, 1)
        sync.stop()
    },
    UnitTest("Notes pending draft survives process restart and remote deletion") { @MainActor in
        let p = AuditNotesProvider(), journal = MemoryNotesDraftJournal()
        let sync = NotesSyncCoordinator(provider: p, journal: journal, debounce: .seconds(60))
        sync.configure(accountID: "account", folderID: "folder"); await sync.refresh()
        sync.select(sync.notes.first { $0.id == "A" }); sync.edit(title: "A", body: "recover me")
        await sync.protectDrafts(); sync.stop(); await p.removeA()
        let restored = NotesSyncCoordinator(provider: p, journal: journal, debounce: .seconds(60))
        restored.configure(accountID: "account", folderID: "folder"); await restored.restore(); await restored.refresh()
        try expectEqual(restored.entries.values.first?.draft.body, "recover me")
        try expectEqual(restored.entries.values.first?.state, .blocked)
        let count = await p.creations(); try expectEqual(count, 0)
        restored.stop()
    },
    UnitTest("Notes old-folder refresh cannot replace a new folder") { @MainActor in
        let p = AuditNotesProvider()
        let sync = NotesSyncCoordinator(provider: p, journal: MemoryNotesDraftJournal())
        sync.configure(accountID: "account", folderID: "folder")
        await p.arm(); let refresh = Task { await sync.refresh() }
        while !(await p.waiting()) { await Task.yield() }
        sync.configure(accountID: "account", folderID: "other")
        await p.release(); await refresh.value
        try expectEqual(sync.folderID, "other"); try expect(sync.notes.isEmpty)
        sync.stop()
    },
    UnitTest("Notes readback comparison never trims user whitespace") {
        try expect(NotesTextConverter.matchesReadback("A\nbody\n", expected: "A\nbody"))
        try expect(!NotesTextConverter.matchesReadback("A\nbody", expected: "A\nbody\n"))
        try expect(!NotesTextConverter.matchesReadback("A\nbody ", expected: "A\nbody"))
        let html = NotesTextConverter.minimalHTML(title: "中文 👩🏽‍💻", body: "  A\tB  \n\n<&>")
        try expect(html.contains("  A")); try expect(html.contains("&#9;"))
        try expect(html.contains("&lt;&amp;&gt;"))
    },
    UnitTest("Notes journal authenticates ciphertext and preserves a corrupt archive") {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("draft.enc")
        let store = NotesDraftJournal(url: url, keyProvider: AuditNotesKey())
        let entry = NotesJournalEntry(
            base: AuditNotesProvider.sample("A"), draft: NotesDraft(title: "SECRET", body: "private payload"),
            revision: 1, state: .memoryOnly)
        try await store.save([entry])
        let encrypted = try Data(contentsOf: url)
        try expect(!String(decoding: encrypted, as: UTF8.self).contains("private payload"))
        let read = try await store.load(); try expectEqual(read.first?.draft, entry.draft)
        var damaged = encrypted; damaged[damaged.count - 1] ^= 1
        try damaged.write(to: url)
        try await expectThrows { _ = try await store.load() }
        try await expectThrows { try await store.save([]) }
        let unchanged = try Data(contentsOf: url)
        try expectEqual(unchanged, damaged)
    },
    UnitTest("Notes worker missing executable is a definite pre-send failure") {
        let worker = NotesWorkerTransport(
            executable: URL(fileURLWithPath: "/private/tmp/does-not-exist-topdrop-worker"))
        do {
            _ = try await worker.perform(NotesWorkerRequest(operation: .save));
            throw TestFailure(description: "Worker unexpectedly ran")
        } catch let error as NotesProviderError { try expectEqual(error, .workerUnavailable) }
    },
    UnitTest("Notes worker deadline reaps a hung mutation with an uncertain result") {
        let directory = Bundle.main.executableURL!.deletingLastPathComponent()
        let worker = NotesWorkerTransport(
            executable: directory.appendingPathComponent("TopDropNotesWorkerFixture"), timeout: 0.1)
        var request = NotesWorkerRequest(operation: .save); request.folderName = "hang"
        let start = ContinuousClock.now
        do {
            _ = try await worker.perform(request); throw TestFailure(description: "Hang unexpectedly succeeded")
        } catch let error as NotesProviderError { try expectEqual(error, .resultUncertain) }
        try expect(start.duration(to: .now) < .seconds(2))
    },
    UnitTest("Notes transport serializes concurrent worker requests") {
        let directory = Bundle.main.executableURL!.deletingLastPathComponent()
        let worker = NotesWorkerTransport(executable: directory.appendingPathComponent("TopDropNotesWorkerFixture"))
        let start = ContinuousClock.now
        async let a = worker.perform(NotesWorkerRequest(operation: .diagnostics))
        async let b = worker.perform(NotesWorkerRequest(operation: .diagnostics))
        async let c = worker.perform(NotesWorkerRequest(operation: .diagnostics))
        let values = try await [a, b, c]
        try expect(values.allSatisfy { $0.mainThread == true })
        try expect(start.duration(to: .now) >= .milliseconds(300))
    },
    UnitTest("Notes worker deadline includes pipes inherited by a subprocess") {
        let directory = Bundle.main.executableURL!.deletingLastPathComponent()
        let worker = NotesWorkerTransport(
            executable: directory.appendingPathComponent("TopDropNotesWorkerFixture"), timeout: 0.15)
        var request = NotesWorkerRequest(operation: .save); request.folderName = "inherited-pipe"
        let start = ContinuousClock.now
        do {
            _ = try await worker.perform(request); throw TestFailure(description: "Expected uncertain write")
        } catch let error as NotesProviderError { try expectEqual(error, .resultUncertain) }
        try expect(start.duration(to: .now) < .seconds(1), "Pipe drain bypassed request deadline")
    },
    UnitTest("Notes cancelled queued mutation never launches") {
        let directory = Bundle.main.executableURL!.deletingLastPathComponent()
        let worker = NotesWorkerTransport(executable: directory.appendingPathComponent("TopDropNotesWorkerFixture"))
        let pending = Task { try await worker.perform(NotesWorkerRequest(operation: .save)) }
        pending.cancel()
        do {
            _ = try await pending.value; throw TestFailure(description: "Cancelled request executed")
        } catch is CancellationError {}
    },
    UnitTest("Notes worker uses its main thread without requesting Notes permission") {
        let directory = Bundle.main.executableURL!.deletingLastPathComponent()
        let worker = NotesWorkerTransport(executable: directory.appendingPathComponent("TopDropNotesWorker"))
        let response = try await worker.perform(NotesWorkerRequest(operation: .diagnostics))
        try expectEqual(response.mainThread, true); try expect(response.error == nil)
    },
    UnitTest("Notes HTML retains plain spaces tabs and Unicode through Apple's HTML reader") { @MainActor in
        let title = "Title", body = "  spaced  text\tend  \n\n中文 👩🏽‍💻 <&>"
        let html = NotesTextConverter.minimalHTML(title: title, body: body)
        let attributed = try NSAttributedString(
            data: Data(html.utf8),
            options: [
                .documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue,
            ], documentAttributes: nil)
        try expect(
            NotesTextConverter.matchesReadback(attributed.string, expected: title + "\n" + body),
            "Synthetic HTML whitespace roundtrip: \(String(reflecting: attributed.string))")
    },
]

private struct AuditNotesKey: ClipboardEncryptionKeyProviding {
    func encryptionKey() async throws -> SymmetricKey { SymmetricKey(data: Data(repeating: 42, count: 32)) }
}
