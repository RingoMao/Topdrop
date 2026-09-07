import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

// Implementation details remain actor-isolated; no additional public storage API.
extension ScreenshotLibrary {
    func sourceFingerprint(for url: URL) throws -> SourceFingerprint {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey,
        ])
        guard values.isRegularFile == true else {
            throw ScreenshotLibraryError.sourceFileMissing
        }
        return SourceFingerprint(
            byteCount: Int64(values.fileSize ?? 0),
            modifiedAt: values.contentModificationDate?.timeIntervalSince1970 ?? 0
        )
    }

    func currentFingerprints(in folder: URL) throws -> [String: SourceFingerprint] {
        var result: [String: SourceFingerprint] = [:]
        for url in try candidateURLs(in: folder) {
            if let fingerprint = try? sourceFingerprint(for: url) {
                result[url.path] = fingerprint
            }
        }
        return result
    }

    func candidateURLs(in folder: URL) throws -> [URL] {
        try fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [
                .isRegularFileKey,
                .creationDateKey,
                .contentModificationDateKey,
                .fileSizeKey,
            ],
            options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants]
        )
        .filter { ScreenshotImageFormat.format(for: $0) != nil }
        .sorted { $0.path < $1.path }
    }

    func contentDigest(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func contentDigest(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func persist() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: metadataURL, options: .atomic)
    }

    func makeSnapshot() -> ScreenshotLibrarySnapshot {
        var versions = state.annotationVersions
        for (itemID, transientVersions) in sessionAnnotationVersions {
            versions[itemID] = transientVersions
        }
        return ScreenshotLibrarySnapshot(
            selectedFolder: selectedFolder,
            isMonitoring: watcher != nil,
            items: allItems,
            annotationVersionsByItemID: versions
        )
    }

    func emitUpdate() {
        let value = makeSnapshot()
        for continuation in updateContinuations.values {
            continuation.yield(value)
        }
    }

    func removeContinuation(_ id: UUID) {
        updateContinuations.removeValue(forKey: id)
    }

    func isDirectChild(_ url: URL, of folder: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL
    }

    static func isDescendant(_ url: URL, of directory: URL) -> Bool {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath().path
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        return candidate.hasPrefix(root + "/")
    }

    func validateManagedURL(
        _ url: URL,
        within directory: URL,
        or alternate: URL? = nil
    ) throws {
        guard
            Self.isDescendant(url, of: directory)
                || alternate.map({ Self.isDescendant(url, of: $0) }) == true
        else {
            throw ScreenshotLibraryError.invalidMetadata
        }
    }

    func managedOriginalData(for item: ScreenshotItem) throws -> Data {
        if item.origin.isTransient {
            try validateManagedURL(item.managedOriginalURL, within: sessionOriginalsDirectory)
            return try readEncryptedSessionData(from: item.managedOriginalURL)
        }
        try validateManagedURL(item.managedOriginalURL, within: originalsDirectory)
        return try Data(contentsOf: item.managedOriginalURL, options: [.mappedIfSafe])
    }

    func writeEncryptedSessionData(_ plaintext: Data, to url: URL) throws {
        let allowed = [
            sessionOriginalsDirectory,
            sessionThumbnailsDirectory,
            sessionAnnotationsDirectory,
            sessionVersionsDirectory,
        ].contains { Self.isDescendant(url, of: $0) }
        guard allowed else { throw ScreenshotLibraryError.invalidMetadata }
        let sealed = try AES.GCM.seal(plaintext, using: sessionEncryptionKey)
        guard let combined = sealed.combined else {
            throw ScreenshotLibraryError.destinationUnavailable
        }
        try combined.write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableURL = url
        try? mutableURL.setResourceValues(values)
    }

    func readEncryptedSessionData(from url: URL) throws -> Data {
        guard Self.isDescendant(url, of: sessionCacheDirectory) else {
            throw ScreenshotLibraryError.invalidMetadata
        }
        let combined = try Data(contentsOf: url, options: [.mappedIfSafe])
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: sessionEncryptionKey)
    }

    func removeIfPresent(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
    }

    func safeBaseName(from filename: String) -> String {
        let value = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "Screenshot" : value
    }

    func writeCollisionSafe(
        data: Data,
        to directory: URL,
        baseName: String,
        filenameExtension: String
    ) throws -> URL {
        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let url =
                directory
                .appendingPathComponent(name)
                .appendingPathExtension(filenameExtension)
            do {
                try data.write(to: url, options: .withoutOverwriting)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ScreenshotLibraryError.destinationUnavailable
    }

    func copyCollisionSafe(
        source: URL,
        to directory: URL,
        baseName: String,
        filenameExtension: String
    ) throws -> URL {
        for suffix in 1...10_000 {
            let name = suffix == 1 ? baseName : "\(baseName) \(suffix)"
            let url =
                directory
                .appendingPathComponent(name)
                .appendingPathExtension(filenameExtension)
            do {
                try fileManager.copyItem(at: source, to: url)
                return url
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw ScreenshotLibraryError.destinationUnavailable
    }

    static func makeThumbnail(sourceURL: URL, destinationURL: URL) throws {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            ),
            let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
    }

    static func thumbnailPNGData(sourceData: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(sourceData as CFData, nil),
            let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source,
                0,
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 480,
                    kCGImageSourceShouldCacheImmediately: true,
                ] as CFDictionary
            )
        else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        let result = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                result,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ScreenshotLibraryError.unsupportedImageFormat
        }
        return result as Data
    }
}
