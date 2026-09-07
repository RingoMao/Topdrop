import Foundation

/// A point expressed in pixels in the source image's top-left coordinate system.
public struct PixelPoint: Codable, Equatable, Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = PixelPoint(x: 0, y: 0)
}

/// A size expressed in source-image pixels, never display points.
public struct PixelSize: Codable, Equatable, Hashable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    public static let zero = PixelSize(width: 0, height: 0)

    public var isValid: Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0
    }
}

/// A rectangle expressed in pixels with an origin at the source image's top-left.
public struct PixelRect: Codable, Equatable, Hashable, Sendable {
    public var origin: PixelPoint
    public var size: PixelSize

    public init(x: Double, y: Double, width: Double, height: Double) {
        origin = PixelPoint(x: x, y: y)
        size = PixelSize(width: width, height: height)
    }

    public init(origin: PixelPoint, size: PixelSize) {
        self.origin = origin
        self.size = size
    }

    public var minX: Double { origin.x }
    public var minY: Double { origin.y }
    public var maxX: Double { origin.x + size.width }
    public var maxY: Double { origin.y + size.height }

    public var isValid: Bool {
        origin.x.isFinite && origin.y.isFinite && size.isValid
    }

    public func offsetBy(dx: Double, dy: Double) -> PixelRect {
        PixelRect(x: origin.x + dx, y: origin.y + dy, width: size.width, height: size.height)
    }

    public static func enclosing(
        _ first: PixelPoint,
        _ second: PixelPoint,
        minimumSize: Double = 1
    ) -> PixelRect {
        let minX = min(first.x, second.x)
        let minY = min(first.y, second.y)
        return PixelRect(
            x: minX,
            y: minY,
            width: max(minimumSize, max(first.x, second.x) - minX),
            height: max(minimumSize, max(first.y, second.y) - minY)
        )
    }

    /// Keeps the entire rectangle on the canvas without changing its size unless
    /// it is larger than the canvas itself.
    public func clamped(to canvas: PixelSize, minimumSize: Double = 1) -> PixelRect {
        let width = min(max(size.width, minimumSize), canvas.width)
        let height = min(max(size.height, minimumSize), canvas.height)
        let x = min(max(origin.x, 0), max(0, canvas.width - width))
        let y = min(max(origin.y, 0), max(0, canvas.height - height))
        return PixelRect(x: x, y: y, width: width, height: height)
    }

    public func resized(
        from handle: AnnotationResizeHandle,
        by delta: PixelPoint,
        minimumSize: Double,
        canvas: PixelSize
    ) -> PixelRect {
        var left = minX
        var top = minY
        var right = maxX
        var bottom = maxY
        switch handle {
        case .topLeading:
            left = min(right - minimumSize, left + delta.x)
            top = min(bottom - minimumSize, top + delta.y)
        case .topTrailing:
            right = max(left + minimumSize, right + delta.x)
            top = min(bottom - minimumSize, top + delta.y)
        case .bottomLeading:
            left = min(right - minimumSize, left + delta.x)
            bottom = max(top + minimumSize, bottom + delta.y)
        case .bottomTrailing:
            right = max(left + minimumSize, right + delta.x)
            bottom = max(top + minimumSize, bottom + delta.y)
        }
        return PixelRect(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        ).clamped(to: canvas, minimumSize: minimumSize)
    }
}

public enum AnnotationResizeHandle: String, Codable, CaseIterable, Hashable, Sendable {
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// An sRGB color suitable for stable Codable persistence.
public struct AnnotationColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public static let red = AnnotationColor(red: 1, green: 0.12, blue: 0.08)
    public static let black = AnnotationColor(red: 0.06, green: 0.06, blue: 0.07)
    public static let gray = AnnotationColor(red: 0.50, green: 0.50, blue: 0.52)
    public static let orange = AnnotationColor(red: 1, green: 0.58, blue: 0)
    public static let yellow = AnnotationColor(red: 1, green: 0.78, blue: 0.05)
    public static let blue = AnnotationColor(red: 0.04, green: 0.52, blue: 1)
    public static let green = AnnotationColor(red: 0.19, green: 0.82, blue: 0.35)
    public static let purple = AnnotationColor(red: 0.75, green: 0.35, blue: 0.95)
    public static let white = AnnotationColor(red: 1, green: 1, blue: 1)

