@preconcurrency import AppKit
import Carbon
import OSLog
import SwiftUI
import TopDropCore

@MainActor
final class ApplicationCoordinator: NSObject {
    let settings = AppSettingsModel()
    let clipboard = ClipboardMonitor()
    let hotKey = ClipboardHotKeyRegistrar()
    let launchAtLogin = LaunchAtLoginManager()
    let menuBarShelf = MenuBarShelfController()
    let accessories = TopDropAccessoryManager()
    let devTools = DevToolsModel()
    let notes: NotesViewModel
    let screenshots: ScreenshotViewModel

    private let screenshotLibrary: ScreenshotLibrary
    private let editorWindows: AnnotationEditorWindowManager
    private let edgeMonitor: EdgeEventMonitor
    private let applicationMenuMode = MenuBarApplicationModeController()
    private var panel: TrayPanelController!
    private var settingsWindow: AuxiliaryWindowController?
    private var onboardingWindow: AuxiliaryWindowController?
    private var lastHotKeyConfiguration: ClipboardHotKeyConfiguration?
    private var terminationHasBegun = false
    private var cleanupHasCompleted = false
    private var activeColorSampler: ScreenColorSamplingSession?
    private var notesLifecycleObservers: [NSObjectProtocol] = []
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "Application")

    init(screenshotLibrary: ScreenshotLibrary) {
        self.screenshotLibrary = screenshotLibrary
        notes = NotesViewModel(provider: AppleNotesProvider(), settings: settings)
        screenshots = ScreenshotViewModel(library: screenshotLibrary, settings: settings)
        editorWindows = AnnotationEditorWindowManager(
            library: screenshotLibrary,
            clipboard: clipboard
        )
        edgeMonitor = EdgeEventMonitor(configuration: .init())
        super.init()

        configurePanel()
        configureMenuBarShelf()
        configureEdgeMonitor()
        configureHotKey()
        configureClipboardImageCapture()
        configureAccessories()

        let notifications = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.didActivateApplicationNotification] {
            notesLifecycleObservers.append(
                notifications.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                    let bundleID =
                        (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                        .bundleIdentifier
                    if bundleID == "com.apple.finder" {
                        Task { @MainActor [weak self] in self?.devTools.hiddenFiles.refresh() }
                    }
                    guard name == NSWorkspace.didWakeNotification || bundleID == TopDropCore.bundleIdentifier else {
                        return
                    }
                    Task { @MainActor [weak self] in await self?.notes.reloadConfiguredFolder() }
                })
        }

        settings.onChange = { [weak self] value in
            self?.apply(value)
        }
    }

    func start() {
        edgeMonitor.start()
        Task { [weak self] in
            guard let self else { return }
            await settings.load()
            clipboard.start()
            await notes.start()
            await screenshots.start()
            if !settings.value.completedOnboarding {
                showOnboarding()
            } else {
                showMenuBarShelfSetupIfNeeded()
            }
            logger.info("TopDrop application services started")
        }
    }

    func stop() async {
        beginTermination()
        await finishTerminationCleanup()
    }

    func beginTermination() {
        guard !terminationHasBegun else { return }
        terminationHasBegun = true
        NotificationCenter.default.post(name: .topDropOCRWillStop, object: nil)
        notes.beginTermination()
        devTools.stop()
        for observer in notesLifecycleObservers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        notesLifecycleObservers.removeAll()
        logger.info("Termination phase: stop event ingress")
        edgeMonitor.stop()
        clipboard.stop()
        hotKey.unregister()
        activeColorSampler?.cancel()
        activeColorSampler = nil
        panel?.outsideDismissalIsSuspended = true
        panel?.hide(animated: false, reason: .programmatic)
        menuBarShelf.beginTermination()
        applicationMenuMode.exit()
    }

    func finishTerminationCleanup() async {
        guard !cleanupHasCompleted else { return }
        cleanupHasCompleted = true
        logger.info("Termination phase: restore native menu items")
        await menuBarShelf.finishTermination()
        logger.info("Termination phase: flush Notes")
        await notes.flushPendingEdit()
        logger.info("Termination phase: flush annotation editors")
        await editorWindows.finishAllEditing()
        logger.info("Termination phase: stop screenshot library")
        await screenshots.stop()
        logger.info("Termination phase: flush settings")
        await settings.flush()
        logger.info("TopDrop application services stopped")
    }

    private func configurePanel() {
        let root = TopDropTrayView(
            notes: notes,
            clipboard: clipboard,
            screenshots: screenshots,
            menuBarShelf: menuBarShelf,
            accessories: accessories,
            devTools: devTools,
            showSettings: { [weak self] in self?.showSettings() },
            toggleClipboardPause: { [weak self] in
                self?.settings.update { $0.clipboardPaused.toggle() }
            },
            pickScreenColor: { [weak self] in self?.beginScreenColorSampling() },
            editScreenshot: { [weak self] item in self?.editorWindows.open(item) },
            hide: { [weak self] in self?.hideTrayAndCollapse() }
        )
        panel = TrayPanelController(rootView: AnyView(root))
        panel.onHide = { [weak self] reason in
            guard let self else { return }
            notes.setTrayVisible(false)
            applicationMenuMode.exit()
            menuBarShelf.setTrayPresented(false)
            clipboard.cancelArrivalWatch()
            switch reason {
            case .escape:
                menuBarShelf.hide()
            case .outsideClick, .programmatic:
                break
            }
        }
    }

    private func configureMenuBarShelf() {
        menuBarShelf.onSettingsChange = { [weak self] shelfSettings in
            self?.settings.update { $0.menuBarShelf = shelfSettings }
        }
        menuBarShelf.onFreshArrangement = { [weak self] in
            self?.settings.update { $0.menuBarShelfSetupVersion = 0 }
        }
        menuBarShelf.installQuickSettings(
            AnyView(
                MenuBarQuickSettingsView(
                    shelf: menuBarShelf,
                    clipboard: clipboard,
                    launchAtLogin: launchAtLogin,
                    toggleTray: { [weak self] in
                        guard let self else { return }
                        menuBarShelf.closeQuickSettings()
                        if panel.isVisible {
                            hideTrayAndCollapse()
                        } else {
                            enterTopDropMode(on: preferredScreen())
                        }
                    },
                    cleanClipboard: { [weak self] in
                        guard let self else { return }
                        Task { try? await clipboard.cleanFormatting() }
                    },
                    toggleClipboardPause: { [weak self] in
                        self?.settings.update { $0.clipboardPaused.toggle() }
                    },
                    showSettings: { [weak self] in
                        self?.menuBarShelf.closeQuickSettings()
                        self?.showSettings()
                    },
                    quit: { NSApp.terminate(nil) }
                )))
        menuBarShelf.installSetupGuide(
            AnyView(
                MenuBarShelfSetupGuideView(
                    shelf: menuBarShelf,
                    done: { [weak self] in
                        guard let self else { return }
                        settings.update {
                            $0.menuBarShelfSetupVersion = MenuBarShelfSetup.currentVersion
                        }
                        menuBarShelf.completeArrangement()
                    }
                )))
    }

    private func configureEdgeMonitor() {
        edgeMonitor.trayIsVisible = { [weak self] in self?.panel.isVisible ?? false }
        edgeMonitor.visibleTrayScreenIdentifier = { [weak self] in
            self?.panel.targetScreenIdentifier
        }
        edgeMonitor.visibleTrayFrame = { [weak self] in self?.panel.frame ?? .zero }
        edgeMonitor.onAction = { [weak self] action, screen in
            guard let self else { return }
            switch action {
            case .reveal:
                enterTopDropMode(on: screen)
            case .hide:
                hideTrayAndCollapse()
            }
        }
    }

    private func configureHotKey() {
        hotKey.onPress = { [weak self] in
            guard let self else { return }
            Task { try? await clipboard.cleanFormatting() }
        }
    }

    private func configureClipboardImageCapture() {
        clipboard.onContentObserved = { [weak self] item in
            guard let self else { return }
            let screenshots = self.screenshots
            Task { await screenshots.cacheClipboardImages(from: item) }
        }
    }

    private func configureAccessories() {
        accessories.onChange = { [weak self] items in
            self?.settings.update { $0.accessories = items }
        }
        accessories.onBuiltinAction = { [weak self] action in
            guard let self else { return }
            switch action {
            case .newNote:
                Task { await notes.createNote() }
            case .refreshNotes:
                Task { await notes.reloadConfiguredFolder() }
            case .cleanClipboard:
                Task { try? await clipboard.cleanFormatting() }
            case .toggleClipboardHistory:
                settings.update { $0.clipboardPaused.toggle() }
            case .openSettings:
                showSettings()
            case .chooseScreenshotFolder:
                chooseScreenshotFolder()
            case .importScreenshots:
                Task { await screenshots.importExisting() }
            }
        }
    }

    private func apply(_ value: AppSettings) {
        edgeMonitor.update(configuration: value.gesture)
        panel.updateHeight(value.panelHeight)
        if clipboard.isPaused != value.clipboardPaused {
            clipboard.setPaused(value.clipboardPaused)
        }
        clipboard.setSensitiveApplicationBundleIdentifiers(
            value.excludedClipboardBundleIdentifiers
        )
        menuBarShelf.apply(value.menuBarShelf)
        accessories.apply(value.accessories)

        let configuration = hotKeyConfiguration(from: value.cleanClipboardHotKey)
        if configuration != lastHotKeyConfiguration {
            do {
                try hotKey.register(configuration)
                lastHotKeyConfiguration = configuration
            } catch {
                lastHotKeyConfiguration = nil
                logger.error(
                    "Clean Formatting hotkey registration failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func hotKeyConfiguration(
        from settings: CleanClipboardHotKeySettings
    ) -> ClipboardHotKeyConfiguration {
        var modifiers: UInt32 = 0
        if settings.control { modifiers |= UInt32(controlKey) }
        if settings.option { modifiers |= UInt32(optionKey) }
        if settings.command { modifiers |= UInt32(cmdKey) }
        if settings.shift { modifiers |= UInt32(shiftKey) }
        return ClipboardHotKeyConfiguration(
            keyCode: settings.keyCode,
            modifiers: modifiers,
            isEnabled: true
        )
    }

    private func chooseScreenshotFolder() {
        guard let folder = settings.chooseScreenshotFolder() else { return }
        Task { [screenshots] in await screenshots.configure(folder: folder) }
    }

    private func showSettings() {
        let view = SettingsView(
            settings: settings,
            notes: notes,
            clipboard: clipboard,
            launchAtLogin: launchAtLogin,
            hotKey: hotKey,
            menuBarShelf: menuBarShelf,
            accessories: accessories,
            screenshotCount: screenshots.snapshot.items.count,
            chooseScreenshotFolder: { [weak self] in self?.chooseScreenshotFolder() },
            importExistingScreenshots: { [weak self] in
                guard let self else { return }
                Task { await screenshots.importExisting() }
            },
            clearClipboardHistory: { [weak self] in
                guard let self else { return }
                Task {
                    let itemIDs = Set(clipboard.items.map(\.id))
                    guard
                        await screenshots.clearClipboardHistoryCache(
                            removingClipboardItemIDs: itemIDs
                        )
                    else { return }
                    await clipboard.clearAll()
                }
            },
            previewTopDrop: { [weak self] in self?.previewTopDropFromSettings() }
        )
        if let settingsWindow {
            settingsWindow.replaceRootView(AnyView(view))
            settingsWindow.present()
        } else {
            let controller = AuxiliaryWindowController(
                title: "TopDrop Settings",
                autosaveName: "TopDrop.Settings",
                size: CGSize(width: 900, height: 680),
                rootView: AnyView(view)
            )
            settingsWindow = controller
            controller.present()
        }
    }

    private func previewTopDropFromSettings() {
        settingsWindow?.window?.orderOut(nil)
        enterTopDropMode(on: preferredScreen())
    }

    private func showOnboarding() {
        let view = OnboardingView(
            settings: settings,
            notes: notes,
            clipboard: clipboard,
            chooseScreenshotFolder: { [weak self] in self?.chooseScreenshotFolder() },
            finish: { [weak self] in
                guard let self else { return }
                onboardingWindow?.window?.orderOut(nil)
                showMenuBarShelfSetupIfNeeded()
            }
        )
        if let onboardingWindow {
            onboardingWindow.replaceRootView(AnyView(view))
            onboardingWindow.present()
        } else {
            let controller = AuxiliaryWindowController(
                title: "Set Up TopDrop",
                autosaveName: "TopDrop.Onboarding",
                size: CGSize(width: 760, height: 700),
                rootView: AnyView(view)
            )
            onboardingWindow = controller
            controller.present()
        }
    }

    private func enterTopDropMode(on screen: NSScreen) {
        guard activeColorSampler == nil else { return }
        devTools.hiddenFiles.refresh()
        notes.setTrayVisible(true)
        menuBarShelf.reveal(scheduleAutoCollapse: false)
        menuBarShelf.setTrayPresented(true)
        panel.show(on: screen, height: settings.value.panelHeight)
        Task { [weak self] in
            guard let self else { return }
            // Inspect the pending clipboard before activating TopDrop so the
            // attribution remains the app that was actually foregrounded.
            await clipboard.pollNow()
            guard panel.isVisible else { return }
            if menuBarShelf.settings.reclaimApplicationMenus {
                applicationMenuMode.enter()
            }
            clipboard.beginArrivalWatch()
        }
    }

    private func hideTrayAndCollapse() {
        clipboard.cancelArrivalWatch()
        menuBarShelf.hide()
        menuBarShelf.setTrayPresented(false)
        applicationMenuMode.exit()
        panel.hide(animated: true)
    }

    private func beginScreenColorSampling() {
        guard activeColorSampler == nil, !terminationHasBegun else { return }

        // Close every TopDrop surface before checking or requesting permission.
        // The permission sheet and the sampler must never be presented above
        // the tray that the user is trying to sample behind.
        dismissTopDropForScreenColorSampling()

        guard
            ScreenColorSamplingSession.hasScreenCapturePermission
                || ScreenColorSamplingSession.requestScreenCapturePermission()
        else {
            showScreenColorPermissionHelp()
            return
        }

        let sampler = ScreenColorSamplingSession()
        activeColorSampler = sampler

        // Give AppKit one complete run-loop turn to commit orderOut before the
        // transparent full-screen sampling panels are installed.
        DispatchQueue.main.async { [weak self, weak sampler] in
            guard let self, let sampler,
                self.activeColorSampler === sampler,
                !self.terminationHasBegun
            else { return }
            sampler.start { [weak self] selectedColor in
                self?.completeScreenColorSampling(selectedColor)
            }
        }
    }

    private func dismissTopDropForScreenColorSampling() {
        clipboard.cancelArrivalWatch()
        menuBarShelf.closeQuickSettings()
        menuBarShelf.hide()
        menuBarShelf.setTrayPresented(false)
        applicationMenuMode.exit()
        panel.hideImmediately()
    }

    private func completeScreenColorSampling(_ selectedColor: NSColor?) {
        activeColorSampler = nil
        guard let selectedColor,
            let rgb = selectedColor.usingColorSpace(.sRGB)
        else { return }

        let hex = AnnotationColor(
            red: Double(rgb.redComponent),
            green: Double(rgb.greenComponent),
            blue: Double(rgb.blueComponent)
        ).hexString(includingAlpha: false)
        let source = ClipboardSourceApplication(
            bundleIdentifier: TopDropCore.bundleIdentifier,
            displayName: "TopDrop"
        )
        Task { [weak self] in
            do {
                try await self?.clipboard.setCurrentPlainText(
                    hex,
                    sourceApplication: source
                )
            } catch {
                self?.logger.error("Sampled color could not be written to the clipboard")
            }
        }
    }

    private func showScreenColorPermissionHelp() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording Is Needed for Live Color Preview"
        alert.informativeText =
            "TopDrop reads only the small pixel area beneath the pointer while Screen Color Picker is active. Allow TopDrop in Privacy & Security, then reopen TopDrop if macOS asks you to."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let candidates = [
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
        ]
        for candidate in candidates {
            guard let url = URL(string: candidate) else { continue }
            if NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(
            URL(fileURLWithPath: "/System/Applications/System Settings.app"),
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func showMenuBarShelfSetupIfNeeded() {
        guard settings.value.menuBarShelfSetupVersion < MenuBarShelfSetup.currentVersion else {
            return
        }
        menuBarShelf.beginFreshArrangement()
    }

    private func preferredScreen() -> NSScreen {
        let location = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let geometries = screens.map {
            TopEdgeDisplayGeometry(
                identifier: EdgeEventMonitor.identifier(for: $0),
                frame: $0.frame
            )
        }
        if let display = TopEdgeDisplayResolver.display(
            at: location,
            among: geometries,
            activationDistance: 0
        ),
            let screen = screens.first(where: {
                EdgeEventMonitor.identifier(for: $0) == display.identifier
            })
        {
            return screen
        }
        return NSScreen.main ?? screens[0]
    }

}
