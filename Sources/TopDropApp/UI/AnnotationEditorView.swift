@preconcurrency import AppKit
import SwiftUI
import TopDropCore

struct AnnotationEditorView: View {
    @ObservedObject var model: AnnotationEditorModel

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geometry in
                editorToolbar(width: geometry.size.width)
            }
            .frame(height: 48)
            Divider()
            if !model.isLoaded {
                ProgressView("Loading editor…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let image = model.image {
                HStack(spacing: 0) {
                    toolRail
                    Divider()
                    AnnotationCanvas(model: model, image: image)
                        .background(Color(nsColor: .underPageBackgroundColor))
                    if model.isInspectorVisible {
                        Divider()
                        AnnotationInspector(model: model)
                            .frame(width: 250)
                    }
                }
            } else {
                ContentUnavailableView("Image Unavailable", systemImage: "exclamationmark.triangle")
            }
            statusBar
        }
        .frame(minWidth: 760, minHeight: 520)
        .task { await model.load() }
        .onDeleteCommand { model.deleteSelection() }
        .onExitCommand {
            if model.textCopy.state == .recognizing {
                model.textCopy.cancel()
            } else if model.editingTextID != nil {
                model.finishTextEditing()
            } else if model.selectedTool != nil {
                model.cancelPlacement()
            } else {
                model.select(nil)
            }
        }
    }

    private func editorToolbar(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(model.item.sourceFilename)
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.annotations.count) object\(model.annotations.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: width >= 980 ? 210 : 120, alignment: .leading)

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                Button {
                    model.undo()
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .disabled(!model.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo — ⌘Z")
                Button {
                    model.redo()
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .disabled(!model.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo — ⇧⌘Z")
            }

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                Button {
                    model.duplicateSelection()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(model.selectedID == nil)
                .keyboardShortcut("d", modifiers: .command)
                .help("Duplicate selected object — ⌘D")

                Button(role: .destructive) {
                    model.deleteSelection()
                } label: {
                    Image(systemName: "trash")
                }
                .disabled(model.selectedID == nil)
                .help("Delete selected object")
            }

            Divider().frame(height: 24)

            HStack(spacing: 2) {
                Button {
                    model.setZoom(model.zoom / 1.2)
                } label: {
                    Image(systemName: "minus.magnifyingglass")
                }
                .help("Zoom out")
                Button {
                    model.setZoom(1)
                } label: {
                    Text("\(Int(model.zoom * 100))%")
                        .font(.caption.monospacedDigit())
                        .frame(width: 46)
                }
                .help("Fit image")
                Button {
                    model.setZoom(model.zoom * 1.2)
                } label: {
                    Image(systemName: "plus.magnifyingglass")
                }
                .help("Zoom in")
            }

            Spacer(minLength: 8)

            ImageTextCopyButton(
                controller: model.textCopy,
                sources: [
                    ImageTextCopySource(id: 0) {
                        try await model.library.originalImageData(for: model.item.id)
                    }
                ], clipboard: model.clipboard, showsTitle: width >= 1_160, inTray: false
            )
            .disabled(!model.isLoaded)

            Button {
                Task { await model.copyUpdatedImageToClipboard() }
            } label: {
                if width >= 980 {
                    Label("Update Clipboard", systemImage: "doc.on.clipboard")
                } else {
                    Image(systemName: "doc.on.clipboard")
                }
            }
            .buttonStyle(MonochromeProminentButtonStyle())
            .help("Replace the current clipboard with this flattened edited image")
            .accessibilityLabel("Update Clipboard")

            Menu {
                Button("Export PNG…") { Task { await model.export(.png) } }
                Button("Export PDF…") { Task { await model.export(.pdf) } }
                Divider()
                Button("Save Copy to Library") { Task { await model.saveCopy() } }
                Button("Download PNG to Desktop") { Task { await model.downloadToDesktop() } }
            } label: {
                if width >= 980 {
                    Label("Export", systemImage: "square.and.arrow.up")
                } else {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            .help("Export Image")
            .accessibilityLabel("Export Image")

            Button {
                model.isInspectorVisible.toggle()
            } label: {
                Image(systemName: "sidebar.right")
            }
            .help(model.isInspectorVisible ? "Hide format inspector" : "Show format inspector")
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 48)
        .background(.bar)
    }

    private var toolRail: some View {
        VStack(spacing: 6) {
            ForEach(AnnotationEditorTool.allCases) { tool in
                Button {
                    model.chooseTool(tool)
                } label: {
                    Image(systemName: tool.symbol)
                        .font(.system(size: 15, weight: model.selectedTool == tool ? .semibold : .regular))
                        .frame(width: 30, height: 30)
                        .background {
                            if model.selectedTool == tool {
                                RoundedRectangle(cornerRadius: 7)
                                    .fill(.primary.opacity(0.12))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 7)
                                            .stroke(.primary.opacity(0.75), lineWidth: 1)
                                    }
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(toolHelp(tool))
                .accessibilityLabel(tool.title)
            }
            Spacer()
        }
        .padding(.vertical, 10)
        .frame(width: 46)
        .background(.bar)
    }

    @ViewBuilder
    private var statusBar: some View {
        Divider()
        HStack(spacing: 8) {
            Image(systemName: model.selectedTool?.symbol ?? "cursorarrow.click")
            Text(statusText)
                .lineLimit(1)
            Spacer()
            if let message = model.statusMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 26)
        .background(.bar)
    }

    private var statusText: String {
        switch model.selectedTool {
        case nil: "Selection mode — click an object to edit; drag it or its handles."
        case .rectangle?: "Place rounded box — drag on the image; selection resumes afterward."
        case .arrow?: "Place arrow — drag from its tail to its head; selection resumes afterward."
        case .text?: "Place text box — drag its frame, then type; selection resumes afterward."
        }
    }

    private func toolHelp(_ tool: AnnotationEditorTool) -> String {
        switch tool {
        case .rectangle: "Place a rounded box; then automatically return to selection"
        case .arrow: "Place an arrow; then automatically return to selection"
        case .text: "Place a text box; then automatically return to selection"
        }
    }
}
