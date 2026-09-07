@preconcurrency import AppKit
import SwiftUI
import TopDropCore

struct HotKeyRecorderView: NSViewRepresentable {
    @Binding var settings: CleanClipboardHotKeySettings

    func makeCoordinator() -> Coordinator {
        Coordinator(settings: $settings)
    }

    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton(title: displayString(settings), target: nil, action: nil)
        button.bezelStyle = .rounded
        button.setButtonType(.momentaryPushIn)
        button.onShortcut = { [weak coordinator = context.coordinator] keyCode, modifiers in
            coordinator?.apply(keyCode: keyCode, modifiers: modifiers)
        }
        return button
    }

    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        context.coordinator.settings = $settings
        if !button.isRecording {
            button.title = displayString(settings)
        }
    }

    @MainActor
    final class Coordinator {
        var settings: Binding<CleanClipboardHotKeySettings>

        init(settings: Binding<CleanClipboardHotKeySettings>) {
            self.settings = settings
        }

        func apply(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
            settings.wrappedValue = CleanClipboardHotKeySettings(
                keyCode: keyCode,
                control: modifiers.contains(.control),
                option: modifiers.contains(.option),
                command: modifiers.contains(.command),
                shift: modifiers.contains(.shift)
            )
        }
    }

    private func displayString(_ value: CleanClipboardHotKeySettings) -> String {
        var result = ""
        if value.control { result += "⌃" }
        if value.option { result += "⌥" }
        if value.shift { result += "⇧" }
        if value.command { result += "⌘" }
        result += Self.keyLabel(value.keyCode)
        return result
    }

    private static func keyLabel(_ keyCode: UInt32) -> String {
        let labels: [UInt32: String] = [
            0: "A", 1: "S", 2: "D", 3: "F", 4: "H", 5: "G", 6: "Z", 7: "X",
            8: "C", 9: "V", 11: "B", 12: "Q", 13: "W", 14: "E", 15: "R",
            16: "Y", 17: "T", 18: "1", 19: "2", 20: "3", 21: "4", 22: "6",
            23: "5", 25: "9", 26: "7", 28: "8", 29: "0", 31: "O", 32: "U",
            34: "I", 35: "P", 37: "L", 38: "J", 40: "K", 45: "N", 46: "M",
            49: "Space",
        ]
        return labels[keyCode] ?? "Key \(keyCode)"
    }
}

final class ShortcutRecorderButton: NSButton {
    var onShortcut: ((UInt32, NSEvent.ModifierFlags) -> Void)?
    private(set) var isRecording = false
    private var previousTitle = ""

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        previousTitle = title
        isRecording = true
        title = "Type shortcut…"
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else {
            super.keyDown(with: event)
            return
        }
        if event.keyCode == 53 {
            cancelRecording()
            return
        }
        let modifiers = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !modifiers.isEmpty else {
            NSSound.beep()
            title = "Include a modifier"
            return
        }
        isRecording = false
        onShortcut?(UInt32(event.keyCode), modifiers)
        window?.makeFirstResponder(nil)
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { cancelRecording() }
        return super.resignFirstResponder()
    }

    private func cancelRecording() {
        isRecording = false
        title = previousTitle
        window?.makeFirstResponder(nil)
    }
}
