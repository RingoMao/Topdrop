@preconcurrency import AppKit
import Combine
import Foundation
import TopDropCore
import UniformTypeIdentifiers

enum AnnotationEditorTool: String, CaseIterable, Identifiable {
    case rectangle
    case arrow
    case text

    var id: String { rawValue }

    var title: String {
        switch self {
        case .rectangle: "Box"
        case .arrow: "Arrow"
        case .text: "Text Box"
        }
    }

    var symbol: String {
        switch self {
        case .rectangle: "rectangle"
        case .arrow: "arrow.up.right"
        case .text: "character.textbox"
        }
    }
}

@MainActor
final class AnnotationEditorModel: ObservableObject {
    @Published private(set) var annotations: [Annotation] = []
    @Published private(set) var zoom = 1.0
    @Published var selectedID: UUID?
    /// `nil` is the normal selection mode. A value means the next canvas
    /// gesture is placing that object; placement returns to selection mode.
    @Published var selectedTool: AnnotationEditorTool?
    @Published var isInspectorVisible = true
    @Published var editingTextID: UUID?
    @Published var pendingText = "Text"
    @Published var selectedColor = AnnotationColor.red
    @Published var sizeValue = 6.0
    @Published var cornerRadiusValue = 16.0
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var isLoaded = false
    @Published private(set) var versions: [ScreenshotAnnotationVersion] = []
    @Published var statusMessage: String?

    let item: ScreenshotItem
    @Published private(set) var image: NSImage?

    let library: ScreenshotLibrary
    let clipboard: ClipboardMonitor
    let textCopy = ImageTextCopyController()
    private var document: AnnotationDocument?
    private var editSession: ScreenshotEditSession?
    private var persistTask: Task<Void, Never>?
    private var defaultStrokeWidth = 6.0
    private var defaultFontSize = 36.0

    init(item: ScreenshotItem, library: ScreenshotLibrary, clipboard: ClipboardMonitor) {
        self.item = item
        self.library = library
        self.clipboard = clipboard
        image = nil
    }

    var sourcePixelSize: PixelSize { item.pixelSize }
    var selectedAnnotation: Annotation? { annotations.first { $0.id == selectedID } }

    func load() async {
        guard !isLoaded else { return }
        do {
            let imageData = try await library.originalImageData(for: item.id)
            guard let loadedImage = NSImage(data: imageData) else {
                throw AnnotationError.sourceImageUnavailable
            }
            let snapshot = try await library.loadAnnotations(for: item.id)
            editSession = try await library.beginEditSession(for: item.id)
            versions = try await library.annotationVersions(for: item.id)
            document = try AnnotationDocument(
                sourcePixelSize: snapshot.sourcePixelSize,
                annotations: snapshot.annotations
            )
            image = loadedImage
            syncFromDocument()
            isLoaded = true
        } catch {
            statusMessage = message(for: error)
        }
    }

    func select(_ id: UUID?) {
        selectedID = id
        selectedTool = nil
        if editingTextID != id { editingTextID = nil }
        guard let annotation = selectedAnnotation else { return }
        selectedColor = annotation.color
        switch annotation.kind {
        case .rectangle:
            sizeValue = annotation.strokeWidth ?? 6
            cornerRadiusValue = annotation.effectiveCornerRadius
        case .arrow:
            sizeValue = annotation.strokeWidth ?? 6
        case .text: sizeValue = annotation.fontSize ?? 36
        }
    }

    func chooseTool(_ tool: AnnotationEditorTool) {
        selectedTool = selectedTool == tool ? nil : tool
        editingTextID = nil
        selectedID = nil
        guard selectedTool != nil else { return }
        switch tool {
        case .text: sizeValue = defaultFontSize
        case .rectangle, .arrow: sizeValue = defaultStrokeWidth
        }
    }

    func cancelPlacement() {
        selectedTool = nil
        editingTextID = nil
    }