    public var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    /// Creates an sRGB annotation color from a web-style hexadecimal value.
    ///
    /// Both `#RRGGBB` and `#RRGGBBAA` are accepted. The leading hash is
    /// optional so a value copied from macOS's color panel can be pasted
    /// directly. Surrounding whitespace is ignored; shorthand and malformed
    /// values are rejected instead of being guessed.
    public init?(hexString: String) {
        var value = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.first == "#" {
            value.removeFirst()
        }
        guard value.count == 6 || value.count == 8,
            value.unicodeScalars.allSatisfy({ scalar in
                switch scalar.value {
                case 48...57, 65...70, 97...102:
                    true
                default:
                    false
                }
            }),
            let packed = UInt32(value, radix: 16)
        else { return nil }

        if value.count == 6 {
            red = Double((packed >> 16) & 0xFF) / 255
            green = Double((packed >> 8) & 0xFF) / 255
            blue = Double(packed & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((packed >> 24) & 0xFF) / 255
            green = Double((packed >> 16) & 0xFF) / 255
            blue = Double((packed >> 8) & 0xFF) / 255
            alpha = Double(packed & 0xFF) / 255
        }
    }

    /// Canonical uppercase `#RRGGBB` text, adding `AA` when the color is not
    /// fully opaque. Invalid programmatically-created components are clamped
    /// for display; document validation still rejects those colors.
    public var hexString: String {
        hexString(includingAlpha: byte(alpha) != 255)
    }

    /// Canonical uppercase hexadecimal text with explicit alpha control.
    public func hexString(includingAlpha: Bool) -> String {
        let rgb = String(
            format: "#%02X%02X%02X",
            byte(red),
            byte(green),
            byte(blue)
        )
        guard includingAlpha else { return rgb }
        return rgb + String(format: "%02X", byte(alpha))
    }

    private func byte(_ component: Double) -> UInt8 {
        guard component.isFinite else { return 0 }
        return UInt8((min(max(component, 0), 1) * 255).rounded())
    }
}

public enum AnnotationKind: String, Codable, CaseIterable, Sendable {
    case rectangle
    case arrow
    case text
}

public enum AnnotationExportFormat: String, Codable, CaseIterable, Sendable {
    case png
    case pdf

    public var preferredFilenameExtension: String { rawValue }
}

/// A deliberately small annotation vocabulary. Irrelevant fields remain nil so
/// the JSON stays readable and forward migration is straightforward.
public struct Annotation: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var kind: AnnotationKind
    public var frame: PixelRect
    public var color: AnnotationColor
    public var strokeWidth: Double?
    public var text: String?
    public var fontSize: Double?
    public var startPoint: PixelPoint?
    public var endPoint: PixelPoint?
    /// Outer corner radius for rectangle annotations. `nil` means TopDrop's
    /// adaptive small-radius default, preserving compatibility with v1 files.
    public var cornerRadius: Double?

    public init(
        id: UUID = UUID(),
        kind: AnnotationKind,
        frame: PixelRect,
        color: AnnotationColor,
        strokeWidth: Double? = nil,
        text: String? = nil,
        fontSize: Double? = nil,
        startPoint: PixelPoint? = nil,
        endPoint: PixelPoint? = nil,
        cornerRadius: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.frame = frame
        self.color = color
        self.strokeWidth = strokeWidth
        self.text = text
        self.fontSize = fontSize
        self.startPoint = startPoint
        self.endPoint = endPoint
        self.cornerRadius = cornerRadius
    }

    public static func rectangle(
        id: UUID = UUID(),
        frame: PixelRect,
        color: AnnotationColor = .red,
        strokeWidth: Double = 6,
        cornerRadius: Double? = nil
    ) -> Annotation {
        Annotation(
            id: id,
            kind: .rectangle,
            frame: frame,
            color: color,
            strokeWidth: strokeWidth,
            cornerRadius: cornerRadius
        )
    }

    public static func text(
        id: UUID = UUID(),
        frame: PixelRect,
        text: String,
        color: AnnotationColor = .red,
        fontSize: Double = 36
    ) -> Annotation {
        Annotation(
            id: id,
            kind: .text,
            frame: frame,
            color: color,
            text: text,
            fontSize: fontSize,
            cornerRadius: nil
        )
    }

    public static func arrow(
        id: UUID = UUID(),
        start: PixelPoint,
        end: PixelPoint,
        color: AnnotationColor = .red,
        strokeWidth: Double = 6
    ) -> Annotation {
        Annotation(
            id: id,
            kind: .arrow,
            frame: .enclosing(start, end),
            color: color,
            strokeWidth: strokeWidth,
            startPoint: start,
            endPoint: end,
            cornerRadius: nil
        )
    }

    /// A restrained radius that scales with stroke and object size. The value
    /// describes the outside curve; stroking the inset path naturally creates
    /// a matching, smaller inside curve.
    public var effectiveCornerRadius: Double {
        guard kind == .rectangle else { return 0 }
        if let cornerRadius { return cornerRadius }
        return Self.automaticCornerRadius(frame: frame, strokeWidth: strokeWidth ?? 1)
    }

