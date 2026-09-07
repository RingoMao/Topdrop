import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

/// Converts a pasteboard snapshot into TopDrop's bounded, restorable model.
/// AppKit's attributed-string and image readers are main-thread-bound.
@MainActor
public struct ClipboardContentConverter {
    public let maximumPayloadBytes: Int

    public init(maximumPayloadBytes: Int = TopDropCore.maximumClipboardPayloadBytes) {
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public func convert(
        _ rawContents: ClipboardRawContents,
        sourceApplication: ClipboardSourceApplication?,
        capturedAt: Date = Date()
    ) -> ClipboardConversionResult {
        var payloadItems: [ClipboardPayloadItem] = []
        var byteCount = 0

        for rawItem in rawContents.items {
            var representations: [ClipboardRepresentation] = []
            var seenTypes = Set<String>()
            for flavor in rawItem.flavors {
                guard seenTypes.insert(flavor.pasteboardType).inserted,
                    let kind = Self.kind(forPasteboardType: flavor.pasteboardType)
                else {
                    continue
                }
                byteCount += flavor.data.count
                if byteCount > maximumPayloadBytes {
                    return .oversized(byteCount: byteCount, limit: maximumPayloadBytes)
                }
                representations.append(
                    ClipboardRepresentation(
                        kind: kind,
                        pasteboardType: flavor.pasteboardType,
                        data: flavor.data
                    )
                )
            }
            if !representations.isEmpty {
                payloadItems.append(ClipboardPayloadItem(representations: representations))
            }
        }

        guard !payloadItems.isEmpty else { return .empty }
        let payload = ClipboardPayload(items: payloadItems)
        let item = ClipboardItem(
            capturedAt: capturedAt,
            sourceApplication: sourceApplication,
            payload: payload,
            preview: makePreview(for: payload),
            fingerprint: Self.fingerprint(for: payload)
        )
        return .item(item)
    }

    public static func kind(forPasteboardType pasteboardType: String) -> ClipboardRepresentationKind? {
        let type = UTType(pasteboardType)

        if pasteboardType == NSPasteboard.PasteboardType.fileURL.rawValue || type?.conforms(to: .fileURL) == true {
            return .fileURL
        }
        if pasteboardType == NSPasteboard.PasteboardType.URL.rawValue || type?.conforms(to: .url) == true {
            return .url
        }
        if pasteboardType == NSPasteboard.PasteboardType.pdf.rawValue || type?.conforms(to: .pdf) == true {
            return .pdf
        }
        if pasteboardType == NSPasteboard.PasteboardType.png.rawValue
            || pasteboardType == NSPasteboard.PasteboardType.tiff.rawValue
            || NSImage.imageTypes.contains(pasteboardType) || type?.conforms(to: .image) == true
        {
            return .image
        }
        if pasteboardType == NSPasteboard.PasteboardType.rtf.rawValue || type?.conforms(to: .rtf) == true {
            return .rtf
        }
        if pasteboardType == NSPasteboard.PasteboardType.html.rawValue || type?.conforms(to: .html) == true {
            return .html
        }
        if pasteboardType == NSPasteboard.PasteboardType.string.rawValue || type?.conforms(to: .plainText) == true {
            return .plainText
        }
        return nil
    }

    /// Produces plain UTF-8 text without evaluating HTML or invoking a shell.
    public static func plainText(from representation: ClipboardRepresentation) -> String? {
        switch representation.kind {
        case .plainText:
            return decodePlainString(representation.data)
        case .rtf:
            return try? NSAttributedString(
                data: representation.data,
                options: [.documentType: NSAttributedString.DocumentType.rtf],
                documentAttributes: nil
            ).string
        case .html:
            return try? NSAttributedString(
                data: representation.data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue,
                ],
                documentAttributes: nil
            ).string
        case .url, .fileURL:
            return decodePlainString(representation.data)
        case .image, .pdf:
            return nil
        }
    }

    public static func preferredPlainText(in representations: [ClipboardRepresentation]) -> String? {
        let preferredKinds: [ClipboardRepresentationKind] = [.plainText, .rtf, .html]
        for kind in preferredKinds {
            for representation in representations where representation.kind == kind {
                if let text = plainText(from: representation) {
                    return text
                }
            }
        }
        return nil
    }

