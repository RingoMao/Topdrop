@preconcurrency import AppKit
import Combine
import Foundation
import TopDropCore

@MainActor
final class ScreenshotViewModel: ObservableObject {
    @Published private(set) var snapshot = ScreenshotLibrarySnapshot(
        selectedFolder: nil,
        isMonitoring: false,
        items: []
    )
    @Published var statusMessage: String?
    @Published private(set) var isBusy = false
    @Published private(set) var clipboardImageResolutions: [UUID: [ClipboardImageResolution]] = [:]

    let library: ScreenshotLibrary

    private unowned let settings: AppSettingsModel
    private var updateTask: Task<Void, Never>?
    private var clipboardCacheEpoch = 0
    private var discardedClipboardItemIDs = Set<UUID>()
    private var isClearingClipboardHistoryCache = false

    init(library: ScreenshotLibrary, settings: AppSettingsModel) {
        self.library = library
        self.settings = settings
    }

    deinit {
        updateTask?.cancel()
    }

    func start() async {
        if updateTask == nil {
            let updates = await library.updates()
            updateTask = Task { [weak self] in
                for await snapshot in updates {
                    guard !Task.isCancelled else { return }
                    self?.snapshot = snapshot
                }
            }
        }
        guard let url = settings.resolvedScreenshotFolder() else { return }
        await configure(folder: url, importExisting: false)
    }

    func stop() async {
        updateTask?.cancel()
        updateTask = nil
        await library.stopMonitoring()
        do {
            try await library.clearTransientClipboardCache()
        } catch {
            statusMessage = message(for: error)
        }
    }

