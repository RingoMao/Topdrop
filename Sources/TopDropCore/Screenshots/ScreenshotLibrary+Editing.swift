import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import UniformTypeIdentifiers

// Implementation details remain actor-isolated; no additional public storage API.
extension ScreenshotLibrary {
    public func loadAnnotations(for id: UUID) throws -> AnnotationDocumentSnapshot {
        let item = try item(id: id)
        let url = currentAnnotationURL(for: item)
        guard fileManager.fileExists(atPath: url.path) else {
            return AnnotationDocumentSnapshot(sourcePixelSize: item.pixelSize)
        }
        let snapshot = try decodeAnnotationSnapshot(at: url, for: item)
        try snapshot.validate()
        guard snapshot.sourcePixelSize == item.pixelSize else {
            throw AnnotationError.sourceImageSizeMismatch(
                expected: item.pixelSize,
                actual: snapshot.sourcePixelSize
            )
        }
        return snapshot
    }

    public func saveAnnotations(
        _ snapshot: AnnotationDocumentSnapshot,
        for id: UUID
    ) throws {
        let item = try item(id: id)
        try validate(snapshot: snapshot, for: item)
        let previous = try loadAnnotations(for: id)
        guard previous != snapshot else { return }
        try writeAnnotations(snapshot, for: item)
        if item.origin == .clipboardCache {
            promoteClipboardCacheItemToProject(id: id)
        }
        emitUpdate()
    }

    /// Starts one logical editing session. The token should be retained by the
    /// editor and supplied to every autosave until that editor closes.
    public func beginEditSession(for id: UUID) throws -> ScreenshotEditSession {
        let selectedItem = try item(id: id)
        if selectedItem.origin == .clipboardCache {
            promoteClipboardCacheItemToProject(id: id)
            emitUpdate()
        }
        let session = ScreenshotEditSession(itemID: id)
        activeEditSessions[session.id] = ActiveEditSession(itemID: id)
        return session
    }

    /// Saves editable annotations and archives the state that existed before
    /// the session's first real mutation. Repeated autosaves in the same
    /// session update the live document without producing version spam.
    public func saveAnnotations(
        _ snapshot: AnnotationDocumentSnapshot,
        for id: UUID,
        editSession: ScreenshotEditSession
    ) throws {
        guard editSession.itemID == id,
            var activeSession = activeEditSessions[editSession.id],
            activeSession.itemID == id
        else {
            throw ScreenshotLibraryError.invalidEditSession
        }
        let item = try item(id: id)
        try validate(snapshot: snapshot, for: item)
        let previous = try loadAnnotations(for: id)
        guard previous != snapshot else { return }

        var newVersion: ScreenshotAnnotationVersion?
        if !activeSession.didArchiveInitialVersion {
            newVersion = try archiveAnnotationSnapshot(previous, for: item)
        }
        do {
            try writeAnnotations(snapshot, for: item)
            if !activeSession.didArchiveInitialVersion, item.origin == .watchedFolder {
                try persist()
            }
        } catch {
            // Keep the live document and version index as one logical commit.
            // A metadata failure must not strand a version pointer or replace
            // annotations without recording their pre-edit state.
            try? writeAnnotations(previous, for: item)
            if let newVersion {
                try? discardAnnotationVersion(newVersion, persistState: false)
            }
            throw error
        }

        if !activeSession.didArchiveInitialVersion {
            activeSession.didArchiveInitialVersion = true
            activeEditSessions[editSession.id] = activeSession
        }
        if item.origin == .clipboardCache {
            promoteClipboardCacheItemToProject(id: id)
        }
        emitUpdate()
    }

    public func endEditSession(_ editSession: ScreenshotEditSession) {
        activeEditSessions.removeValue(forKey: editSession.id)
    }

    public func annotationVersions(for id: UUID) throws -> [ScreenshotAnnotationVersion] {
        let item = try item(id: id)
        return versions(for: item).sorted { $0.createdAt > $1.createdAt }
    }