    func addRectangle() {
        guard let document else { return }
        let strokeWidth = selectedAnnotation?.kind == .rectangle ? sizeValue : 6
        let frame = PixelRect(
            x: sourcePixelSize.width * 0.25,
            y: sourcePixelSize.height * 0.25,
            width: sourcePixelSize.width * 0.5,
            height: sourcePixelSize.height * 0.3
        )
        do {
            let id = try document.addRectangle(
                frame: frame,
                color: selectedColor,
                strokeWidth: max(1, strokeWidth)
            )
            mutated()
            select(id)
        } catch { statusMessage = message(for: error) }
    }

    func addArrow() {
        guard let document else { return }
        let width = selectedAnnotation?.kind == .arrow ? sizeValue : 6
        do {
            let id = try document.addArrow(
                start: PixelPoint(
                    x: sourcePixelSize.width * 0.3,
                    y: sourcePixelSize.height * 0.65
                ),
                end: PixelPoint(
                    x: sourcePixelSize.width * 0.7,
                    y: sourcePixelSize.height * 0.35
                ),
                color: selectedColor,
                strokeWidth: max(1, width)
            )
            mutated()
            select(id)
        } catch { statusMessage = message(for: error) }
    }

    func addText() {
        guard let document else { return }
        let fontSize = selectedAnnotation?.kind == .text ? sizeValue : 36
        let frame = PixelRect(
            x: sourcePixelSize.width * 0.2,
            y: sourcePixelSize.height * 0.2,
            width: sourcePixelSize.width * 0.6,
            height: max(80, sourcePixelSize.height * 0.15)
        )
        do {
            let id = try document.addText(
                frame: frame,
                text: pendingText,
                color: selectedColor,
                fontSize: max(6, fontSize)
            )
            mutated()
            select(id)
            editingTextID = id
        } catch { statusMessage = message(for: error) }
    }

    func createAnnotation(
        tool: AnnotationEditorTool,
        from start: PixelPoint,
        to end: PixelPoint
    ) {
        guard let document else { return }
        let horizontalDistance = abs(end.x - start.x)
        let verticalDistance = abs(end.y - start.y)
        let isClick = horizontalDistance < 8 && verticalDistance < 8
        do {
            let id: UUID
            switch tool {
            case .rectangle:
                let targetEnd =
                    isClick
                    ? PixelPoint(
                        x: start.x + sourcePixelSize.width * 0.28,
                        y: start.y + sourcePixelSize.height * 0.2
                    )
                    : end
                id = try document.addRectangle(
                    frame: .enclosing(start, targetEnd, minimumSize: 8),
                    color: selectedColor,
                    strokeWidth: max(1, sizeValue),
                    cornerRadius: nil
                )
            case .arrow:
                let targetEnd =
                    isClick
                    ? PixelPoint(
                        x: start.x + sourcePixelSize.width * 0.25,
                        y: start.y - sourcePixelSize.height * 0.16
                    )
                    : end
                id = try document.addArrow(
                    start: start,
                    end: targetEnd,
                    color: selectedColor,
                    strokeWidth: max(1, sizeValue)
                )
            case .text:
                let targetEnd =
                    isClick
                    ? PixelPoint(
                        x: start.x + sourcePixelSize.width * 0.32,
                        y: start.y + max(80, sourcePixelSize.height * 0.12)
                    )
                    : end
                id = try document.addText(
                    frame: .enclosing(start, targetEnd, minimumSize: 16),
                    text: pendingText,
                    color: selectedColor,
                    fontSize: max(6, sizeValue < 12 ? 36 : sizeValue)
                )
                editingTextID = id
            }
            mutated()
            select(id)
            if tool == .text { editingTextID = id }
        } catch { statusMessage = message(for: error) }
    }

