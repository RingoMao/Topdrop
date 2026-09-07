import AppKit
import SwiftUI
import TopDropCore

struct AnnotationInspector: View {
    @ObservedObject var model: AnnotationEditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(model.selectedAnnotation.map(kindTitle) ?? "New Object")
                        .font(.headline)
                    Spacer()
                    if model.selectedAnnotation != nil {
                        Text("SELECTED")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                }

                inspectorSection("COLOR") {
                    AnnotationColorControl(
                        color: Binding(
                            get: { model.selectedColor },
                            set: { model.applyColor($0) }
                        )
                    )
                }

                if model.selectedAnnotation?.kind == .text {
                    inspectorSection("TEXT") {
                        TextEditor(
                            text: Binding(
                                get: { model.selectedAnnotation?.text ?? model.pendingText },
                                set: { model.applySelectedText($0) }
                            )
                        )
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .frame(minHeight: 82)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(.primary.opacity(0.18), lineWidth: 1)
                        }
                    }
                }

                inspectorSection(sizeTitle) {
                    HStack {
                        Slider(
                            value: Binding(
                                get: { model.sizeValue },
                                set: { model.applySize($0) }
                            ),
                            in: sizeRange
                        )
                        Text(model.sizeValue.formatted(.number.precision(.fractionLength(0))))
                            .font(.caption.monospacedDigit())
                            .frame(width: 34, alignment: .trailing)
                    }
                }

                if let selected = model.selectedAnnotation, selected.kind == .rectangle {
                    inspectorSection("CORNER RADIUS") {
                        HStack {
                            Slider(
                                value: Binding(
                                    get: { model.cornerRadiusValue },
                                    set: { model.applyCornerRadius($0) }
                                ),
                                in: 0...max(1, min(selected.frame.size.width, selected.frame.size.height) / 2)
                            )
                            Text(model.cornerRadiusValue.formatted(.number.precision(.fractionLength(0))))
                                .font(.caption.monospacedDigit())
                                .frame(width: 34, alignment: .trailing)
                        }
                        Button("Automatic") { model.useAutomaticCornerRadius() }
                            .controlSize(.small)
                            .disabled(selected.cornerRadius == nil)
                            .help("Use TopDrop's adaptive small inside/outside corner radius")
                    }
                }

                if let selected = model.selectedAnnotation {
                    inspectorSection("POSITION & SIZE") {
                        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                            GridRow {
                                metric("X", selected.frame.origin.x)
                                metric("Y", selected.frame.origin.y)
                            }
                            GridRow {
                                metric("W", selected.frame.size.width)
                                metric("H", selected.frame.size.height)
                            }
                        }
                    }

                    inspectorSection("ARRANGE") {
                        HStack(spacing: 6) {
                            Button {
                                model.bringSelectionForward()
                            } label: {
                                Label("Forward", systemImage: "square.2.layers.3d.top.filled")
                            }
                            Button {
                                model.sendSelectionBackward()
                            } label: {
                                Label("Backward", systemImage: "square.2.layers.3d.bottom.filled")
                            }
                        }
                        .labelStyle(.iconOnly)
                        .help("Change object stacking order")
                    }
                } else {
                    Text(
                        "Choose Box, Arrow, or Text Box, then drag directly on the image. Each object keeps its own color and size."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
        }
        .background(.bar)
    }

    private var sizeTitle: String {
        usesFontSize ? "FONT SIZE" : "LINE WIDTH"
    }

    private var sizeRange: ClosedRange<Double> {
        usesFontSize ? 8...200 : 1...40
    }

    private var usesFontSize: Bool {
        model.selectedAnnotation?.kind == .text
            || (model.selectedAnnotation == nil && model.selectedTool == .text)
    }

    private func kindTitle(_ annotation: Annotation) -> String {
        switch annotation.kind {
        case .rectangle: "Box"
        case .arrow: "Arrow"
        case .text: "Text Box"
        }
    }

    private func inspectorSection<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func metric(_ label: String, _ value: Double) -> some View {
        HStack(spacing: 4) {
            Text(label).foregroundStyle(.secondary)
            Text(value.formatted(.number.precision(.fractionLength(0))))
                .monospacedDigit()
        }
        .font(.caption)
    }
}
