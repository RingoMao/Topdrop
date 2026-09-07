import SwiftUI
import TopDropCore

@MainActor
final class AnnotationEditorWindowManager {
    private let library: ScreenshotLibrary
    private let clipboard: ClipboardMonitor
    private var windows: [UUID: AuxiliaryWindowController] = [:]
    private var models: [UUID: AnnotationEditorModel] = [:]
    private var closingTasks: [UUID: Task<Void, Never>] = [:]
    private var pendingReopens: [UUID: ScreenshotItem] = [:]
    private var isShuttingDown = false

    init(library: ScreenshotLibrary, clipboard: ClipboardMonitor) {
        self.library = library
        self.clipboard = clipboard
    }

    func open(_ item: ScreenshotItem) {
        guard !isShuttingDown else { return }
        if closingTasks[item.id] != nil {
            pendingReopens[item.id] = item
            return
        }
        if let existing = windows[item.id] {
            existing.present()
            return
        }
        let model = AnnotationEditorModel(item: item, library: library, clipboard: clipboard)
        let controller = AuxiliaryWindowController(
            title: "Edit \(item.sourceFilename)",
            autosaveName: "TopDrop.AnnotationEditor.\(item.id.uuidString)",
            size: CGSize(width: 1_120, height: 760),
            rootView: AnyView(AnnotationEditorView(model: model))
        )
        models[item.id] = model
        windows[item.id] = controller
        controller.onClose = { [weak self, weak model] in
            self?.beginClosing(itemID: item.id, model: model)
        }
        controller.present()
    }

    func finishAllEditing() async {
        isShuttingDown = true
        pendingReopens.removeAll(keepingCapacity: false)

        let openModels = Array(models.values)
        openModels.forEach { $0.textCopy.cancel() }
        for controller in windows.values {
            controller.window?.orderOut(nil)
        }
        windows.removeAll(keepingCapacity: false)
        models.removeAll(keepingCapacity: false)
        for model in openModels {
            await model.finishEditing()
        }

        let tasks = Array(closingTasks.values)
        for task in tasks {
            await task.value
        }
        closingTasks.removeAll(keepingCapacity: false)
    }

    private func beginClosing(itemID: UUID, model: AnnotationEditorModel?) {
        model?.textCopy.cancel()
        // Remove the hidden controller immediately so a rapid reopen cannot
        // resurrect a window whose edit session is in the process of ending.
        windows.removeValue(forKey: itemID)
        models.removeValue(forKey: itemID)
        guard closingTasks[itemID] == nil else { return }

        let task = Task {
            if let model {
                await model.finishEditing()
            }
        }
        closingTasks[itemID] = task
        Task { [weak self] in
            await task.value
            self?.completeClosing(itemID: itemID)
        }
    }

    private func completeClosing(itemID: UUID) {
        closingTasks.removeValue(forKey: itemID)
        guard !isShuttingDown, let item = pendingReopens.removeValue(forKey: itemID) else {
            return
        }
        open(item)
    }
}
