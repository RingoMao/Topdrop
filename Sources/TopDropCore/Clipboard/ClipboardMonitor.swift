import Combine
import Foundation
import OSLog

@MainActor
public protocol ClipboardMonitoring: AnyObject {
    var snapshot: ClipboardMonitorSnapshot { get }
    func start()
    func stop()
    func pollNow() async
    @discardableResult func requestPasteboardAccess() -> ClipboardAccessState
    func setPaused(_ paused: Bool)
    func setSensitiveApplicationBundleIdentifiers(_ bundleIdentifiers: Set<String>)
    func setCurrentPlainText(
        _ text: String,
        sourceApplication: ClipboardSourceApplication?
    ) async throws
    func setCurrentImagePNG(
        _ data: Data,
        sourceApplication: ClipboardSourceApplication?
    ) async throws
    func setCurrentFile(template: BlankFileTemplate) async throws
    func makeCurrent(itemID: UUID) async throws
    func restore(itemID: UUID) async throws
    func beginArrivalWatch(duration: Duration)
    func cancelArrivalWatch()
    func delete(itemID: UUID) async
    func clearAll() async
    @discardableResult func cleanFormatting() async throws -> ClipboardCleanFormattingOutcome
}

/// The public clipboard subsystem boundary used by the status menu and tray UI.
/// AppKit access is main-actor isolated; disk and Keychain work run through actors.
@MainActor
public final class ClipboardMonitor: ObservableObject, ClipboardMonitoring {
    @Published public private(set) var snapshot: ClipboardMonitorSnapshot

    /// Delivers only newly retained history entries. Loading encrypted history,
    /// restoring a clip, TopDrop-owned writes, exclusions, pauses, and duplicate
    /// suppression never replay through this hook.
    public var onItemCaptured: ((ClipboardItem) -> Void)?

    /// Delivers every eligible pasteboard observation after permission, pause,
    /// ownership, exclusion, size, and conversion checks. Unlike
    /// `onItemCaptured`, this also runs for a consecutive history duplicate.
    /// Session-only consumers use it to rebuild transient state after relaunch
    /// without weakening clipboard-history duplicate suppression.
    public var onContentObserved: ((ClipboardItem) -> Void)?

    public var items: [ClipboardItem] { snapshot.items }
    public var isPaused: Bool { snapshot.isPaused }
    public var accessState: ClipboardAccessState { snapshot.accessState }

