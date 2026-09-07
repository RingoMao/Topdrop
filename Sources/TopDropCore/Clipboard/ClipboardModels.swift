import Foundation

/// The state macOS exposes for programmatic access to the general pasteboard.
public enum ClipboardAccessState: String, Codable, Sendable {
    /// TopDrop may monitor the pasteboard without presenting another prompt.
    case allowed
    /// Access has not been requested yet, or macOS is configured to ask each time.
    case promptRequired
    /// System Settings is configured to deny programmatic pasteboard access.
    case denied

    public var userMessage: String {
        switch self {
        case .allowed:
            "Clipboard history is enabled."
        case .promptRequired:
            "Allow TopDrop to access the clipboard, then choose Always Allow to enable history."
        case .denied:
            "Clipboard access is denied. Enable TopDrop in System Settings > Privacy & Security > Pasteboard."
        }
    }
}

public enum ClipboardRepresentationKind: String, Codable, CaseIterable, Sendable {
    case plainText
    case rtf
    case html
    case url
    case image
    case pdf
    case fileURL

    public var isTextualFormatting: Bool {
        switch self {
        case .plainText, .rtf, .html:
            true
        case .url, .image, .pdf, .fileURL:
            false
        }
    }
}

/// A single pasteboard flavor. `pasteboardType` is retained so a restored clip
/// can reproduce its original Apple UTI rather than a lossy approximation.
public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public let kind: ClipboardRepresentationKind
    public let pasteboardType: String
    public let data: Data

    public init(kind: ClipboardRepresentationKind, pasteboardType: String, data: Data) {
        self.kind = kind
        self.pasteboardType = pasteboardType
        self.data = data
    }
}

/// Pasteboards may contain more than one item, so the grouping is preserved.
public struct ClipboardPayloadItem: Codable, Equatable, Sendable {
    public let representations: [ClipboardRepresentation]

    public init(representations: [ClipboardRepresentation]) {
        self.representations = representations
    }
}

public struct ClipboardPayload: Codable, Equatable, Sendable {
    public let items: [ClipboardPayloadItem]

    public init(items: [ClipboardPayloadItem]) {
        self.items = items
    }

    public var byteCount: Int {
        items.reduce(into: 0) { total, item in
            for representation in item.representations {
                total += representation.data.count
            }
        }
    }
}

public struct ClipboardSourceApplication: Codable, Equatable, Sendable {
    public let bundleIdentifier: String?
    public let displayName: String
    public let iconPNG: Data?

    public init(bundleIdentifier: String?, displayName: String, iconPNG: Data? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.displayName = displayName
        self.iconPNG = iconPNG
    }
}

public enum ClipboardPreviewKind: String, Codable, Sendable {
    case text
    case url
    case image
    case pdf
    case file
}

/// Non-secret presentation metadata. The default encrypted store encrypts this
/// together with the payload, which is intentionally stricter than required.
public struct ClipboardPreview: Codable, Equatable, Sendable {
    public let kind: ClipboardPreviewKind
    public let excerpt: String?
    public let thumbnailPNG: Data?
    public let fileName: String?
    public let urlDomain: String?
    public let fileIconPNG: Data?

    public init(
        kind: ClipboardPreviewKind,
        excerpt: String? = nil,
        thumbnailPNG: Data? = nil,
        fileName: String? = nil,
        urlDomain: String? = nil,
        fileIconPNG: Data? = nil
    ) {
        self.kind = kind
        self.excerpt = excerpt
        self.thumbnailPNG = thumbnailPNG
        self.fileName = fileName
        self.urlDomain = urlDomain
        self.fileIconPNG = fileIconPNG
    }
}

