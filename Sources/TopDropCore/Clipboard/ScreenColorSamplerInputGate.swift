import Foundation

public struct ScreenColorSamplerInputSnapshot: Equatable, Sendable {
    public var leftMouseDown: Bool
    public var rightMouseDown: Bool
    public var escapeDown: Bool

    public init(leftMouseDown: Bool, rightMouseDown: Bool, escapeDown: Bool) {
        self.leftMouseDown = leftMouseDown
        self.rightMouseDown = rightMouseDown
        self.escapeDown = escapeDown
    }

    fileprivate var isReleased: Bool {
        !leftMouseDown && !rightMouseDown && !escapeDown
    }
}

public enum ScreenColorSamplerInputAction: Equatable, Sendable {
    case none
    case confirm
    case cancel
}

/// Converts polled mouse/key state into one-shot sampler actions. The gate
/// deliberately waits for the input that launched the eyedropper to release.
public struct ScreenColorSamplerInputGate: Sendable {
    private var prior: ScreenColorSamplerInputSnapshot
    private var isArmed: Bool

    public init(initial: ScreenColorSamplerInputSnapshot) {
        prior = initial
        isArmed = initial.isReleased
    }

    public mutating func update(
        _ current: ScreenColorSamplerInputSnapshot
    ) -> ScreenColorSamplerInputAction {
        defer { prior = current }

        guard isArmed else {
            isArmed = current.isReleased
            return .none
        }
        if current.escapeDown && !prior.escapeDown {
            return .cancel
        }
        if current.rightMouseDown && !prior.rightMouseDown {
            return .cancel
        }
        if current.leftMouseDown && !prior.leftMouseDown {
            return .confirm
        }
        return .none
    }
}
