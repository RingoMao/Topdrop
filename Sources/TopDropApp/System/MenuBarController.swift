// Copyright (C) 2026 TopDrop contributors
// SPDX-License-Identifier: GPL-3.0-only

@preconcurrency import AppKit
import SwiftUI

/// Owns TopDrop's single native menu-bar entry.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let quickSettingsPopover = NSPopover()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()

        // This identity intentionally differs from the retired menu control so
        // a stale hidden-state record cannot suppress the new icon.
        statusItem.autosaveName = "TopDrop.MainMenu.v2"
        statusItem.isVisible = true

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "tray.full", accessibilityDescription: "TopDrop")
            button.image?.isTemplate = true
            button.imagePosition = .imageOnly
            button.toolTip = "TopDrop"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        quickSettingsPopover.behavior = .transient
        quickSettingsPopover.animates = true
    }

    func installQuickSettings(_ rootView: AnyView) {
        let size = CGSize(width: 300, height: 250)
        let controller = NSHostingController(rootView: rootView)
        controller.view.frame.size = size
        quickSettingsPopover.contentSize = size
        quickSettingsPopover.contentViewController = controller
    }

    func closeQuickSettings() {
        quickSettingsPopover.performClose(nil)
    }

    func beginTermination() {
        closeQuickSettings()
    }

    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        if quickSettingsPopover.isShown {
            closeQuickSettings()
        } else {
            quickSettingsPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

}
