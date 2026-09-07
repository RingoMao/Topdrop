@preconcurrency import AppKit
import SwiftUI
import TopDropCore

@MainActor
final class TrayPanelController {
    enum DismissalReason {
        case programmatic
        case escape
        case outsideClick
    }

    private let panel: EscapeAwarePanel
    private var targetScreen: NSScreen?
    private var outsideClickMonitor: Any?
    private var localOutsideClickMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var currentHeight: CGFloat = 520
    private var topInset: CGFloat = 0
    private(set) var isVisible = false

    var onHide: ((DismissalReason) -> Void)?
    var additionalInsideFrames: (() -> [CGRect])?
    var outsideDismissalIsSuspended = false

    init(rootView: AnyView) {
        panel = EscapeAwarePanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle,
        ]
        panel.contentView = NSHostingView(rootView: rootView)
        panel.onEscape = { [weak self] in self?.hide(animated: true, reason: .escape) }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.handleScreenConfigurationChange()
            }
        }
    }

    var frame: CGRect { panel.frame }
    var targetScreenIdentifier: String? { targetScreen.map(Self.identifier(for:)) }

    func replaceRootView(_ rootView: AnyView) {
        panel.contentView = NSHostingView(rootView: rootView)
    }

    func show(on screen: NSScreen, height: CGFloat) {
        targetScreen = screen
        currentHeight = height
        let finalFrame = frameForPanel(on: screen, height: height)
        let fadeOnly = shouldFadeAcrossTopEdge(of: screen)
        var hiddenFrame = finalFrame
        hiddenFrame.origin.y = fadeOnly ? finalFrame.origin.y : screen.frame.maxY + 6

        panel.setFrame(hiddenFrame, display: false)
        panel.alphaValue = fadeOnly ? 0 : 1
        panel.orderFrontRegardless()
        panel.makeKey()
        isVisible = true
        installOutsideClickMonitor()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(finalFrame, display: true)
            panel.animator().alphaValue = 1
        }
    }

    func hide(animated: Bool, reason: DismissalReason = .programmatic) {
        guard isVisible else { return }
        NotificationCenter.default.post(name: .topDropTrayDidHide, object: nil)
        isVisible = false
        removeOutsideClickMonitor()

        guard animated, let screen = targetScreen else {
            panel.alphaValue = 1
            panel.orderOut(nil)
            onHide?(reason)
            return
        }

        let fadeOnly = shouldFadeAcrossTopEdge(of: screen)
        var hiddenFrame = panel.frame
        hiddenFrame.origin.y = fadeOnly ? panel.frame.origin.y : screen.frame.maxY + 6
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.16
                context.timingFunction = CAMediaTimingFunction(name: .easeIn)
                panel.animator().setFrame(hiddenFrame, display: true)
                if fadeOnly {
                    panel.animator().alphaValue = 0
                }
            },
            completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isVisible else { return }
                    self.panel.orderOut(nil)
                    self.panel.alphaValue = 1
                    self.onHide?(reason)
                }
            })
    }

    /// Removes the tray from the window server synchronously, even if the
    /// controller's presentation flag became stale. System interactions such
    /// as screen-color sampling must never start above a visible TopDrop tray.
    func hideImmediately(reason: DismissalReason = .programmatic) {
        NotificationCenter.default.post(name: .topDropTrayDidHide, object: nil)
        let wasPresented = isVisible || panel.isVisible
        isVisible = false
        removeOutsideClickMonitor()
        panel.contentView?.layer?.removeAllAnimations()
        panel.orderOut(nil)
        panel.alphaValue = 1
        if wasPresented {
            onHide?(reason)
        }
    }

    func toggle(on screen: NSScreen, height: CGFloat) {
        isVisible ? hide(animated: true) : show(on: screen, height: height)
    }

    func updateHeight(_ height: CGFloat) {
        currentHeight = height
        guard let screen = targetScreen, isVisible else { return }
        panel.setFrame(frameForPanel(on: screen, height: height), display: true, animate: true)
    }

    func updateTopInset(_ value: CGFloat) {
        topInset = max(0, value)
        guard let screen = targetScreen, isVisible else { return }
        panel.setFrame(frameForPanel(on: screen, height: currentHeight), display: true)
    }

    private func frameForPanel(on screen: NSScreen, height: CGFloat) -> CGRect {
        TrayPanelLayoutPolicy.layout(
            for: Self.metrics(for: screen),
            configuredHeight: height,
            minimumHeight: AppSettings.minimumPanelHeight,
            topInset: topInset
        ).frame
    }

    private func handleScreenConfigurationChange() {
        guard isVisible else { return }
        let priorIdentifier = targetScreen.map(Self.identifier(for:))
        let screens = NSScreen.screens
        guard
            let screen = screens.first(where: {
                Self.identifier(for: $0) == priorIdentifier
            }) ?? NSScreen.main ?? screens.first
        else {
            hide(animated: false)
            return
        }
        targetScreen = screen
        panel.setFrame(frameForPanel(on: screen, height: currentHeight), display: true)
    }

    private func shouldFadeAcrossTopEdge(of screen: NSScreen) -> Bool {
        let displays = NSScreen.screens.map {
            TopEdgeDisplayGeometry(
                identifier: Self.identifier(for: $0),
                frame: $0.frame
            )
        }
        guard
            let target = displays.first(where: {
                $0.identifier == Self.identifier(for: screen)
            })
        else { return false }
        return TopEdgeDisplayResolver.hasOverlappingDisplayAbove(
            target,
            among: displays
        )
    }

    private static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")
        ] as? NSNumber {
            return number.stringValue
        }
        return NSStringFromRect(screen.frame)
    }

    private static func metrics(for screen: NSScreen) -> TrayDisplayMetrics {
        guard
            let number = screen.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber
        else {
            return TrayDisplayMetrics(
                visibleFrame: screen.visibleFrame,
                isBuiltIn: false
            )
        }
        let displayID = CGDirectDisplayID(number.uint32Value)
        let millimeters = CGDisplayScreenSize(displayID)
        return TrayDisplayMetrics(
            visibleFrame: screen.visibleFrame,
            isBuiltIn: CGDisplayIsBuiltin(displayID) != 0,
            physicalSizeMillimeters: millimeters.width > 0 && millimeters.height > 0
                ? millimeters
                : nil
        )
    }

    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil, localOutsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isVisible, !self.outsideDismissalIsSuspended else { return }
                if !self.containsInteractivePoint(NSEvent.mouseLocation) {
                    self.hide(animated: true, reason: .outsideClick)
                }
            }
        }
        localOutsideClickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            if let self, self.isVisible,
                !self.outsideDismissalIsSuspended,
                !self.containsInteractivePoint(NSEvent.mouseLocation)
            {
                self.hide(animated: true, reason: .outsideClick)
            }
            return event
        }
    }

    private func removeOutsideClickMonitor() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
            self.outsideClickMonitor = nil
        }
        if let localOutsideClickMonitor {
            NSEvent.removeMonitor(localOutsideClickMonitor)
            self.localOutsideClickMonitor = nil
        }
    }

    private func containsInteractivePoint(_ point: CGPoint) -> Bool {
        panel.frame.contains(point)
            || (additionalInsideFrames?().contains(where: { $0.contains(point) }) ?? false)
    }
}

private final class EscapeAwarePanel: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
        } else {
            super.keyDown(with: event)
        }
    }
}
