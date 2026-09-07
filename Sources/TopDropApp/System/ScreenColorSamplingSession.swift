@preconcurrency import AppKit
@preconcurrency import ScreenCaptureKit
import TopDropCore

/// A short-lived, cancellable screen-color interaction. Transparent panels
/// consume the confirmation click while a separate HUD magnifies the pixels
/// beneath the pointer and displays their current hexadecimal value.
@MainActor
final class ScreenColorSamplingSession {
    fileprivate struct Sample {
        let color: NSColor
        let hex: String
        let magnifiedImage: CGImage
    }

    private static let captureSide: CGFloat = 14
    private static let magnifiedPixelSide = 11
    private static let refreshInterval = Duration.milliseconds(55)

    private let previewPanel = ScreenColorPreviewPanel()
    private var overlayPanels: [ScreenColorOverlayPanel] = []
    private var previewTask: Task<Void, Never>?
    private var completion: ((NSColor?) -> Void)?
    private var isFinishing = false
    private var lastSample: Sample?
    private var lastSamplePoint: CGPoint?
    private var localKeyMonitor: Any?
    private var interactionTask: Task<Void, Never>?
    private weak var previousApplication: NSRunningApplication?

    static var hasScreenCapturePermission: Bool {
        CGPreflightScreenCaptureAccess()
    }

    static func requestScreenCapturePermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    func start(completion: @escaping (NSColor?) -> Void) {
        guard self.completion == nil else { return }
        self.completion = completion
        let frontmostApplication = NSWorkspace.shared.frontmostApplication
        if frontmostApplication?.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmostApplication
        }
        NSApp.activate(ignoringOtherApps: true)
        installOverlayPanels()
        installKeyMonitor()
        installInteractionFallback()
        previewPanel.update(sample: nil)
        updatePreviewPosition(at: NSEvent.mouseLocation)
        previewPanel.orderFrontRegardless()
        NSCursor.crosshair.set()

        previewTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, !self.isFinishing else { return }
                let point = NSEvent.mouseLocation
                self.updatePreviewPosition(at: point)
                if let sample = await self.capture(at: point) {
                    guard !Task.isCancelled, !self.isFinishing else { return }
                    self.lastSample = sample
                    self.lastSamplePoint = point
                    self.previewPanel.update(sample: sample)
                }
                try? await Task.sleep(for: Self.refreshInterval)
            }
        }
    }

    func cancel() {
        finish(with: nil)
    }

    private func installOverlayPanels() {
        overlayPanels = NSScreen.screens.map { screen in
            let panel = ScreenColorOverlayPanel(screen: screen)
            let view = ScreenColorOverlayView(frame: panel.contentView?.bounds ?? .zero)
            view.onPointerMove = { [weak self] point in
                self?.updatePreviewPosition(at: point)
            }
            view.onSelect = { [weak self] point in
                self?.select(at: point)
            }
            view.onCancel = { [weak self] in
                self?.cancel()
            }
            panel.contentView = view
            panel.acceptsMouseMovedEvents = true
            panel.orderFrontRegardless()
            return panel
        }

        let pointer = NSEvent.mouseLocation
        if let owningPanel = overlayPanels.first(where: { $0.frame.contains(pointer) }),
            let view = owningPanel.contentView
        {
            owningPanel.makeKeyAndOrderFront(nil)
            owningPanel.makeFirstResponder(view)
        }
    }

    private func installKeyMonitor() {
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
            [weak self] event in
            if event.keyCode == 53 {
                self?.cancel()
                return nil
            }
            return event
        }
    }

    /// Full-screen transparent AppKit windows are occasionally omitted from
    /// hit testing by WindowServer (notably across Spaces and fullscreen
    /// displays). Poll the combined-session input state while the short-lived
    /// sampler is active so confirmation and Escape never depend on which
    /// application currently owns the key window. This reads state only; it
    /// does not install an event tap or require Accessibility permission.
    private func installInteractionFallback() {
        guard interactionTask == nil else { return }
        interactionTask = Task { @MainActor [weak self] in
            var inputGate = ScreenColorSamplerInputGate(
                initial: Self.currentInputSnapshot()
            )

            while !Task.isCancelled {
                guard let self, !self.isFinishing else { return }
                switch inputGate.update(Self.currentInputSnapshot()) {
                case .cancel:
                    self.cancel()
                    return
                case .confirm:
                    self.select(at: NSEvent.mouseLocation)
                    return
                case .none:
                    break
                }
                try? await Task.sleep(for: .milliseconds(8))
            }
        }
    }

    private static func currentInputSnapshot() -> ScreenColorSamplerInputSnapshot {
        ScreenColorSamplerInputSnapshot(
            leftMouseDown: CGEventSource.buttonState(.combinedSessionState, button: .left),
            rightMouseDown: CGEventSource.buttonState(.combinedSessionState, button: .right),
            escapeDown: CGEventSource.keyState(.combinedSessionState, key: 53)
        )
    }

    private func select(at point: CGPoint) {
        guard !isFinishing else { return }
        // The HUD already contains the live color under the pointer. Starting a
        // second ScreenCaptureKit request here can block behind the in-flight
        // preview request and leave the full-screen overlays stranded. Commit
        // the visible sample synchronously so one click always exits.
        let nearbyStoredSample: Sample? =
            if let lastSamplePoint,
                hypot(
                    lastSamplePoint.x - point.x,
                    lastSamplePoint.y - point.y
                ) <= 3
            {
                lastSample
            } else {
                nil
            }
        finish(with: nearbyStoredSample?.color ?? lastSample?.color)
    }

    private func finish(with color: NSColor?) {
        guard completion != nil else { return }
        isFinishing = true
        previewTask?.cancel()
        previewTask = nil
        interactionTask?.cancel()
        interactionTask = nil
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        previewPanel.orderOut(nil)
        overlayPanels.forEach { $0.orderOut(nil) }
        overlayPanels.removeAll()
        NSCursor.arrow.set()

        let handler = completion
        completion = nil
        handler?(color)

        let topDropIsFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        if topDropIsFrontmost {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
    }

    private func updatePreviewPosition(at point: CGPoint) {
        guard
            let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.screens.first
        else { return }
        let frame = ScreenColorSamplerGeometry.previewFrame(
            pointer: point,
            screenFrame: screen.frame,
            previewSize: previewPanel.frame.size
        )
        guard frame != .zero else { return }
        previewPanel.setFrame(frame, display: true)
    }

    private func capture(at appKitPoint: CGPoint) async -> Sample? {
        let mainHeight = CGDisplayBounds(CGMainDisplayID()).height
        guard mainHeight.isFinite, mainHeight > 0 else { return nil }
        let capturePoint = ScreenColorSamplerGeometry.capturePoint(
            fromAppKit: appKitPoint,
            mainDisplayHeight: mainHeight
        )
        let side = Self.captureSide
        let captureRect = CGRect(
            x: capturePoint.x - side / 2,
            y: capturePoint.y - side / 2,
            width: side,
            height: side
        )

        // The synthesized Swift async overload traps before `try?` can handle
        // a nil CGImage, even though the Objective-C completion-handler API
        // explicitly declares that image nullable. Use that API directly and
        // preserve its optional result so a display/Space transition merely
        // skips one preview frame.
        guard let image = await Self.captureImageSafely(in: captureRect),
            let color = Self.centerColor(in: image),
            let rgb = color.usingColorSpace(.sRGB),
            let magnifiedImage = Self.centerCrop(
                image,
                maximumSide: Self.magnifiedPixelSide
            )
        else { return nil }

        let hex = AnnotationColor(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent)
        ).hexString(includingAlpha: false)
        return Sample(color: rgb, hex: hex, magnifiedImage: magnifiedImage)
    }

    private static func captureImageSafely(in rect: CGRect) async -> CGImage? {
        guard rect.width > 0, rect.height > 0 else { return nil }
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    private static func centerCrop(_ image: CGImage, maximumSide: Int) -> CGImage? {
        var side = min(maximumSide, min(image.width, image.height))
        if side.isMultiple(of: 2) { side -= 1 }
        guard side > 0 else { return nil }
        return image.cropping(
            to: CGRect(
                x: (image.width - side) / 2,
                y: (image.height - side) / 2,
                width: side,
                height: side
            ))
    }

    private static func centerColor(in image: CGImage) -> NSColor? {
        guard
            let pixel = image.cropping(
                to: CGRect(
                    x: image.width / 2,
                    y: image.height / 2,
                    width: 1,
                    height: 1
                )),
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        else { return nil }

        var bytes = [UInt8](repeating: 0, count: 4)
        let drewPixel = bytes.withUnsafeMutableBytes { storage -> Bool in
            guard
                let context = CGContext(
                    data: storage.baseAddress,
                    width: 1,
                    height: 1,
                    bitsPerComponent: 8,
                    bytesPerRow: 4,
                    space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                        | CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return false }
            context.interpolationQuality = .none
            context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        guard drewPixel else { return nil }
        return NSColor(
            srgbRed: CGFloat(bytes[0]) / 255,
            green: CGFloat(bytes[1]) / 255,
            blue: CGFloat(bytes[2]) / 255,
            alpha: 1
        )
    }
}

private final class ScreenColorOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: false)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        ignoresMouseEvents = false
        hasShadow = false
        hidesOnDeactivate = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = false
    }
}

