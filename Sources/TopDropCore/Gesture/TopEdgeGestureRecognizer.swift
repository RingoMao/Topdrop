import CoreGraphics
import Foundation

public enum ScrollGesturePhase: Sendable {
    case none
    case began
    case changed
    case ended
    case cancelled
}

public struct TopEdgeScrollSample: Sendable {
    public var timestamp: TimeInterval
    public var screenIdentifier: String
    public var pointer: CGPoint
    public var screenFrame: CGRect
    public var scrollingDeltaY: Double
    public var isDirectionInvertedFromDevice: Bool
    public var hasPreciseDeltas: Bool
    public var phase: ScrollGesturePhase
    public var isMomentum: Bool

    public init(
        timestamp: TimeInterval,
        screenIdentifier: String,
        pointer: CGPoint,
        screenFrame: CGRect,
        scrollingDeltaY: Double,
        isDirectionInvertedFromDevice: Bool,
        hasPreciseDeltas: Bool = true,
        phase: ScrollGesturePhase = .changed,
        isMomentum: Bool = false
    ) {
        self.timestamp = timestamp
        self.screenIdentifier = screenIdentifier
        self.pointer = pointer
        self.screenFrame = screenFrame
        self.scrollingDeltaY = scrollingDeltaY
        self.isDirectionInvertedFromDevice = isDirectionInvertedFromDevice
        self.hasPreciseDeltas = hasPreciseDeltas
        self.phase = phase
        self.isMomentum = isMomentum
    }
}

/// The part of an attached display needed to route a global scroll event.
/// Keeping this AppKit-independent makes unusual multi-display layouts
/// deterministic and unit-testable.
public struct TopEdgeDisplayGeometry: Equatable, Sendable {
    public var identifier: String
    public var frame: CGRect

    public init(identifier: String, frame: CGRect) {
        self.identifier = identifier
        self.frame = frame
    }
}

/// Resolves a pointer in AppKit's global coordinate space to an attached
/// display. A top edge is preferred over ordinary frame containment because a
/// point on a vertical display seam is both the lower display's top edge and
/// the upper display's bottom edge. `CGRect.contains` excludes max edges and
/// therefore routes that point to the wrong display for TopDrop's gesture.
public enum TopEdgeDisplayResolver {
    /// True when sliding a tray beyond the target display's top edge would put
    /// it visibly onto another attached display. Callers can use a fade on
    /// such vertically stacked layouts instead of animating across displays.
    public static func hasOverlappingDisplayAbove(
        _ target: TopEdgeDisplayGeometry,
        among displays: [TopEdgeDisplayGeometry],
        coordinateTolerance: Double = 0.5
    ) -> Bool {
        let tolerance = max(0, coordinateTolerance)
        return displays.contains { candidate in
            guard candidate.identifier != target.identifier else { return false }
            let overlapsHorizontally =
                candidate.frame.maxX > target.frame.minX + tolerance
                && candidate.frame.minX < target.frame.maxX - tolerance
            let beginsAtOrAboveTop =
                candidate.frame.minY
                >= target.frame.maxY - tolerance
            return overlapsHorizontally && beginsAtOrAboveTop
        }
    }

    public static func display(
        at pointer: CGPoint,
        among displays: [TopEdgeDisplayGeometry],
        activationDistance: Double,
        preferredIdentifier: String? = nil,
        coordinateTolerance: Double = 0.5
    ) -> TopEdgeDisplayGeometry? {
        guard !displays.isEmpty else { return nil }

        let activationDistance = max(0, activationDistance)
        let tolerance = max(0, coordinateTolerance)
        let topEdgeCandidates = displays.filter { display in
            containsHorizontally(pointer.x, in: display.frame, tolerance: tolerance)
                && pointer.y >= display.frame.maxY - activationDistance
                && pointer.y <= display.frame.maxY + tolerance
        }

        if let edgeDisplay = bestCandidate(
            topEdgeCandidates,
            pointer: pointer,
            preferredIdentifier: preferredIdentifier,
            edgeSelection: true
        ) {
            return edgeDisplay
        }

        let containingCandidates = displays.filter { display in
            contains(pointer, in: display.frame, tolerance: tolerance)
        }
        return bestCandidate(
            containingCandidates,
            pointer: pointer,
            preferredIdentifier: preferredIdentifier,
            edgeSelection: false
        )
    }

    private static func containsHorizontally(
        _ x: Double,
        in frame: CGRect,
        tolerance: Double
    ) -> Bool {
        x >= frame.minX - tolerance && x <= frame.maxX + tolerance
    }

    private static func contains(
        _ point: CGPoint,
        in frame: CGRect,
        tolerance: Double
    ) -> Bool {
        containsHorizontally(point.x, in: frame, tolerance: tolerance)
            && point.y >= frame.minY - tolerance
            && point.y <= frame.maxY + tolerance
    }