public struct ClipboardItem: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let capturedAt: Date
    /// The most recent time the user promoted this retained item back to the
    /// system clipboard. It is encrypted with the rest of the archive.
    public let lastActivatedAt: Date?
    public let generatedTemplate: BlankFileTemplate?
    public let sourceApplication: ClipboardSourceApplication?
    public let payload: ClipboardPayload
    public let preview: ClipboardPreview
    /// SHA-256 over the payload, used only for consecutive duplicate suppression.
    public let fingerprint: Data

    public init(
        id: UUID = UUID(),
        capturedAt: Date = Date(),
        lastActivatedAt: Date? = nil,
        generatedTemplate: BlankFileTemplate? = nil,
        sourceApplication: ClipboardSourceApplication?,
        payload: ClipboardPayload,
        preview: ClipboardPreview,
        fingerprint: Data
    ) {
        self.id = id
        self.capturedAt = capturedAt
        self.lastActivatedAt = lastActivatedAt
        self.generatedTemplate = generatedTemplate
        self.sourceApplication = sourceApplication
        self.payload = payload
        self.preview = preview
        self.fingerprint = fingerprint
    }

    public var activityDate: Date { lastActivatedAt ?? capturedAt }

    public var imageLogicalIndices: [Int] {
        let indices = payload.items.enumerated().compactMap { index, item in
            item.representations.contains(where: { $0.kind == .image }) ? index : nil
        }
        if !indices.isEmpty { return indices }
        return preview.kind == .image && !payload.items.isEmpty ? [0] : []
    }

    public func activated(at date: Date) -> Self {
        Self(
            id: id,
            capturedAt: capturedAt,
            lastActivatedAt: date,
            generatedTemplate: generatedTemplate,
            sourceApplication: sourceApplication,
            payload: payload,
            preview: preview,
            fingerprint: fingerprint
        )
    }

    /// A strict full-value Hex match used to render clipboard color swatches.
    /// Ordinary text containing a color somewhere in a sentence is not treated
    /// as a color transaction.
    public var hexColorPreview: AnnotationColor? {
        guard preview.kind == .text,
            let excerpt = preview.excerpt,
            let color = AnnotationColor(hexString: excerpt)
        else { return nil }
        return color
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case capturedAt
        case lastActivatedAt
        case generatedTemplate
        case sourceApplication
        case payload
        case preview
        case fingerprint
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        capturedAt = try values.decode(Date.self, forKey: .capturedAt)
        lastActivatedAt = try values.decodeIfPresent(Date.self, forKey: .lastActivatedAt)
        generatedTemplate = try values.decodeIfPresent(BlankFileTemplate.self, forKey: .generatedTemplate)
        sourceApplication = try values.decodeIfPresent(
            ClipboardSourceApplication.self,
            forKey: .sourceApplication
        )
        payload = try values.decode(ClipboardPayload.self, forKey: .payload)
        preview = try values.decode(ClipboardPreview.self, forKey: .preview)
        fingerprint = try values.decode(Data.self, forKey: .fingerprint)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(capturedAt, forKey: .capturedAt)
        try values.encodeIfPresent(lastActivatedAt, forKey: .lastActivatedAt)
        try values.encodeIfPresent(generatedTemplate, forKey: .generatedTemplate)
        try values.encodeIfPresent(sourceApplication, forKey: .sourceApplication)
        try values.encode(payload, forKey: .payload)
        try values.encode(preview, forKey: .preview)
        try values.encode(fingerprint, forKey: .fingerprint)
    }
}

/// Raw data copied out of NSPasteboard before it is classified and bounded.
public struct ClipboardRawItem: Equatable, Sendable {
    public struct Flavor: Equatable, Sendable {
        public let pasteboardType: String
        public let data: Data

        public init(pasteboardType: String, data: Data) {
            self.pasteboardType = pasteboardType
            self.data = data
        }
    }

    public let flavors: [Flavor]

    public init(flavors: [Flavor]) {
        self.flavors = flavors
    }
}

public struct ClipboardRawContents: Equatable, Sendable {
    public let items: [ClipboardRawItem]
    public let containsTopDropMarker: Bool

    public init(items: [ClipboardRawItem], containsTopDropMarker: Bool = false) {
        self.items = items
        self.containsTopDropMarker = containsTopDropMarker
    }
}

public enum ClipboardConversionResult: Equatable, Sendable {
    case item(ClipboardItem)
    case empty
    case oversized(byteCount: Int, limit: Int)
}

public enum ClipboardCleanFormattingOutcome: Equatable, Sendable {
    case cleaned(changeCount: Int)
    case alreadyPlainText
    case noText
}

public enum ClipboardCleanFormattingPlan: Equatable, Sendable {
    case rewrite([ClipboardRawItem])
    case alreadyPlainText
    case noText
}

public struct ClipboardMonitorConfiguration: Equatable, Sendable {
    public var pollingInterval: Duration
    public var sensitiveApplicationBundleIdentifiers: Set<String>

    public init(
        pollingInterval: Duration = .milliseconds(500),
        sensitiveApplicationBundleIdentifiers: Set<String> = []
    ) {
        self.pollingInterval = pollingInterval
        self.sensitiveApplicationBundleIdentifiers = sensitiveApplicationBundleIdentifiers
    }
}

public enum ClipboardUntrackedReason: String, Equatable, Sendable {
    case changedWhilePaused
    case excludedApplication
    case oversized
    case unsupported
    case accessUnavailable
    case topDropOwnedWrite
    case formattingCleaned
    case removedFromHistory
    case historyCleared
    case readFailed

