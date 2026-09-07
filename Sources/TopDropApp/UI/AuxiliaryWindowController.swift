@preconcurrency import AppKit
import SwiftUI

@MainActor
final class AuxiliaryWindowController: NSWindowController, NSWindowDelegate {
    private let autosaveName: String
    var onClose: (() -> Void)?

    init(
        title: String,
        autosaveName: String,
        size: CGSize,
        rootView: AnyView
    ) {
        self.autosaveName = autosaveName
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = title
        window.minSize = CGSize(width: min(520, size.width), height: min(420, size.height))
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: rootView)
        window.setFrameAutosaveName(autosaveName)
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func replaceRootView(_ rootView: AnyView) {
        window?.contentView = NSHostingView(rootView: rootView)
    }

    func present() {
        guard let window else { return }
        if !window.setFrameUsingName(autosaveName) {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        onClose?()
        return false
    }
}
