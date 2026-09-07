import Foundation

public enum UnifiedMediaFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case text
    case images

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .all: "All"
        case .text: "Text"
        case .images: "Images"
        }
    }
}

public struct UnifiedMediaImageEntry: Equatable, Sendable {
    public let clipboardItem: ClipboardItem?
    public let logicalIndex: Int?
    public let contentDigest: String?
    public let screenshotItem: ScreenshotItem?
    public let occurredAt: Date

    public init(
        clipboardItem: ClipboardItem?,
        logicalIndex: Int?,
        contentDigest: String?,
        screenshotItem: ScreenshotItem?,
        occurredAt: Date
    ) {
        self.clipboardItem = clipboardItem
        self.logicalIndex = logicalIndex
        self.contentDigest = contentDigest
        self.screenshotItem = screenshotItem
        self.occurredAt = occurredAt
    }

    public var id: String {
        if let clipboardItem, let logicalIndex {
            return "clipboard-image:\(clipboardItem.id.uuidString):\(logicalIndex)"
        }
        if let screenshotItem {
            return "screenshot:\(screenshotItem.id.uuidString)"
        }
        return "image:\(occurredAt.timeIntervalSinceReferenceDate)"
    }

    public var isWatchedScreenshot: Bool {
        screenshotItem?.origin == .watchedFolder
    }
}

public enum UnifiedMediaFeedEntry: Equatable, Identifiable, Sendable {
    case clipboard(ClipboardItem)
    case image(UnifiedMediaImageEntry)

    public var id: String {
        switch self {
        case let .clipboard(item): "clipboard:\(item.id.uuidString)"
        case let .image(item): item.id
        }
    }

    public var occurredAt: Date {
        switch self {
        case let .clipboard(item): item.activityDate
        case let .image(item): item.occurredAt
        }
    }
}

/// Pure merge logic for the Clipboard & Images workspace. Clipboard-backed
/// images become image rows instead of appearing once as a clip and again as a
/// screenshot-cache item. Content digests preserve that relationship when a
/// transient root is replaced or recreated.
public enum UnifiedMediaFeedBuilder {
    public static func build(
        clipboardItems: [ClipboardItem],
        screenshotItems: [ScreenshotItem],
        resolutions: [UUID: [ClipboardImageResolution]],
        filter: UnifiedMediaFilter,
        excludingClipboardItemID: UUID? = nil
    ) -> [UnifiedMediaFeedEntry] {
        let screenshotsByDigest = Dictionary(grouping: screenshotItems, by: \.contentDigest)
        let excludedManagedScreenshotIDs = Set(
            excludingClipboardItemID
                .flatMap { resolutions[$0] }?
                .compactMap { resolution in
                    resolution.screenshotItem.origin == .watchedFolder
                        ? nil
                        : resolution.screenshotItem.id
                } ?? []
        )
        var representedScreenshotIDs = excludedManagedScreenshotIDs
        var entries: [UnifiedMediaFeedEntry] = []

        for clipboardItem in clipboardItems where clipboardItem.id != excludingClipboardItemID {
            let known = (resolutions[clipboardItem.id] ?? [])
                .sorted { $0.logicalIndex < $1.logicalIndex }
            let logicalIndices = Array(
                Set(
                    known.map(\.logicalIndex) + probableImageLogicalIndices(in: clipboardItem)
                )
            ).sorted()

            guard !logicalIndices.isEmpty else {
                entries.append(.clipboard(clipboardItem))
                continue
            }

            let knownByIndex = Dictionary(
                known.map { ($0.logicalIndex, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for logicalIndex in logicalIndices {
                let resolution = knownByIndex[logicalIndex]
                let candidates =
                    resolution.flatMap {
                        screenshotsByDigest[$0.contentDigest]
                    } ?? []
                let screenshot = preferredScreenshot(
                    among: candidates,
                    originallyResolved: resolution?.screenshotItem
                )
                representedScreenshotIDs.formUnion(candidates.map(\.id))
                entries.append(
                    .image(
                        UnifiedMediaImageEntry(
                            clipboardItem: clipboardItem,
                            logicalIndex: logicalIndex,
                            contentDigest: resolution?.contentDigest,
                            screenshotItem: screenshot,
                            occurredAt: clipboardItem.activityDate
                        )))
            }
        }

        for screenshot in screenshotItems where !representedScreenshotIDs.contains(screenshot.id) {
            entries.append(
                .image(
                    UnifiedMediaImageEntry(
                        clipboardItem: nil,
                        logicalIndex: nil,
                        contentDigest: screenshot.contentDigest,
                        screenshotItem: screenshot,
                        occurredAt: screenshot.importedAt
                    )))
        }

        return
            entries
            .filter { entry in includes(entry, in: filter) }
            .sorted { left, right in
                if left.occurredAt == right.occurredAt { return left.id < right.id }
                return left.occurredAt > right.occurredAt
            }
    }

    private static func probableImageLogicalIndices(in item: ClipboardItem) -> [Int] {
        let indices = item.payload.items.enumerated().compactMap { index, payloadItem in
            payloadItem.representations.contains(where: { $0.kind == .image }) ? index : nil
        }
        if !indices.isEmpty { return indices }
        return item.preview.kind == .image && !item.payload.items.isEmpty ? [0] : []
    }

    private static func preferredScreenshot(
        among candidates: [ScreenshotItem],
        originallyResolved: ScreenshotItem?
    ) -> ScreenshotItem? {
        guard !candidates.isEmpty else { return nil }
        if let originallyResolved,
            let current = candidates.first(where: { $0.id == originallyResolved.id })
        {
            return current
        }
        return candidates.sorted { left, right in
            let leftRank = originRank(left.origin)
            let rightRank = originRank(right.origin)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.importedAt != right.importedAt { return left.importedAt > right.importedAt }
            return left.id.uuidString < right.id.uuidString
        }.first
    }

    private static func originRank(_ origin: ScreenshotItemOrigin) -> Int {
        switch origin {
        case .clipboardProject: 0
        case .clipboardCache: 1
        case .watchedFolder: 2
        }
    }

    private static func includes(
        _ entry: UnifiedMediaFeedEntry,
        in filter: UnifiedMediaFilter
    ) -> Bool {
        switch (filter, entry) {
        case (.all, _): true
        case (.text, .clipboard): true
        case (.images, .image): true
        default: false
        }
    }
}