    /// Restoring a version first archives the current live document, making
    /// restore itself reversible without adding another image to history.
    @discardableResult
    public func restoreAnnotationVersion(
        id versionID: UUID,
        for itemID: UUID
    ) throws -> AnnotationDocumentSnapshot {
        let item = try item(id: itemID)
        guard let version = versions(for: item).first(where: { $0.id == versionID }) else {
            throw ScreenshotLibraryError.annotationVersionNotFound(versionID)
        }
        let restored = try decodeAnnotationSnapshot(at: version.annotationURL, for: item)
        let current = try loadAnnotations(for: itemID)
        let rollbackVersion = try archiveAnnotationSnapshot(current, for: item)
        do {
            try writeAnnotations(restored, for: item)
            if item.origin == .watchedFolder {
                try persist()
            }
        } catch {
            try? writeAnnotations(current, for: item)
            try? discardAnnotationVersion(rollbackVersion, persistState: false)
            throw error
        }
        if item.origin == .clipboardCache {
            promoteClipboardCacheItemToProject(id: itemID)
        }
        emitUpdate()
        return restored
    }

    /// Writes a flattened PNG without changing the original or editable JSON.
    @discardableResult
    public func saveCopy(
        id: UUID,
        annotations snapshot: AnnotationDocumentSnapshot
    ) throws -> URL {
        let item = try item(id: id)
        try validate(snapshot: snapshot, for: item)
        let data = try AnnotationRenderer.flattenedPNGData(
            sourceImageData: managedOriginalData(for: item),
            snapshot: snapshot
        )
        let baseName = safeBaseName(from: item.sourceFilename) + " Annotated"
        return try writeCollisionSafe(
            data: data,
            to: flattenedDirectory,
            baseName: baseName,
            filenameExtension: "png"
        )
    }

    /// Produces a flattened representation without modifying the managed
    /// original or editable annotation JSON. Callers use this for clipboard
    /// replacement and explicit Save-panel exports.
    public func flattenedData(
        id: UUID,
        annotations snapshot: AnnotationDocumentSnapshot,
        format: AnnotationExportFormat
    ) throws -> Data {
        let item = try item(id: id)
        try validate(snapshot: snapshot, for: item)
        let sourceData = try managedOriginalData(for: item)
        switch format {
        case .png:
            return try AnnotationRenderer.flattenedPNGData(
                sourceImageData: sourceData,
                snapshot: snapshot
            )
        case .pdf:
            return try AnnotationRenderer.flattenedPDFData(
                sourceImageData: sourceData,
                snapshot: snapshot
            )
        }
    }

    @discardableResult
    public func export(
        id: UUID,
        annotations snapshot: AnnotationDocumentSnapshot,
        format: AnnotationExportFormat,
        destinationURL: URL
    ) throws -> URL {
        let data = try flattenedData(id: id, annotations: snapshot, format: format)
        try data.write(to: destinationURL, options: .atomic)
        return destinationURL
    }

    /// Exports either the untouched managed original or, when supplied, a
    /// flattened annotated PNG. A destination argument supports tests and a
    /// future Save panel; nil means the user's Desktop.
    @discardableResult
    public func downloadToDesktop(
        id: UUID,
        annotations snapshot: AnnotationDocumentSnapshot? = nil,
        destinationDirectory: URL? = nil
    ) throws -> URL {
        let item = try item(id: id)
        let destination: URL
        if let destinationDirectory {
            destination = destinationDirectory
        } else {
            guard
                let desktop = fileManager.urls(
                    for: .desktopDirectory,
                    in: .userDomainMask
                ).first
            else {
                throw ScreenshotLibraryError.destinationUnavailable
            }
            destination = desktop
        }
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: destination.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw ScreenshotLibraryError.destinationUnavailable
        }

