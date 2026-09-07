import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Flattens an annotation snapshot over its source image. Rendering occurs at
/// the source image's exact pixel dimensions, independent of display scale.
public enum AnnotationRenderer {
    public static func sourcePixelSize(at imageURL: URL) throws -> PixelSize {
        try sourcePixelSize(data: Data(contentsOf: imageURL))
    }

    public static func sourcePixelSize(data: Data) throws -> PixelSize {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
            let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
            width > 0,
            height > 0
        else {
            throw AnnotationError.sourceImageUnavailable
        }
        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        if 5...8 ~= orientation {
            return PixelSize(width: height, height: width)
        }
        return PixelSize(width: width, height: height)
    }

    public static func flattenedPNGData(
        sourceImageURL: URL,
        snapshot: AnnotationDocumentSnapshot
    ) throws -> Data {
        try flattenedPNGData(
            sourceImageData: Data(contentsOf: sourceImageURL),
            snapshot: snapshot
        )
    }

    public static func flattenedPNGData(
        sourceImageData: Data,
        snapshot: AnnotationDocumentSnapshot
    ) throws -> Data {
        try snapshot.validate()
        let sourceImage = try loadOrientedImage(data: sourceImageData)
        let actualSize = PixelSize(
            width: Double(sourceImage.width),
            height: Double(sourceImage.height)
        )
        guard dimensionsMatch(snapshot.sourcePixelSize, actualSize) else {
            throw AnnotationError.sourceImageSizeMismatch(
                expected: snapshot.sourcePixelSize,
                actual: actualSize
            )
        }

        let width = sourceImage.width
        let height = sourceImage.height
        let (bytesPerRow, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (_, totalOverflow) = bytesPerRow.multipliedReportingOverflow(by: height)
        guard !rowOverflow, !totalOverflow,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else {
            throw AnnotationError.bitmapAllocationFailed
        }

        context.interpolationQuality = .high
        context.draw(
            sourceImage,
            in: CGRect(x: 0, y: 0, width: width, height: height)
        )
        for annotation in snapshot.annotations {
            switch annotation.kind {
            case .rectangle:
                drawRectangle(annotation, imageHeight: Double(height), in: context)
            case .arrow:
                drawArrow(annotation, imageHeight: Double(height), in: context)
            case .text:
                drawText(annotation, imageHeight: Double(height), in: context)
            }
        }

        guard let flattened = context.makeImage() else {
            throw AnnotationError.bitmapAllocationFailed
        }
        let result = NSMutableData()
        guard
            let destination = CGImageDestinationCreateWithData(
                result,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else {
            throw AnnotationError.pngEncodingFailed
        }
        let properties: [CFString: Any] = [
            kCGImagePropertyColorModel: kCGImagePropertyColorModelRGB,
            kCGImagePropertyProfileName: "sRGB IEC61966-2.1",
            kCGImagePropertyPNGDictionary: [
                kCGImagePropertyPNGsRGBIntent: 0
            ],
        ]
        CGImageDestinationAddImage(destination, flattened, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw AnnotationError.pngEncodingFailed
        }
        return result as Data
    }

    public static func writeFlattenedPNG(
        sourceImageURL: URL,
        snapshot: AnnotationDocumentSnapshot,
        destinationURL: URL
    ) throws {
        let data = try flattenedPNGData(sourceImageURL: sourceImageURL, snapshot: snapshot)
        try data.write(to: destinationURL, options: [.atomic, .withoutOverwriting])
    }

    public static func flattenedPDFData(
        sourceImageURL: URL,
        snapshot: AnnotationDocumentSnapshot
    ) throws -> Data {
        try flattenedPDFData(
            sourceImageData: Data(contentsOf: sourceImageURL),
            snapshot: snapshot
        )
    }

    public static func flattenedPDFData(
        sourceImageData: Data,
        snapshot: AnnotationDocumentSnapshot
    ) throws -> Data {
        let png = try flattenedPNGData(sourceImageData: sourceImageData, snapshot: snapshot)
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else {
            throw AnnotationError.pdfEncodingFailed
        }
        let result = NSMutableData()
        guard let consumer = CGDataConsumer(data: result as CFMutableData) else {
            throw AnnotationError.pdfEncodingFailed
        }
        var mediaBox = CGRect(
            x: 0,
            y: 0,
            width: snapshot.sourcePixelSize.width,
            height: snapshot.sourcePixelSize.height
        )
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw AnnotationError.pdfEncodingFailed
        }
        context.beginPDFPage(nil)
        context.draw(image, in: mediaBox)
        context.endPDFPage()
        context.closePDF()
        guard !result.isEmpty else { throw AnnotationError.pdfEncodingFailed }
        return result as Data
    }

    private static func loadOrientedImage(data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > 0
        else {
            throw AnnotationError.sourceImageUnavailable
        }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let rawWidth = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let rawHeight = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        guard rawWidth > 0, rawHeight > 0 else {
            throw AnnotationError.sourceImageUnavailable
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(rawWidth, rawHeight),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw AnnotationError.sourceImageUnavailable
        }
        return image
    }

    private static func dimensionsMatch(_ lhs: PixelSize, _ rhs: PixelSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }

    private static func cgColor(_ color: AnnotationColor) -> CGColor {
        CGColor(
            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
            components: [color.red, color.green, color.blue, color.alpha]
        )!
    }

    private static func drawRectangle(
        _ annotation: Annotation,
        imageHeight: Double,
        in context: CGContext
    ) {
        let frame = annotation.frame
        let rect = CGRect(
            x: frame.origin.x,
            y: imageHeight - frame.origin.y - frame.size.height,
            width: frame.size.width,
            height: frame.size.height
        )
        let lineWidth = annotation.strokeWidth ?? 1
        let inset = min(
            lineWidth / 2,
            max(0, min(rect.width, rect.height) / 2 - 0.5)
        )
        let strokeRect = rect.insetBy(dx: inset, dy: inset)
        let radius = min(
            max(0, annotation.effectiveCornerRadius - inset),
            min(strokeRect.width, strokeRect.height) / 2
        )
        context.saveGState()
        context.setStrokeColor(cgColor(annotation.color))
        context.setLineWidth(lineWidth)
        context.setLineJoin(.round)
        context.addPath(CGPath(roundedRect: strokeRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawArrow(
        _ annotation: Annotation,
        imageHeight: Double,
        in context: CGContext
    ) {
        guard let start = annotation.startPoint, let end = annotation.endPoint else { return }
        let startPoint = CGPoint(x: start.x, y: imageHeight - start.y)
        let endPoint = CGPoint(x: end.x, y: imageHeight - end.y)
        let width = annotation.strokeWidth ?? 1
        let angle = atan2(endPoint.y - startPoint.y, endPoint.x - startPoint.x)
        let headLength = max(12, width * 4)
        let headAngle = Double.pi / 7

        context.saveGState()
        context.setStrokeColor(cgColor(annotation.color))
        context.setLineWidth(width)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: startPoint)
        context.addLine(to: endPoint)
        context.move(to: endPoint)
        context.addLine(
            to: CGPoint(
                x: endPoint.x - headLength * cos(angle - headAngle),
                y: endPoint.y - headLength * sin(angle - headAngle)
            ))
        context.move(to: endPoint)
        context.addLine(
            to: CGPoint(
                x: endPoint.x - headLength * cos(angle + headAngle),
                y: endPoint.y - headLength * sin(angle + headAngle)
            ))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawText(
        _ annotation: Annotation,
        imageHeight: Double,
        in context: CGContext
    ) {
        guard let text = annotation.text, !text.isEmpty else { return }
        let frame = annotation.frame
        let font = CTFontCreateWithName(
            "Helvetica" as CFString,
            annotation.fontSize ?? 12,
            nil
        )
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: cgColor(annotation.color),
        ]
        let attributed = CFAttributedStringCreate(
            kCFAllocatorDefault,
            text as CFString,
            attributes as CFDictionary
        )!
        let framesetter = CTFramesetterCreateWithAttributedString(attributed)

        context.saveGState()
        // Core Text uses a lower-left origin; this establishes the editor's
        // top-left pixel coordinate system while keeping glyphs upright.
        context.textMatrix = .identity
        context.translateBy(x: 0, y: imageHeight)
        context.scaleBy(x: 1, y: -1)
        let path = CGPath(
            rect: CGRect(
                x: frame.origin.x,
                y: frame.origin.y,
                width: frame.size.width,
                height: frame.size.height
            ),
            transform: nil
        )
        let textFrame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        CTFrameDraw(textFrame, context)
        context.restoreGState()
    }
}
