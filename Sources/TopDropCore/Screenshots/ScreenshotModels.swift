import Foundation

public enum ScreenshotImageFormat: String, Codable, CaseIterable, Sendable {
    case png
    case jpeg
    case heic
    case tiff

    public var preferredFilenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .tiff: "tiff"
        }
    }

    public static func format(for url: URL) -> ScreenshotImageFormat? {
        switch url.pathExtension.lowercased() {
        case "png": .png
        case "jpg", "jpeg": .jpeg
        case "heic", "heif": .heic
        case "tif", "tiff": .tiff
        default: nil
        }
    }
}

/// Describes why an image appears in the Screenshots column and, importantly,
/// which retention rules apply to it.
public enum ScreenshotItemOrigin: String, Codable, CaseIterable, Sendable {
    /// A durable import copied from the user-selected screenshot-only folder.
    case watchedFolder
    /// An unedited clipboard image in the ten-item, session-only rolling cache.
    case clipboardCache
    /// A clipboard image promoted out of the rolling count after it is edited.
    /// Projects remain session-only and are removed when TopDrop next launches.
    case clipboardProject

    public var isTransient: Bool {
        self != .watchedFolder
    }
}

public struct ScreenshotItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let importedAt: Date
    public let sourceCreatedAt: Date?
    public let sourceModifiedAt: Date?
    public let sourceURL: URL
    public let sourceFilename: String
    public let managedOriginalURL: URL
    public let thumbnailURL: URL
    public let format: ScreenshotImageFormat
    public let pixelSize: PixelSize
    public let byteCount: Int64
    /// Hex SHA-256 used for deduplication. It is never included in diagnostics.
    public let contentDigest: String
    public let origin: ScreenshotItemOrigin

    public init(
        id: UUID,
        importedAt: Date,
        sourceCreatedAt: Date?,
        sourceModifiedAt: Date?,
        sourceURL: URL,
        sourceFilename: String,
        managedOriginalURL: URL,
        thumbnailURL: URL,
        format: ScreenshotImageFormat,
        pixelSize: PixelSize,
        byteCount: Int64,
        contentDigest: String,
        origin: ScreenshotItemOrigin = .watchedFolder
    ) {
        self.id = id
        self.importedAt = importedAt
        self.sourceCreatedAt = sourceCreatedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceURL = sourceURL
        self.sourceFilename = sourceFilename
        self.managedOriginalURL = managedOriginalURL
        self.thumbnailURL = thumbnailURL
        self.format = format
        self.pixelSize = pixelSize
        self.byteCount = byteCount
        self.contentDigest = contentDigest
        self.origin = origin
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case importedAt
        case sourceCreatedAt
        case sourceModifiedAt
        case sourceURL
        case sourceFilename
        case managedOriginalURL
        case thumbnailURL
        case format
        case pixelSize
        case byteCount
        case contentDigest
        case origin
    }

    /// Metadata written before clipboard images were supported has no origin.
    /// Those records necessarily came from the watched folder.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        importedAt = try container.decode(Date.self, forKey: .importedAt)
        sourceCreatedAt = try container.decodeIfPresent(Date.self, forKey: .sourceCreatedAt)
        sourceModifiedAt = try container.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
        sourceURL = try container.decode(URL.self, forKey: .sourceURL)
        sourceFilename = try container.decode(String.self, forKey: .sourceFilename)
        managedOriginalURL = try container.decode(URL.self, forKey: .managedOriginalURL)
        thumbnailURL = try container.decode(URL.self, forKey: .thumbnailURL)
        format = try container.decode(ScreenshotImageFormat.self, forKey: .format)
        pixelSize = try container.decode(PixelSize.self, forKey: .pixelSize)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        contentDigest = try container.decode(String.self, forKey: .contentDigest)
        origin =
            try container.decodeIfPresent(ScreenshotItemOrigin.self, forKey: .origin)
            ?? .watchedFolder
    }
}

/// An immutable pointer to an annotation snapshot that existed immediately
/// before an edit session first changed an image. The alias does not represent
/// another screenshot and therefore never participates in image retention.
public struct ScreenshotAnnotationVersion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let itemID: UUID
    public let createdAt: Date
    public let annotationURL: URL
    public let annotationCount: Int

    public init(
        id: UUID = UUID(),
        itemID: UUID,
        createdAt: Date = Date(),
        annotationURL: URL,
        annotationCount: Int
    ) {
        self.id = id
        self.itemID = itemID
        self.createdAt = createdAt
        self.annotationURL = annotationURL
        self.annotationCount = annotationCount
    }
}