    public var userMessage: String {
        switch self {
        case .changedWhilePaused: "Clipboard changed while history was paused."
        case .excludedApplication: "Current clipboard is hidden by a sensitive-app exclusion."
        case .oversized: "Current clipboard exceeds TopDrop's 20 MB history limit."
        case .unsupported: "Current clipboard uses a format TopDrop does not retain."
        case .accessUnavailable: "Current clipboard is unavailable until access is allowed."
        case .topDropOwnedWrite: "A TopDrop action changed the clipboard outside history."
        case .formattingCleaned: "Current clipboard was cleaned by TopDrop."
        case .removedFromHistory: "Current clipboard is no longer retained in history."
        case .historyCleared: "Clipboard history was cleared."
        case .readFailed: "TopDrop could not inspect the current clipboard."
        }
    }
}

public enum ClipboardCurrentState: Equatable, Sendable {
    case unknown
    case tracked(itemID: UUID)
    case untracked(reason: ClipboardUntrackedReason)

    public var itemID: UUID? {
        guard case let .tracked(itemID) = self else { return nil }
        return itemID
    }
}

public enum ClipboardArrivalWatchUnavailableReason: String, Equatable, Sendable {
    case accessRequired
    case paused

    public var userMessage: String {
        switch self {
        case .accessRequired: "Always Allow clipboard access to watch automatically."
        case .paused: "Resume clipboard history to watch for a new arrival."
        }
    }
}

public enum ClipboardArrivalWatchState: Equatable, Sendable {
    case idle
    case watching(startedAt: Date, deadline: Date)
    case received(itemID: UUID, receivedAt: Date)
    case timedOut
    case unavailable(reason: ClipboardArrivalWatchUnavailableReason)
}

public enum ClipboardUtilityWatchState: Equatable, Sendable {
    case idle
    case watching(secondsRemaining: Int)
    case received
    case timedOut
    case paused
    case inaccessible

    public var systemImageName: String {
        switch self {
        case .idle, .watching: "iphone.and.arrow.forward"
        case .received: "checkmark.circle.fill"
        case .timedOut: "exclamationmark.triangle"
        case .paused: "pause.fill"
        case .inaccessible: "lock.fill"
        }
    }
}

public enum ClipboardUtilityWatchPolicy {
    public static func state(
        arrivalWatch: ClipboardArrivalWatchState,
        accessState: ClipboardAccessState,
        isPaused: Bool,
        now: Date = Date()
    ) -> ClipboardUtilityWatchState {
        if isPaused { return .paused }
        if accessState != .allowed { return .inaccessible }
        switch arrivalWatch {
        case .idle:
            return .idle
        case let .watching(_, deadline):
            return .watching(
                secondsRemaining: max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
            )
        case .received:
            return .received
        case .timedOut:
            return .timedOut
        case let .unavailable(reason):
            return reason == .paused ? .paused : .inaccessible
        }
    }
}

public struct ClipboardMonitorSnapshot: Equatable, Sendable {
    public var items: [ClipboardItem]
    public var isPaused: Bool
    public var accessState: ClipboardAccessState
    public var sensitiveApplicationBundleIdentifiers: Set<String>
    public var statusMessage: String?
    public var currentState: ClipboardCurrentState
    public var arrivalWatch: ClipboardArrivalWatchState

    public init(
        items: [ClipboardItem] = [],
        isPaused: Bool = false,
        accessState: ClipboardAccessState = .promptRequired,
        sensitiveApplicationBundleIdentifiers: Set<String> = [],
        statusMessage: String? = nil,
        currentState: ClipboardCurrentState = .unknown,
        arrivalWatch: ClipboardArrivalWatchState = .idle
    ) {
        self.items = items
        self.isPaused = isPaused
        self.accessState = accessState
        self.sensitiveApplicationBundleIdentifiers = sensitiveApplicationBundleIdentifiers
        self.statusMessage = statusMessage
        self.currentState = currentState
        self.arrivalWatch = arrivalWatch
    }
}

public enum ClipboardSubsystemError: Error, Equatable, LocalizedError, Sendable {
    case accessPromptRequired
    case accessDenied
    case pasteboardReadFailed
    case pasteboardWriteFailed
    case itemNotFound
    case invalidArchive
    case keychain(status: Int32)
    case encryptionFailed

    public var errorDescription: String? {
        switch self {
        case .accessPromptRequired:
            "Clipboard access still requires a macOS prompt. Choose Always Allow to enable history."
        case .accessDenied:
            "Clipboard access is denied in System Settings."
        case .pasteboardReadFailed:
            "TopDrop could not read the current clipboard."
        case .pasteboardWriteFailed:
            "TopDrop could not update the clipboard."
        case .itemNotFound:
            "That clipboard item is no longer in history."
        case .invalidArchive:
            "The encrypted clipboard history could not be decoded."
        case let .keychain(status):
            "Keychain failed with status \(status)."
        case .encryptionFailed:
            "The encrypted clipboard history could not be opened."
        }
    }
}
