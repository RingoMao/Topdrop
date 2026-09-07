// Copyright (C) 2026 TopDrop contributors
// SPDX-License-Identifier: GPL-3.0-only
// The expanding single-divider technique was informed by Hidden Bar (MIT).

@preconcurrency import AppKit
import OSLog
import SwiftUI
import TopDropCore

/// A native one-divider shelf. Third-party status items stay genuine: users
/// Command-drag on-demand items left of this divider. Expanding the divider
/// pushes them off-screen and shrinking it reveals their original controls.
@MainActor
final class MenuBarShelfController: NSObject, ObservableObject {
    @Published private(set) var state: MenuBarShelfPresentationState = .hidden
    @Published private(set) var settings = MenuBarShelfSettings()
    @Published private(set) var trayIsPresented = false
    @Published private(set) var setupGuidePointerOffset: CGFloat = 0

    let interactionIsActive = false
    var onSettingsChange: ((MenuBarShelfSettings) -> Void)?
    var onFreshArrangement: (() -> Void)?

    private var stateMachine = MenuBarShelfStateMachine()
    private var controlItem: NSStatusItem?
    private var dividerItem: NSStatusItem?
    private var statusItemObservations: [NSKeyValueObservation] = []
    private var decorationItems: [UUID: NSStatusItem] = [:]
    private var decorationObservations: [UUID: NSKeyValueObservation] = [:]
    private var decorationIDByButton: [ObjectIdentifier: UUID] = [:]
    private let quickSettingsPopover = NSPopover()
    private var setupGuidePanel: NSPanel?
    private var autoCollapseTask: Task<Void, Never>?
    private var guideTrackingTask: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var defaultsObserver: NSObjectProtocol?
    private var isInstalling = false
    private let defaults = UserDefaults(suiteName: TopDropCore.bundleIdentifier) ?? .standard
    private let generationKey = "TopDrop.ScrollShelf.generation"
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "MenuBarShelf")

    init(installNativeItems: Bool = true) {
        super.init()
        quickSettingsPopover.behavior = .transient
        quickSettingsPopover.animates = true
        if installNativeItems {
            installStatusItems()
            installEnvironmentObservers()
        }
    }

    deinit {
        autoCollapseTask?.cancel()
        guideTrackingTask?.cancel()
        statusItemObservations.forEach { $0.invalidate() }
        decorationObservations.values.forEach { $0.invalidate() }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        if let spaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver) }
    }

    func installQuickSettings(_ rootView: AnyView) {
        let size = CGSize(width: 310, height: 330)
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame.size = size
        quickSettingsPopover.contentSize = size
        quickSettingsPopover.contentViewController = controller
    }

    func installSetupGuide(_ rootView: AnyView) {
        let size = CGSize(width: 360, height: 260)
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame.size = size
        let panel = NSPanel(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.contentViewController = controller
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .utilityWindow
        setupGuidePanel = panel
    }

    func apply(_ newSettings: MenuBarShelfSettings) {
        settings = MenuBarShelfSettings(
            autoCollapseDelay: newSettings.autoCollapseDelay,
            reclaimApplicationMenus: newSettings.reclaimApplicationMenus,
            decorations: newSettings.decorations
        )
        reconcileDecorationItems()
        scheduleAutoCollapseIfNeeded()
    }

    func setAutoCollapseDelay(_ delay: TimeInterval?) {
        updateSettings { $0.autoCollapseDelay = delay }
    }

    func setReclaimApplicationMenus(_ enabled: Bool) {
        updateSettings { $0.reclaimApplicationMenus = enabled }
    }

    @discardableResult
    func addLabel(_ text: String = "Label") -> UUID {
        let decoration = MenuBarShelfDecoration.label(text: text)
        updateSettings { $0.decorations.append(decoration) }
        beginArranging()
        return decoration.id
    }

    @discardableResult
    func addSpacer(width: Double = MenuBarShelfDecoration.defaultSpacerWidth) -> UUID {
        let decoration = MenuBarShelfDecoration.spacer(width: width)
        updateSettings { $0.decorations.append(decoration) }
        beginArranging()
        return decoration.id
    }

    func renameLabel(id: UUID, text: String) {
        updateDecoration(id: id) { $0.content = .label(text: text) }
    }

    func resizeSpacer(id: UUID, width: Double) {
        updateDecoration(id: id) { $0.content = .spacer(width: width) }
    }

    func removeDecoration(id: UUID) {
        let existing = settings.decorations.first { $0.id == id }
        updateSettings { $0.decorations.removeAll { $0.id == id } }
        if let existing {
            for key in existing.statusItemDefaultsKeys { defaults.removeObject(forKey: key) }
        }
    }

    func reveal(scheduleAutoCollapse: Bool = true) {
        autoCollapseTask?.cancel()
        stateMachine.reveal()
        publishStateAndLayout()
        if scheduleAutoCollapse { scheduleAutoCollapseIfNeeded() }
    }

    func hide() {
        autoCollapseTask?.cancel()
        guideTrackingTask?.cancel()
        setupGuidePanel?.orderOut(nil)
        stateMachine.hide()
        publishStateAndLayout()
    }

    func beginArranging(showGuide: Bool = true) {
        autoCollapseTask?.cancel()
        stateMachine.beginArranging()
        publishStateAndLayout()
        if showGuide { presentSetupGuideWhenStable() }
    }

    func beginFreshArrangement() {
        onFreshArrangement?()
        clearFormerProxyStatusItemPreferences()
        resetShelfIdentity()
        beginArranging()
    }

    func completeArrangement() {
        setupGuidePanel?.orderOut(nil)
        hide()
    }

    func toggleShelfVisibility() {
        state == .hidden ? reveal() : hide()
    }

    func setTrayPresented(_ presented: Bool) {
        trayIsPresented = presented
        if presented { autoCollapseTask?.cancel() } else { scheduleAutoCollapseIfNeeded() }
    }

    func closeQuickSettings() { quickSettingsPopover.performClose(nil) }

    func showGuide() {
        guard state == .arranging else { return }
        presentSetupGuideWhenStable()
    }

    func beginTermination() {
        autoCollapseTask?.cancel()
        guideTrackingTask?.cancel()
        quickSettingsPopover.performClose(nil)
        setupGuidePanel?.orderOut(nil)
        stateMachine.hide()
        publishStateAndLayout()
    }

    func finishTermination() async {}

    private func updateSettings(_ mutation: (inout MenuBarShelfSettings) -> Void) {
        var updated = settings
        mutation(&updated)
        apply(updated)
        onSettingsChange?(settings)
    }

    private func updateDecoration(
        id: UUID,
        mutation: (inout MenuBarShelfDecoration) -> Void
    ) {
        updateSettings { value in
            guard let index = value.decorations.firstIndex(where: { $0.id == id }) else { return }
            mutation(&value.decorations[index])
        }
    }

    private func installEnvironmentObservers() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.environmentDidChange() } }
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.restoreStatusItemsIfNeeded() } }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.environmentDidChange() } }
    }

    private func environmentDidChange() {
        restoreStatusItemsIfNeeded()
        applyCurrentLayout()
        if state == .arranging { presentSetupGuideWhenStable() }
    }

    private func installStatusItems() {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }

        // New status items appear to the left: divider then control in the bar.
        let control = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let divider = NSStatusBar.system.statusItem(withLength: MenuBarShelfStateMachine.visibleDividerLength)
        let generation = defaults.integer(forKey: generationKey)
        control.autosaveName = "TopDrop.ScrollShelfControl.\(generation)"
        divider.autosaveName = "TopDrop.ScrollShelfDivider.\(generation)"
        control.isVisible = true
        divider.isVisible = true

        if let button = control.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "TopDrop")
            button.image?.isTemplate = true
            button.toolTip = "TopDrop"
            button.target = self
            button.action = #selector(controlItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        if let button = divider.button {
            button.target = self
            button.action = #selector(dividerClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        controlItem = control
        dividerItem = divider
        observeStatusItem(control)
        observeStatusItem(divider)
        reconcileDecorationItems()
        updateAppearances()
        applyCurrentLayout()
    }

    private func observeStatusItem(_ item: NSStatusItem) {
        statusItemObservations.append(
            item.observe(\.isVisible, options: [.new]) { [weak self] _, change in
                guard change.newValue == false else { return }
                DispatchQueue.main.async { self?.restoreStatusItemsIfNeeded() }
            }
        )
    }

    private func restoreStatusItemsIfNeeded() {
        guard !isInstalling else { return }
        guard
            MenuBarShelfStatusItemRestoration.requiresReinstallation(
                controlIsVisible: controlItem?.isVisible == true,
                dividerIsVisible: dividerItem?.isVisible == true
            )
        else { return }
        removeStatusItems()
        installStatusItems()
        logger.info("Restored a removed TopDrop Scroll Shelf item")
    }

    private func resetShelfIdentity() {
        removeStatusItems()
        defaults.set(defaults.integer(forKey: generationKey) + 1, forKey: generationKey)
        installStatusItems()
    }

    /// Clears only TopDrop-owned identities from the retired capture/proxy
    /// experiment. Third-party status-item placement remains macOS-owned and
    /// untouched.
    private func clearFormerProxyStatusItemPreferences() {
        let legacyGenerationKey = "TopDrop.MenuBarShelf.dividerGeneration"
        let finalGeneration = max(0, defaults.integer(forKey: legacyGenerationKey))
        for generation in 0...finalGeneration {
            for name in [
                "TopDrop.ProxyControl.\(generation)",
                "TopDrop.NativeProxyStrip.\(generation)",
                "TopDrop.ProxySourceDivider.\(generation)",
                "TopDrop.ProxyOpenDivider.\(generation)",
            ] {
                defaults.removeObject(forKey: "NSStatusItem Preferred Position \(name)")
                defaults.removeObject(forKey: "NSStatusItem Visible \(name)")
                defaults.removeObject(forKey: "NSStatusItem VisibleCC \(name)")
            }
        }
        defaults.removeObject(forKey: legacyGenerationKey)
    }

    private func removeStatusItems() {
        statusItemObservations.forEach { $0.invalidate() }
        statusItemObservations.removeAll()
        decorationObservations.values.forEach { $0.invalidate() }
        decorationObservations.removeAll()
        decorationIDByButton.removeAll()
        for item in Array(decorationItems.values) + [dividerItem, controlItem].compactMap({ $0 }) {
            NSStatusBar.system.removeStatusItem(item)
        }
        decorationItems.removeAll()
        dividerItem = nil
        controlItem = nil
    }

    private func publishStateAndLayout() {
        state = stateMachine.state
        updateAppearances()
        applyCurrentLayout()
    }

    private func applyCurrentLayout() {
        let widest = NSScreen.screens.map(\.frame.width).max() ?? 1_728
        dividerItem?.length = stateMachine.layout(forWidestScreenWidth: widest).dividerLength
    }

    private func updateAppearances() {
        guard let button = dividerItem?.button else { return }
        button.image =
            state == .arranging
            ? Self.arrangingDividerImage()
            : NSImage(systemSymbolName: "line.vertical", accessibilityDescription: "TopDrop Scroll Shelf divider")
        button.image?.isTemplate = true
        button.contentTintColor = nil
        button.toolTip =
            state == .arranging
            ? "Highlighted Scroll Shelf divider — Command-drag native items across it"
            : "TopDrop Scroll Shelf divider"
        for decoration in settings.decorations { configureDecorationStatusItem(decoration) }
    }

    private func reconcileDecorationItems() {
        guard controlItem != nil, dividerItem != nil else { return }
        let desired = Set(settings.decorations.map(\.id))
        for id in Array(decorationItems.keys) where !desired.contains(id) { removeDecorationStatusItem(id: id) }
        for decoration in settings.decorations {
            if decorationItems[decoration.id] == nil {
                installDecorationStatusItem(decoration)
            } else {
                configureDecorationStatusItem(decoration)
            }
        }
    }

    private func installDecorationStatusItem(_ decoration: MenuBarShelfDecoration) {
        let length: CGFloat =
            switch decoration.content {
            case .spacer(let width): width
            case .label: NSStatusItem.variableLength
            }
        let item = NSStatusBar.system.statusItem(withLength: length)
        item.autosaveName = decoration.statusItemAutosaveName
        item.isVisible = true
        decorationItems[decoration.id] = item
        if let button = item.button {
            decorationIDByButton[ObjectIdentifier(button)] = decoration.id
            button.target = self
            button.action = #selector(decorationClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        decorationObservations[decoration.id] = item.observe(\.isVisible, options: [.new]) {
            [weak self] _, change in
            guard change.newValue == false else { return }
            DispatchQueue.main.async { self?.restoreDecoration(id: decoration.id) }
        }
        configureDecorationStatusItem(decoration)
    }

    private func configureDecorationStatusItem(_ decoration: MenuBarShelfDecoration) {
        guard let item = decorationItems[decoration.id], let button = item.button else { return }
        switch decoration.content {
        case .spacer(let width):
            item.length = width
            button.title = ""
            button.imagePosition = .imageOnly
            button.image = state == .arranging ? Self.spacerDragImage(width: width) : nil
            button.toolTip = "TopDrop spacer — right-click to edit"
        case .label(let text):
            item.length = NSStatusItem.variableLength
            button.image = nil
            button.imagePosition = .noImage
            button.title = MenuBarShelfDecoration.normalizedLabel(text)
            button.toolTip = "TopDrop label — right-click to edit"
        }
    }

    private func restoreDecoration(id: UUID) {
        guard let item = decorationItems[id], !item.isVisible else { return }
        item.isVisible = true
        if !item.isVisible, let decoration = settings.decorations.first(where: { $0.id == id }) {
            removeDecorationStatusItem(id: id)
            installDecorationStatusItem(decoration)
        }
    }

    private func removeDecorationStatusItem(id: UUID) {
        decorationObservations.removeValue(forKey: id)?.invalidate()
        guard let item = decorationItems.removeValue(forKey: id) else { return }
        if let button = item.button { decorationIDByButton.removeValue(forKey: ObjectIdentifier(button)) }
        NSStatusBar.system.removeStatusItem(item)
    }

    private func scheduleAutoCollapseIfNeeded() {
        autoCollapseTask?.cancel()
        guard
            MenuBarShelfAutoCollapsePolicy.shouldSchedule(
                state: state,
                trayIsPresented: trayIsPresented,
                delay: settings.autoCollapseDelay
            ), let delay = settings.autoCollapseDelay
        else { return }
        autoCollapseTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            self?.hide()
        }
    }

    private func presentSetupGuideWhenStable() {
        guideTrackingTask?.cancel()
        guard setupGuidePanel != nil else { return }
        guideTrackingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var stability = MenuBarShelfGuideAnchorStability()
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !Task.isCancelled, ContinuousClock.now < deadline {
                let frame = dividerGlobalFrame()
                if stability.record(frame), let frame {
                    placeGuide(anchor: frame)
                    beginGuideFollowing()
                    return
                }
                try? await Task.sleep(for: .milliseconds(80))
            }
            setupGuidePanel?.orderOut(nil)
        }
    }

    private func beginGuideFollowing() {
        guideTrackingTask?.cancel()
        guideTrackingTask = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.state == .arranging {
                if let frame = self?.dividerGlobalFrame() { self?.placeGuide(anchor: frame) }
                try? await Task.sleep(for: .milliseconds(220))
            }
        }
    }

    private func dividerGlobalFrame() -> CGRect? {
        guard let button = dividerItem?.button, let window = button.window else { return nil }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return frame.width > 0 && frame.height > 0 ? frame : nil
    }

    private func placeGuide(anchor: CGRect) {
        guard let panel = setupGuidePanel else { return }
        let screens = NSScreen.screens.map {
            MenuBarShelfGuideScreen(
                identifier: EdgeEventMonitor.identifier(for: $0),
                frame: $0.frame,
                visibleFrame: $0.visibleFrame
            )
        }
        guard
            let placement = MenuBarShelfGuidePlacement.resolve(
                anchorFrame: anchor,
                guideSize: panel.frame.size,
                screens: screens
            )
        else { return }
        setupGuidePointerOffset = placement.pointerOffset
        panel.setFrame(placement.panelFrame, display: true)
        panel.orderFrontRegardless()
    }

    @objc private func controlItemClicked() {
        guard let button = controlItem?.button else { return }
        if quickSettingsPopover.isShown {
            quickSettingsPopover.performClose(nil)
        } else {
            quickSettingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    @objc private func dividerClicked() {
        state == .arranging ? showGuide() : toggleShelfVisibility()
    }

    @objc private func decorationClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp,
            let id = decorationIDByButton[ObjectIdentifier(sender)],
            let decoration = settings.decorations.first(where: { $0.id == id })
        else { return }
        let menu = NSMenu(title: "Scroll Shelf Decoration")
        switch decoration.content {
        case .label:
            let item = NSMenuItem(title: "Rename…", action: #selector(renameDecoration(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = id.uuidString; menu.addItem(item)
        case .spacer(let width):
            for value in [8, 16, 24, 32, 48, 64, 80] {
                let item = NSMenuItem(title: "\(value) pt", action: #selector(resizeDecoration(_:)), keyEquivalent: "")
                item.target = self; item.tag = value; item.representedObject = id.uuidString
                item.state = Int(width.rounded()) == value ? .on : .off
                menu.addItem(item)
            }
        }
        menu.addItem(.separator())
        let remove = NSMenuItem(title: "Remove", action: #selector(removeDecorationFromMenu(_:)), keyEquivalent: "")
        remove.target = self; remove.representedObject = id.uuidString; menu.addItem(remove)
        menu.popUp(positioning: nil, at: CGPoint(x: 0, y: sender.bounds.minY), in: sender)
    }

    @objc private func renameDecoration(_ sender: NSMenuItem) {
        guard let id = representedID(sender),
            let decoration = settings.decorations.first(where: { $0.id == id }),
            case .label(let value) = decoration.content
        else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Menu-Bar Label"
        let field = NSTextField(string: value)
        field.frame = CGRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "Rename"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        renameLabel(id: id, text: field.stringValue)
    }

    @objc private func resizeDecoration(_ sender: NSMenuItem) {
        guard let id = representedID(sender) else { return }
        resizeSpacer(id: id, width: Double(sender.tag))
    }

    @objc private func removeDecorationFromMenu(_ sender: NSMenuItem) {
        guard let id = representedID(sender) else { return }
        removeDecoration(id: id)
    }

    private func representedID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init(uuidString:))
    }

    private static func arrangingDividerImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 16), flipped: false) { _ in
            NSColor.labelColor.setStroke()
            let path = NSBezierPath(); path.lineWidth = 1.6
            path.move(to: NSPoint(x: 10, y: 1)); path.line(to: NSPoint(x: 10, y: 15))
            path.move(to: NSPoint(x: 7, y: 8)); path.line(to: NSPoint(x: 2, y: 8))
            path.move(to: NSPoint(x: 2, y: 8)); path.line(to: NSPoint(x: 4.5, y: 10.5))
            path.move(to: NSPoint(x: 2, y: 8)); path.line(to: NSPoint(x: 4.5, y: 5.5))
            path.move(to: NSPoint(x: 13, y: 8)); path.line(to: NSPoint(x: 18, y: 8))
            path.move(to: NSPoint(x: 18, y: 8)); path.line(to: NSPoint(x: 15.5, y: 10.5))
            path.move(to: NSPoint(x: 18, y: 8)); path.line(to: NSPoint(x: 15.5, y: 5.5))
            path.stroke(); return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Highlighted TopDrop Scroll Shelf divider"
        return image
    }

    private static func spacerDragImage(width: Double) -> NSImage {
        let image = NSImage(size: NSSize(width: max(8, width), height: 16), flipped: false) { rect in
            NSColor.labelColor.withAlphaComponent(0.45).setStroke()
            let path = NSBezierPath(rect: rect.insetBy(dx: 2, dy: 5))
            path.lineWidth = 1; path.setLineDash([2, 2], count: 2, phase: 0); path.stroke()
            return true
        }
        image.isTemplate = true
        return image
    }
}

enum MenuBarSystemSettings {
    static func open() {
        let workspace = NSWorkspace.shared
        for candidate in [
            "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension",
            "x-apple.systempreferences:com.apple.Desktop-Settings.extension",
        ] {
            if let url = URL(string: candidate), workspace.open(url) { return }
        }
        workspace.openApplication(
            at: URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: .init()
        )
    }
}
