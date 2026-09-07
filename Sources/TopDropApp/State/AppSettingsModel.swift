@preconcurrency import AppKit
import Foundation
import SwiftUI
import TopDropCore

@MainActor
final class AppSettingsModel: ObservableObject {
    @Published private(set) var value = AppSettings()
    @Published var lastErrorMessage: String?

    var onChange: ((AppSettings) -> Void)?

    private let store: UserDefaultsSettingsStore
    private var didLoad = false
    private var persistTask: Task<Void, Never>?

    init(store: UserDefaultsSettingsStore = UserDefaultsSettingsStore()) {
        self.store = store
    }

    func load() async {
        value = await store.load()
        value.panelHeight = AppSettings.clampedPanelHeight(value.panelHeight)
        didLoad = true
        onChange?(value)
    }

    func binding<Value>(for keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.value[keyPath: keyPath] },
            set: { newValue in
                self.update { $0[keyPath: keyPath] = newValue }
            }
        )
    }

    func update(_ mutation: (inout AppSettings) -> Void) {
        mutation(&value)
        value.panelHeight = AppSettings.clampedPanelHeight(value.panelHeight)
        onChange?(value)
        persist()
    }

    func replace(with settings: AppSettings) {
        value = settings
        value.panelHeight = AppSettings.clampedPanelHeight(value.panelHeight)
        onChange?(value)
        persist()
    }

    @discardableResult
    func chooseScreenshotFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Choose a Screenshot-Only Folder"
        panel.message =
            "TopDrop imports supported screenshots created in this folder. Source files are never changed or deleted."
        panel.prompt = "Use Folder"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }

        do {
            let bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: [.isDirectoryKey],
                relativeTo: nil
            )
            update {
                $0.screenshotFolderBookmark = bookmark
                $0.screenshotFolderDisplayPath = url.path
            }
            return url
        } catch {
            lastErrorMessage = "Could not remember the screenshot folder: \(error.localizedDescription)"
            return nil
        }
    }

    func resolvedScreenshotFolder() -> URL? {
        guard let bookmark = value.screenshotFolderBookmark else { return nil }
        do {
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            if stale {
                let refreshed = try url.bookmarkData(
                    options: [],
                    includingResourceValuesForKeys: [.isDirectoryKey],
                    relativeTo: nil
                )
                update { $0.screenshotFolderBookmark = refreshed }
            }
            return url
        } catch {
            lastErrorMessage = "The screenshot folder permission expired. Choose the folder again."
            return nil
        }
    }

    func flush() async {
        persistTask?.cancel()
        persistTask = nil
        guard didLoad else { return }
        do {
            try await store.save(value)
        } catch {
            lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
        }
    }

    private func persist() {
        guard didLoad else { return }
        let snapshot = value
        persistTask?.cancel()
        persistTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(80))
                try Task.checkCancellation()
                try await store.save(snapshot)
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    self.lastErrorMessage = "Could not save settings: \(error.localizedDescription)"
                }
            }
        }
    }
}
