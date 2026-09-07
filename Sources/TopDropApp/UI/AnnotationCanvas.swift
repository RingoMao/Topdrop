import AppKit
import SwiftUI
import TopDropCore

struct AnnotationCanvas: View {
    @ObservedObject var model: AnnotationEditorModel
    let image: NSImage

    @State private var magnificationStartZoom: Double?
    @State private var drawingStart: PixelPoint?
    @State private var drawingCurrent: PixelPoint?
    @FocusState private var hasKeyboardFocus: Bool

    var body: some View {
        GeometryReader { geometry in
            let viewport = PixelSize(
                width: max(1, geometry.size.width),
                height: max(1, geometry.size.height)
            )
            let fittedScale = min(
                viewport.width / max(1, model.sourcePixelSize.width),
                viewport.height / max(1, model.sourcePixelSize.height)
            )
            let renderedSize = CGSize(
                width: model.sourcePixelSize.width * fittedScale * model.zoom,
                height: model.sourcePixelSize.height * fittedScale * model.zoom
            )
            let contentSize = CGSize(
                width: max(geometry.size.width, renderedSize.width),
                height: max(geometry.size.height, renderedSize.height)
            )
            let contentUsesOverflowScale =
                renderedSize.width > geometry.size.width
                || renderedSize.height > geometry.size.height
            let transform = AnnotationViewportTransform(
                sourcePixelSize: model.sourcePixelSize,
                viewportPointSize: PixelSize(
                    width: contentSize.width,
                    height: contentSize.height
                ),
                zoom: contentUsesOverflowScale ? 1 : model.zoom
            )
            let imageFrame = transform.sourceToView(
                PixelRect(origin: .zero, size: model.sourcePixelSize)
            )

            ScrollView([.horizontal, .vertical]) {
                ZStack(alignment: .topLeading) {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(backgroundGesture(transform: transform))

                    Image(nsImage: image)
                        .resizable()
                        .frame(width: imageFrame.size.width, height: imageFrame.size.height)
                        .position(
                            x: imageFrame.origin.x + imageFrame.size.width / 2,
                            y: imageFrame.origin.y + imageFrame.size.height / 2
                        )
                        .shadow(color: .black.opacity(0.2), radius: 5, y: 2)
                        .overlay {
                            Rectangle().stroke(.black.opacity(0.18), lineWidth: 0.5)
                        }
                        .allowsHitTesting(false)

                    ForEach(model.annotations) { annotation in
                        AnnotationOverlay(
                            annotation: annotation,
                            transform: transform,
                            isSelected: model.selectedID == annotation.id,
                            isEditingText: model.editingTextID == annotation.id,
                            select: { model.select(annotation.id) },
                            beginTextEditing: {
                                model.select(annotation.id)
                                model.beginTextEditing()
                            },
                            updateText: { model.applySelectedText($0) },
                            finishTextEditing: { model.finishTextEditing() },
                            move: {
                                model.move(
                                    id: annotation.id,
                                    viewTranslation: $0,
                                    scale: transform.scale
                                )
                            },
                            resize: { handle, translation in
                                model.resize(
                                    id: annotation.id,
                                    from: annotation.frame,
                                    handle: handle,
                                    viewTranslation: translation,
                                    scale: transform.scale
                                )
                            },
                            moveArrowEndpoint: { isStart, point, translation in
                                model.moveArrowEndpoint(
                                    id: annotation.id,
                                    isStart: isStart,
                                    from: point,
                                    viewTranslation: translation,
                                    scale: transform.scale
                                )
                            }
                        )
                        .allowsHitTesting(model.selectedTool == nil)
                    }

                    if let tool = model.selectedTool, let drawingStart, let drawingCurrent {
                        AnnotationDraftOverlay(
                            tool: tool,
                            start: transform.sourceToView(drawingStart),
                            end: transform.sourceToView(drawingCurrent),
                            color: model.selectedColor,
                            lineWidth: max(1, model.sizeValue * transform.scale)
                        )
                        .allowsHitTesting(false)
                    }
                }
                .frame(width: contentSize.width, height: contentSize.height)
                .focusable()
                .focused($hasKeyboardFocus)
                .onMoveCommand(perform: nudge)
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            if magnificationStartZoom == nil {
                                magnificationStartZoom = model.zoom
                            }
                            model.setZoom((magnificationStartZoom ?? model.zoom) * value.magnification)
                        }
                        .onEnded { _ in magnificationStartZoom = nil }
                )
            }
            .scrollIndicators(.automatic)
        }
    }

    private func backgroundGesture(
        transform: AnnotationViewportTransform
    ) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                hasKeyboardFocus = true
                if model.selectedTool == nil {
                    if abs(value.translation.width) < 2, abs(value.translation.height) < 2 {
                        model.select(nil)
                    }
                    return
                }
                guard drawingStart != nil || sourceImageContains(value.startLocation, transform: transform) else {
                    return
                }
                if drawingStart == nil {
                    drawingStart = clampedSourcePoint(value.startLocation, transform: transform)
                }
                drawingCurrent = clampedSourcePoint(value.location, transform: transform)
            }
            .onEnded { value in
                defer {
                    drawingStart = nil
                    drawingCurrent = nil
                }
                guard let tool = model.selectedTool, let start = drawingStart else { return }
                let end = drawingCurrent ?? clampedSourcePoint(value.location, transform: transform)
                model.createAnnotation(tool: tool, from: start, to: end)
            }
    }

    private func clampedSourcePoint(
        _ point: CGPoint,
        transform: AnnotationViewportTransform
    ) -> PixelPoint {
        let source = transform.viewToSource(PixelPoint(x: point.x, y: point.y))
        return PixelPoint(
            x: min(max(source.x, 0), model.sourcePixelSize.width),
            y: min(max(source.y, 0), model.sourcePixelSize.height)
        )
    }

    private func sourceImageContains(
        _ point: CGPoint,
        transform: AnnotationViewportTransform
    ) -> Bool {
        let frame = transform.sourceToView(
            PixelRect(origin: .zero, size: model.sourcePixelSize)
        )
        return point.x >= frame.minX && point.x <= frame.maxX
            && point.y >= frame.minY && point.y <= frame.maxY
    }

    private func nudge(_ direction: MoveCommandDirection) {
        let amount = NSEvent.modifierFlags.contains(.shift) ? 10.0 : 1.0
        switch direction {
        case .left: model.nudgeSelection(horizontal: -amount, vertical: 0)
        case .right: model.nudgeSelection(horizontal: amount, vertical: 0)
        case .up: model.nudgeSelection(horizontal: 0, vertical: -amount)
        case .down: model.nudgeSelection(horizontal: 0, vertical: amount)
        @unknown default: break
        }
    }
}

