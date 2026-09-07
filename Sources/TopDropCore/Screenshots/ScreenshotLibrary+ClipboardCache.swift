import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

// Implementation details remain actor-isolated; no additional public storage API.
extension ScreenshotLibrary {
    public func importClipboardImages(from clipboardItem: ClipboardItem) throws -> [ScreenshotItem] {
        var imported: [ScreenshotItem] = []
        for (logicalIndex, payloadItem) in clipboardItem.payload.items.enumerated() {
            guard let candidate = clipboardImageCandidate(from: payloadItem) else { continue }
            if let item = cacheClipboardImageCandidate(
                candidate,
                clipboardItem: clipboardItem,
                logicalIndex: logicalIndex,
                origin: .clipboardCache
            ) {
                imported.append(item)
            }
        }

        guard !imported.isEmpty else { return [] }
        sortSessionItems()
        evictExcessClipboardCacheItems()
        let retainedIDs = Set(sessionItems.map(\.id))
        imported.removeAll { !retainedIDs.contains($0.id) }
        Self.logger.info(
            "Clipboard images retained; transientCount=\(self.sessionItems.count, privacy: .public)"
        )
        emitUpdate()
        return imported
    }

    /// Returns an ordered association for every decodable logical image in a
    /// clipboard event. Existing cache roots, edited projects, and watched
    /// screenshots are reused; missing transient roots are recreated lazily.
    public func resolveClipboardImages(
        from clipboardItem: ClipboardItem
    ) throws -> [ClipboardImageResolution] {
        _ = try importClipboardImages(from: clipboardItem)
        var resolutions: [ClipboardImageResolution] = []
        for (logicalIndex, payloadItem) in clipboardItem.payload.items.enumerated() {
            guard let candidate = clipboardImageCandidate(from: payloadItem) else { continue }
            let digest = contentDigest(for: candidate.pngData)
            guard let item = preferredItem(withDigest: digest) else { continue }
            resolutions.append(
                ClipboardImageResolution(
                    clipboardItemID: clipboardItem.id,
                    logicalIndex: logicalIndex,
                    contentDigest: digest,
                    screenshotItem: item
                ))
        }
        return resolutions
    }

    public func resolveClipboardImage(
        from clipboardItem: ClipboardItem,
        logicalIndex: Int
    ) throws -> ClipboardImageResolution? {
        guard clipboardItem.payload.items.indices.contains(logicalIndex),
            let candidate = clipboardImageCandidate(
                from: clipboardItem.payload.items[logicalIndex]
            )
        else { return nil }
        let digest = contentDigest(for: candidate.pngData)
        if let item = preferredItem(withDigest: digest) {
            return ClipboardImageResolution(
                clipboardItemID: clipboardItem.id,
                logicalIndex: logicalIndex,
                contentDigest: digest,
                screenshotItem: item
            )
        }

        // This path is reached when a visible encrypted clipboard-history row
        // outlived the ten-image rolling cache. The user is opening it to edit,
        // so recreate it as a project immediately; recreating an old cache root
        // with its original timestamp would simply evict it again.
        guard
            let item = cacheClipboardImageCandidate(
                candidate,
                clipboardItem: clipboardItem,
                logicalIndex: logicalIndex,
                origin: .clipboardProject
            )
        else { return nil }
        sortSessionItems()
        emitUpdate()
        return ClipboardImageResolution(
            clipboardItemID: clipboardItem.id,
            logicalIndex: logicalIndex,
            contentDigest: digest,
            screenshotItem: item
        )
    }

