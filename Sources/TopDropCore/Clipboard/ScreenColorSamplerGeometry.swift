import Foundation

/// Deterministic geometry shared by the live screen-color sampler and its tests.
public enum ScreenColorSamplerGeometry {
    /// Converts AppKit's global, bottom-left-origin point into ScreenCaptureKit's
    /// top-left-origin global display space.
    public static func capturePoint(
        fromAppKit point: CGPoint,
        mainDisplayHeight: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x, y: mainDisplayHeight - point.y)
    }

    /// Places the magnifier beside the pointer, flipping it across either axis
    /// before clamping so it never leaves the display that owns the pointer.
    public static func previewFrame(
        pointer: CGPoint,
        screenFrame: CGRect,
        previewSize: CGSize,
        offset: CGFloat = 22,
        margin: CGFloat = 8
    ) -> CGRect {
        guard screenFrame.width > 0,
            screenFrame.height > 0,
            previewSize.width > 0,
            previewSize.height > 0
        else { return .zero }

        let minimumX = screenFrame.minX + margin
        let maximumX = screenFrame.maxX - margin - previewSize.width
        let minimumY = screenFrame.minY + margin
        let maximumY = screenFrame.maxY - margin - previewSize.height

        var x = pointer.x + offset
        if x > maximumX {
            x = pointer.x - offset - previewSize.width
        }

        var y = pointer.y + offset
        if y > maximumY {
            y = pointer.y - offset - previewSize.height
        }

        return CGRect(
            x: min(max(x, minimumX), max(minimumX, maximumX)),
            y: min(max(y, minimumY), max(minimumY, maximumY)),
            width: min(previewSize.width, max(0, screenFrame.width - margin * 2)),
            height: min(previewSize.height, max(0, screenFrame.height - margin * 2))
        )
    }
}
