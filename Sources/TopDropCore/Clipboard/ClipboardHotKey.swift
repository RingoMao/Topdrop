import Carbon
import Combine
import Foundation
import OSLog

public struct ClipboardHotKeyConfiguration: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    /// Carbon modifier bits (`controlKey`, `optionKey`, `cmdKey`, `shiftKey`).
    public var modifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    /// Control-Option-Command-V, as required for Clean Formatting.
    public static let cleanFormattingDefault = ClipboardHotKeyConfiguration(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        isEnabled: true
    )

    public var displayString: String {
        var value = ""
        if modifiers & UInt32(controlKey) != 0 { value += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { value += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { value += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { value += "⌘" }
        if keyCode == UInt32(kVK_ANSI_V) { value += "V" } else { value += "Key \(keyCode)" }
        return value
    }
}

public enum ClipboardHotKeyError: Error, Equatable, LocalizedError, Sendable {
    case conflict
    case handlerInstallationFailed(status: Int32)
    case registrationFailed(status: Int32)

    public var errorDescription: String? {
        switch self {
        case .conflict:
            "That global shortcut is already in use. Choose a different Clean Formatting shortcut."
        case let .handlerInstallationFailed(status):
            "The global shortcut event handler could not be installed (status \(status))."
        case let .registrationFailed(status):
            "The global shortcut could not be registered (status \(status))."
        }
    }
}

/// Exclusive Carbon registration makes conflicts deterministic instead of
/// silently invoking more than one application.
@MainActor
public final class ClipboardHotKeyRegistrar: ObservableObject {
    @Published public private(set) var configuration: ClipboardHotKeyConfiguration?
    @Published public private(set) var lastError: ClipboardHotKeyError?

    public var onPress: (@MainActor @Sendable () -> Void)?

    private static let signature: OSType = 0x5444_7270  // "TDrp"
    private let hotKeyID: EventHotKeyID
    // Store Carbon's non-Sendable opaque pointers as addresses so Swift 6 can
    // safely run deinit outside the actor while still releasing registrations.
    private var hotKeyAddress: UInt?
    private var handlerAddress: UInt?
    private let logger = Logger(subsystem: TopDropCore.bundleIdentifier, category: "ClipboardHotKey")

    public init(onPress: (@MainActor @Sendable () -> Void)? = nil) {
        self.onPress = onPress
        self.hotKeyID = EventHotKeyID(
            signature: Self.signature,
            id: UInt32.random(in: 1...UInt32.max)
        )
    }

    deinit {
        if let hotKeyAddress, let reference = EventHotKeyRef(bitPattern: hotKeyAddress) {
            UnregisterEventHotKey(reference)
        }
        if let handlerAddress, let reference = EventHandlerRef(bitPattern: handlerAddress) {
            RemoveEventHandler(reference)
        }
    }

    public func register(_ newConfiguration: ClipboardHotKeyConfiguration) throws {
        unregister()
        configuration = newConfiguration
        lastError = nil
        guard newConfiguration.isEnabled else { return }

        do {
            try installHandlerIfNeeded()
            var newReference: EventHotKeyRef?
            let status = RegisterEventHotKey(
                newConfiguration.keyCode,
                newConfiguration.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                UInt32(kEventHotKeyExclusive),
                &newReference
            )
            if status == eventHotKeyExistsErr {
                throw ClipboardHotKeyError.conflict
            }
            guard status == noErr, let newReference else {
                throw ClipboardHotKeyError.registrationFailed(status: status)
            }
            hotKeyAddress = UInt(bitPattern: newReference)
            logger.info("Clean Formatting hotkey registered")
        } catch let error as ClipboardHotKeyError {
            lastError = error
            logger.error("Hotkey registration failed: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    public func unregister() {
        if let hotKeyAddress, let reference = EventHotKeyRef(bitPattern: hotKeyAddress) {
            UnregisterEventHotKey(reference)
            self.hotKeyAddress = nil
            logger.info("Clean Formatting hotkey unregistered")
        }
    }

    private func installHandlerIfNeeded() throws {
        guard handlerAddress == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        var newHandler: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.eventHandler,
            1,
            &eventType,
            userData,
            &newHandler
        )
        guard status == noErr else {
            throw ClipboardHotKeyError.handlerInstallationFailed(status: status)
        }
        if let newHandler {
            handlerAddress = UInt(bitPattern: newHandler)
        }
    }

    private func handle(event: EventRef) -> OSStatus {
        var receivedID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &receivedID
        )
        guard status == noErr,
            receivedID.signature == hotKeyID.signature,
            receivedID.id == hotKeyID.id
        else {
            return OSStatus(eventNotHandledErr)
        }
        onPress?()
        return noErr
    }

    private static let eventHandler: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return OSStatus(eventNotHandledErr) }
        let eventAddress = UInt(bitPattern: event)
        let userDataAddress = UInt(bitPattern: userData)
        // Application event-target handlers are delivered on the main event loop.
        return MainActor.assumeIsolated {
            guard let event = EventRef(bitPattern: eventAddress),
                let userData = UnsafeMutableRawPointer(bitPattern: userDataAddress)
            else {
                return OSStatus(eventNotHandledErr)
            }
            return Unmanaged<ClipboardHotKeyRegistrar>
                .fromOpaque(userData)
                .takeUnretainedValue()
                .handle(event: event)
        }
    }
}
