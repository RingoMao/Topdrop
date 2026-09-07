import SwiftUI
import TopDropCore

@MainActor
final class DevToolsModel: ObservableObject {
    let awake = KeepAwakeController()
    let hiddenFiles = HiddenFilesController()
    @Published private(set) var copying = false
    @Published private(set) var message: String?
    private var stopped = false

    func copy(_ template: BlankFileTemplate, clipboard: ClipboardMonitor, closeTray: @escaping () -> Void) {
        guard !copying, !stopped else { return }
        copying = true
        message = nil
        Task { @MainActor in
            defer { copying = false }
            guard !stopped else { return }
            do {
                try await clipboard.setCurrentFile(template: template)
                message = "File Copied — Paste in Finder"
                guard !stopped else { return }
                NSAccessibility.post(
                    element: NSApplication.shared, notification: .announcementRequested,
                    userInfo: [
                        .announcement: "File Copied. Paste in Finder.",
                        .priority: NSAccessibilityPriorityLevel.medium.rawValue,
                    ])
                closeTray()
            } catch { message = "Could not copy file. Try again." }
        }
    }
    func stop() { stopped = true; awake.stop(); hiddenFiles.stop() }
}

struct DevToolsView: View {
    @ObservedObject var model: DevToolsModel
    let clipboard: ClipboardMonitor
    let hide: () -> Void
    let collapse: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label("Dev Tools", systemImage: "wrench.and.screwdriver")
                        .font(.headline)
                    Spacer()
                    Button(action: collapse) { Image(systemName: "sidebar.right") }
                        .buttonStyle(.borderless)
                        .help("Collapse Dev Tools")
                        .accessibilityLabel("Collapse Dev Tools")
                }
                KeepAwakeControl(model: model.awake)
                Divider()
                HiddenFilesControl(model: model.hiddenFiles, hide: hide)
                Divider()
                Text("New File").font(.subheadline.weight(.semibold))
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                    ForEach(BlankFileTemplate.primary, id: \.self) { template in
                        Button {
                            model.copy(template, clipboard: clipboard, closeTray: hide)
                        } label: {
                            Text(template.title).font(.callout.weight(.medium))
                                .frame(maxWidth: .infinity, minHeight: 30)
                        }
                        .buttonStyle(.bordered)
                        .help("Copy a blank \(template.title) file to paste in Finder")
                        .accessibilityLabel("Copy new \(template.title) file")
                    }
                }
                .disabled(model.copying)
                Menu("More") {
                    ForEach(BlankFileTemplate.more, id: \.self) { template in
                        Button(template.title) { model.copy(template, clipboard: clipboard, closeTray: hide) }
                    }
                }
                .disabled(model.copying)
                Text(model.message ?? "Copy a file, then ⌘V in Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
        }
        .tint(.primary)
    }
}

private struct KeepAwakeControl: View {
    @ObservedObject var model: KeepAwakeController
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Keep Awake", isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) }))
                .toggleStyle(.switch)
                .help(
                    "Keep the display awake while TopDrop runs. Uses more battery; does not prevent lid-close or manual sleep."
                )
                .accessibilityValue(model.isEnabled ? "TopDrop assertion active" : "Off")
            Text(
                model.message
                    ?? (model.isEnabled ? "Until switched off or TopDrop quits" : "Display idle sleep allowed")
            )
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct HiddenFilesControl: View {
    @ObservedObject var model: HiddenFilesController
    let hide: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Hidden Files").font(.callout.weight(.medium))
                    Text(model.state.rawValue).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("⌘⇧.") { model.perform(closeTray: hide) }
                    .disabled(model.isBusy)
                    .help("Toggle hidden files in Finder")
                    .accessibilityLabel("Toggle hidden files in Finder")
            }
            Text(model.message ?? "Finder preference, not live UI status.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
