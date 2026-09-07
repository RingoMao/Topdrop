import Foundation

public struct TrayDisplayMetrics: Equatable, Sendable {
    public var visibleFrame: CGRect
    public var isBuiltIn: Bool
    public var physicalSizeMillimeters: CGSize?

    public init(
        visibleFrame: CGRect,
        isBuiltIn: Bool,
        physicalSizeMillimeters: CGSize? = nil
    ) {
        self.visibleFrame = visibleFrame
        self.isBuiltIn = isBuiltIn
        self.physicalSizeMillimeters = physicalSizeMillimeters
    }

    public var physicalDiagonalInches: Double? {
        guard let size = physicalSizeMillimeters,
            size.width > 0,
            size.height > 0
        else { return nil }
        return hypot(size.width, size.height) / 25.4
    }
}

public enum TrayContentMode: String, Equatable, Sendable {
    case twoPane
    case compact
}

public struct TrayPanelLayout: Equatable, Sendable {
    public var frame: CGRect
    public var contentMode: TrayContentMode

    public init(frame: CGRect, contentMode: TrayContentMode) {
        self.frame = frame
        self.contentMode = contentMode
    }
}

public enum TrayPanelLayoutPolicy {
    public static let maximumWidth: CGFloat = 1_320
    public static let compactBreakpoint: CGFloat = 980
    public static let minimumNotesWidth: CGFloat = 300
    public static let minimumClipboardWidth: CGFloat = 560

    /// Calculates a tray frame using only available display geometry. Small
    /// built-in panels get four-point side margins; other displays remain
    /// centered and capped so large desktop screens do not produce an
    /// excessively wide workspace.
    public static func layout(
        for metrics: TrayDisplayMetrics,
        configuredHeight: CGFloat,
        minimumHeight: CGFloat,
        topInset: CGFloat = 0
    ) -> TrayPanelLayout {
        let visible = metrics.visibleFrame.standardized
        let inset = max(0, topInset)
        let compactBuiltIn = isCompactBuiltInDisplay(metrics)
        let horizontalMargin: CGFloat = compactBuiltIn ? 4 : 12
        let availableWidth = max(1, visible.width - horizontalMargin * 2)
        let width = compactBuiltIn ? availableWidth : min(maximumWidth, availableWidth)
        let availableHeight = max(1, visible.height - inset - 8)
        let requestedHeight = max(minimumHeight, configuredHeight)
        let height = min(requestedHeight, availableHeight)
        let frame = CGRect(
            x: visible.midX - width / 2,
            y: visible.maxY - inset - 2 - height,
            width: width,
            height: height
        ).integral
        return TrayPanelLayout(
            frame: frame,
            contentMode: width >= compactBreakpoint ? .twoPane : .compact
        )
    }

    public static func isCompactBuiltInDisplay(_ metrics: TrayDisplayMetrics) -> Bool {
        guard metrics.isBuiltIn else { return false }
        if let diagonal = metrics.physicalDiagonalInches {
            return diagonal < 16
        }
        // Some virtual/scaled built-in modes omit millimetre dimensions. The
        // fallback keeps typical 13/14-inch logical widths nearly full-screen.
        return metrics.visibleFrame.width < 1_600
    }

    public static func notesFractionRange(
        for workspaceWidth: CGFloat,
        dividerWidth: CGFloat = 10
    ) -> ClosedRange<Double> {
        let available = max(1, workspaceWidth - max(0, dividerWidth))
        guard available >= minimumNotesWidth + minimumClipboardWidth else {
            let neutral = min(1, max(0, minimumNotesWidth / available))
            return neutral...neutral
        }
        let lower = Double(minimumNotesWidth / available)
        let upper = Double(1 - minimumClipboardWidth / available)
        return lower...max(lower, upper)
    }

    public static func clampNotesFraction(
        _ fraction: Double,
        workspaceWidth: CGFloat,
        dividerWidth: CGFloat = 10
    ) -> Double {
        let range = notesFractionRange(
            for: workspaceWidth,
            dividerWidth: dividerWidth
        )
        return min(max(fraction, range.lowerBound), range.upperBound)
    }
}
