import Combine
import IOKit.pwr_mgt

@MainActor
public protocol DisplayAwakeProviding {
    func acquire() throws -> UInt32
    func release(_ id: UInt32) throws
}

public struct NativeDisplayAwakeProvider: DisplayAwakeProviding {
    public init() {}
    public func acquire() throws -> UInt32 {
        var id = IOPMAssertionID(kIOPMNullAssertionID)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "TopDrop Keep Awake" as CFString, &id)
        guard result == kIOReturnSuccess else { throw DevToolsError.operationFailed }
        return id
    }
    public func release(_ id: UInt32) throws {
        guard IOPMAssertionRelease(id) == kIOReturnSuccess else { throw DevToolsError.operationFailed }
    }
}

public enum DevToolsError: Error { case operationFailed, finderNotActive, keyUnavailable }

@MainActor
public final class KeepAwakeController: ObservableObject {
    @Published public private(set) var isEnabled = false
    @Published public private(set) var message: String?
    private let provider: any DisplayAwakeProviding
    private var assertion: UInt32?

    public init(provider: any DisplayAwakeProviding = NativeDisplayAwakeProvider()) { self.provider = provider }
    public func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        do {
            if enabled {
                assertion = try provider.acquire()
            } else if let assertion {
                try provider.release(assertion)
                self.assertion = nil
            }
            isEnabled = enabled
            message = nil
        } catch { message = "Could not change Keep Awake. Try again." }
    }
    public func stop() { setEnabled(false) }
}
