import AppKit
import SwiftUI
import TopDropCore

extension Notification.Name {
    static let topDropTrayDidHide = Notification.Name("TopDrop.TrayDidHide")
    static let topDropImageTextCopied = Notification.Name("TopDrop.ImageTextCopied")
    static let topDropOCRWillStop = Notification.Name("TopDrop.OCRWillStop")
}

struct ImageTextCopySource: Identifiable {
    let id: Int
    let load: @MainActor () async throws -> Data
}

struct ImageTextCopyButton: View {
    @ObservedObject var controller: ImageTextCopyController
    let sources: [ImageTextCopySource]
    let clipboard: ClipboardMonitor
    var showsTitle = false
    var inTray = true
    @State private var showsFeedback = false

    var body: some View {
        // Keep one structural root while swapping button/spinner/menu so their
        // transitions do not trigger the owner's disappearance cancellation.
        HStack(spacing: 0) {
            if controller.state == .recognizing {
                Button {
                    controller.cancel()
                } label: {
                    ProgressView().controlSize(.mini).frame(width: 20, height: 20)
                }
                .help("Cancel Text Recognition")
                .accessibilityLabel("Cancel Text Recognition")
            } else if sources.count > 1 {
                Menu {
                    ForEach(sources) { source in
                        Button("Copy Text from Image \(source.id + 1)") { copy(source) }
                    }
                } label: {
                    controlLabel
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            } else {
                Button {
                    if let source = sources.first { copy(source) }
                } label: {
                    controlLabel
                }
                .disabled(sources.isEmpty)
            }
        }
        .buttonStyle(.borderless)
        .help(inTray ? controller.state.message : "Copy Text from Original Image — ignores annotations")
        .accessibilityLabel(controller.state == .recognizing ? "Cancel Text Recognition" : "Copy Text from Image")
        .accessibilityHint("Recognize the original image and copy plain text. Does not paste or change the image.")
        .popover(isPresented: $showsFeedback) {
            Text(controller.state.message).font(.callout).padding(12)
        }
        .onChange(of: controller.state) { _, state in
            showsFeedback = state == .noText || state == .failed
            if showsFeedback { announce(state.message) }
        }
        .task(id: controller.state) {
            guard controller.state == .copied else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { controller.cancel() }
        }
        .onDisappear { controller.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .topDropTrayDidHide)) { _ in
            if inTray { controller.cancel(); showsFeedback = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: .topDropOCRWillStop)) { _ in
            controller.cancel(); showsFeedback = false
        }
    }

    private var controlLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: controller.state == .copied ? "checkmark" : "text.viewfinder")
                .frame(width: 20, height: 20)
            if showsTitle {
                Text(controller.state == .copied ? "Text Copied" : "Copy Text").lineLimit(1)
            }
        }
    }

    private func copy(_ source: ImageTextCopySource) {
        showsFeedback = false
        controller.copy(load: source.load) { text in
            try await clipboard.setCurrentPlainText(
                text,
                sourceApplication: ClipboardSourceApplication(
                    bundleIdentifier: TopDropCore.bundleIdentifier, displayName: "TopDrop"
                ))
            NotificationCenter.default.post(name: .topDropImageTextCopied, object: nil)
            announce("Text Copied")
        }
    }

    private func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [
                .announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ])
    }
}