    /// Removes rolling-cache roots associated with one clipboard-history item.
    ///
    /// Resolutions are used instead of decoding the clipboard payload again so
    /// file-URL clipboard entries cannot change underneath deletion. A digest
    /// that is still referenced by another retained history item is preserved.
    /// Watched screenshots and promoted edit projects are never removed.
    @discardableResult
    public func removeUneditedClipboardCache(
        associatedWith clipboardItemID: UUID,
        resolutions: [ClipboardImageResolution],
        retainingContentDigests: Set<String> = []
    ) throws -> Set<UUID> {
        let associated = resolutions.filter {
            $0.clipboardItemID == clipboardItemID
        }
        let itemIDs = Set(associated.map(\.screenshotItem.id))
        let digests = Set(associated.map(\.contentDigest))
            .subtracting(retainingContentDigests)
        let roots = sessionItems.filter { item in
            item.origin == .clipboardCache
                && !retainingContentDigests.contains(item.contentDigest)
                && (itemIDs.contains(item.id) || digests.contains(item.contentDigest))
        }
        guard !roots.isEmpty else { return [] }

        var removedIDs = Set<UUID>()
        defer {
            if !removedIDs.isEmpty { emitUpdate() }
        }
        for item in roots {
            try removeClipboardCacheRoot(item)
            removedIDs.insert(item.id)
        }
        Self.logger.info(
            "Clipboard image cache roots removed with history item; count=\(removedIDs.count, privacy: .public)"
        )
        return removedIDs
    }

    /// Clears only the rolling, unedited clipboard-image cache. Edited
    /// projects (including their annotation aliases) and watched screenshots
    /// remain available in image history.
    @discardableResult
    public func clearUneditedClipboardCache() throws -> Set<UUID> {
        let roots = sessionItems.filter { $0.origin == .clipboardCache }
        guard !roots.isEmpty else { return [] }

        var removedIDs = Set<UUID>()
        defer {
            if !removedIDs.isEmpty { emitUpdate() }
        }
        for item in roots {
            try removeClipboardCacheRoot(item)
            removedIDs.insert(item.id)
        }
        Self.logger.info(
            "Unedited clipboard image cache cleared; count=\(removedIDs.count, privacy: .public)"
        )
        return removedIDs
    }

    var allItems: [ScreenshotItem] {
        (state.items + sessionItems).sorted { left, right in
            if left.importedAt == right.importedAt {
                return left.id.uuidString < right.id.uuidString
            }
            return left.importedAt > right.importedAt
        }
    }

    func cacheClipboardImageCandidate(
        _ candidate: ClipboardImageCandidate,
        clipboardItem: ClipboardItem,
        logicalIndex: Int,
        origin: ScreenshotItemOrigin
    ) -> ScreenshotItem? {
        let pngData = candidate.pngData
        guard pngData.count <= TopDropCore.maximumClipboardScreenshotBytes else { return nil }
        let digest = contentDigest(for: pngData)
        guard !allItems.contains(where: { $0.contentDigest == digest }) else { return nil }

        let identifier = UUID()
        let managedURL = sessionOriginalsDirectory.appendingPathComponent(
            "\(identifier.uuidString).png"
        )
        let thumbnailURL = sessionThumbnailsDirectory.appendingPathComponent(
            "\(identifier.uuidString).png"
        )
        do {
            let thumbnailData = try Self.thumbnailPNGData(sourceData: pngData)
            try writeEncryptedSessionData(pngData, to: managedURL)
            try writeEncryptedSessionData(thumbnailData, to: thumbnailURL)
        } catch {
            try? removeIfPresent(managedURL)
            try? removeIfPresent(thumbnailURL)
            Self.logger.error("A clipboard image could not be cached")
            return nil
        }

        let pixelSize: PixelSize
        do {
            pixelSize = try AnnotationRenderer.sourcePixelSize(data: pngData)
        } catch {
            try? removeIfPresent(managedURL)
            try? removeIfPresent(thumbnailURL)
            return nil
        }
        let sourceURL = candidate.sourceURL ?? managedURL
        let sourceFilename: String
        if let originalName = candidate.sourceURL?.lastPathComponent,
            !originalName.isEmpty
        {
            sourceFilename = originalName
        } else {
            sourceFilename = "Clipboard Image \(logicalIndex + 1).png"
        }
        let sourceValues: URLResourceValues? = candidate.sourceURL.flatMap {
            try? $0.resourceValues(forKeys: [
                .creationDateKey,
                .contentModificationDateKey,
            ])
        }
        let item = ScreenshotItem(
            id: identifier,
            importedAt: clipboardItem.capturedAt,
            sourceCreatedAt: sourceValues?.creationDate,
            sourceModifiedAt: sourceValues?.contentModificationDate,
            sourceURL: sourceURL,
            sourceFilename: sourceFilename,
            managedOriginalURL: managedURL,
            thumbnailURL: thumbnailURL,
            format: .png,
            pixelSize: pixelSize,
            byteCount: Int64(pngData.count),
            contentDigest: digest,
            origin: origin
        )
        sessionItems.append(item)
        return item
    }