    private static func bestCandidate(
        _ candidates: [TopEdgeDisplayGeometry],
        pointer: CGPoint,
        preferredIdentifier: String?,
        edgeSelection: Bool
    ) -> TopEdgeDisplayGeometry? {
        guard !candidates.isEmpty else { return nil }

        let nearestCandidates: [TopEdgeDisplayGeometry]
        if edgeSelection,
            let nearestDistance = candidates.map({ abs($0.frame.maxY - pointer.y) }).min()
        {
            nearestCandidates = candidates.filter {
                abs(abs($0.frame.maxY - pointer.y) - nearestDistance) < 0.001
            }
        } else {
            nearestCandidates = candidates
        }

        // Tolerance bridges sub-point event/display rounding, but it must not
        // let stale display preference win after the pointer has genuinely
        // crossed a horizontal seam. Prefer candidates whose real frame owns
        // the coordinate before consulting the previous display identifier.
        let strictCandidates = nearestCandidates.filter {
            pointer.x >= $0.frame.minX && pointer.x <= $0.frame.maxX
                && (edgeSelection
                    || (pointer.y >= $0.frame.minY && pointer.y <= $0.frame.maxY))
        }
        let eligibleCandidates =
            strictCandidates.isEmpty
            ? nearestCandidates
            : strictCandidates

        if let preferredIdentifier,
            let preferred = eligibleCandidates.first(where: {
                $0.identifier == preferredIdentifier
            })
        {
            return preferred
        }

        return eligibleCandidates.min { lhs, rhs in
            let lhsDistance =
                edgeSelection
                ? abs(lhs.frame.maxY - pointer.y)
                : squaredDistance(from: pointer, to: lhs.frame)
            let rhsDistance =
                edgeSelection
                ? abs(rhs.frame.maxY - pointer.y)
                : squaredDistance(from: pointer, to: rhs.frame)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.identifier < rhs.identifier
        }
    }

    /// Zero for a point inside the frame; otherwise the squared distance to
    /// the nearest point on it. This also gives deterministic behavior for
    /// mirrored/overlapping display descriptions.
    private static func squaredDistance(from point: CGPoint, to frame: CGRect) -> Double {
        let dx = max(frame.minX - point.x, 0, point.x - frame.maxX)
        let dy = max(frame.minY - point.y, 0, point.y - frame.maxY)
        return dx * dx + dy * dy
    }
}

public enum TopEdgeGestureAction: Equatable, Sendable {
    case reveal(screenIdentifier: String)
    case hide
}

/// A deterministic state machine used by the global AppKit event monitor.
/// AppKit applies the user's natural-scrolling preference to deltas. Multiplying
/// an inverted event by -1 recovers physical device direction: negative is down.
public struct TopEdgeGestureRecognizer: Sendable {
    public var configuration: TopEdgeGestureConfiguration

    private var activeScreenIdentifier: String?
    private var downwardDistance = 0.0
    private var upwardDistance = 0.0
    private var lastActionTime = -Double.greatestFiniteMagnitude
    private var lastSampleTime: TimeInterval?

    public init(configuration: TopEdgeGestureConfiguration = .init()) {
        self.configuration = configuration
    }

    public mutating func reset() {
        activeScreenIdentifier = nil
        downwardDistance = 0
        upwardDistance = 0
        lastSampleTime = nil
    }

    public mutating func process(
        _ sample: TopEdgeScrollSample,
        trayIsVisible: Bool,
        pointerIsInsideVisibleTray: Bool = false
    ) -> TopEdgeGestureAction? {
        guard !sample.isMomentum else { return nil }

        let idleGap = lastSampleTime.map { sample.timestamp - $0 > 0.45 } ?? false

        if sample.phase == .cancelled || sample.phase == .ended {
            reset()
            return nil
        }

        if sample.phase == .began
            || activeScreenIdentifier != sample.screenIdentifier
            || idleGap
        {
            reset()
            activeScreenIdentifier = sample.screenIdentifier
        }
        lastSampleTime = sample.timestamp

        guard sample.timestamp - lastActionTime >= configuration.cooldown else {
            return nil
        }

        let physicalDelta =
            sample.isDirectionInvertedFromDevice
            ? -sample.scrollingDeltaY
            : sample.scrollingDeltaY
        // Coarse wheels normally report line units, while trackpads report points.
        let pointDelta = physicalDelta * (sample.hasPreciseDeltas ? 1 : 12)
        let topDistance = sample.screenFrame.maxY - sample.pointer.y
        let isAtTopEdge =
            topDistance >= -0.5
            && topDistance <= configuration.activationDistance
            && sample.pointer.x >= sample.screenFrame.minX
            && sample.pointer.x <= sample.screenFrame.maxX

        if !trayIsVisible {
            guard isAtTopEdge else {
                downwardDistance = 0
                return nil
            }
            if pointDelta < 0 {
                downwardDistance += -pointDelta
            } else if pointDelta > 0 {
                downwardDistance = max(0, downwardDistance - pointDelta)
            }
            guard downwardDistance >= configuration.revealThreshold else { return nil }
            lastActionTime = sample.timestamp
            reset()
            return .reveal(screenIdentifier: sample.screenIdentifier)
        }

        guard pointerIsInsideVisibleTray || isAtTopEdge else {
            upwardDistance = 0
            return nil
        }
        if pointDelta > 0 {
            upwardDistance += pointDelta
        } else if pointDelta < 0 {
            upwardDistance = max(0, upwardDistance + pointDelta)
        }
        guard upwardDistance >= configuration.hideThreshold else { return nil }
        lastActionTime = sample.timestamp
        reset()
        return .hide
    }
}
