import CoreGraphics
import Foundation

/// Aspect-fit conversion between a view's point coordinates and the source
/// image's pixel coordinates. `backingScaleFactor` intentionally does not
/// participate: annotations always remain stable when a window moves between
/// Retina and non-Retina displays.
public struct AnnotationViewportTransform: Equatable, Sendable {
    public var sourcePixelSize: PixelSize
    public var viewportPointSize: PixelSize
    public var zoom: Double
    public var panInViewPoints: PixelPoint

    public init(
        sourcePixelSize: PixelSize,
        viewportPointSize: PixelSize,
        zoom: Double = 1,
        panInViewPoints: PixelPoint = .zero
    ) {
        self.sourcePixelSize = sourcePixelSize
        self.viewportPointSize = viewportPointSize
        self.zoom = zoom
        self.panInViewPoints = panInViewPoints
    }

    public var scale: Double {
        guard sourcePixelSize.isValid, viewportPointSize.isValid else { return 0 }
        let fitted = min(
            viewportPointSize.width / sourcePixelSize.width,
            viewportPointSize.height / sourcePixelSize.height
        )
        return fitted * min(max(zoom, 0.05), 64)
    }

    public var imageOriginInView: PixelPoint {
        let renderedWidth = sourcePixelSize.width * scale
        let renderedHeight = sourcePixelSize.height * scale
        return PixelPoint(
            x: (viewportPointSize.width - renderedWidth) / 2 + panInViewPoints.x,
            y: (viewportPointSize.height - renderedHeight) / 2 + panInViewPoints.y
        )
    }

    public func sourceToView(_ point: PixelPoint) -> PixelPoint {
        let origin = imageOriginInView
        return PixelPoint(x: origin.x + point.x * scale, y: origin.y + point.y * scale)
    }

    public func viewToSource(_ point: PixelPoint) -> PixelPoint {
        guard scale > 0 else { return .zero }
        let origin = imageOriginInView
        return PixelPoint(x: (point.x - origin.x) / scale, y: (point.y - origin.y) / scale)
    }

    public func sourceToView(_ rect: PixelRect) -> PixelRect {
        let origin = sourceToView(rect.origin)
        return PixelRect(
            origin: origin,
            size: PixelSize(width: rect.size.width * scale, height: rect.size.height * scale)
        )
    }

    public func viewToSource(_ rect: PixelRect) -> PixelRect {
        guard scale > 0 else { return PixelRect(origin: .zero, size: .zero) }
        let origin = viewToSource(rect.origin)
        return PixelRect(
            origin: origin,
            size: PixelSize(width: rect.size.width / scale, height: rect.size.height / scale)
        )
    }
}
