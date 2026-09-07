import Foundation

/// Mutable editor state for one screenshot. All model geometry is stored in
/// source-image pixels; zoom and viewport state are deliberately transient.
@MainActor
public final class AnnotationDocument {
    public let sourcePixelSize: PixelSize
    public private(set) var annotations: [Annotation]
    public private(set) var zoom: Double = 1

    private var undoStack: [[Annotation]] = []
    private var redoStack: [[Annotation]] = []
    private let historyLimit: Int

    public init(
        sourcePixelSize: PixelSize,
        annotations: [Annotation] = [],
        historyLimit: Int = 100
    ) throws {
        let snapshot = AnnotationDocumentSnapshot(
            sourcePixelSize: sourcePixelSize,
            annotations: annotations
        )
        try snapshot.validate()
        self.sourcePixelSize = sourcePixelSize
        self.annotations = annotations
        self.historyLimit = max(1, historyLimit)
    }

    public convenience init(jsonData: Data, historyLimit: Int = 100) throws {
        let snapshot = try JSONDecoder().decode(AnnotationDocumentSnapshot.self, from: jsonData)
        try snapshot.validate()
        try self.init(
            sourcePixelSize: snapshot.sourcePixelSize,
            annotations: snapshot.annotations,
            historyLimit: historyLimit
        )
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public var hasUnsavedAnnotations: Bool { !annotations.isEmpty }

    public func setZoom(_ value: Double) {
        guard value.isFinite else { return }
        zoom = min(max(value, 0.05), 64)
    }

    public func zoomBy(_ multiplier: Double) {
        guard multiplier.isFinite, multiplier > 0 else { return }
        setZoom(zoom * multiplier)
    }

    @discardableResult
    public func addRectangle(
        frame: PixelRect,
        color: AnnotationColor = .red,
        strokeWidth: Double = 6,
        cornerRadius: Double? = nil
    ) throws -> UUID {
        let annotation = Annotation.rectangle(
            frame: frame.clamped(to: sourcePixelSize),
            color: color,
            strokeWidth: strokeWidth,
            cornerRadius: cornerRadius
        )
        guard annotation.isValid else { throw AnnotationError.invalidAnnotation }
        recordMutation { $0.append(annotation) }
        return annotation.id
    }

    @discardableResult
    public func addText(
        frame: PixelRect,
        text: String,
        color: AnnotationColor = .red,
        fontSize: Double = 36
    ) throws -> UUID {
        let annotation = Annotation.text(
            frame: frame.clamped(to: sourcePixelSize),
            text: text,
            color: color,
            fontSize: fontSize
        )
        guard annotation.isValid else { throw AnnotationError.invalidAnnotation }
        recordMutation { $0.append(annotation) }
        return annotation.id
    }

    @discardableResult
    public func addArrow(
        start: PixelPoint,
        end: PixelPoint,
        color: AnnotationColor = .red,
        strokeWidth: Double = 6
    ) throws -> UUID {
        let clampedStart = clamped(point: start)
        let clampedEnd = clamped(point: end)
        let annotation = Annotation.arrow(
            start: clampedStart,
            end: clampedEnd,
            color: color,
            strokeWidth: strokeWidth
        )
        guard annotation.isValid else { throw AnnotationError.invalidAnnotation }
        recordMutation { $0.append(annotation) }
        return annotation.id
    }

    public func move(id: UUID, by delta: PixelPoint) throws {
        guard delta.x.isFinite, delta.y.isFinite else {
            throw AnnotationError.invalidAnnotation
        }
        try mutateAnnotation(id: id) { annotation in
            if annotation.kind == .arrow,
                let start = annotation.startPoint,
                let end = annotation.endPoint
            {
                let desiredFrame = annotation.frame.offsetBy(dx: delta.x, dy: delta.y)
                let clampedFrame = desiredFrame.clamped(to: sourcePixelSize)
                let appliedX = clampedFrame.origin.x - annotation.frame.origin.x
                let appliedY = clampedFrame.origin.y - annotation.frame.origin.y
                annotation.startPoint = PixelPoint(x: start.x + appliedX, y: start.y + appliedY)
                annotation.endPoint = PixelPoint(x: end.x + appliedX, y: end.y + appliedY)
                annotation.frame = .enclosing(annotation.startPoint!, annotation.endPoint!)
            } else {
                annotation.frame = annotation.frame
                    .offsetBy(dx: delta.x, dy: delta.y)
                    .clamped(to: sourcePixelSize)
            }
        }
    }

    public func resize(id: UUID, to frame: PixelRect) throws {
        guard frame.isValid else { throw AnnotationError.invalidAnnotation }
        try mutateAnnotation(id: id) { annotation in
            let resizedFrame = frame.clamped(to: sourcePixelSize)
            if annotation.kind == .arrow,
                let start = annotation.startPoint,
                let end = annotation.endPoint
            {
                let oldFrame = annotation.frame
                func mapped(_ point: PixelPoint) -> PixelPoint {
                    PixelPoint(
                        x: resizedFrame.minX
                            + ((point.x - oldFrame.minX) / oldFrame.size.width) * resizedFrame.size.width,
                        y: resizedFrame.minY
                            + ((point.y - oldFrame.minY) / oldFrame.size.height) * resizedFrame.size.height
                    )
                }
                annotation.startPoint = mapped(start)
                annotation.endPoint = mapped(end)
                annotation.frame = .enclosing(annotation.startPoint!, annotation.endPoint!)
            } else {
                annotation.frame = resizedFrame
            }
        }
    }

    public func setColor(_ color: AnnotationColor, for id: UUID) throws {
        guard color.isValid else { throw AnnotationError.invalidAnnotation }
        try mutateAnnotation(id: id) { $0.color = color }
    }

    public func setArrowEndpoints(
        start: PixelPoint,
        end: PixelPoint,
        for id: UUID
    ) throws {
        let clampedStart = clamped(point: start)
        let clampedEnd = clamped(point: end)
        guard clampedStart != clampedEnd else { throw AnnotationError.invalidAnnotation }
        try mutateAnnotation(id: id) { annotation in
            guard annotation.kind == .arrow else {
                throw AnnotationError.wrongAnnotationKind(expected: .arrow, actual: annotation.kind)
            }
            annotation.startPoint = clampedStart
            annotation.endPoint = clampedEnd
            annotation.frame = .enclosing(clampedStart, clampedEnd)
        }
    }

    public func setStrokeWidth(_ width: Double, for id: UUID) throws {
        guard width.isFinite, width > 0 else { throw AnnotationError.invalidAnnotation }
        try mutateAnnotation(id: id) { annotation in
            guard annotation.kind == .rectangle || annotation.kind == .arrow else {
                throw AnnotationError.wrongAnnotationKind(
                    expected: .rectangle,
                    actual: annotation.kind
                )
            }
            annotation.strokeWidth = width
        }
    }

    public func setCornerRadius(_ radius: Double?, for id: UUID) throws {
        guard radius.map({ $0.isFinite && $0 >= 0 }) != false else {
            throw AnnotationError.invalidAnnotation
        }
        try mutateAnnotation(id: id) { annotation in
            guard annotation.kind == .rectangle else {
                throw AnnotationError.wrongAnnotationKind(
                    expected: .rectangle,
                    actual: annotation.kind
                )
            }
            let maximum = min(annotation.frame.size.width, annotation.frame.size.height) / 2
            annotation.cornerRadius = radius.map { min($0, maximum) }
        }
    }

    public func setFontSize(_ size: Double, for id: UUID) throws {
        guard size.isFinite, size > 0 else { throw AnnotationError.invalidAnnotation }
        try mutateAnnotation(id: id) { annotation in
            guard annotation.kind == .text else {
                throw AnnotationError.wrongAnnotationKind(expected: .text, actual: annotation.kind)
            }
            annotation.fontSize = size
        }
    }

    public func setText(_ text: String, for id: UUID) throws {
        try mutateAnnotation(id: id) { annotation in
            guard annotation.kind == .text else {
                throw AnnotationError.wrongAnnotationKind(expected: .text, actual: annotation.kind)
            }
            annotation.text = text
        }
    }

    public func delete(id: UUID) throws {
        guard annotations.contains(where: { $0.id == id }) else {
            throw AnnotationError.annotationNotFound(id)
        }
        recordMutation { annotations in
            annotations.removeAll { $0.id == id }
        }
    }

    public func deleteAll() {
        guard !annotations.isEmpty else { return }
        recordMutation { $0.removeAll() }
    }

    @discardableResult
    public func duplicate(id: UUID, offset: PixelPoint = PixelPoint(x: 12, y: 12)) throws -> UUID {
        guard let source = annotations.first(where: { $0.id == id }) else {
            throw AnnotationError.annotationNotFound(id)
        }
        var duplicate = source
        duplicate.id = UUID()
        if duplicate.kind == .arrow,
            let start = duplicate.startPoint,
            let end = duplicate.endPoint
        {
            let desiredFrame = duplicate.frame.offsetBy(dx: offset.x, dy: offset.y)
            let clampedFrame = desiredFrame.clamped(to: sourcePixelSize)
            let dx = clampedFrame.origin.x - duplicate.frame.origin.x
            let dy = clampedFrame.origin.y - duplicate.frame.origin.y
            duplicate.startPoint = PixelPoint(x: start.x + dx, y: start.y + dy)
            duplicate.endPoint = PixelPoint(x: end.x + dx, y: end.y + dy)
            duplicate.frame = .enclosing(duplicate.startPoint!, duplicate.endPoint!)
        } else {
            duplicate.frame = duplicate.frame
                .offsetBy(dx: offset.x, dy: offset.y)
                .clamped(to: sourcePixelSize)
        }
        recordMutation { $0.append(duplicate) }
        return duplicate.id
    }

    public func bringForward(id: UUID) throws {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw AnnotationError.annotationNotFound(id)
        }
        guard index < annotations.index(before: annotations.endIndex) else { return }
        recordMutation { $0.swapAt(index, index + 1) }
    }