private final class ScreenColorOverlayView: NSView {
    var onPointerMove: ((CGPoint) -> Void)?
    var onSelect: ((CGPoint) -> Void)?
    var onCancel: (() -> Void)?
    private var pointerTrackingArea: NSTrackingArea?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func updateTrackingAreas() {
        if let pointerTrackingArea {
            removeTrackingArea(pointerTrackingArea)
        }
        let next = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(next)
        pointerTrackingArea = next
        super.updateTrackingAreas()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseEntered(with event: NSEvent) {
        window?.makeKey()
        window?.makeFirstResponder(self)
        onPointerMove?(NSEvent.mouseLocation)
    }

    override func mouseMoved(with event: NSEvent) {
        onPointerMove?(NSEvent.mouseLocation)
    }

    override func mouseDragged(with event: NSEvent) {
        onPointerMove?(NSEvent.mouseLocation)
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?(NSEvent.mouseLocation)
    }

    override func rightMouseDown(with event: NSEvent) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }
}

private final class ScreenColorPreviewPanel: NSPanel {
    private static let previewSize = CGSize(width: 132, height: 158)
    private let previewView = ScreenColorPreviewView(
        frame: CGRect(origin: .zero, size: previewSize)
    )

    init() {
        super.init(
            contentRect: CGRect(origin: .zero, size: Self.previewSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        ignoresMouseEvents = true
        animationBehavior = .none
        contentView = previewView
    }

    func update(sample: ScreenColorSamplingSession.Sample?) {
        previewView.update(
            image: sample?.magnifiedImage,
            color: sample?.color,
            hex: sample?.hex ?? "#------"
        )
    }
}

private final class ScreenColorPreviewView: NSView {
    private var magnifiedImage: CGImage?
    private var sampledColor: NSColor?
    private var hex = "#------"

    override var isFlipped: Bool { true }

    func update(image: CGImage?, color: NSColor?, hex: String) {
        magnifiedImage = image
        sampledColor = color
        self.hex = hex
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let container = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 13, yRadius: 13)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        container.fill()
        NSColor.labelColor.withAlphaComponent(0.42).setStroke()
        container.lineWidth = 1
        container.stroke()

        let imageRect = CGRect(x: 10, y: 10, width: 112, height: 112)
        let imagePath = NSBezierPath(roundedRect: imageRect, xRadius: 7, yRadius: 7)
        NSGraphicsContext.saveGraphicsState()
        imagePath.addClip()
        NSColor.controlBackgroundColor.setFill()
        imagePath.fill()
        if let magnifiedImage {
            NSGraphicsContext.current?.imageInterpolation = .none
            NSImage(cgImage: magnifiedImage, size: imageRect.size).draw(
                in: imageRect,
                from: .zero,
                operation: .copy,
                fraction: 1,
                respectFlipped: true,
                hints: [.interpolation: NSImageInterpolation.none]
            )
        }
        NSGraphicsContext.restoreGraphicsState()

        let cellSide = magnifiedImage.map { imageRect.width / CGFloat($0.width) } ?? 10
        let targetRect = CGRect(
            x: imageRect.midX - cellSide / 2,
            y: imageRect.midY - cellSide / 2,
            width: cellSide,
            height: cellSide
        ).insetBy(dx: -1, dy: -1)
        NSColor.white.withAlphaComponent(0.95).setStroke()
        let outerTarget = NSBezierPath(rect: targetRect)
        outerTarget.lineWidth = 3
        outerTarget.stroke()
        NSColor.black.withAlphaComponent(0.9).setStroke()
        let innerTarget = NSBezierPath(rect: targetRect.insetBy(dx: 1.5, dy: 1.5))
        innerTarget.lineWidth = 1
        innerTarget.stroke()

        let swatchRect = CGRect(x: 12, y: 130, width: 18, height: 18)
        let swatch = NSBezierPath(roundedRect: swatchRect, xRadius: 4, yRadius: 4)
        (sampledColor ?? NSColor.clear).setFill()
        swatch.fill()
        NSColor.labelColor.withAlphaComponent(0.45).setStroke()
        swatch.lineWidth = 1
        swatch.stroke()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        NSAttributedString(string: hex, attributes: attributes).draw(
            in: CGRect(x: 37, y: 130, width: 86, height: 20)
        )
    }
}
