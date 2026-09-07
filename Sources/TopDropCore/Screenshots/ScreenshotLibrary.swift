import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

/// Owns imported screenshot history and monitors the user-selected,
/// screenshot-only source folder. Source files are read and copied but are
/// never changed or deleted.
public actor ScreenshotLibrary {
    struct SourceFingerprint: Codable, Equatable, Sendable {
        let byteCount: Int64
        let modifiedAt: TimeInterval
    }

    struct PersistedState: Codable, Sendable {
        var version = 1
        var selectedFolderPath: String?
        var selectedFolderBookmark: Data?
        var observedFiles: [String: SourceFingerprint] = [:]
        var items: [ScreenshotItem] = []
        var annotationVersions: [UUID: [ScreenshotAnnotationVersion]] = [:]

        private enum CodingKeys: String, CodingKey {
            case version
            case selectedFolderPath
            case selectedFolderBookmark
            case observedFiles
            case items
            case annotationVersions
        }

        init() {}

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
            selectedFolderPath = try container.decodeIfPresent(
                String.self,
                forKey: .selectedFolderPath
            )
            selectedFolderBookmark = try container.decodeIfPresent(
                Data.self,
                forKey: .selectedFolderBookmark
            )
            observedFiles =
                try container.decodeIfPresent(
                    [String: SourceFingerprint].self,
                    forKey: .observedFiles
                ) ?? [:]
            items = try container.decodeIfPresent([ScreenshotItem].self, forKey: .items) ?? []
            annotationVersions =
                try container.decodeIfPresent(
                    [UUID: [ScreenshotAnnotationVersion]].self,
                    forKey: .annotationVersions
                ) ?? [:]
        }
    }

    struct ActiveEditSession: Sendable {
        let itemID: UUID
        var didArchiveInitialVersion = false
    }

    struct ClipboardImageCandidate: Sendable {
        let pngData: Data
        let sourceURL: URL?
    }

    static let logger = Logger(
        subsystem: TopDropCore.bundleIdentifier,
        category: "Screenshots"
    )
    static let maximumDecodedClipboardPixels = 100_000_000

    let fileManager: FileManager
    let libraryDirectory: URL
    let originalsDirectory: URL
    let thumbnailsDirectory: URL
    let annotationsDirectory: URL
    let annotationVersionsDirectory: URL
    let flattenedDirectory: URL
    let sessionCacheDirectory: URL
    let sessionOriginalsDirectory: URL
    let sessionThumbnailsDirectory: URL
    let sessionAnnotationsDirectory: URL
    let sessionVersionsDirectory: URL
    let sessionFlattenedDirectory: URL
    let metadataURL: URL
    let stabilizationPolicy: ScreenshotStabilizationPolicy
    /// Deliberately never persisted. A crash can leave only ciphertext that
    /// becomes undecryptable and is removed during the next initialization.
    let sessionEncryptionKey: SymmetricKey

    var state: PersistedState
    var sessionItems: [ScreenshotItem] = []
    var sessionAnnotationVersions: [UUID: [ScreenshotAnnotationVersion]] = [:]
    var activeEditSessions: [UUID: ActiveEditSession] = [:]
    var selectedFolder: URL?
    var selectedFolderAccessStarted = false
    var watcher: FSEventFolderWatcher?
    var scheduledScanTask: Task<Void, Never>?
    var updateContinuations: [UUID: AsyncStream<ScreenshotLibrarySnapshot>.Continuation] = [:]

    public init(
        libraryDirectory: URL? = nil,
        stabilizationPolicy: ScreenshotStabilizationPolicy = .init()
    ) throws {
        let fileManager = FileManager.default
        let root: URL
        if let libraryDirectory {
            root = libraryDirectory.standardizedFileURL
        } else {
            guard
                let applicationSupport = fileManager.urls(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask
                ).first
            else {
                throw ScreenshotLibraryError.destinationUnavailable
            }
            root =
                applicationSupport
                .appendingPathComponent(TopDropCore.bundleIdentifier, isDirectory: true)
                .appendingPathComponent("Screenshots", isDirectory: true)
        }

        let originals = root.appendingPathComponent("Originals", isDirectory: true)
        let thumbnails = root.appendingPathComponent("Thumbnails", isDirectory: true)
        let annotations = root.appendingPathComponent("Annotations", isDirectory: true)
        let annotationVersions = annotations.appendingPathComponent("Versions", isDirectory: true)
        let flattened = root.appendingPathComponent("Flattened", isDirectory: true)
        let sessionCache = root.appendingPathComponent("SessionCache", isDirectory: true)
        let sessionOriginals = sessionCache.appendingPathComponent("Originals", isDirectory: true)
        let sessionThumbnails = sessionCache.appendingPathComponent("Thumbnails", isDirectory: true)
        let sessionAnnotations = sessionCache.appendingPathComponent("Annotations", isDirectory: true)
        let sessionVersions = sessionCache.appendingPathComponent("Versions", isDirectory: true)
        let sessionFlattened = sessionCache.appendingPathComponent("Flattened", isDirectory: true)
        // Clipboard-derived images and annotations are deliberately ephemeral.
        // Purge the complete dedicated cache before loading any durable state.
        if fileManager.fileExists(atPath: sessionCache.path) {
            try fileManager.removeItem(at: sessionCache)
        }
        for directory in [
            root,
            originals,
            thumbnails,
            annotations,
            annotationVersions,
            flattened,
            sessionOriginals,
            sessionThumbnails,
            sessionAnnotations,
            sessionVersions,
            sessionFlattened,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionCache.path
        )
        var sessionValues = URLResourceValues()
        sessionValues.isExcludedFromBackup = true
        var mutableSessionCache = sessionCache
        try? mutableSessionCache.setResourceValues(sessionValues)

        let metadataURL = root.appendingPathComponent("library.json", isDirectory: false)
        let loadedState: PersistedState
        if fileManager.fileExists(atPath: metadataURL.path) {
            do {
                loadedState = try JSONDecoder().decode(
                    PersistedState.self,
                    from: Data(contentsOf: metadataURL)
                )
            } catch {
                throw ScreenshotLibraryError.invalidMetadata
            }
        } else {
            loadedState = PersistedState()
        }
        guard loadedState.version == 1 else {
            throw ScreenshotLibraryError.invalidMetadata
        }

        self.fileManager = fileManager
        self.libraryDirectory = root
        originalsDirectory = originals
        thumbnailsDirectory = thumbnails
        annotationsDirectory = annotations
        annotationVersionsDirectory = annotationVersions
        flattenedDirectory = flattened
        sessionCacheDirectory = sessionCache
        sessionOriginalsDirectory = sessionOriginals
        sessionThumbnailsDirectory = sessionThumbnails
        sessionAnnotationsDirectory = sessionAnnotations
        sessionVersionsDirectory = sessionVersions
        sessionFlattenedDirectory = sessionFlattened
        self.metadataURL = metadataURL
        self.stabilizationPolicy = stabilizationPolicy
        sessionEncryptionKey = SymmetricKey(size: .bits256)
        state = loadedState

        if let bookmark = loadedState.selectedFolderBookmark {
            var isStale = false
            selectedFolder = try? URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
        }
        if selectedFolder == nil, let path = loadedState.selectedFolderPath {
            selectedFolder = URL(fileURLWithPath: path, isDirectory: true)
        }
        if let selectedFolder {
            selectedFolderAccessStarted = selectedFolder.startAccessingSecurityScopedResource()
        }

        // A missing managed file cannot be displayed, so repair that narrow
        // metadata inconsistency at load without touching any source file.
        state.items.removeAll {
            $0.origin != .watchedFolder
                || !Self.isDescendant($0.managedOriginalURL, of: originals)
                || !Self.isDescendant($0.thumbnailURL, of: thumbnails)
                || !fileManager.fileExists(atPath: $0.managedOriginalURL.path)
        }
        let durableItemIDs = Set(state.items.map(\.id))
        state.annotationVersions = state.annotationVersions.compactMapValues { versions in
            let available = versions.filter {
                durableItemIDs.contains($0.itemID)
                    && Self.isDescendant($0.annotationURL, of: annotationVersions)
                    && fileManager.fileExists(atPath: $0.annotationURL.path)
            }
            return available.isEmpty ? nil : available
        }
    }

    public func snapshot() -> ScreenshotLibrarySnapshot {
        makeSnapshot()
    }

    /// Emits the current value immediately, then emits after every history or
    /// monitoring-state change. SwiftUI can consume this from a small
    /// `@MainActor ObservableObject` adapter.
    public func updates() -> AsyncStream<ScreenshotLibrarySnapshot> {
        let identifier = UUID()
        let (stream, continuation) = AsyncStream<ScreenshotLibrarySnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        updateContinuations[identifier] = continuation
        continuation.yield(makeSnapshot())
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeContinuation(identifier) }
        }
        return stream
    }

    public func configureSourceFolder(
        _ folderURL: URL,
        importExisting: Bool = false,
        startMonitoring: Bool = true
    ) async throws -> [ScreenshotItem] {
        var isDirectory: ObjCBool = false
        let standardized = folderURL.standardizedFileURL
        guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ScreenshotLibraryError.sourceFolderUnavailable
        }
        let previousFolder = selectedFolder?.standardizedFileURL
        let isSamePersistedSelection = previousFolder == standardized

        stopMonitoring()
        if selectedFolderAccessStarted {
            selectedFolder?.stopAccessingSecurityScopedResource()
        }
        selectedFolder = standardized
        selectedFolderAccessStarted = standardized.startAccessingSecurityScopedResource()
        state.selectedFolderPath = standardized.path
        state.selectedFolderBookmark = try? standardized.bookmarkData(
            // TopDrop is a non-sandboxed personal utility. Ordinary bookmarks
            // retain relocation resilience; security-scoped bookmarks require
            // sandbox/bookmark entitlements and fail in this hardened build.
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        // Reconfiguring the persisted selection at launch must not erase the
        // prior baseline: files created while TopDrop was closed are new and
        // should be reconciled. A genuinely different folder starts with a
        // fresh baseline so onboarding still defaults to new files only.
        if !isSamePersistedSelection {
            state.observedFiles = try currentFingerprints(in: standardized)
        }
        try persist()

        let imported = importExisting ? try await importExistingScreenshots() : []
        if startMonitoring {
            try self.startMonitoring()
        } else {
            emitUpdate()
        }
        return imported
    }

    public func startMonitoring() throws {
        guard watcher == nil else { return }
        guard let selectedFolder else {
            throw ScreenshotLibraryError.sourceFolderNotConfigured
        }
        watcher = try FSEventFolderWatcher(folderURL: selectedFolder) { [weak self] _ in
            Task { await self?.fileSystemDidChange() }
        }
        Self.logger.info("Screenshot folder monitoring started")
        emitUpdate()
        // Reconcile files created while TopDrop was not running. Persisted
        // fingerprints ensure the first selection still defaults to new-only.
        scheduleScan()
    }

    public func stopMonitoring() {
        watcher?.stop()
        watcher = nil
        scheduledScanTask?.cancel()
        scheduledScanTask = nil
        emitUpdate()
    }

    /// Explicit onboarding action that imports every supported image currently
    /// in the selected folder. Content hashes suppress duplicates already in
    /// history.
    @discardableResult
    public func importExistingScreenshots() async throws -> [ScreenshotItem] {
        guard let selectedFolder else {
            throw ScreenshotLibraryError.sourceFolderNotConfigured
        }
        var imported: [ScreenshotItem] = []
        for url in try candidateURLs(in: selectedFolder) {
            do {
                let fingerprint = try await waitUntilStable(url)
                if let item = try importStableFile(url, fingerprint: fingerprint) {
                    imported.append(item)
                }
                state.observedFiles[url.path] = fingerprint
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.error("An existing screenshot could not be imported")
            }
        }
        try persist()
        emitUpdate()
        return imported
    }

    /// Imports one newly-created screenshot. The URL must belong to the selected
    /// screenshot-only folder; UI drag/drop should use a separate workflow.
    @discardableResult
    public func importScreenshot(at url: URL) async throws -> ScreenshotItem? {
        guard let selectedFolder else {
            throw ScreenshotLibraryError.sourceFolderNotConfigured
        }
        let standardized = url.standardizedFileURL
        guard isDirectChild(standardized, of: selectedFolder) else {
            throw ScreenshotLibraryError.fileOutsideSelectedFolder
        }
        let fingerprint = try await waitUntilStable(standardized)
        let item = try importStableFile(standardized, fingerprint: fingerprint)
        state.observedFiles[standardized.path] = fingerprint
        try persist()
        emitUpdate()
        return item
    }

    /// Synchronously reconciles the folder and is also useful after waking from
    /// sleep or regaining access to an iCloud-backed source folder.
    @discardableResult
    public func scanNow() async throws -> [ScreenshotItem] {
        guard let selectedFolder else {
            throw ScreenshotLibraryError.sourceFolderNotConfigured
        }
        let candidates = try candidateURLs(in: selectedFolder)
        let candidatePaths = Set(candidates.map(\.path))
        var imported: [ScreenshotItem] = []

        for url in candidates {
            let initial = try sourceFingerprint(for: url)
            guard state.observedFiles[url.path] != initial else { continue }
            do {
                let stable = try await waitUntilStable(url)
                if let item = try importStableFile(url, fingerprint: stable) {
                    imported.append(item)
                }
                state.observedFiles[url.path] = stable
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                Self.logger.error("A changed screenshot could not be imported")
            }
        }

        let folderPrefix = selectedFolder.path + "/"
        state.observedFiles = state.observedFiles.filter { path, _ in
            !path.hasPrefix(folderPrefix) || candidatePaths.contains(path)
        }
        try persist()
        emitUpdate()
        return imported
    }

    /// Imports at most one preferred image representation from each logical
    /// pasteboard item. Inline image data wins; an image file URL is used only
    /// when that logical item has no usable inline representation. Every result
    /// is normalized to a metadata-free PNG in the session cache.
    @discardableResult
    public func item(id: UUID) throws -> ScreenshotItem {
        guard let item = allItems.first(where: { $0.id == id }) else {
            throw ScreenshotLibraryError.screenshotNotFound(id)
        }
        return item
    }

    public func sourceIsAvailable(for id: UUID) throws -> Bool {
        let item = try item(id: id)
        if item.origin.isTransient, item.sourceURL == item.managedOriginalURL {
            return false
        }
        return fileManager.fileExists(atPath: item.sourceURL.path)
    }

    /// Returns display-ready bytes without materializing a plaintext cache
    /// file. Transient bytes are authenticated and decrypted in memory.
    public func originalImageData(for id: UUID) throws -> Data {
        let item = try item(id: id)
        return try managedOriginalData(for: item)
    }

    /// Read one full-resolution logical clipboard image without creating an
    /// edit project, changing cache eviction order, or writing annotation versions.
    public func clipboardOriginalImageData(from item: ClipboardItem, logicalIndex: Int) throws -> Data {
        guard item.payload.items.indices.contains(logicalIndex),
            let candidate = clipboardImageCandidate(from: item.payload.items[logicalIndex])
        else {
            throw AnnotationError.sourceImageUnavailable
        }
        return candidate.pngData
    }

    public func thumbnailImageData(for id: UUID) throws -> Data {
        let item = try item(id: id)
        if item.origin.isTransient {
            return try readEncryptedSessionData(from: item.thumbnailURL)
        }
        try validateManagedURL(item.thumbnailURL, within: thumbnailsDirectory)
        return try Data(contentsOf: item.thumbnailURL, options: [.mappedIfSafe])
    }

    public func annotationURL(for id: UUID) throws -> URL {
        let item = try item(id: id)
        return currentAnnotationURL(for: item)
    }

    public func copyToPasteboard(id: UUID) async throws {
        let item = try item(id: id)
        let data = try managedOriginalData(for: item)
        let succeeded = await MainActor.run {
            guard let image = NSImage(data: data),
                let tiff = image.tiffRepresentation
            else { return false }
            let pasteboardItem = NSPasteboardItem()
            guard pasteboardItem.setData(tiff, forType: .tiff),
                pasteboardItem.setString(
                    UUID().uuidString,
                    forType: SystemClipboardPasteboardClient.ownerMarkerType
                )
            else {
                return false
            }
            if let bitmap = NSBitmapImageRep(data: tiff),
                let png = bitmap.representation(using: .png, properties: [:])
            {
                _ = pasteboardItem.setData(png, forType: .png)
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            return pasteboard.writeObjects([pasteboardItem])
        }
        guard succeeded else { throw ScreenshotLibraryError.pasteboardWriteFailed }
    }

    /// Returns false when the source has since been moved/deleted. The managed
    /// history item remains usable in that case.
    @discardableResult
    public func revealSource(id: UUID) async throws -> Bool {
        let item = try item(id: id)
        guard item.origin == .watchedFolder || item.sourceURL != item.managedOriginalURL else {
            return false
        }
        guard fileManager.fileExists(atPath: item.sourceURL.path) else { return false }
        await MainActor.run {
            NSWorkspace.shared.activateFileViewerSelecting([item.sourceURL])
        }
        return true
    }

    /// Removes only app-managed history data. The selected-folder source file is
    /// intentionally never deleted or modified.
    public func removeFromHistory(id: UUID) throws {
        let item = try item(id: id)
        if item.origin == .watchedFolder {
            try validateManagedURL(item.managedOriginalURL, within: originalsDirectory)
            try validateManagedURL(item.thumbnailURL, within: thumbnailsDirectory)
        } else {
            try validateManagedURL(item.managedOriginalURL, within: sessionOriginalsDirectory)
            try validateManagedURL(item.thumbnailURL, within: sessionThumbnailsDirectory)
        }
        try removeIfPresent(item.managedOriginalURL)
        try removeIfPresent(item.thumbnailURL)
        try removeIfPresent(currentAnnotationURL(for: item))
        for version in versions(for: item) {
            try removeIfPresent(version.annotationURL)
        }
        activeEditSessions = activeEditSessions.filter { $0.value.itemID != id }
        if item.origin == .watchedFolder {
            state.items.removeAll { $0.id == id }
            state.annotationVersions.removeValue(forKey: id)
            try persist()
        } else {
            sessionItems.removeAll { $0.id == id }
            sessionAnnotationVersions.removeValue(forKey: id)
        }
        Self.logger.info("Screenshot removed from managed history")
        emitUpdate()
    }

    /// Explicit lifecycle hook for lock, logout, or app shutdown. As at init,
    /// it removes clipboard originals, thumbnails, annotations, and versions.
    public func clearTransientClipboardCache() throws {
        let transientIDs = Set(sessionItems.map(\.id))
        activeEditSessions = activeEditSessions.filter {
            !transientIDs.contains($0.value.itemID)
        }
        sessionItems.removeAll(keepingCapacity: false)
        sessionAnnotationVersions.removeAll(keepingCapacity: false)
        if fileManager.fileExists(atPath: sessionCacheDirectory.path) {
            try fileManager.removeItem(at: sessionCacheDirectory)
        }
        for directory in [
            sessionOriginalsDirectory,
            sessionThumbnailsDirectory,
            sessionAnnotationsDirectory,
            sessionVersionsDirectory,
            sessionFlattenedDirectory,
        ] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionCacheDirectory.path
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableSessionCache = sessionCacheDirectory
        try? mutableSessionCache.setResourceValues(values)
        emitUpdate()
    }

    /// Writes an annotated, flattened PNG into the managed library while the
    /// imported original and its editable JSON remain untouched.
    @discardableResult
    func fileSystemDidChange() {
        scheduleScan()
    }

    func scheduleScan() {
        guard scheduledScanTask == nil else { return }
        let delay = stabilizationPolicy.eventCoalescingDelay
        scheduledScanTask = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(for: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.performScheduledScan()
        }
    }

    func performScheduledScan() async {
        scheduledScanTask = nil
        do {
            _ = try await scanNow()
        } catch is CancellationError {
            return
        } catch {
            Self.logger.error("Screenshot folder reconciliation failed")
        }
    }

    func waitUntilStable(_ url: URL) async throws -> SourceFingerprint {
        var previous: SourceFingerprint?
        var matchingSamples = 0
        for attempt in 0..<stabilizationPolicy.maximumAttempts {
            try Task.checkCancellation()
            let current = try sourceFingerprint(for: url)
            if current == previous {
                matchingSamples += 1
            } else {
                previous = current
                matchingSamples = 1
            }
            if matchingSamples >= stabilizationPolicy.requiredMatchingSamples {
                return current
            }
            if attempt + 1 < stabilizationPolicy.maximumAttempts,
                stabilizationPolicy.pollInterval > .zero
            {
                try await Task.sleep(for: stabilizationPolicy.pollInterval)
            }
        }
        throw ScreenshotLibraryError.fileDidNotStabilize
    }

    func importStableFile(
        _ sourceURL: URL,
        fingerprint: SourceFingerprint
    ) throws -> ScreenshotItem? {
        guard let format = ScreenshotImageFormat.format(for: sourceURL) else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        let pixelSize: PixelSize
        do {
            pixelSize = try AnnotationRenderer.sourcePixelSize(at: sourceURL)
        } catch {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        let digest: String
        if fingerprint.byteCount <= Int64(TopDropCore.maximumClipboardScreenshotBytes),
            let sourceData = try? Data(contentsOf: sourceURL, options: [.mappedIfSafe]),
            let canonical = Self.canonicalPNGData(from: sourceData)
        {
            digest = contentDigest(for: canonical)
        } else {
            digest = try contentDigest(for: sourceURL)
        }
        guard !state.items.contains(where: { $0.contentDigest == digest }) else {
            return nil
        }

        let identifier = UUID()
        let managedURL = originalsDirectory.appendingPathComponent(
            "\(identifier.uuidString).\(format.preferredFilenameExtension)"
        )
        let thumbnailURL = thumbnailsDirectory.appendingPathComponent(
            "\(identifier.uuidString).png"
        )
        do {
            try fileManager.copyItem(at: sourceURL, to: managedURL)
            try Self.makeThumbnail(sourceURL: managedURL, destinationURL: thumbnailURL)
        } catch {
            try? removeIfPresent(managedURL)
            try? removeIfPresent(thumbnailURL)
            throw error
        }

        let values = try sourceURL.resourceValues(forKeys: [
            .creationDateKey,
            .contentModificationDateKey,
        ])
        let item = ScreenshotItem(
            id: identifier,
            importedAt: Date(),
            sourceCreatedAt: values.creationDate,
            sourceModifiedAt: values.contentModificationDate,
            sourceURL: sourceURL,
            sourceFilename: sourceURL.lastPathComponent,
            managedOriginalURL: managedURL,
            thumbnailURL: thumbnailURL,
            format: format,
            pixelSize: pixelSize,
            byteCount: fingerprint.byteCount,
            contentDigest: digest
        )
        state.items.insert(item, at: 0)
        removeMatchingUneditedClipboardCache(digest: digest)
        Self.logger.info("Screenshot imported; history count: \(self.state.items.count, privacy: .public)")
        return item
    }

}
