import Combine
import Foundation
import TopDropCore

@MainActor
final class NotesViewModel: ObservableObject {
    @Published private(set) var permission: NotesAutomationPermission = .promptRequired
    @Published private(set) var accounts: [NotesAccount] = []
    @Published private(set) var folders: [NotesFolder] = []
    @Published var searchText = ""
    @Published private var busy = false
    @Published private var localMessage: String?
    @Published private(set) var recoveryCandidates: [FolderCandidate] = []
    struct FolderCandidate: Identifiable {
        var folder: NotesFolder
        var count: Int?
        var id: String { folder.id }
    }
    let sync: NotesSyncCoordinator
    private let provider: any NotesProvider
    private unowned let settings: AppSettingsModel
    private var subscription: AnyCancellable?
    private var setupGeneration: UInt64 = 0

    init(provider: any NotesProvider, settings: AppSettingsModel) {
        self.provider = provider; self.settings = settings
        sync = NotesSyncCoordinator(provider: provider, journal: NotesDraftJournal())
        subscription = sync.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
    var notes: [NotesNote] {
        sync.notes.map { note in
            guard let pending = sync.entries[NotesIdentity(note)] else { return note }
            var display = note
            display.title = pending.draft.title; display.body = pending.draft.body
            return display
        }
    }
    var selectedNote: NotesNote? { sync.selectedNote }
    var selectedNoteID: String? { sync.selected?.noteID }
    var draftTitle: String { sync.draft.title }
    var draftBody: String { sync.draft.body }
    var isBusy: Bool { busy || sync.isRefreshing }
    var isSelectedReadOnly: Bool { sync.selectedIsReadOnly }
    var saveStatus: String { sync.status }
    var hasRecoveryDraft: Bool { sync.selected.flatMap { sync.entries[$0] } != nil }
    var statusMessage: String? { localMessage ?? sync.message }
    var filteredNotes: [NotesNote] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.body.localizedCaseInsensitiveContains(query)
        }
    }
    private func configure() {
        if let account = settings.value.notesAccountIdentifier, let folder = settings.value.notesFolderIdentifier {
            sync.configure(accountID: account, folderID: folder)
        }
    }
    func start() async {
        configure()
        await sync.restore()
        permission = await provider.automationPermission(promptIfNeeded: false)
        guard permission == .allowed else { return }
        await loadAccounts()
        await sync.resumeRecovery()
        await reloadConfiguredFolder()
    }
    func requestAutomationAndLoadAccounts() async {
        busy = true; defer { busy = false }
        permission = await provider.automationPermission(promptIfNeeded: true)
        guard permission == .allowed else {
            localMessage =
                permission == .denied
                ? "Enable TopDrop's Notes automation in System Settings, then recheck."
                : "Notes automation is not ready. Check that the complete app is installed, then recheck."
            return
        }
        await loadAccounts(showBusy: false)
        configure()
        await sync.restore()
        await sync.resumeRecovery()
        await reloadConfiguredFolder()
    }
    func loadAccounts(showBusy: Bool = true) async {
        if showBusy { busy = true }
        defer { if showBusy { busy = false } }
        do {
            accounts = try await provider.listAccounts().filter(\.isICloud)
            localMessage = accounts.isEmpty ? "No iCloud Notes account is available." : nil
        } catch { localMessage = error.localizedDescription }
    }
    func loadFolders(accountID: String) async {
        do { folders = try await provider.listFolders(accountID: accountID) } catch {
            localMessage = error.localizedDescription
        }
    }
    @discardableResult
    func prepareDedicatedFolder(accountID: String, folderName: String) async -> Bool {
        setupGeneration &+= 1; let token = setupGeneration
        busy = true; defer { if token == setupGeneration { busy = false } }
        _ = await sync.protectDrafts()
        do {
            let folder = try await provider.prepareTopDropFolder(accountID: accountID, folderName: folderName)
            guard token == setupGeneration else { return false }
            bind(folder)
            await sync.refresh()
            return true
        } catch { localMessage = error.localizedDescription; return false }
    }
    private func bind(_ folder: NotesFolder) {
        settings.update {
            $0.notesAccountIdentifier = folder.accountID
            $0.notesAccountName = accounts.first { $0.id == folder.accountID }?.name
            $0.notesFolderIdentifier = folder.id
            $0.notesFolderName = folder.name
        }
        configure(); localMessage = nil
    }
    func findRecoveryFolders() async {
        guard let account = settings.value.notesAccountIdentifier else { return }
        busy = true; defer { busy = false }
        do {
            let discovered = try await provider.listFolders(accountID: account)
            var candidates: [FolderCandidate] = []
            for folder in discovered
            where folder.name.localizedCaseInsensitiveCompare(settings.value.notesFolderName) == .orderedSame {
                let result = try? await provider.fetch(accountID: account, folderID: folder.id)
                candidates.append(
                    FolderCandidate(folder: folder, count: result?.isComplete == true ? result?.notes.count : nil))
            }
            recoveryCandidates = candidates
            if candidates.isEmpty {
                localMessage = "No matching folders found. Existing folder selection was not changed."
            }
        } catch { localMessage = error.localizedDescription }
    }
    func chooseRecoveryFolder(_ folder: NotesFolder) async {
        _ = await sync.protectDrafts()
        bind(folder)
        await sync.refresh()
    }
    func reloadConfiguredFolder() async {
        localMessage = nil; configure(); await sync.refresh()
    }
    func select(_ note: NotesNote?) { sync.select(note) }
    func showCollection() { sync.select(nil) }
    func setDraftTitle(_ value: String) { sync.edit(title: value, body: draftBody) }
    func setDraftBody(_ value: String) { sync.edit(title: draftTitle, body: value) }
    func createNote() async { configure(); sync.create() }
    func deleteSelectedNote() async { await sync.deleteSelected() }
    func openSelectedInNotes() async { await sync.openSelected() }
    func flushPendingEdit() async { await sync.flush() }
    func setTrayVisible(_ visible: Bool) { sync.setVisible(visible) }
    func beginTermination() { sync.stop() }
}
