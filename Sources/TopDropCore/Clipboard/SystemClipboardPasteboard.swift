import AppKit
import Foundation
import OSLog

@MainActor
public protocol ClipboardPasteboardClient: AnyObject {
    var changeCount: Int { get }
    var accessState: ClipboardAccessState { get }

    /// Must only be called from an explicit user action because it can present
    /// the macOS pasteboard access prompt.
    func requestAccess() -> ClipboardAccessState
    func readSupportedContents() throws -> ClipboardRawContents
    @discardableResult func write(_ payload: ClipboardPayload) throws -> Int
    func cleanFormatting() throws -> ClipboardCleanFormattingOutcome
}

@MainActor
public protocol ClipboardSourceApplicationProviding: AnyObject {
    func currentSourceApplication() -> ClipboardSourceApplication?
}

@MainActor
public final class WorkspaceClipboardSourceApplicationProvider: ClipboardSourceApplicationProviding {
    public init() {}

    public func currentSourceApplication() -> ClipboardSourceApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication else { return nil }
        let name = application.localizedName ?? application.bundleIdentifier ?? "Unknown Application"
        let iconPNG: Data?
        if let bundleURL = application.bundleURL {
            iconPNG = ClipboardImageRenderer.pngThumbnail(
                from: NSWorkspace.shared.icon(forFile: bundleURL.path),
                maximumPixelDimension: 40
            )
        } else {
            iconPNG = nil
        }
        return ClipboardSourceApplication(
            bundleIdentifier: application.bundleIdentifier,
            displayName: name,
            iconPNG: iconPNG
        )
    }
}

@MainActor
public final class SystemClipboardPasteboardClient: ClipboardPasteboardClient {
    public static let ownerMarkerType = NSPasteboard.PasteboardType("com.personal.TopDrop.clipboard-owner")

    private let pasteboard: NSPasteboard
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "ClipboardPasteboard")

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    public var accessState: ClipboardAccessState {
        switch pasteboard.accessBehavior {
        case .alwaysAllow:
            .allowed
        case .alwaysDeny:
            .denied
        case .default, .ask:
            .promptRequired
        @unknown default:
            .promptRequired
        }
    }

    public func requestAccess() -> ClipboardAccessState {
        guard accessState != .denied else { return .denied }
        // Reading the item list is the smallest useful access that triggers the
        // system's permission sheet. No clipboard content is logged or retained.
        _ = pasteboard.pasteboardItems
        let result = accessState
        logger.info("Explicit pasteboard access request completed; state=\(result.rawValue, privacy: .public)")
        return result
    }

    public func readSupportedContents() throws -> ClipboardRawContents {
        switch accessState {
        case .allowed:
            return try readContents(preservingUnsupportedTypes: false)
        case .promptRequired:
            throw ClipboardSubsystemError.accessPromptRequired
        case .denied:
            throw ClipboardSubsystemError.accessDenied
        }
    }

    @discardableResult
    public func write(_ payload: ClipboardPayload) throws -> Int {
        let rawItems = payload.items.map { item in
            ClipboardRawItem(
                flavors: item.representations.map {
                    ClipboardRawItem.Flavor(pasteboardType: $0.pasteboardType, data: $0.data)
                }
            )
        }
        return try write(rawItems: rawItems)
    }

    public func cleanFormatting() throws -> ClipboardCleanFormattingOutcome {
        // This is only called for an explicit button/hotkey action. macOS allows
        // user-originated paste-related access even when background monitoring is denied.
        let rawContents = try readContents(preservingUnsupportedTypes: true)
        switch try ClipboardFormattingCleaner.plan(for: rawContents) {
        case let .rewrite(outputItems):
            let newChangeCount = try write(rawItems: outputItems)
            logger.info("Clipboard formatting removed; itemCount=\(outputItems.count, privacy: .public)")
            return .cleaned(changeCount: newChangeCount)
        case .alreadyPlainText:
            return .alreadyPlainText
        case .noText:
            return .noText
        }
    }

    private func readContents(preservingUnsupportedTypes: Bool) throws -> ClipboardRawContents {
        guard let pasteboardItems = pasteboard.pasteboardItems else {
            throw ClipboardSubsystemError.pasteboardReadFailed
        }
        var containsMarker = false
        var result: [ClipboardRawItem] = []

        for item in pasteboardItems {
            var flavors: [ClipboardRawItem.Flavor] = []
            for type in item.types {
                if type == Self.ownerMarkerType {
                    containsMarker = true
                    continue
                }
                if !preservingUnsupportedTypes,
                    ClipboardContentConverter.kind(forPasteboardType: type.rawValue) == nil
                {
                    continue
                }
                guard let data = item.data(forType: type) else {
                    // Clean Formatting must be all-or-nothing for nontext data;
                    // refusing the operation is safer than dropping a promised flavor.
                    if preservingUnsupportedTypes {
                        throw ClipboardSubsystemError.pasteboardReadFailed
                    }
                    continue
                }
                flavors.append(ClipboardRawItem.Flavor(pasteboardType: type.rawValue, data: data))
            }
            if !flavors.isEmpty {
                result.append(ClipboardRawItem(flavors: flavors))
            }
        }
        return ClipboardRawContents(items: result, containsTopDropMarker: containsMarker)
    }

    @discardableResult
    private func write(rawItems: [ClipboardRawItem]) throws -> Int {
        guard !rawItems.isEmpty else { throw ClipboardSubsystemError.pasteboardWriteFailed }
        var pasteboardItems: [NSPasteboardItem] = []
        for (index, rawItem) in rawItems.enumerated() {
            let item = NSPasteboardItem()
            for flavor in rawItem.flavors {
                guard
                    item.setData(
                        flavor.data,
                        forType: NSPasteboard.PasteboardType(flavor.pasteboardType)
                    )
                else {
                    throw ClipboardSubsystemError.pasteboardWriteFailed
                }
            }
            if index == 0 {
                guard item.setString(UUID().uuidString, forType: Self.ownerMarkerType) else {
                    throw ClipboardSubsystemError.pasteboardWriteFailed
                }
            }
            pasteboardItems.append(item)
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(pasteboardItems) else {
            throw ClipboardSubsystemError.pasteboardWriteFailed
        }
        return pasteboard.changeCount
    }
}