    public static func automaticCornerRadius(frame: PixelRect, strokeWidth: Double) -> Double {
        let sizeLimit = max(0, min(frame.size.width, frame.size.height) * 0.16)
        return min(max(10, strokeWidth * 1.75), sizeLimit)
    }

    public var isValid: Bool {
        guard frame.isValid, color.isValid else { return false }
        switch kind {
        case .rectangle:
            return strokeWidth.map { $0.isFinite && $0 > 0 } == true
                && cornerRadius.map { $0.isFinite && $0 >= 0 } != false
                && text == nil && fontSize == nil
                && startPoint == nil && endPoint == nil
        case .arrow:
            guard strokeWidth.map({ $0.isFinite && $0 > 0 }) == true,
                let startPoint,
                let endPoint,
                [startPoint.x, startPoint.y, endPoint.x, endPoint.y].allSatisfy(\.isFinite)
            else { return false }
            return startPoint != endPoint && text == nil && fontSize == nil
                && cornerRadius == nil
        case .text:
            return text != nil
                && fontSize.map { $0.isFinite && $0 > 0 } == true
                && strokeWidth == nil
                && startPoint == nil && endPoint == nil
                && cornerRadius == nil
        }
    }
}

public struct AnnotationDocumentSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var sourcePixelSize: PixelSize
    public var annotations: [Annotation]

    public init(
        version: Int = AnnotationDocumentSnapshot.currentVersion,
        sourcePixelSize: PixelSize,
        annotations: [Annotation] = []
    ) {
        self.version = version
        self.sourcePixelSize = sourcePixelSize
        self.annotations = annotations
    }

    public func validate() throws {
        guard version == Self.currentVersion else {
            throw AnnotationError.unsupportedDocumentVersion(version)
        }
        guard sourcePixelSize.isValid else { throw AnnotationError.invalidSourceSize }
        guard annotations.allSatisfy(\.isValid) else { throw AnnotationError.invalidAnnotation }
        guard
            annotations.allSatisfy({ annotation in
                let frameIsInside =
                    annotation.frame.minX >= 0
                    && annotation.frame.minY >= 0
                    && annotation.frame.maxX <= sourcePixelSize.width
                    && annotation.frame.maxY <= sourcePixelSize.height
                guard frameIsInside else { return false }
                if annotation.kind == .arrow,
                    let start = annotation.startPoint,
                    let end = annotation.endPoint
                {
                    return [start, end].allSatisfy { point in
                        point.x >= 0 && point.y >= 0
                            && point.x <= sourcePixelSize.width
                            && point.y <= sourcePixelSize.height
                    }
                }
                return true
            })
        else {
            throw AnnotationError.invalidAnnotation
        }
        let identifiers = annotations.map(\.id)
        guard Set(identifiers).count == identifiers.count else {
            throw AnnotationError.duplicateIdentifier
        }
    }
}

public enum AnnotationError: Error, Equatable, LocalizedError, Sendable {
    case invalidSourceSize
    case invalidAnnotation
    case duplicateIdentifier
    case annotationNotFound(UUID)
    case wrongAnnotationKind(expected: AnnotationKind, actual: AnnotationKind)
    case unsupportedDocumentVersion(Int)
    case sourceImageUnavailable
    case sourceImageSizeMismatch(expected: PixelSize, actual: PixelSize)
    case bitmapAllocationFailed
    case pngEncodingFailed
    case pdfEncodingFailed

    public var errorDescription: String? {
        switch self {
        case .invalidSourceSize:
            "The source image size is invalid."
        case .invalidAnnotation:
            "The annotation contains invalid geometry or styling."
        case .duplicateIdentifier:
            "The annotation document contains duplicate identifiers."
        case let .annotationNotFound(id):
            "Annotation \(id) was not found."
        case let .wrongAnnotationKind(expected, actual):
            "This operation requires a \(expected.rawValue) annotation, not \(actual.rawValue)."
        case let .unsupportedDocumentVersion(version):
            "Annotation document version \(version) is not supported."
        case .sourceImageUnavailable:
            "The source image could not be decoded."
        case let .sourceImageSizeMismatch(expected, actual):
            "The annotation canvas is \(expected.width)x\(expected.height), but the image is \(actual.width)x\(actual.height)."
        case .bitmapAllocationFailed:
            "A bitmap large enough for this image could not be allocated."
        case .pngEncodingFailed:
            "The annotated PNG could not be encoded."
        case .pdfEncodingFailed:
            "The annotated PDF could not be encoded."
        }
    }
}
