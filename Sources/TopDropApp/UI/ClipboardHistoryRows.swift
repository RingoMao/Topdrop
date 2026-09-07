import AppKit
import SwiftUI
import TopDropCore

struct ClipboardItemRow: View {
    let item: ClipboardItem
    let makeCurrent: () -> Void
    let delete: () -> Void

    var body: some View {
        Button(action: makeCurrent) {
            HStack(spacing: 7) {
                ClipboardPreviewIcon(item: item)
                    .frame(width: 36, height: 36)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.primaryLabel).lineLimit(1)
                    ClipboardActivityLine(item: item, isCurrent: false)
                }
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    Label("Make Current", systemImage: "arrow.up.to.line")
                        .monochromeActionCapsule()
                    Image(systemName: "arrow.up.to.line")
                        .monochromeActionCapsule()
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .frame(minHeight: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu {
            Button("Make Current", action: makeCurrent)
            Button("Delete", role: .destructive, action: delete)
        }
        .help("Make this the current clipboard item")
        .accessibilityLabel("\(item.primaryLabel), make current")
        .accessibilityHint("Writes this saved item to the system clipboard")
    }
}

struct ClipboardPreviewIcon: View {
    let item: ClipboardItem

    @ViewBuilder
    var body: some View {
        if let sampledColor = item.hexColorPreview {
            Color(
                red: sampledColor.red,
                green: sampledColor.green,
                blue: sampledColor.blue,
                opacity: sampledColor.alpha
            )
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.primary.opacity(0.42), lineWidth: 1)
            }
            .accessibilityLabel("Color \(sampledColor.hexString)")
        } else if let data = item.preview.thumbnailPNG, let image = NSImage(data: data) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else if let data = item.preview.fileIconPNG, let image = NSImage(data: data) {
            Image(nsImage: image).resizable().scaledToFit().padding(5)
        } else {
            Image(systemName: item.previewSymbol)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

struct ClipboardActivityLine: View {
    let item: ClipboardItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 4) {
            if let iconData = item.sourceApplication?.iconPNG,
                let icon = NSImage(data: iconData)
            {
                Image(nsImage: icon).resizable().frame(width: 13, height: 13)
            }
            if let application = item.sourceApplication?.displayName {
                Text("Detected while \(application) was active")
            } else {
                Text("Source unavailable")
            }
            Text("•")
            if isCurrent {
                Text("Now")
            } else if item.lastActivatedAt != nil {
                Text("Used \(Text(item.activityDate, style: .relative))")
            } else {
                Text(item.capturedAt, style: .time)
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .help("Originally captured \(item.capturedAt.formatted(date: .abbreviated, time: .shortened))")
    }
}

struct UnifiedImageRow: View {
    let entry: UnifiedMediaImageEntry
    @ObservedObject var model: ScreenshotViewModel
    let clipboard: ClipboardMonitor
    @StateObject private var textCopy = ImageTextCopyController()
    let makeClipboardItemCurrent: () -> Void
    let copyImage: () -> Void
    let deleteClipboardItem: () -> Void
    let edit: () -> Void

    @State private var thumbnail: NSImage?

    var body: some View {
        HStack(spacing: 5) {
            Button(action: entry.clipboardItem == nil ? edit : makeClipboardItemCurrent) {
                rowContent
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ImageTextCopyButton(
                controller: textCopy,
                sources: [
                    ImageTextCopySource(id: entry.logicalIndex ?? 0) {
                        if let item = entry.screenshotItem {
                            return try await model.library.originalImageData(for: item.id)
                        }
                        guard let item = entry.clipboardItem, let index = entry.logicalIndex else {
                            throw AnnotationError.sourceImageUnavailable
                        }
                        return try await model.library.clipboardOriginalImageData(from: item, logicalIndex: index)
                    }
                ], clipboard: clipboard)
            if entry.clipboardItem != nil {
                Button(action: edit) {
                    Image(systemName: "pencil")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Edit Image")
            } else {
                Button(action: copyImage) {
                    Image(systemName: "doc.on.doc")
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.borderless)
                .help("Copy Image")
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .frame(minHeight: 66)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 9))
        .contextMenu { contextMenu }
        .task(id: entry.screenshotItem?.id) {
            if let item = entry.screenshotItem {
                thumbnail = await model.thumbnail(for: item)
            } else if let data = entry.clipboardItem?.preview.thumbnailPNG {
                thumbnail = NSImage(data: data)
            } else {
                thumbnail = nil
            }
        }
        .help(entry.clipboardItem == nil ? "Click to edit this image" : "Make this image clip current")
        .accessibilityHint(
            entry.clipboardItem == nil
                ? "Opens the image editor"
                : "Writes the complete original clip to the system clipboard"
        )
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            thumbnailView
                .frame(width: 68, height: 52)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1).truncationMode(.middle)
                if let item = entry.screenshotItem {
                    Text("\(Int(item.pixelSize.width))×\(Int(item.pixelSize.height))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Label(originLabel, systemImage: originSymbol)
                    Text("•")
                    Text(entry.occurredAt, style: .time)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if entry.clipboardItem != nil {
                ViewThatFits(in: .horizontal) {
                    Label("Make Current", systemImage: "arrow.up.to.line")
                        .monochromeActionCapsule()
                    Image(systemName: "arrow.up.to.line")
                        .monochromeActionCapsule()
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail {
            Image(nsImage: thumbnail).resizable().scaledToFill()
        } else {
            Image(systemName: "photo").font(.title).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Edit", action: edit)
        if entry.clipboardItem != nil {
            Button("Make Current", action: makeClipboardItemCurrent)
        }
        if entry.screenshotItem != nil {
            Button("Copy Image", action: copyImage)
        }
        if let item = entry.screenshotItem {
            if item.origin == .watchedFolder || item.sourceURL != item.managedOriginalURL {
                Button("Reveal Source") { Task { await model.reveal(item) } }
            }
            Divider()
            Button("Save Copy") { Task { await model.saveCopy(item) } }
            Button("Download to Desktop") { Task { await model.downloadToDesktop(item) } }
            Divider()
            Button("Remove from Image History", role: .destructive) {
                Task { await model.remove(item) }
            }
        }
        if entry.clipboardItem != nil {
            Button("Delete Clipboard Item", role: .destructive, action: deleteClipboardItem)
        }
    }

    private var title: String {
        if let item = entry.screenshotItem, item.origin == .watchedFolder {
            return item.sourceFilename
        }
        if let item = entry.screenshotItem,
            item.sourceURL != item.managedOriginalURL,
            !item.sourceFilename.isEmpty
        {
            return item.sourceFilename
        }
        return "Clipboard Image \((entry.logicalIndex ?? 0) + 1)"
    }

    private var originLabel: String {
        switch entry.screenshotItem?.origin {
        case .watchedFolder: "Screenshot"
        case .clipboardProject: "Edited Project"
        case .clipboardCache: "Clipboard Image"
        case nil: "Clipboard Image"
        }
    }

    private var originSymbol: String {
        switch entry.screenshotItem?.origin {
        case .watchedFolder: "camera.viewfinder"
        case .clipboardProject: "square.stack.3d.up"
        case .clipboardCache, nil: "clipboard"
        }
    }

}

extension ClipboardItem {
    var primaryLabel: String {
        preview.excerpt
            ?? preview.fileName
            ?? preview.urlDomain
            ?? preview.kind.rawValue.capitalized
    }

    var previewSymbol: String {
        switch preview.kind {
        case .text: "text.alignleft"
        case .url: "link"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .file: "doc"
        }
    }
}

extension ClipboardArrivalWatchState {
    var receivedItemID: UUID? {
        guard case let .received(itemID, _) = self else { return nil }
        return itemID
    }
}