    private let pasteboard: any ClipboardPasteboardClient
    private let sourceApplications: any ClipboardSourceApplicationProviding
    private let historyStore: any ClipboardHistoryPersisting
    private let converter: ClipboardContentConverter
    private let blankFiles: any BlankFileTemplateProviding
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "ClipboardMonitor")
    private var configuration: ClipboardMonitorConfiguration
    private var pollingTask: Task<Void, Never>?
    private var arrivalWatchTask: Task<Void, Never>?
    private var observedChangeCount: Int?
    private var historyLoaded = false
    private var historyLoadTask: Task<[ClipboardItem], Error>?
    private var historySaveTask: Task<Void, Never>?
    private var removedHistoryIDs = Set<UUID>()
    @Published public private(set) var historyNeedsRecovery = false

    public convenience init(configuration: ClipboardMonitorConfiguration = .init()) {
        let applicationSupport =
            FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let archiveURL =
            applicationSupport
            .appendingPathComponent("TopDrop", isDirectory: true)
            .appendingPathComponent("Clipboard", isDirectory: true)
            .appendingPathComponent("history.tdclip", isDirectory: false)
        self.init(
            pasteboard: SystemClipboardPasteboardClient(),
            sourceApplications: WorkspaceClipboardSourceApplicationProvider(),
            historyStore: EncryptedClipboardHistoryStore(fileURL: archiveURL),
            configuration: configuration
        )
    }

    public init(
        pasteboard: any ClipboardPasteboardClient,
        sourceApplications: any ClipboardSourceApplicationProviding,
        historyStore: any ClipboardHistoryPersisting,
        configuration: ClipboardMonitorConfiguration = .init(),
        converter: ClipboardContentConverter = .init(),
        blankFiles: any BlankFileTemplateProviding = BlankFileTemplateStore()
    ) {
        self.pasteboard = pasteboard
        self.sourceApplications = sourceApplications
        self.historyStore = historyStore
        self.configuration = configuration
        self.converter = converter
        self.blankFiles = blankFiles
        self.snapshot = ClipboardMonitorSnapshot(
            accessState: pasteboard.accessState,
            sensitiveApplicationBundleIdentifiers: configuration.sensitiveApplicationBundleIdentifiers,
            statusMessage: pasteboard.accessState == .allowed ? nil : pasteboard.accessState.userMessage
        )
    }

    deinit {
        pollingTask?.cancel()
        arrivalWatchTask?.cancel()
    }

    public func start() {
        guard pollingTask == nil else { return }
        historyNeedsRecovery = false
        // Baseline the live pasteboard. Its source application cannot be known
        // reliably during startup, so reading it here could bypass an exclusion.
        observedChangeCount = pasteboard.changeCount
        updateAccessState()
        let interval = configuration.pollingInterval
        pollingTask = Task { [weak self] in
            await self?.loadHistory()
            self?.replayHistoryForObservers()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                guard let self else { return }
                await self.pollNow()
            }
        }
        logger.info("Clipboard monitoring started")
    }

    public func stop() {
        pollingTask?.cancel()
        pollingTask = nil
        cancelArrivalWatch()
        logger.info("Clipboard monitoring stopped")
    }

    public func pollNow() async {
        updateAccessState()
        let currentChangeCount = pasteboard.changeCount
        guard observedChangeCount != currentChangeCount else { return }

        // A pause means no changes made during the paused interval are retained.
        if snapshot.isPaused {
            observedChangeCount = currentChangeCount
            snapshot.currentState = .untracked(reason: .changedWhilePaused)
            return
        }
        guard snapshot.accessState == .allowed else {
            // Do not consume the count: if permission is granted later, the most
            // recent clipboard value can be captured on the next poll.
            snapshot.currentState = .untracked(reason: .accessUnavailable)
            return
        }

        let sourceApplication = sourceApplications.currentSourceApplication()
        if let bundleIdentifier = sourceApplication?.bundleIdentifier,
            configuration.sensitiveApplicationBundleIdentifiers.contains(bundleIdentifier)
        {
            observedChangeCount = currentChangeCount
            snapshot.currentState = .untracked(reason: .excludedApplication)
            snapshot.statusMessage = "Clipboard change skipped for an excluded application."
            logger.info("Clipboard change skipped by sensitive-application exclusion")
            return
        }

        do {
            let rawContents = try pasteboard.readSupportedContents()
            observedChangeCount = currentChangeCount
            guard !rawContents.containsTopDropMarker else {
                snapshot.currentState = .untracked(reason: .topDropOwnedWrite)
                logger.debug("TopDrop-owned clipboard write ignored")
                return
            }

            switch converter.convert(rawContents, sourceApplication: sourceApplication) {
            case let .item(item):
                if snapshot.items.first?.fingerprint == item.fingerprint {
                    if let existing = snapshot.items.first {
                        let activated = existing.activated(at: item.capturedAt)
                        snapshot.items[0] = activated
                        snapshot.currentState = .tracked(itemID: existing.id)
                        completeArrivalWatch(itemID: existing.id, receivedAt: item.capturedAt)
                        snapshot.statusMessage = nil
                        onContentObserved?(activated)
                        await persistHistory()
                    }
                    logger.debug("Consecutive duplicate clipboard item ignored")
                    return
                }
                snapshot.items.insert(item, at: 0)
                if snapshot.items.count > TopDropCore.maximumClipboardItemCount {
                    snapshot.items.removeLast(snapshot.items.count - TopDropCore.maximumClipboardItemCount)
                }
                snapshot.currentState = .tracked(itemID: item.id)
                completeArrivalWatch(itemID: item.id, receivedAt: item.capturedAt)
                snapshot.statusMessage = nil
                onContentObserved?(item)
                onItemCaptured?(item)
                await persistHistory()
                logger.info("Clipboard item retained; historyCount=\(self.snapshot.items.count, privacy: .public)")
            case let .oversized(byteCount, limit):
                snapshot.currentState = .untracked(reason: .oversized)
                snapshot.statusMessage =
                    "Clipboard item skipped (\(Self.byteCountLabel(byteCount)); limit \(Self.byteCountLabel(limit)))."
                logger.notice("Oversized clipboard item skipped; byteCount=\(byteCount, privacy: .public)")
            case .empty:
                snapshot.currentState = .untracked(reason: .unsupported)
                logger.debug("Clipboard change did not contain a supported type")
            }
        } catch {
            observedChangeCount = currentChangeCount
            snapshot.currentState = .untracked(reason: .readFailed)
            snapshot.statusMessage = Self.message(for: error)
            logger.error("Clipboard poll failed")
        }
    }

    @discardableResult
    public func requestPasteboardAccess() -> ClipboardAccessState {
        let result = pasteboard.requestAccess()
        snapshot.accessState = result
        snapshot.statusMessage = result == .allowed ? nil : result.userMessage
        if result == .allowed,
            snapshot.arrivalWatch == .unavailable(reason: .accessRequired)
        {
            beginArrivalWatch()
        }
        return result
    }

    public func setPaused(_ paused: Bool) {
        guard snapshot.isPaused != paused else { return }
        snapshot.isPaused = paused
        // Discard anything copied while paused, including the value immediately
        // before Resume is selected.
        observedChangeCount = pasteboard.changeCount
        snapshot.statusMessage = paused ? "Clipboard history paused." : nil
        if paused {
            arrivalWatchTask?.cancel()
            arrivalWatchTask = nil
            snapshot.arrivalWatch = .unavailable(reason: .paused)
        } else if snapshot.arrivalWatch == .unavailable(reason: .paused) {
            snapshot.arrivalWatch = .idle
        }
        logger.info("Clipboard history pause state changed; paused=\(paused, privacy: .public)")
    }

    public func setSensitiveApplicationBundleIdentifiers(_ bundleIdentifiers: Set<String>) {
        configuration.sensitiveApplicationBundleIdentifiers = bundleIdentifiers
        snapshot.sensitiveApplicationBundleIdentifiers = bundleIdentifiers
        logger.info("Sensitive-application exclusions updated; count=\(bundleIdentifiers.count, privacy: .public)")
    }

    /// Writes text produced by an explicit TopDrop action and retains the same
    /// transaction as the current history item. System pasteboard writes carry
    /// TopDrop's ownership marker, so normal polling intentionally cannot add
    /// them after the fact.
    public func setCurrentPlainText(
        _ text: String,
        sourceApplication: ClipboardSourceApplication? = nil
    ) async throws {
        let rawContents = ClipboardRawContents(items: [
            ClipboardRawItem(flavors: [
                ClipboardRawItem.Flavor(
                    pasteboardType: "public.utf8-plain-text",
                    data: Data(text.utf8)
                )
            ])
        ])
        guard
            case let .item(candidate) = converter.convert(
                rawContents,
                sourceApplication: sourceApplication
            )
        else {
            throw ClipboardSubsystemError.pasteboardWriteFailed
        }

        try await commitExplicitCandidate(candidate)
        logger.info("Explicit text retained as current clipboard item")
    }

    /// Replaces the current general pasteboard with one flattened PNG and
    /// retains that exact transaction as the current encrypted history item.
    /// This is used by the annotation editor, so its result is immediately
    /// visible in Clipboard & Images instead of waiting for a poll that would
    /// intentionally ignore TopDrop's ownership marker.
    public func setCurrentImagePNG(
        _ data: Data,
        sourceApplication: ClipboardSourceApplication? = nil
    ) async throws {
        let rawContents = ClipboardRawContents(items: [
            ClipboardRawItem(flavors: [
                ClipboardRawItem.Flavor(
                    pasteboardType: "public.png",
                    data: data
                )
            ])
        ])
        guard
            case let .item(candidate) = converter.convert(
                rawContents,
                sourceApplication: sourceApplication
            )
        else {
            throw ClipboardSubsystemError.pasteboardWriteFailed
        }
        try await commitExplicitCandidate(candidate)
        logger.info("Annotated image retained as current clipboard item")
    }

    public func setCurrentFile(template: BlankFileTemplate) async throws {
        let url = try blankFiles.create(template)
        let candidate = try fileCandidate(url: url, template: template)
        try await commitExplicitCandidate(candidate)
        snapshot.statusMessage = "File Copied — Paste in Finder"
    }

    private func fileCandidate(url: URL, template: BlankFileTemplate, replacing old: ClipboardItem? = nil) throws
        -> ClipboardItem
    {
        let raw = ClipboardRawContents(items: [
            ClipboardRawItem(flavors: [
                .init(pasteboardType: "public.file-url", data: Data(url.absoluteString.utf8))
            ])
        ])
        guard case .item(let converted) = converter.convert(raw, sourceApplication: nil) else {
            throw ClipboardSubsystemError.pasteboardWriteFailed
        }
        return ClipboardItem(
            id: old?.id ?? converted.id,
            capturedAt: old?.capturedAt ?? converted.capturedAt,
            lastActivatedAt: old?.lastActivatedAt,
            generatedTemplate: template,
            sourceApplication: old?.sourceApplication,
            payload: converted.payload, preview: converted.preview,
            fingerprint: converted.fingerprint)
    }

    public func makeCurrent(itemID: UUID) async throws {
        guard let index = snapshot.items.firstIndex(where: { $0.id == itemID }) else {
            throw ClipboardSubsystemError.itemNotFound
        }
        var item = snapshot.items[index]
        if let template = item.generatedTemplate {
            let url = item.payload.items.flatMap(\.representations)
                .first(where: { $0.kind == .fileURL })
                .flatMap { String(data: $0.data, encoding: .utf8) }
                .flatMap { URL(string: $0) }
            if url == nil || !FileManager.default.isReadableFile(atPath: url!.path) {
                item = try fileCandidate(url: blankFiles.create(template), template: template, replacing: item)
            }
        }
        let beforeWrite = pasteboard.changeCount
        let changeCount: Int
        do {
            changeCount = try pasteboard.write(item.payload)
        } catch {
            reconcileFailedWrite(previousCount: beforeWrite)
            snapshot.statusMessage = Self.message(for: error)
            logger.error("Clipboard promotion failed")
            throw error
        }
        let activated = item.activated(at: Date())
        observedChangeCount = changeCount
        snapshot.items.remove(at: index)
        snapshot.items.insert(activated, at: 0)
        snapshot.currentState = .tracked(itemID: activated.id)
        snapshot.statusMessage = "Now on clipboard."
        await persistHistory()
        logger.info("Clipboard history item promoted to current")
    }

    public func restore(itemID: UUID) async throws {
        try await makeCurrent(itemID: itemID)
    }

    public func beginArrivalWatch(duration: Duration = .seconds(30)) {
        arrivalWatchTask?.cancel()
        arrivalWatchTask = nil
        guard snapshot.accessState == .allowed else {
            snapshot.arrivalWatch = .unavailable(reason: .accessRequired)
            return
        }
        guard !snapshot.isPaused else {
            snapshot.arrivalWatch = .unavailable(reason: .paused)
            return
        }

        let startedAt = Date()
        let deadline = startedAt.addingTimeInterval(Self.timeInterval(for: duration))
        snapshot.arrivalWatch = .watching(startedAt: startedAt, deadline: deadline)
        arrivalWatchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: duration)
                try Task.checkCancellation()
                self?.arrivalWatchDidTimeOut(deadline: deadline)
            } catch {
                return
            }
        }
    }

    public func cancelArrivalWatch() {
        arrivalWatchTask?.cancel()
        arrivalWatchTask = nil
        snapshot.arrivalWatch = .idle
    }

    public func delete(itemID: UUID) async {
        removedHistoryIDs.insert(itemID)
        let oldCount = snapshot.items.count
        snapshot.items.removeAll { $0.id == itemID }
        guard snapshot.items.count != oldCount else { return }
        if snapshot.currentState.itemID == itemID {
            snapshot.currentState = .untracked(reason: .removedFromHistory)
        }
        await persistHistory()
        logger.info("Clipboard history item deleted; historyCount=\(self.snapshot.items.count, privacy: .public)")
    }

    public func clearAll() async {
        guard !snapshot.items.isEmpty else { return }
        removedHistoryIDs.formUnion(snapshot.items.map(\.id))
        snapshot.items.removeAll(keepingCapacity: false)
        snapshot.currentState = .untracked(reason: .historyCleared)
        await persistHistory()
        if !historyNeedsRecovery { snapshot.statusMessage = "Clipboard history cleared." }
        logger.info("Clipboard history cleared")
    }

    @discardableResult
    public func cleanFormatting() async throws -> ClipboardCleanFormattingOutcome {
        let beforeWrite = pasteboard.changeCount
        do {
            let result = try pasteboard.cleanFormatting()
            switch result {
            case let .cleaned(changeCount):
                observedChangeCount = changeCount
                snapshot.currentState = .untracked(reason: .formattingCleaned)
                snapshot.statusMessage = "Clipboard formatting removed. Paste normally when ready."
            case .alreadyPlainText:
                snapshot.statusMessage = "Clipboard text is already plain."
            case .noText:
                snapshot.statusMessage = "Clipboard contains no text; it was not changed."
            }
            return result
        } catch {
            reconcileFailedWrite(previousCount: beforeWrite)
            snapshot.statusMessage = Self.message(for: error)
            logger.error("Clean Formatting failed")
            throw error
        }
    }

    private func loadHistory() async {
        guard !historyLoaded, !historyNeedsRecovery else { return }
        if historyLoadTask == nil {
            historyLoadTask = Task { [historyStore] in try await historyStore.load() }
        }
        guard let task = historyLoadTask else { return }
        do {
            let loaded = try await task.value
            guard !historyLoaded else { return }
            // New copies may arrive during disk/Keychain access. Never replace
            // those or resurrect items explicitly deleted during this session.
            let sessionFingerprints = Set(snapshot.items.map(\.fingerprint))
            var merged = Dictionary(
                loaded.filter { !removedHistoryIDs.contains($0.id) && !sessionFingerprints.contains($0.fingerprint) }
                    .map { ($0.id, $0) }, uniquingKeysWith: { a, b in a.activityDate >= b.activityDate ? a : b })
            for item in snapshot.items { merged[item.id] = item }
            snapshot.items = Array(
                merged.values
                    .sorted { left, right in
                        if left.activityDate == right.activityDate {
                            return left.id.uuidString < right.id.uuidString
                        }
                        return left.activityDate > right.activityDate
                    }
                    .prefix(TopDropCore.maximumClipboardItemCount)
            )
            historyLoaded = true
            historyLoadTask = nil
        } catch {
            historyLoadTask = nil
            historyNeedsRecovery = true
            snapshot.statusMessage = "Encrypted clipboard history could not be loaded. New clips can still be captured."
            logger.error("Clipboard history load failed")
        }
    }

    /// Rehydrates session-only consumers (not clipboard history itself) from
    /// already accepted encrypted history. Recorded source applications still
    /// honor current exclusions, and pausing history also pauses this replay.
    private func replayHistoryForObservers() {
        guard !snapshot.isPaused else { return }
        for item in snapshot.items {
            if let bundleIdentifier = item.sourceApplication?.bundleIdentifier,
                configuration.sensitiveApplicationBundleIdentifiers.contains(bundleIdentifier)
            {
                continue
            }
            onContentObserved?(item)
        }
    }

    private func persistHistory() async {
        await loadHistory()
        guard historyLoaded, !historyNeedsRecovery else {
            snapshot.statusMessage =
                "Old history is protected. New clips are session-only. Retry History Recovery after unlocking Keychain."
            return
        }
        let previous = historySaveTask
        let items = snapshot.items
        let task = Task { [weak self, historyStore] in
            await previous?.value
            do { try await historyStore.save(items) } catch {
                self?.snapshot.statusMessage =
                    "Clipboard history is available for this session but could not be saved securely."
                self?.logger.error("Clipboard history save failed")
            }
        }
        historySaveTask = task
        await task.value
    }

    public func retryHistoryRecovery() async {
        historyNeedsRecovery = false
        await loadHistory()
        guard historyLoaded else { return }
        snapshot.statusMessage = "History recovered."
        replayHistoryForObservers()
        await persistHistory()
    }

    private func reconcileFailedWrite(previousCount: Int) {
        guard pasteboard.changeCount != previousCount else { return }
        snapshot.currentState = .untracked(reason: .readFailed)
        // Do not restore an old snapshot over another process's clipboard.
        observedChangeCount = nil
    }

    private func commitExplicitCandidate(_ candidate: ClipboardItem) async throws {
        let beforeWrite = pasteboard.changeCount
        let changeCount: Int
        do {
            changeCount = try pasteboard.write(candidate.payload)
        } catch {
            reconcileFailedWrite(previousCount: beforeWrite)
            snapshot.statusMessage = Self.message(for: error)
            logger.error("Explicit clipboard write failed")
            throw error
        }

        observedChangeCount = changeCount
        if let index = snapshot.items.firstIndex(where: {
            $0.fingerprint == candidate.fingerprint
        }) {
            let activated = snapshot.items[index].activated(at: candidate.capturedAt)
            snapshot.items.remove(at: index)
            snapshot.items.insert(activated, at: 0)
            snapshot.currentState = .tracked(itemID: activated.id)
            onContentObserved?(activated)
        } else {
            snapshot.items.insert(candidate, at: 0)
            if snapshot.items.count > TopDropCore.maximumClipboardItemCount {
                snapshot.items.removeLast(snapshot.items.count - TopDropCore.maximumClipboardItemCount)
            }
            snapshot.currentState = .tracked(itemID: candidate.id)
            onContentObserved?(candidate)
            onItemCaptured?(candidate)
        }
        snapshot.statusMessage = "Copied to clipboard."
        await persistHistory()
    }

    private func updateAccessState() {
        let state = pasteboard.accessState
        if snapshot.accessState != state {
            snapshot.accessState = state
            snapshot.statusMessage = state == .allowed ? nil : state.userMessage
            if state != .allowed {
                snapshot.currentState = .untracked(reason: .accessUnavailable)
                if case .watching = snapshot.arrivalWatch {
                    arrivalWatchTask?.cancel()
                    arrivalWatchTask = nil
                    snapshot.arrivalWatch = .unavailable(reason: .accessRequired)
                }
            }
            logger.info("Pasteboard access state changed; state=\(state.rawValue, privacy: .public)")
        }
    }

    private func completeArrivalWatch(itemID: UUID, receivedAt: Date) {
        guard case .watching = snapshot.arrivalWatch else { return }
        arrivalWatchTask?.cancel()
        arrivalWatchTask = nil
        snapshot.arrivalWatch = .received(itemID: itemID, receivedAt: receivedAt)
    }

    private func arrivalWatchDidTimeOut(deadline: Date) {
        guard case let .watching(_, currentDeadline) = snapshot.arrivalWatch,
            currentDeadline == deadline
        else { return }
        arrivalWatchTask = nil
        snapshot.arrivalWatch = .timedOut
    }

    private static func timeInterval(for duration: Duration) -> TimeInterval {
        let components = duration.components
        let seconds = Double(components.seconds)
        let fractional = Double(components.attoseconds) / 1_000_000_000_000_000_000
        return max(0, seconds + fractional)
    }

    private static func byteCountLabel(_ count: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(count), countStyle: .file)
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? "Clipboard operation failed."
    }
}
