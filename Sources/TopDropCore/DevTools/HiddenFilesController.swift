@preconcurrency import AppKit
import ApplicationServices
import Carbon
import Combine
import IOKit.pwr_mgt

public enum FinderHiddenFilesState: String, Sendable {
    case shown = "Shown", hidden = "Hidden", unknown = "Unknown"
    public static func preference(_ value: Any?) -> Self {
        if let number = value as? NSNumber {
            if number == 1 { return .shown }
            if number == 0 { return .hidden }
        }
        if let string = value as? String {
            switch string.lowercased() {
            case "true", "yes", "1": return .shown
            case "false", "no", "0": return .hidden
            default: break
            }
        }
        return .unknown
    }
}

@MainActor
public protocol FinderHiddenFilesProviding {
    func readState() -> FinderHiddenFilesState
    func hasPermission() -> Bool
    func requestPermission()
    func activateFinder() async -> Bool
    func sendShortcut() throws
}

@MainActor
public struct NativeFinderHiddenFilesProvider: FinderHiddenFilesProviding {
    public init() {}
    public func readState() -> FinderHiddenFilesState {
        guard CFPreferencesAppSynchronize("com.apple.finder" as CFString) else { return .unknown }
        return .preference(CFPreferencesCopyAppValue("AppleShowAllFiles" as CFString, "com.apple.finder" as CFString))
    }
    public func hasPermission() -> Bool { AXIsProcessTrusted() }
    public func requestPermission() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }
    public func activateFinder() async -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first else {
            return false
        }
        guard app.activate() else { return false }
        for _ in 0..<20 {
            if Task.isCancelled { return false }
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
    public func sendShortcut() throws {
        guard hasPermission(), let app = NSWorkspace.shared.frontmostApplication,
            app.bundleIdentifier == "com.apple.finder"
        else { throw DevToolsError.finderNotActive }
        guard let key = Self.periodKeyCode(),
            let down = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true),
            let up = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)
        else {
            throw DevToolsError.keyUnavailable
        }
        down.flags = [.maskCommand, .maskShift]
        up.flags = [.maskCommand, .maskShift]
        // Recheck immediately before delivery; PID-targeting prevents a focus
        // race from delivering this to a newly foregrounded editor instead.
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
            throw DevToolsError.finderNotActive
        }
        down.postToPid(app.processIdentifier)
        up.postToPid(app.processIdentifier)
    }

    public static func periodKeyCode() -> CGKeyCode? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
            let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var base: [UInt16: String] = [:], shifted: [UInt16: String] = [:]
        for modifiers in [UInt32(0), UInt32(shiftKey >> 8)] {
            for code in UInt16(0)..<UInt16(128) {
                var dead: UInt32 = 0
                var count = 0
                var chars = [UniChar](repeating: 0, count: 8)
                let status = UCKeyTranslate(
                    layout, code, UInt16(kUCKeyActionDown), modifiers,
                    UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, 8, &count, &chars)
                guard status == noErr, count == 1 else { continue }
                let character = String(utf16CodeUnits: chars, count: count)
                if modifiers == 0 { base[code] = character } else { shifted[code] = character }
            }
        }
        return periodKeyCode(unshifted: base, shifted: shifted)
    }

    public static func periodKeyCode(unshifted: [UInt16: String], shifted: [UInt16: String]) -> CGKeyCode? {
        // Prefer the base period key; some layouts expose period only with Shift.
        // A keypad decimal is not Finder's punctuation shortcut. In layouts
        // such as AZERTY, prefer the shifted punctuation key over that decimal.
        let decimal = UInt16(kVK_ANSI_KeypadDecimal)
        return unshifted.keys.sorted().first(where: { $0 != decimal && unshifted[$0] == "." })
            ?? shifted.keys.sorted().first(where: { $0 != decimal && shifted[$0] == "." })
    }
}

@MainActor
public final class HiddenFilesController: ObservableObject {
    @Published public private(set) var state: FinderHiddenFilesState = .unknown
    @Published public private(set) var isBusy = false
    @Published public private(set) var message: String?
    private let provider: any FinderHiddenFilesProviding
    private var task: Task<Void, Never>?
    private var generation = 0

    public init(provider: any FinderHiddenFilesProviding = NativeFinderHiddenFilesProvider()) {
        self.provider = provider
    }
    public func refresh() { state = provider.readState() }
    public func perform(closeTray: () -> Void) {
        guard !isBusy else { return }
        refresh()
        guard provider.hasPermission() else {
            provider.requestPermission()
            message = "Allow Accessibility, then retry. Or press ⌘⇧. in Finder."
            return
        }
        closeTray()
        let previous = state
        generation += 1
        let request = generation
        isBusy = true
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            // Allow tray dismissal/menu restoration to finish before activation.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, request == generation else { return }
            let active = await provider.activateFinder()
            guard !Task.isCancelled, request == generation else { return }
            guard active else {
                message = "Finder could not be activated. No shortcut sent."
                isBusy = false
                return
            }
            do { try provider.sendShortcut() } catch {
                message = "Shortcut unavailable. Press ⌘⇧. in Finder."
                isBusy = false
                return
            }
            for _ in 0..<4 {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled, request == generation else { return }
                refresh()
                if previous != .unknown, state != .unknown, state != previous { break }
            }
            message =
                previous != .unknown && state != .unknown && state != previous
                ? "Finder preference updated." : "State Not Confirmed — check Finder."
            isBusy = false
        }
    }
    public func stop() { generation += 1; task?.cancel(); task = nil; isBusy = false }
}
