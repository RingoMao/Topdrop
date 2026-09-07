import CoreGraphics

/// Content and scrollbar hit slop for the global scroll monitor. This does not
/// change mouse hit testing or outside-click dismissal.
public enum TrayScrollProtection {
    public static let margin: CGFloat = 24

    public static func contains(
        _ pointer: CGPoint,
        trayFrame: CGRect,
        screenFrame: CGRect,
        activationDistance: CGFloat
    ) -> Bool {
        guard !trayFrame.isEmpty, !trayFrame.isNull,
            trayFrame.minX.isFinite, trayFrame.minY.isFinite,
            trayFrame.width.isFinite, trayFrame.height.isFinite
        else { return false }
        if trayFrame.contains(pointer) { return true }
        // Keep the actual screen-edge gesture strip usable with auto-hidden
        // menu bars and nearly full-width laptop trays.
        let topDistance = screenFrame.maxY - pointer.y
        if topDistance >= -0.5 && topDistance <= activationDistance { return false }
        return trayFrame.insetBy(dx: -margin, dy: -margin).contains(pointer)
    }
}
