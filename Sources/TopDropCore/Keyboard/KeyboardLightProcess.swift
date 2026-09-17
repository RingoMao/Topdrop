import Darwin
import Foundation

public struct KeyboardLightProcessResult: Sendable {
    public let status: Int32
    public let timedOut: Bool
    public var succeeded: Bool { status == 0 && !timedOut }
}

/// A serial, cancellable worker. Discard output so a broken helper cannot fill
/// a pipe or log; expose bounded, content-free error codes to the UI instead.
public final class KeyboardLightProcess: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.personal.TopDrop.keyboard-light", qos: .utility)
    public init() {}

    public func run(_ executable: URL, arguments: [String], timeout: TimeInterval = 4) async
        -> KeyboardLightProcessResult
    {
        let cancellation = KeyboardLightCancellation()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                queue.async {
                    let result = Self.execute(
                        executable, arguments: arguments, timeout: timeout, cancellation: cancellation)
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private static func execute(
        _ executable: URL, arguments: [String], timeout: TimeInterval, cancellation: KeyboardLightCancellation
    ) -> KeyboardLightProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard !cancellation.isCancelled else { return .init(status: -1, timedOut: false) }
        do { try process.run() } catch { return .init(status: 127, timedOut: false) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout.isFinite ? max(0.05, timeout) : 4))
        while process.isRunning {
            if cancellation.isCancelled || ContinuousClock.now >= deadline {
                // Kill only the child we still own. No synchronous wait can wedge
                // the UI; Foundation reaps it. The helper spawns no descendants.
                kill(process.processIdentifier, SIGKILL)
                return .init(status: -1, timedOut: !cancellation.isCancelled)
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return .init(status: process.terminationStatus, timedOut: false)
    }
}

private final class KeyboardLightCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
