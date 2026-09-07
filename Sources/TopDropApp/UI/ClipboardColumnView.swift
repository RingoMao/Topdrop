@preconcurrency import AppKit
import SwiftUI
import TopDropCore

struct ClipboardColumnView: View {
    @ObservedObject var monitor: ClipboardMonitor
    @ObservedObject var screenshots: ScreenshotViewModel
    let togglePause: () -> Void
    let pickScreenColor: () -> Void
    let edit: (ScreenshotItem) -> Void

    @State private var filter: UnifiedMediaFilter = .all
    @State private var currentPulse = false
    @State private var textCopiedToast = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum PresentationMode {
        case wide
        case compact
        case narrow

        init(width: CGFloat) {
            if width >= 720 { self = .wide } else if width >= 520 { self = .compact } else { self = .narrow }
        }
    }

    private var currentItem: ClipboardItem? {
        guard let id = monitor.snapshot.currentState.itemID else { return nil }
        return monitor.items.first { $0.id == id }
    }

    private var feed: [UnifiedMediaFeedEntry] {
        UnifiedMediaFeedBuilder.build(
            clipboardItems: monitor.items,
            screenshotItems: screenshots.snapshot.items,
            resolutions: screenshots.clipboardImageResolutions,
            filter: filter,
            excludingClipboardItemID: currentItem?.id
        )
    }

    var body: some View {
        GeometryReader { geometry in
            let mode = PresentationMode(width: geometry.size.width)
            VStack(spacing: 6) {
                header(mode: mode)
                historyViewport
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .overlay(alignment: .bottomTrailing) {
                if textCopiedToast {
                    Label("Text Copied", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold)).padding(9)
                        .background(.regularMaterial, in: Capsule()).padding(12)
                        .allowsHitTesting(false)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .topDropImageTextCopied)) { _ in textCopiedToast = true }
        .task(id: textCopiedToast) {
            guard textCopiedToast else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { textCopiedToast = false }
        }
        .onChange(of: monitor.snapshot.currentState) { _, newState in
            guard case .tracked = newState else { return }
            announce("Now on clipboard")
            guard !reduceMotion else { return }
            currentPulse = true
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                currentPulse = false
            }
        }
    }

    @ViewBuilder
    private func header(mode: PresentationMode) -> some View {
        switch mode {
        case .wide:
            HStack(spacing: 8) {
                headerTitle(compact: false)
                filterPicker
                    .frame(maxWidth: 430)
                Spacer(minLength: 4)
                headerUtilities
            }

        case .compact:
            VStack(spacing: 5) {
                HStack(spacing: 8) {
                    headerTitle(compact: false)
                    Spacer(minLength: 4)
                    headerUtilities
                }
                filterPicker
                    .frame(height: 30)
            }

        case .narrow:
            VStack(spacing: 5) {
                HStack(spacing: 6) {
                    headerTitle(compact: true)
                    Spacer(minLength: 2)
                    headerUtilities
                }
                filterPicker
                    .frame(height: 30)
            }
        }
    }

    private func headerTitle(compact: Bool) -> some View {
        Label(compact ? "Clipboard" : "Clipboard & Images", systemImage: "rectangle.stack.badge.plus")
            .font(.headline)
            .lineLimit(1)
    }

    private var headerUtilities: some View {
        ClipboardHeaderUtilities(
            monitor: monitor,
            togglePause: togglePause,
            pickScreenColor: pickScreenColor,
            openHandoffSettings: openHandoffSettings,
            announce: announce
        )
    }