        let baseName = safeBaseName(from: item.sourceFilename)
        if let snapshot {
            try validate(snapshot: snapshot, for: item)
            let data = try AnnotationRenderer.flattenedPNGData(
                sourceImageData: managedOriginalData(for: item),
                snapshot: snapshot
            )
            return try writeCollisionSafe(
                data: data,
                to: destination,
                baseName: baseName + " Annotated",
                filenameExtension: "png"
            )
        }
        if item.origin.isTransient {
            return try writeCollisionSafe(
                data: managedOriginalData(for: item),
                to: destination,
                baseName: baseName,
                filenameExtension: item.format.preferredFilenameExtension
            )
        }
        try validateManagedURL(item.managedOriginalURL, within: originalsDirectory)
        return try copyCollisionSafe(
            source: item.managedOriginalURL,
            to: destination,
            baseName: baseName,
            filenameExtension: item.format.preferredFilenameExtension
        )
    }

    func currentAnnotationURL(for item: ScreenshotItem) -> URL {
        let directory =
            item.origin.isTransient
            ? sessionAnnotationsDirectory
            : annotationsDirectory
        return directory.appendingPathComponent("\(item.id.uuidString).json")
    }

    func writeAnnotations(
        _ snapshot: AnnotationDocumentSnapshot,
        for item: ScreenshotItem
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        if item.origin.isTransient {
            try writeEncryptedSessionData(data, to: currentAnnotationURL(for: item))
        } else {
            try data.write(to: currentAnnotationURL(for: item), options: .atomic)
        }
    }

    func decodeAnnotationSnapshot(
        at url: URL,
        for item: ScreenshotItem
    ) throws -> AnnotationDocumentSnapshot {
        let data: Data
        if item.origin.isTransient {
            try validateManagedURL(url, within: sessionAnnotationsDirectory, or: sessionVersionsDirectory)
            data = try readEncryptedSessionData(from: url)
        } else {
            try validateManagedURL(url, within: annotationsDirectory)
            data = try Data(contentsOf: url)
        }
        let snapshot = try JSONDecoder().decode(AnnotationDocumentSnapshot.self, from: data)
        try validate(snapshot: snapshot, for: item)
        return snapshot
    }

    func archiveAnnotationSnapshot(
        _ snapshot: AnnotationDocumentSnapshot,
        for item: ScreenshotItem
    ) throws -> ScreenshotAnnotationVersion {
        try validate(snapshot: snapshot, for: item)
        let identifier = UUID()
        let directory =
            item.origin.isTransient
            ? sessionVersionsDirectory
            : annotationVersionsDirectory
        let url = directory.appendingPathComponent(
            "\(item.id.uuidString)-\(identifier.uuidString).json"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        if item.origin.isTransient {
            try writeEncryptedSessionData(data, to: url)
        } else {
            try data.write(to: url, options: .withoutOverwriting)
        }
        let version = ScreenshotAnnotationVersion(
            id: identifier,
            itemID: item.id,
            annotationURL: url,
            annotationCount: snapshot.annotations.count
        )
        if item.origin.isTransient {
            sessionAnnotationVersions[item.id, default: []].insert(version, at: 0)
        } else {
            state.annotationVersions[item.id, default: []].insert(version, at: 0)
        }
        return version
    }

    func discardAnnotationVersion(
        _ version: ScreenshotAnnotationVersion,
        persistState: Bool
    ) throws {
        try removeIfPresent(version.annotationURL)
        state.annotationVersions[version.itemID]?.removeAll { $0.id == version.id }
        sessionAnnotationVersions[version.itemID]?.removeAll { $0.id == version.id }
        if state.annotationVersions[version.itemID]?.isEmpty == true {
            state.annotationVersions.removeValue(forKey: version.itemID)
        }
        if sessionAnnotationVersions[version.itemID]?.isEmpty == true {
            sessionAnnotationVersions.removeValue(forKey: version.itemID)
        }
        if persistState {
            try persist()
        }
    }

    func versions(for item: ScreenshotItem) -> [ScreenshotAnnotationVersion] {
        if item.origin.isTransient {
            return sessionAnnotationVersions[item.id] ?? []
        }
        return state.annotationVersions[item.id] ?? []
    }

    func validate(
        snapshot: AnnotationDocumentSnapshot,
        for item: ScreenshotItem
    ) throws {
        try snapshot.validate()
        guard snapshot.sourcePixelSize == item.pixelSize else {
            throw AnnotationError.sourceImageSizeMismatch(
                expected: item.pixelSize,
                actual: snapshot.sourcePixelSize
            )
        }
    }

}