    func move(id: UUID, viewTranslation: CGSize, scale: Double) {
        guard let document, scale > 0 else { return }
        do {
            try document.move(
                id: id,
                by: PixelPoint(
                    x: viewTranslation.width / scale,
                    y: viewTranslation.height / scale
                )
            )
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func resize(id: UUID, viewTranslation: CGSize, scale: Double) {
        guard
            let document,
            let annotation = document.annotations.first(where: { $0.id == id }),
            scale > 0
        else { return }
        let frame = PixelRect(
            x: annotation.frame.origin.x,
            y: annotation.frame.origin.y,
            width: max(8 / scale, annotation.frame.size.width + viewTranslation.width / scale),
            height: max(8 / scale, annotation.frame.size.height + viewTranslation.height / scale)
        )
        do {
            try document.resize(id: id, to: frame)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func resize(
        id: UUID,
        from originalFrame: PixelRect,
        handle: AnnotationResizeHandle,
        viewTranslation: CGSize,
        scale: Double
    ) {
        guard let document, scale > 0 else { return }
        let frame = originalFrame.resized(
            from: handle,
            by: PixelPoint(
                x: viewTranslation.width / scale,
                y: viewTranslation.height / scale
            ),
            minimumSize: max(4, 12 / scale),
            canvas: sourcePixelSize
        )
        do {
            try document.resize(id: id, to: frame)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func moveArrowEndpoint(
        id: UUID,
        isStart: Bool,
        from originalPoint: PixelPoint,
        viewTranslation: CGSize,
        scale: Double
    ) {
        guard let document,
            let arrow = document.annotations.first(where: { $0.id == id }),
            let currentStart = arrow.startPoint,
            let currentEnd = arrow.endPoint,
            scale > 0
        else { return }
        let updated = PixelPoint(
            x: originalPoint.x + viewTranslation.width / scale,
            y: originalPoint.y + viewTranslation.height / scale
        )
        do {
            try document.setArrowEndpoints(
                start: isStart ? updated : currentStart,
                end: isStart ? currentEnd : updated,
                for: id
            )
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func deleteSelection() {
        guard let document, let selectedID else { return }
        do {
            try document.delete(id: selectedID)
            self.selectedID = nil
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func applyColor(_ color: AnnotationColor) {
        selectedColor = color
        guard let document, let selectedID else { return }
        do {
            try document.setColor(color, for: selectedID)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func applySize(_ value: Double) {
        sizeValue = value
        if selectedAnnotation == nil {
            if selectedTool == .text {
                defaultFontSize = max(6, value)
            } else if selectedTool == .rectangle || selectedTool == .arrow {
                defaultStrokeWidth = max(1, value)
            }
        }
        guard let document, let selected = selectedAnnotation else { return }
        do {
            switch selected.kind {
            case .rectangle, .arrow:
                defaultStrokeWidth = max(1, value)
                try document.setStrokeWidth(max(1, value), for: selected.id)
            case .text:
                defaultFontSize = max(6, value)
                try document.setFontSize(max(6, value), for: selected.id)
            }
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func applyCornerRadius(_ value: Double) {
        cornerRadiusValue = value
        guard let document, let selected = selectedAnnotation, selected.kind == .rectangle else {
            return
        }
        do {
            try document.setCornerRadius(max(0, value), for: selected.id)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func useAutomaticCornerRadius() {
        guard let document, let selected = selectedAnnotation, selected.kind == .rectangle else {
            return
        }
        do {
            try document.setCornerRadius(nil, for: selected.id)
            mutated()
            cornerRadiusValue = selectedAnnotation?.effectiveCornerRadius ?? cornerRadiusValue
        } catch { statusMessage = message(for: error) }
    }

    func applySelectedText(_ text: String) {
        pendingText = text
        guard let document, let selected = selectedAnnotation, selected.kind == .text else { return }
        do {
            try document.setText(text, for: selected.id)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func beginTextEditing() {
        guard selectedAnnotation?.kind == .text else { return }
        editingTextID = selectedID
    }

    func finishTextEditing() {
        editingTextID = nil
    }

    func duplicateSelection() {
        guard let document, let selectedID else { return }
        do {
            let duplicateID = try document.duplicate(id: selectedID)
            mutated()
            select(duplicateID)
        } catch { statusMessage = message(for: error) }
    }

    func bringSelectionForward() {
        guard let document, let selectedID else { return }
        do {
            try document.bringForward(id: selectedID)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func sendSelectionBackward() {
        guard let document, let selectedID else { return }
        do {
            try document.sendBackward(id: selectedID)
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func nudgeSelection(horizontal: Double, vertical: Double) {
        guard let document, let selectedID else { return }
        do {
            try document.move(
                id: selectedID,
                by: PixelPoint(x: horizontal, y: vertical)
            )
            mutated()
        } catch { statusMessage = message(for: error) }
    }

    func setZoom(_ value: Double) {
        document?.setZoom(value)
        syncFromDocument()
    }

    func undo() {
        guard document?.undo() == true else { return }
        syncFromDocument()
        persist()
    }

    func redo() {
        guard document?.redo() == true else { return }
        syncFromDocument()
        persist()
    }

    func saveCopy() async {
        guard let document else { return }
        do {
            let url = try await library.saveCopy(id: item.id, annotations: document.snapshot())
            statusMessage = "Saved \(url.lastPathComponent)."
        } catch { statusMessage = message(for: error) }
    }

    func downloadToDesktop() async {
        guard let document else { return }
        do {
            let url = try await library.downloadToDesktop(
                id: item.id,
                annotations: document.annotations.isEmpty ? nil : document.snapshot(),
                destinationDirectory: nil
            )
            statusMessage = "Downloaded \(url.lastPathComponent)."
        } catch { statusMessage = message(for: error) }
    }

    func copyUpdatedImageToClipboard() async {
        guard let document else { return }
        do {
            let data = try await library.flattenedData(
                id: item.id,
                annotations: document.snapshot(),
                format: .png
            )
            try await clipboard.setCurrentImagePNG(
                data,
                sourceApplication: ClipboardSourceApplication(
                    bundleIdentifier: TopDropCore.bundleIdentifier,
                    displayName: "TopDrop"
                )
            )
            statusMessage = "Updated image copied to the clipboard."
        } catch { statusMessage = message(for: error) }
    }

    func export(_ format: AnnotationExportFormat) async {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.allowedContentTypes = [format == .png ? .png : .pdf]
        let baseName = URL(fileURLWithPath: item.sourceFilename)
            .deletingPathExtension().lastPathComponent
        panel.nameFieldStringValue = "\(baseName) Annotated.\(format.preferredFilenameExtension)"
        guard panel.runModal() == .OK, let destinationURL = panel.url else { return }
        do {
            let url = try await library.export(
                id: item.id,
                annotations: document.snapshot(),
                format: format,
                destinationURL: destinationURL
            )
            statusMessage = "Exported \(url.lastPathComponent)."
        } catch { statusMessage = message(for: error) }
    }

    func restore(_ version: ScreenshotAnnotationVersion) async {
        persistTask?.cancel()
        do {
            let restored = try await library.restoreAnnotationVersion(
                id: version.id,
                for: item.id
            )
            document = try AnnotationDocument(
                sourcePixelSize: restored.sourcePixelSize,
                annotations: restored.annotations
            )
            selectedID = nil
            syncFromDocument()
            versions = try await library.annotationVersions(for: item.id)
            statusMessage = "Restored a previous version; the replaced state was preserved."
        } catch {
            statusMessage = message(for: error)
        }
    }

    func finishEditing() async {
        persistTask?.cancel()
        guard let editSession else { return }
        if let snapshot = document?.snapshot() {
            do {
                try await library.saveAnnotations(
                    snapshot,
                    for: item.id,
                    editSession: editSession
                )
            } catch {
                statusMessage = message(for: error)
            }
        }
        await library.endEditSession(editSession)
        self.editSession = nil
    }

    private func mutated() {
        syncFromDocument()
        persist()
    }

    private func syncFromDocument() {
        guard let document else { return }
        annotations = document.annotations
        zoom = document.zoom
        canUndo = document.canUndo
        canRedo = document.canRedo
        if let selectedID, !annotations.contains(where: { $0.id == selectedID }) {
            self.selectedID = nil
        }
    }

    private func persist() {
        guard let snapshot = document?.snapshot(), let editSession else { return }
        persistTask?.cancel()
        persistTask = Task { [weak self, library, item, editSession] in
            do {
                try await Task.sleep(for: .milliseconds(120))
                try Task.checkCancellation()
                try await library.saveAnnotations(
                    snapshot,
                    for: item.id,
                    editSession: editSession
                )
                let refreshed = try await library.annotationVersions(for: item.id)
                guard !Task.isCancelled else { return }
                self?.versions = refreshed
            } catch is CancellationError {
                return
            } catch {
                self?.statusMessage = self?.message(for: error)
            }
        }
    }

    private func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