    func sortSessionItems() {
        sessionItems.sort { left, right in
            if left.importedAt == right.importedAt {
                return left.id.uuidString < right.id.uuidString
            }
            return left.importedAt > right.importedAt
        }
    }

    func preferredItem(withDigest digest: String) -> ScreenshotItem? {
        allItems
            .filter { $0.contentDigest == digest }
            .sorted { left, right in
                let leftRank = Self.clipboardResolutionRank(left.origin)
                let rightRank = Self.clipboardResolutionRank(right.origin)
                if leftRank != rightRank { return leftRank < rightRank }
                if left.importedAt != right.importedAt { return left.importedAt > right.importedAt }
                return left.id.uuidString < right.id.uuidString
            }
            .first
    }

    static func clipboardResolutionRank(_ origin: ScreenshotItemOrigin) -> Int {
        switch origin {
        case .clipboardProject: 0
        case .clipboardCache: 1
        case .watchedFolder: 2
        }
    }

    func clipboardImageCandidate(
        from payloadItem: ClipboardPayloadItem
    ) -> ClipboardImageCandidate? {
        let inlineImages = payloadItem.representations
            .enumerated()
            .filter { $0.element.kind == .image }
            .sorted { left, right in
                let leftRank = Self.inlineImagePreference(left.element.pasteboardType)
                let rightRank = Self.inlineImagePreference(right.element.pasteboardType)
                return leftRank == rightRank ? left.offset < right.offset : leftRank < rightRank
            }
        for entry in inlineImages {
            let data = entry.element.data
            guard data.count <= TopDropCore.maximumClipboardScreenshotBytes,
                let pngData = Self.canonicalPNGData(from: data),
                pngData.count <= TopDropCore.maximumClipboardScreenshotBytes
            else {
                continue
            }
            return ClipboardImageCandidate(pngData: pngData, sourceURL: nil)
        }

        for representation in payloadItem.representations where representation.kind == .fileURL {
            guard let url = Self.fileURL(from: representation.data),
                url.isFileURL,
                let values = try? url.resourceValues(forKeys: [
                    .isRegularFileKey,
                    .fileSizeKey,
                ]),
                values.isRegularFile == true,
                let byteCount = values.fileSize,
                byteCount <= TopDropCore.maximumClipboardScreenshotBytes,
                let data = try? Data(contentsOf: url, options: [.mappedIfSafe]),
                data.count <= TopDropCore.maximumClipboardScreenshotBytes,
                let pngData = Self.canonicalPNGData(from: data),
                pngData.count <= TopDropCore.maximumClipboardScreenshotBytes
            else {
                continue
            }
            return ClipboardImageCandidate(pngData: pngData, sourceURL: url)
        }
        return nil
    }

    static func inlineImagePreference(_ pasteboardType: String) -> Int {
        guard let type = UTType(pasteboardType) else { return 10 }
        if type.conforms(to: .png) { return 0 }
        if type.conforms(to: .jpeg) { return 1 }
        if type.conforms(to: .heic) { return 2 }
        if type.conforms(to: .tiff) { return 3 }
        return 10
    }