    private var filterPicker: some View {
        HStack(spacing: 3) {
            ForEach(UnifiedMediaFilter.allCases) { option in
                Button {
                    filter = option
                } label: {
                    Text(option.title)
                        .font(.caption.weight(filter == option ? .semibold : .regular))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(
                            filter == option ? Color.primary.opacity(0.13) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                        )
                        .overlay {
                            if filter == option {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(Color.primary.opacity(0.42), lineWidth: 1)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(option.title)")
                .accessibilityValue(filter == option ? "Selected" : "Not selected")
            }
        }
        .frame(height: 30)
        .padding(2)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.primary.opacity(0.16), lineWidth: 1)
        }
    }

    private var historyViewport: some View {
        ScrollView {
            LazyVStack(spacing: 6, pinnedViews: [.sectionHeaders]) {
                Section {
                    if feed.isEmpty {
                        emptyView
                    } else {
                        ForEach(feed) { entry in row(for: entry) }
                    }
                    statusMessages
                } header: {
                    currentClipboardSection
                        .padding(.bottom, 2)
                        .background(.regularMaterial)
                }
            }
            .padding(.horizontal, 1)
            .padding(.bottom, 3)
        }
    }

    @ViewBuilder
    private var currentClipboardSection: some View {
        if let currentItem {
            CurrentClipboardCard(
                item: currentItem,
                library: screenshots.library,
                clipboard: monitor,
                isPulsing: currentPulse,
                receivedDuringWatch: monitor.snapshot.arrivalWatch.receivedItemID == currentItem.id,
                editImage: { logicalIndex in
                    openEditor(for: currentItem, logicalIndex: logicalIndex)
                },
                delete: { deleteClipboardItem(currentItem) }
            )
            .id(currentItem.id)
        } else {
            CurrentClipboardStatusCard(state: monitor.snapshot.currentState)
        }
    }

    @ViewBuilder
    private func row(for entry: UnifiedMediaFeedEntry) -> some View {
        switch entry {
        case let .clipboard(item):
            ClipboardItemRow(
                item: item,
                makeCurrent: { makeCurrent(item) },
                delete: { deleteClipboardItem(item) }
            )
        case let .image(image):
            UnifiedImageRow(
                entry: image,
                model: screenshots,
                clipboard: monitor,
                makeClipboardItemCurrent: {
                    guard let item = image.clipboardItem else { return }
                    makeCurrent(item)
                },
                copyImage: {
                    guard let item = image.screenshotItem else { return }
                    Task { await screenshots.copy(item) }
                },
                deleteClipboardItem: {
                    guard let item = image.clipboardItem else { return }
                    deleteClipboardItem(item)
                },
                edit: { openEditor(for: image) }
            )
        }
    }

    private func deleteClipboardItem(_ item: ClipboardItem) {
        Task {
            let retainedIDs = Set(monitor.items.lazy.filter { $0.id != item.id }.map(\.id))
            guard
                await screenshots.removeClipboardCache(
                    for: item,
                    retainingClipboardItemIDs: retainedIDs
                )
            else { return }
            await monitor.delete(itemID: item.id)
        }
    }

    private func openEditor(for image: UnifiedMediaImageEntry) {
        if let item = image.screenshotItem {
            edit(item)
            return
        }
        guard let clipboardItem = image.clipboardItem,
            let logicalIndex = image.logicalIndex
        else { return }
        Task {
            if let item = await screenshots.resolveClipboardImage(
                from: clipboardItem,
                logicalIndex: logicalIndex
            ) {
                edit(item)
            }
        }
    }

    private func openEditor(for item: ClipboardItem, logicalIndex: Int) {
        Task {
            if let resolved = await screenshots.resolveClipboardImage(
                from: item,
                logicalIndex: logicalIndex
            ) {
                edit(resolved)
            }
        }
    }

    private func makeCurrent(_ item: ClipboardItem) {
        Task { try? await monitor.makeCurrent(itemID: item.id) }
    }

    private func openHandoffSettings() {
        if let url = URL(
            string: "x-apple.systempreferences:com.apple.AirDrop-Handoff-Settings.extension"
        ) {
            NSWorkspace.shared.open(url)
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    @ViewBuilder
    private var emptyView: some View {
        CompactClipboardEmptyView(
            title: emptyTitle,
            detail: emptyDescription,
            symbol: emptySymbol,
            actionTitle: nil,
            action: nil
        )
    }

    private var emptyTitle: String {
        switch filter {
        case .all: "No Clipboard Items or Images"
        case .text: "No Text Yet"
        case .images: "No Images Yet"
        }
    }

    private var emptySymbol: String {
        switch filter {
        case .all: "rectangle.stack"
        case .text: "text.alignleft"
        case .images: "photo.on.rectangle"
        }
    }

    private var emptyDescription: String {
        switch filter {
        case .all:
            monitor.isPaused
                ? "Clipboard history is paused. Watched screenshots will still appear here."
                : "Copy something or create a screenshot to add it to this workspace."
        case .text:
            monitor.isPaused ? "Clipboard history is paused." : "Copy text, a link, a file, or a PDF to add it here."
        case .images:
            "Copied images and watched screenshots appear here."
        }
    }

    @ViewBuilder
    private var statusMessages: some View {
        if monitor.historyNeedsRecovery {
            Button("Retry History Recovery") {
                Task { await monitor.retryHistoryRecovery() }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        if let clipboardMessage = monitor.snapshot.statusMessage {
            Text(clipboardMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
        if let screenshotMessage = screenshots.statusMessage,
            screenshotMessage != monitor.snapshot.statusMessage
        {
            Text(screenshotMessage)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
        }
    }
}