    public static func fingerprint(for payload: ClipboardPayload) -> Data {
        var hasher = SHA256()
        for (itemIndex, item) in payload.items.enumerated() {
            hasher.update(data: withUnsafeBytes(of: UInt64(itemIndex).bigEndian) { Data($0) })
            for representation in item.representations.sorted(by: { $0.pasteboardType < $1.pasteboardType }) {
                let typeData = Data(representation.pasteboardType.utf8)
                hasher.update(data: withUnsafeBytes(of: UInt64(typeData.count).bigEndian) { Data($0) })
                hasher.update(data: typeData)
                hasher.update(data: withUnsafeBytes(of: UInt64(representation.data.count).bigEndian) { Data($0) })
                hasher.update(data: representation.data)
            }
        }
        return Data(hasher.finalize())
    }

    private func makePreview(for payload: ClipboardPayload) -> ClipboardPreview {
        let representations = payload.items.flatMap(\.representations)

        if let image = representations.first(where: { $0.kind == .image }) {
            return ClipboardPreview(
                kind: .image,
                thumbnailPNG: ClipboardImageRenderer.pngThumbnail(from: image.data, maximumPixelDimension: 180)
            )
        }
        if let pdf = representations.first(where: { $0.kind == .pdf }) {
            return ClipboardPreview(
                kind: .pdf,
                thumbnailPNG: ClipboardImageRenderer.pngThumbnail(from: pdf.data, maximumPixelDimension: 180)
            )
        }
        if let file = representations.first(where: { $0.kind == .fileURL }),
            let url = Self.url(from: file.data)
        {
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return ClipboardPreview(
                kind: .file,
                fileName: url.lastPathComponent,
                fileIconPNG: ClipboardImageRenderer.pngThumbnail(from: icon, maximumPixelDimension: 48)
            )
        }
        if let urlRepresentation = representations.first(where: { $0.kind == .url }),
            let url = Self.url(from: urlRepresentation.data)
        {
            return ClipboardPreview(
                kind: .url,
                excerpt: url.absoluteString,
                urlDomain: url.host(percentEncoded: false)
            )
        }
        if let text = Self.preferredPlainText(in: representations) {
            return ClipboardPreview(kind: .text, excerpt: Self.excerpt(from: text))
        }

        // A supported URL may have malformed data; retain it and show a safe label.
        return ClipboardPreview(kind: .text, excerpt: "Clipboard item")
    }

    private static func decodePlainString(_ data: Data) -> String? {
        if let string = String(data: data, encoding: .utf8) { return string }
        if let string = String(data: data, encoding: .utf16) { return string }
        if let string = String(data: data, encoding: .utf16LittleEndian) { return string }
        return String(data: data, encoding: .macOSRoman)
    }

    private static func url(from data: Data) -> URL? {
        if let value = decodePlainString(data)?.trimmingCharacters(in: .whitespacesAndNewlines),
            let url = URL(string: value)
        {
            return url
        }
        return URL(dataRepresentation: data, relativeTo: nil)
    }

    private static func excerpt(from string: String, maximumCharacters: Int = 240) -> String {
        let collapsed =
            string
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard collapsed.count > maximumCharacters else { return collapsed }
        let end = collapsed.index(collapsed.startIndex, offsetBy: maximumCharacters)
        return String(collapsed[..<end]) + "…"
    }
}

@MainActor
enum ClipboardImageRenderer {
    static func pngThumbnail(from data: Data, maximumPixelDimension: Int) -> Data? {
        guard let image = NSImage(data: data) else { return nil }
        return pngThumbnail(from: image, maximumPixelDimension: maximumPixelDimension)
    }

    static func pngThumbnail(from image: NSImage, maximumPixelDimension: Int) -> Data? {
        let sourceSize = image.size
        guard sourceSize.width > 0, sourceSize.height > 0 else { return nil }
        let scale = min(
            1,
            CGFloat(maximumPixelDimension) / max(sourceSize.width, sourceSize.height)
        )
        let width = max(1, Int((sourceSize.width * scale).rounded()))
        let height = max(1, Int((sourceSize.height * scale).rounded()))
        guard
            let bitmap = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: width,
                pixelsHigh: height,
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ), let context = NSGraphicsContext(bitmapImageRep: bitmap)
        else {
            return nil
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        image.draw(
            in: NSRect(x: 0, y: 0, width: width, height: height),
            from: .zero,
            operation: .copy,
            fraction: 1,
            respectFlipped: false,
            hints: nil
        )
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        return bitmap.representation(using: .png, properties: [:])
    }
}