/// A token scoped to one open editor session. Supplying it to annotation saves
/// ensures the pre-edit state is archived once, not once per autosave.
public struct ScreenshotEditSession: Identifiable, Hashable, Sendable {
    public let id: UUID
    public let itemID: UUID

    init(id: UUID = UUID(), itemID: UUID) {
        self.id = id
        self.itemID = itemID
    }
}

public struct ScreenshotLibrarySnapshot: Equatable, Sendable {
    public let selectedFolder: URL?
    public let isMonitoring: Bool
    public let items: [ScreenshotItem]
    public let annotationVersionsByItemID: [UUID: [ScreenshotAnnotationVersion]]

    public init(
        selectedFolder: URL?,
        isMonitoring: Bool,
        items: [ScreenshotItem],
        annotationVersionsByItemID: [UUID: [ScreenshotAnnotationVersion]] = [:]
    ) {
        self.selectedFolder = selectedFolder
        self.isMonitoring = isMonitoring
        self.items = items
        self.annotationVersionsByItemID = annotationVersionsByItemID
    }

    public func annotationVersions(for itemID: UUID) -> [ScreenshotAnnotationVersion] {
        annotationVersionsByItemID[itemID] ?? []
    }

    public func annotationVersionCount(for itemID: UUID) -> Int {
        annotationVersionsByItemID[itemID]?.count ?? 0
    }
}

/// Connects one logical image in a multi-item clipboard event to the managed
/// image TopDrop can display and edit. The digest deliberately carries no
/// clipboard bytes; it lets presentation code recover the current item after
/// cache eviction, promotion, or replacement by a watched screenshot.
public struct ClipboardImageResolution: Equatable, Sendable {
    public let clipboardItemID: UUID
    public let logicalIndex: Int
    public let contentDigest: String
    public let screenshotItem: ScreenshotItem

    public init(
        clipboardItemID: UUID,
        logicalIndex: Int,
        contentDigest: String,
        screenshotItem: ScreenshotItem
    ) {
        self.clipboardItemID = clipboardItemID
        self.logicalIndex = logicalIndex
        self.contentDigest = contentDigest
        self.screenshotItem = screenshotItem
    }
}

public struct ScreenshotStabilizationPolicy: Equatable, Sendable {
    public var pollInterval: Duration
    public var requiredMatchingSamples: Int
    public var maximumAttempts: Int
    public var eventCoalescingDelay: Duration

    public init(
        pollInterval: Duration = .milliseconds(250),
        requiredMatchingSamples: Int = 3,
        maximumAttempts: Int = 60,
        eventCoalescingDelay: Duration = .milliseconds(150)
    ) {
        self.pollInterval = pollInterval
        self.requiredMatchingSamples = max(1, requiredMatchingSamples)
        self.maximumAttempts = max(1, maximumAttempts)
        self.eventCoalescingDelay = eventCoalescingDelay
    }

    public static let immediateForTesting = ScreenshotStabilizationPolicy(
        pollInterval: .zero,
        requiredMatchingSamples: 1,
        maximumAttempts: 1,
        eventCoalescingDelay: .zero
    )
}

public enum ScreenshotLibraryError: Error, LocalizedError, Sendable {
    case sourceFolderNotConfigured
    case sourceFolderUnavailable
    case fileOutsideSelectedFolder
    case unsupportedImageFormat
    case fileDidNotStabilize
    case screenshotNotFound(UUID)
    case sourceFileMissing
    case pasteboardWriteFailed
    case destinationUnavailable
    case invalidMetadata
    case invalidEditSession
    case annotationVersionNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .sourceFolderNotConfigured:
            "Choose the folder used exclusively for macOS screenshots first."
        case .sourceFolderUnavailable:
            "The selected screenshot folder is unavailable."
        case .fileOutsideSelectedFolder:
            "Only files inside the selected screenshot folder can be imported."
        case .unsupportedImageFormat:
            "TopDrop supports PNG, JPEG, HEIC, and TIFF screenshots."
        case .fileDidNotStabilize:
            "The screenshot was still being written and could not be imported yet."
        case let .screenshotNotFound(id):
            "Screenshot \(id) is no longer in history."
        case .sourceFileMissing:
            "The original screenshot file has been moved or deleted."
        case .pasteboardWriteFailed:
            "The screenshot could not be copied to the pasteboard."
        case .destinationUnavailable:
            "The destination folder is unavailable."
        case .invalidMetadata:
            "The screenshot library metadata is invalid."
        case .invalidEditSession:
            "That screenshot editing session is no longer active."
        case let .annotationVersionNotFound(id):
            "Annotation version \(id) is no longer available."
        }
    }
}