    public func sendBackward(id: UUID) throws {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw AnnotationError.annotationNotFound(id)
        }
        guard index > annotations.startIndex else { return }
        recordMutation { $0.swapAt(index, index - 1) }
    }

    @discardableResult
    public func undo() -> Bool {
        guard let previous = undoStack.popLast() else { return false }
        redoStack.append(annotations)
        annotations = previous
        return true
    }

    @discardableResult
    public func redo() -> Bool {
        guard let next = redoStack.popLast() else { return false }
        pushUndo(annotations)
        annotations = next
        return true
    }

    public func snapshot() -> AnnotationDocumentSnapshot {
        AnnotationDocumentSnapshot(
            sourcePixelSize: sourcePixelSize,
            annotations: annotations
        )
    }

    public func encodedJSON(prettyPrinted: Bool = false) throws -> Data {
        let current = snapshot()
        try current.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = prettyPrinted ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
        return try encoder.encode(current)
    }

    public func writeJSON(to url: URL, prettyPrinted: Bool = false) throws {
        try encodedJSON(prettyPrinted: prettyPrinted).write(to: url, options: .atomic)
    }

    private func mutateAnnotation(
        id: UUID,
        mutation: (inout Annotation) throws -> Void
    ) throws {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else {
            throw AnnotationError.annotationNotFound(id)
        }
        var updated = annotations[index]
        try mutation(&updated)
        guard updated.isValid else { throw AnnotationError.invalidAnnotation }
        recordMutation { $0[index] = updated }
    }

    private func recordMutation(_ mutation: (inout [Annotation]) -> Void) {
        let previous = annotations
        mutation(&annotations)
        pushUndo(previous)
        redoStack.removeAll(keepingCapacity: true)
    }

    private func pushUndo(_ state: [Annotation]) {
        undoStack.append(state)
        if undoStack.count > historyLimit {
            undoStack.removeFirst(undoStack.count - historyLimit)
        }
    }

    private func clamped(point: PixelPoint) -> PixelPoint {
        PixelPoint(
            x: min(max(point.x, 0), sourcePixelSize.width),
            y: min(max(point.y, 0), sourcePixelSize.height)
        )
    }
}
