import AppKit
import Foundation

/// Pure transformation used by the live pasteboard client and unit tests. It
/// removes only plain/RTF/HTML flavors and leaves every nontext/private flavor
/// byte-for-byte unchanged.
@MainActor
public enum ClipboardFormattingCleaner {
    public static func plan(for rawContents: ClipboardRawContents) throws -> ClipboardCleanFormattingPlan {
        var outputItems: [ClipboardRawItem] = []
        var foundText = false
        var foundFormatting = false

        for rawItem in rawContents.items {
            let classified: [(ClipboardRawItem.Flavor, ClipboardRepresentationKind)] = rawItem.flavors.compactMap {
                flavor in
                guard let kind = ClipboardContentConverter.kind(forPasteboardType: flavor.pasteboardType) else {
                    return nil
                }
                return (flavor, kind)
            }
            let textual = classified.filter { $0.1.isTextualFormatting }
            guard !textual.isEmpty else {
                outputItems.append(rawItem)
                continue
            }

            foundText = true
            let hasRichText = textual.contains { $0.1 == .rtf || $0.1 == .html }
            foundFormatting = foundFormatting || hasRichText

            guard hasRichText else {
                outputItems.append(rawItem)
                continue
            }

            let representations = textual.map {
                ClipboardRepresentation(kind: $0.1, pasteboardType: $0.0.pasteboardType, data: $0.0.data)
            }
            guard let plainText = ClipboardContentConverter.preferredPlainText(in: representations),
                let utf8 = plainText.data(using: .utf8)
            else {
                throw ClipboardSubsystemError.pasteboardReadFailed
            }

            var flavors = rawItem.flavors.filter { flavor in
                guard let kind = ClipboardContentConverter.kind(forPasteboardType: flavor.pasteboardType) else {
                    return true
                }
                return !kind.isTextualFormatting
            }
            flavors.append(
                ClipboardRawItem.Flavor(
                    pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                    data: utf8
                )
            )
            outputItems.append(ClipboardRawItem(flavors: flavors))
        }

        guard foundText else { return .noText }
        guard foundFormatting else { return .alreadyPlainText }
        return .rewrite(outputItems)
    }
}
