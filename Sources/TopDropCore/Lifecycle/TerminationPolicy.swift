import Foundation

public enum TopDropTerminationReason: String, Equatable, Sendable {
    case cleanupCompleted
    case deadlineReached
}

/// A small, deterministic exactly-once gate shared by the AppKit delegate and
/// unit tests. It contains no process or UI state.
public struct TopDropTerminationReplyArbiter: Equatable, Sendable {
    public private(set) var winningReason: TopDropTerminationReason?

    public init(winningReason: TopDropTerminationReason? = nil) {
        self.winningReason = winningReason
    }

    @discardableResult
    public mutating func claim(_ reason: TopDropTerminationReason) -> Bool {
        guard winningReason == nil else { return false }
        winningReason = reason
        return true
    }
}

public enum TopDropTerminationPolicy {
    public static let deadline: TimeInterval = 5

    public static func normalizedDeadline(_ value: TimeInterval) -> TimeInterval {
        guard value.isFinite else { return deadline }
        return min(max(value, 0.1), 30)
    }
}
