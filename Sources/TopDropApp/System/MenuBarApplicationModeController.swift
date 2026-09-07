@preconcurrency import AppKit

/// Temporarily makes TopDrop the active regular application so the foreground
/// application's long File/Edit/View menu is replaced by a minimal TopDrop
/// menu while the native Scroll Shelf and tray are revealed.
@MainActor
final class MenuBarApplicationModeController {
    private weak var previousApplication: NSRunningApplication?
    private var previousMainMenu: NSMenu?
    private(set) var isActive = false

    func enter() {
        guard !isActive else { return }
        isActive = true
        let frontmost = NSWorkspace.shared.frontmostApplication
        if frontmost?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApplication = frontmost
        }
        previousMainMenu = NSApp.mainMenu
        NSApp.mainMenu = makeMinimalMenu()
        _ = NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func exit() {
        guard isActive else { return }
        isActive = false
        let topDropWasFrontmost =
            NSWorkspace.shared.frontmostApplication?.processIdentifier
            == ProcessInfo.processInfo.processIdentifier
        NSApp.mainMenu = previousMainMenu
        _ = NSApp.setActivationPolicy(.accessory)
        if topDropWasFrontmost {
            previousApplication?.activate(options: [])
        }
        previousApplication = nil
        previousMainMenu = nil
    }

    private func makeMinimalMenu() -> NSMenu {
        let mainMenu = NSMenu(title: "TopDrop")
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "TopDrop")
        let hide = NSMenuItem(
            title: "Hide TopDrop",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        hide.target = NSApp
        appMenu.addItem(hide)
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)
        return mainMenu
    }
}
