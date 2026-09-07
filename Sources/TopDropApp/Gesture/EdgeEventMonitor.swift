@preconcurrency import AppKit
import Foundation
import TopDropCore

@MainActor
final class EdgeEventMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var screenChangeObserver: NSObjectProtocol?
    private var spaceChangeObserver: NSObjectProtocol?
    private var recognizer: TopEdgeGestureRecognizer
    private var lastResolvedScreenIdentifier: String?

    var trayIsVisible: () -> Bool = { false }
    var visibleTrayScreenIdentifier: () -> String? = { nil }
    var visibleTrayFrame: () -> CGRect = { .zero }
    var onAction: (TopEdgeGestureAction, NSScreen) -> Void = { _, _ in }

    init(configuration: TopEdgeGestureConfiguration) {
        recognizer = TopEdgeGestureRecognizer(configuration: configuration)
    }

    func update(configuration: TopEdgeGestureConfiguration) {
        recognizer.configuration = configuration
        recognizer.reset()
    }

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
        screenChangeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetForDisplayChange()
            }
        }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.resetForDisplayChange()
            }
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        if let screenChangeObserver {
            NotificationCenter.default.removeObserver(screenChangeObserver)
            self.screenChangeObserver = nil
        }
        if let spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceChangeObserver)
            self.spaceChangeObserver = nil
        }
        lastResolvedScreenIdentifier = nil
        recognizer.reset()
    }

    private func handle(_ event: NSEvent) {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let displayGeometries = screens.map {
            TopEdgeDisplayGeometry(identifier: Self.identifier(for: $0), frame: $0.frame)
        }
        guard
            let resolvedDisplay = TopEdgeDisplayResolver.display(
                at: pointer,
                among: displayGeometries,
                activationDistance: recognizer.configuration.activationDistance,
                preferredIdentifier: lastResolvedScreenIdentifier
            ),
            let screen = screens.first(where: {
                Self.identifier(for: $0) == resolvedDisplay.identifier
            })
        else {
            lastResolvedScreenIdentifier = nil
            recognizer.reset()
            return
        }

        let screenIdentifier = resolvedDisplay.identifier
        lastResolvedScreenIdentifier = screenIdentifier
        let sample = TopEdgeScrollSample(
            timestamp: event.timestamp,
            screenIdentifier: screenIdentifier,
            pointer: pointer,
            screenFrame: screen.frame,
            scrollingDeltaY: event.scrollingDeltaY,
            isDirectionInvertedFromDevice: event.isDirectionInvertedFromDevice,
            hasPreciseDeltas: event.hasPreciseScrollingDeltas,
            phase: Self.phase(for: event.phase),
            isMomentum: !event.momentumPhase.isEmpty
        )
        let trayIsVisibleHere =
            trayIsVisible()
            && (visibleTrayScreenIdentifier().map { $0 == screenIdentifier } ?? true)
        if let action = recognizer.process(
            sample,
            trayIsVisible: trayIsVisibleHere,
            pointerIsInsideVisibleTray: visibleTrayFrame().contains(pointer)
        ) {
            onAction(action, screen)
        }
    }

    private func resetForDisplayChange() {
        lastResolvedScreenIdentifier = nil
        recognizer.reset()
    }

    static func identifier(for screen: NSScreen) -> String {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            return number.stringValue
        }
        return NSStringFromRect(screen.frame)
    }

    private static func phase(for phase: NSEvent.Phase) -> ScrollGesturePhase {
        if phase.contains(.began) { return .began }
        if phase.contains(.changed) { return .changed }
        if phase.contains(.ended) { return .ended }
        if phase.contains(.cancelled) { return .cancelled }
        return .none
    }
}
