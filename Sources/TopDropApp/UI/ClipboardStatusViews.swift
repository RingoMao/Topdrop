import AppKit
import SwiftUI
import TopDropCore

struct CompactClipboardEmptyView: View {
    let title: String
    let detail: String
    let symbol: String
    let actionTitle: String?
    let action: (() -> Void)?

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 12)
        .accessibilityElement(children: .contain)
    }
}

struct CurrentClipboardCard: View {
    let item: ClipboardItem
    let library: ScreenshotLibrary
    let clipboard: ClipboardMonitor
    @StateObject private var textCopy = ImageTextCopyController()
    let isPulsing: Bool
    let receivedDuringWatch: Bool
    let editImage: (Int) -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 7) {
            Rectangle()
                .fill(Color.primary.opacity(0.9))
                .frame(width: 4)
                .clipShape(Capsule())
                .accessibilityHidden(true)
            ClipboardPreviewIcon(item: item)
                .frame(
                    width: item.preview.kind == .image ? 64 : 36,
                    height: item.preview.kind == .image ? 48 : 36
                )
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                .layoutPriority(1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Label("CURRENT", systemImage: "checkmark.circle.fill")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.primary)
                    if receivedDuringWatch {
                        Text("RECEIVED")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                Text(item.primaryLabel)
                    .font(.callout)
                    .lineLimit(1)
                ClipboardActivityLine(item: item, isCurrent: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(2)
            Spacer(minLength: 6)
            if !item.imageLogicalIndices.isEmpty {
                ImageTextCopyButton(
                    controller: textCopy,
                    sources: item.imageLogicalIndices.map { index in
                        ImageTextCopySource(id: index) {
                            try await library.clipboardOriginalImageData(from: item, logicalIndex: index)
                        }
                    }, clipboard: clipboard)
            }
            imageEditControl
            Menu {
                Button("Remove from History", role: .destructive, action: delete)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Current clipboard actions")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .frame(minHeight: item.preview.kind == .image ? 60 : 50)
        .background(Color.primary.opacity(isPulsing ? 0.12 : 0.055))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(
                    Color.primary.opacity(isPulsing ? 0.95 : 0.62),
                    lineWidth: isPulsing ? 2.6 : 2
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Current clipboard, \(item.primaryLabel)")
        .accessibilityValue("On clipboard now")
    }

    @ViewBuilder
    private var imageEditControl: some View {
        if item.imageLogicalIndices.count == 1, let index = item.imageLogicalIndices.first {
            Button {
                editImage(index)
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .help("Edit Current Image")
        } else if item.imageLogicalIndices.count > 1 {
            Menu {
                ForEach(item.imageLogicalIndices, id: \.self) { index in
                    Button("Edit Image \(index + 1)") { editImage(index) }
                }
            } label: {
                Image(systemName: "pencil")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Choose an image to edit")
        }
    }
}

struct CurrentClipboardStatusCard: View {
    let state: ClipboardCurrentState

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text("CURRENT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .frame(minHeight: 48)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityElement(children: .combine)
    }

    private var message: String {
        switch state {
        case .unknown: "Waiting for the next clipboard change."
        case .tracked: "Current item is loading."
        case let .untracked(reason): reason.userMessage
        }
    }

    private var symbol: String {
        switch state {
        case .unknown: "clipboard"
        case .tracked: "clock"
        case .untracked: "clipboard.fill"
        }
    }
}