    static func canonicalPNGData(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            return nil
        }
        let properties =
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let rawWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard rawWidth > 0, rawHeight > 0 else { return nil }
        let (pixelCount, overflow) = rawWidth.multipliedReportingOverflow(by: rawHeight)
        guard !overflow, pixelCount <= maximumDecodedClipboardPixels else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            // Asking for the full source dimension applies EXIF orientation
            // without downsampling the clipboard image.
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard
            let image = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                options as CFDictionary
            )
        else { return nil }
        let result = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                result,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    static func fileURL(from data: Data) -> URL? {
        if let string = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: string),
            url.isFileURL
        {
            return url.standardizedFileURL
        }
        if let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL {
            return url.standardizedFileURL
        }
        return nil
    }

    func evictExcessClipboardCacheItems() {
        let cacheItems =
            sessionItems
            .filter { $0.origin == .clipboardCache }
            .sorted { left, right in
                if left.importedAt == right.importedAt {
                    return left.id.uuidString < right.id.uuidString
                }
                return left.importedAt > right.importedAt
            }
        guard cacheItems.count > TopDropCore.maximumClipboardScreenshotCount else { return }
        for item in cacheItems.dropFirst(TopDropCore.maximumClipboardScreenshotCount) {
            try? removeIfPresent(item.managedOriginalURL)
            try? removeIfPresent(item.thumbnailURL)
            try? removeIfPresent(currentAnnotationURL(for: item))
            for version in sessionAnnotationVersions[item.id] ?? [] {
                try? removeIfPresent(version.annotationURL)
            }
            sessionAnnotationVersions.removeValue(forKey: item.id)
            activeEditSessions = activeEditSessions.filter { $0.value.itemID != item.id }
            sessionItems.removeAll { $0.id == item.id }
        }
    }

    /// A file created by macOS Screenshot is the durable source of truth. If
    /// the same pixels reached the clipboard first, replace only its unedited
    /// rolling-cache root; promoted edit projects remain independent.
    func removeMatchingUneditedClipboardCache(digest: String) {
        let duplicates = sessionItems.filter {
            $0.origin == .clipboardCache && $0.contentDigest == digest
        }
        for item in duplicates {
            try? removeIfPresent(item.managedOriginalURL)
            try? removeIfPresent(item.thumbnailURL)
            try? removeIfPresent(currentAnnotationURL(for: item))
            for version in sessionAnnotationVersions[item.id] ?? [] {
                try? removeIfPresent(version.annotationURL)
            }
            sessionAnnotationVersions.removeValue(forKey: item.id)
            sessionItems.removeAll { $0.id == item.id }
        }
    }

    func removeClipboardCacheRoot(_ item: ScreenshotItem) throws {
        guard item.origin == .clipboardCache,
            sessionItems.contains(where: { $0.id == item.id && $0.origin == .clipboardCache })
        else { return }
        try validateManagedURL(item.managedOriginalURL, within: sessionOriginalsDirectory)
        try validateManagedURL(item.thumbnailURL, within: sessionThumbnailsDirectory)
        try removeIfPresent(item.managedOriginalURL)
        try removeIfPresent(item.thumbnailURL)
        try removeIfPresent(currentAnnotationURL(for: item))
        for version in sessionAnnotationVersions[item.id] ?? [] {
            try removeIfPresent(version.annotationURL)
        }
        sessionAnnotationVersions.removeValue(forKey: item.id)
        activeEditSessions = activeEditSessions.filter { $0.value.itemID != item.id }
        sessionItems.removeAll { $0.id == item.id }
    }

    func promoteClipboardCacheItemToProject(id: UUID) {
        guard
            let index = sessionItems.firstIndex(where: {
                $0.id == id && $0.origin == .clipboardCache
            })
        else { return }
        let item = sessionItems[index]
        sessionItems[index] = ScreenshotItem(
            id: item.id,
            importedAt: item.importedAt,
            sourceCreatedAt: item.sourceCreatedAt,
            sourceModifiedAt: item.sourceModifiedAt,
            sourceURL: item.sourceURL,
            sourceFilename: item.sourceFilename,
            managedOriginalURL: item.managedOriginalURL,
            thumbnailURL: item.thumbnailURL,
            format: item.format,
            pixelSize: item.pixelSize,
            byteCount: item.byteCount,
            contentDigest: item.contentDigest,
            origin: .clipboardProject
        )
    }

}