private struct AnnotationOverlay: View {
    let annotation: Annotation
    let transform: AnnotationViewportTransform
    let isSelected: Bool
    let isEditingText: Bool
    let select: () -> Void
    let beginTextEditing: () -> Void
    let updateText: @MainActor @Sendable (String) -> Void
    let finishTextEditing: () -> Void
    let move: (CGSize) -> Void
    let resize: (AnnotationResizeHandle, CGSize) -> Void
    let moveArrowEndpoint: (Bool, PixelPoint, CGSize) -> Void

    @State private var moveOffset: CGSize = .zero
    @State private var resizeOffset: CGSize = .zero
    @State private var activeHandle: AnnotationResizeHandle?
    @State private var arrowStartOffset: CGSize = .zero
    @State private var arrowEndOffset: CGSize = .zero
    @FocusState private var textIsFocused: Bool

    private var baseFrame: PixelRect { transform.sourceToView(annotation.frame) }

    private var displayFrame: PixelRect {
        guard let activeHandle else { return baseFrame }
        return resizedViewFrame(baseFrame, handle: activeHandle, delta: resizeOffset)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            annotationContent
                .frame(
                    width: max(2, displayFrame.size.width),
                    height: max(2, displayFrame.size.height),
                    alignment: .topLeading
                )
                .contentShape(Rectangle())
                .onTapGesture { select() }
                .onTapGesture(count: 2) {
                    if annotation.kind == .text { beginTextEditing() }
                }
                .gesture(moveGesture)

            if isSelected {
                selectionBorder
                selectionHandles
            }
        }
        .frame(
            width: max(2, displayFrame.size.width),
            height: max(2, displayFrame.size.height)
        )
        .position(
            x: displayFrame.origin.x + displayFrame.size.width / 2 + moveOffset.width,
            y: displayFrame.origin.y + displayFrame.size.height / 2 + moveOffset.height
        )
        .onChange(of: isEditingText) { _, editing in
            textIsFocused = editing
        }
    }

    @ViewBuilder
    private var annotationContent: some View {
        switch annotation.kind {
        case .rectangle:
            RoundedRectangle(
                cornerRadius: annotation.effectiveCornerRadius * transform.scale,
                style: .continuous
            )
            .strokeBorder(
                Color(annotation.color),
                lineWidth: max(1, (annotation.strokeWidth ?? 1) * transform.scale)
            )
        case .arrow:
            ArrowAnnotationShape(
                start: localArrowPoint(annotation.startPoint, offset: arrowStartOffset),
                end: localArrowPoint(annotation.endPoint, offset: arrowEndOffset),
                lineWidth: max(1, (annotation.strokeWidth ?? 1) * transform.scale)
            )
            .stroke(
                Color(annotation.color),
                style: StrokeStyle(
                    lineWidth: max(1, (annotation.strokeWidth ?? 1) * transform.scale),
                    lineCap: .round,
                    lineJoin: .round
                )
            )
        case .text:
            if isEditingText {
                TextField(
                    "Text",
                    text: Binding(
                        get: { annotation.text ?? "" },
                        set: { value in updateText(value) }
                    ),
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .font(.system(size: max(6, (annotation.fontSize ?? 12) * transform.scale)))
                .foregroundStyle(Color(annotation.color))
                .focused($textIsFocused)
                .onExitCommand(perform: finishTextEditing)
                .padding(2)
            } else {
                Text(annotation.text ?? "")
                    .font(.system(size: max(6, (annotation.fontSize ?? 12) * transform.scale)))
                    .foregroundStyle(Color(annotation.color))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .clipped()
            }
        }
    }

    private var selectionBorder: some View {
        Rectangle()
            .stroke(.primary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            .background(Rectangle().stroke(.background, lineWidth: 2).opacity(0.7))
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private var selectionHandles: some View {
        if annotation.kind == .arrow,
            let start = annotation.startPoint,
            let end = annotation.endPoint
        {
            arrowHandle(isStart: true, point: start)
            arrowHandle(isStart: false, point: end)
        } else {
            ForEach(AnnotationResizeHandle.allCases, id: \.self) { handle in
                resizeHandle(handle)
            }
        }
    }

    private func resizeHandle(_ handle: AnnotationResizeHandle) -> some View {
        handleCircle
            .position(handlePosition(handle, in: displayFrame.size))
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        activeHandle = handle
                        resizeOffset = value.translation
                    }
                    .onEnded { value in
                        resize(handle, value.translation)
                        activeHandle = nil
                        resizeOffset = .zero
                    }
            )
            .help("Drag to resize")
    }

    private func arrowHandle(isStart: Bool, point: PixelPoint) -> some View {
        let offset = isStart ? arrowStartOffset : arrowEndOffset
        return
            handleCircle
            .position(localArrowPoint(point, offset: offset))
            .highPriorityGesture(
                DragGesture()
                    .onChanged { value in
                        if isStart { arrowStartOffset = value.translation } else { arrowEndOffset = value.translation }
                    }
                    .onEnded { value in
                        moveArrowEndpoint(isStart, point, value.translation)
                        if isStart { arrowStartOffset = .zero } else { arrowEndOffset = .zero }
                    }
            )
            .help(isStart ? "Move arrow tail" : "Move arrow head")
    }

    private var handleCircle: some View {
        Circle()
            .fill(Color(nsColor: .windowBackgroundColor))
            .frame(width: 10, height: 10)
            .overlay(Circle().stroke(.primary, lineWidth: 1.5))
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { moveOffset = $0.translation }
            .onEnded {
                move($0.translation)
                moveOffset = .zero
            }
    }

    private func localArrowPoint(_ point: PixelPoint?, offset: CGSize) -> CGPoint {
        guard let point else { return .zero }
        let view = transform.sourceToView(point)
        return CGPoint(
            x: view.x - baseFrame.origin.x + offset.width,
            y: view.y - baseFrame.origin.y + offset.height
        )
    }

    private func handlePosition(_ handle: AnnotationResizeHandle, in size: PixelSize) -> CGPoint {
        switch handle {
        case .topLeading: CGPoint(x: 0, y: 0)
        case .topTrailing: CGPoint(x: size.width, y: 0)
        case .bottomLeading: CGPoint(x: 0, y: size.height)
        case .bottomTrailing: CGPoint(x: size.width, y: size.height)
        }
    }

    private func resizedViewFrame(
        _ frame: PixelRect,
        handle: AnnotationResizeHandle,
        delta: CGSize
    ) -> PixelRect {
        var x = frame.origin.x
        var y = frame.origin.y
        var width = frame.size.width
        var height = frame.size.height
        switch handle {
        case .topLeading:
            x += delta.width
            y += delta.height
            width -= delta.width
            height -= delta.height
        case .topTrailing:
            y += delta.height
            width += delta.width
            height -= delta.height
        case .bottomLeading:
            x += delta.width
            width -= delta.width
            height += delta.height
        case .bottomTrailing:
            width += delta.width
            height += delta.height
        }
        return PixelRect(
            x: x,
            y: y,
            width: max(8, width),
            height: max(8, height)
        )
    }
}