    func configure(folder: URL, importExisting: Bool = false) async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await library.configureSourceFolder(
                folder,
                importExisting: importExisting,
                startMonitoring: true
            )
            snapshot = await library.snapshot()
            statusMessage =
                importExisting
                ? "Existing screenshots imported."
                : "Watching for new screenshots."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func importExisting() async {
        isBusy = true
        defer { isBusy = false }
        do {
            _ = try await library.importExistingScreenshots()
            snapshot = await library.snapshot()
            statusMessage = "Existing screenshot scan finished."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func cacheClipboardImages(from item: ClipboardItem) async {
        guard !isClearingClipboardHistoryCache,
            !discardedClipboardItemIDs.contains(item.id)
        else { return }
        let startingEpoch = clipboardCacheEpoch
        do {
            let previousIDs = Set(snapshot.items.map(\.id))
            let resolutions = try await library.resolveClipboardImages(from: item)
            guard !resolutions.isEmpty else { return }
            guard startingEpoch == clipboardCacheEpoch,
                !discardedClipboardItemIDs.contains(item.id),
                !isClearingClipboardHistoryCache
            else {
                _ = try await library.removeUneditedClipboardCache(
                    associatedWith: item.id,
                    resolutions: resolutions,
                    retainingContentDigests: retainedClipboardDigests()
                )
                snapshot = await library.snapshot()
                return
            }
            clipboardImageResolutions[item.id] = resolutions
            snapshot = await library.snapshot()
            let importedCount = resolutions.reduce(into: 0) { count, resolution in
                if !previousIDs.contains(resolution.screenshotItem.id) { count += 1 }
            }
            if importedCount > 0 {
                let noun = importedCount == 1 ? "image" : "images"
                statusMessage = "Cached \(importedCount) clipboard \(noun) for this session."
            }
        } catch {
            statusMessage = message(for: error)
        }
    }

    /// Resolves an image row at click time. This recreates an evicted transient
    /// cache root from encrypted clipboard history without eagerly extending
    /// the ten-image rolling cache.
    func resolveClipboardImage(
        from item: ClipboardItem,
        logicalIndex: Int
    ) async -> ScreenshotItem? {
        do {
            guard
                let resolution = try await library.resolveClipboardImage(
                    from: item,
                    logicalIndex: logicalIndex
                )
            else {
                statusMessage = "That clipboard image could not be decoded for editing."
                return nil
            }
            var current = clipboardImageResolutions[item.id] ?? []
            current.removeAll { $0.logicalIndex == logicalIndex }
            current.append(resolution)
            current.sort { $0.logicalIndex < $1.logicalIndex }
            clipboardImageResolutions[item.id] = current
            snapshot = await library.snapshot()
            if let latest = snapshot.items.first(where: {
                $0.contentDigest == resolution.contentDigest
            }) {
                return latest
            }
            return resolution.screenshotItem
        } catch {
            statusMessage = message(for: error)
            return nil
        }
    }

    /// Removes only the unedited image-cache roots owned exclusively by this
    /// history row. Cleanup completes before the caller deletes encrypted
    /// clipboard history, so a file-system error cannot silently split the two
    /// privacy operations.
    func removeClipboardCache(
        for item: ClipboardItem,
        retainingClipboardItemIDs: Set<UUID>
    ) async -> Bool {
        discardedClipboardItemIDs.insert(item.id)
        let associated = clipboardImageResolutions[item.id] ?? []
        let retainedDigests = Set(
            clipboardImageResolutions
                .filter { retainingClipboardItemIDs.contains($0.key) }
                .flatMap { $0.value.map(\.contentDigest) }
        )
        do {
            _ = try await library.removeUneditedClipboardCache(
                associatedWith: item.id,
                resolutions: associated,
                retainingContentDigests: retainedDigests
            )
            clipboardImageResolutions = clipboardImageResolutions.filter {
                retainingClipboardItemIDs.contains($0.key)
            }
            snapshot = await library.snapshot()
            statusMessage = nil
            return true
        } catch {
            discardedClipboardItemIDs.remove(item.id)
            snapshot = await library.snapshot()
            statusMessage = message(for: error)
            return false
        }
    }

    /// Clears the unedited image cache while deliberately retaining edited
    /// clipboard projects and their annotation versions.
    func clearClipboardHistoryCache(removingClipboardItemIDs: Set<UUID>) async -> Bool {
        clipboardCacheEpoch &+= 1
        let newlyDiscarded =
            removingClipboardItemIDs
            .union(clipboardImageResolutions.keys)
            .subtracting(discardedClipboardItemIDs)
        discardedClipboardItemIDs.formUnion(newlyDiscarded)
        isClearingClipboardHistoryCache = true
        defer { isClearingClipboardHistoryCache = false }
        do {
            _ = try await library.clearUneditedClipboardCache()
            clipboardImageResolutions.removeAll(keepingCapacity: false)
            snapshot = await library.snapshot()
            statusMessage = nil
            return true
        } catch {
            discardedClipboardItemIDs.subtract(newlyDiscarded)
            snapshot = await library.snapshot()
            statusMessage = message(for: error)
            return false
        }
    }

    func copy(_ item: ScreenshotItem) async {
        do {
            try await library.copyToPasteboard(id: item.id)
            statusMessage = "Screenshot copied."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func thumbnail(for item: ScreenshotItem) async -> NSImage? {
        guard let data = try? await library.thumbnailImageData(for: item.id) else { return nil }
        return NSImage(data: data)
    }

    func reveal(_ item: ScreenshotItem) async {
        do {
            let revealed = try await library.revealSource(id: item.id)
            statusMessage = revealed ? nil : "The source file is missing; the managed original remains available."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func remove(_ item: ScreenshotItem) async {
        do {
            try await library.removeFromHistory(id: item.id)
            snapshot = await library.snapshot()
        } catch {
            statusMessage = message(for: error)
        }
    }

    func saveCopy(_ item: ScreenshotItem) async {
        do {
            let annotations = try await library.loadAnnotations(for: item.id)
            let url = try await library.saveCopy(id: item.id, annotations: annotations)
            statusMessage = "Saved flattened PNG as \(url.lastPathComponent)."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func downloadToDesktop(_ item: ScreenshotItem) async {
        do {
            let annotations = try await library.loadAnnotations(for: item.id)
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
            let url = try await library.downloadToDesktop(
                id: item.id,
                annotations: annotations.annotations.isEmpty ? nil : annotations,
                destinationDirectory: desktop
            )
            statusMessage = "Downloaded \(url.lastPathComponent) to Desktop."
        } catch {
            statusMessage = message(for: error)
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }

    private func retainedClipboardDigests() -> Set<String> {
        Set(
            clipboardImageResolutions.values.flatMap { resolutions in
                resolutions.map(\.contentDigest)
            })
    }
}