private struct AnnotationDraftOverlay: View {
    let tool: AnnotationEditorTool
    let start: PixelPoint
    let end: PixelPoint
    let color: AnnotationColor
    let lineWidth: Double

    private var frame: PixelRect { .enclosing(start, end, minimumSize: 1) }

    var body: some View {
        Group {
            switch tool {
            case .rectangle:
                RoundedRectangle(
                    cornerRadius: min(frame.size.width, frame.size.height) * 0.16,
                    style: .continuous
                )
                .stroke(
                    Color(color),
                    lineWidth: max(1, lineWidth)
                )
                .frame(width: frame.size.width, height: frame.size.height)
                .position(
                    x: frame.origin.x + frame.size.width / 2,
                    y: frame.origin.y + frame.size.height / 2
                )
            case .text:
                Rectangle()
                    .stroke(
                        Color(color),
                        style: StrokeStyle(lineWidth: max(1, lineWidth), dash: [5, 4])
                    )
                    .frame(width: frame.size.width, height: frame.size.height)
                    .position(
                        x: frame.origin.x + frame.size.width / 2,
                        y: frame.origin.y + frame.size.height / 2
                    )
            case .arrow:
                ArrowAnnotationShape(
                    start: CGPoint(x: start.x, y: start.y),
                    end: CGPoint(x: end.x, y: end.y),
                    lineWidth: lineWidth
                )
                .stroke(
                    Color(color),
                    style: StrokeStyle(
                        lineWidth: max(1, lineWidth),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
            }
        }
    }
}

private struct ArrowAnnotationShape: Shape {
    let start: CGPoint
    let end: CGPoint
    let lineWidth: Double

    func path(in _: CGRect) -> Path {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let headLength = max(10, lineWidth * 4)
        let headAngle = Double.pi / 7
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        path.move(to: end)
        path.addLine(
            to: CGPoint(
                x: end.x - headLength * cos(angle - headAngle),
                y: end.y - headLength * sin(angle - headAngle)
            ))
        path.move(to: end)
        path.addLine(
            to: CGPoint(
                x: end.x - headLength * cos(angle + headAngle),
                y: end.y - headLength * sin(angle + headAngle)
            ))
        return path
    }
}

private extension Color {
    init(_ color: AnnotationColor) {
        self.init(
            .sRGB,
            red: color.red,
            green: color.green,
            blue: color.blue,
            opacity: color.alpha
        )
    }
}
