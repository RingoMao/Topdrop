import CoreGraphics
import Foundation
import TopDropCore

private let gestureTestFrame = CGRect(x: 0, y: 0, width: 1_440, height: 900)

let gestureTests: [UnitTest] = [
    UnitTest("Gesture: downward threshold reveals at top edge") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 20, hideThreshold: 10, cooldown: 0)
        )
        let first = gestureSample(time: 1, delta: -12, phase: .began)
        let second = gestureSample(time: 1.1, delta: -9)
        try expect(recognizer.process(first, trayIsVisible: false) == nil)
        try expectEqual(recognizer.process(second, trayIsVisible: false), .reveal(screenIdentifier: "main"))
    },
    UnitTest("Gesture: natural scrolling is normalized") {
        var standard = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 10, cooldown: 0)
        )
        var natural = standard
        try expectEqual(
            standard.process(gestureSample(time: 1, delta: -10), trayIsVisible: false),
            .reveal(screenIdentifier: "main"))
        try expectEqual(
            natural.process(gestureSample(time: 1, delta: 10, inverted: true), trayIsVisible: false),
            .reveal(screenIdentifier: "main"))
    },
    UnitTest("Gesture: momentum and off-edge input are ignored") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 1, cooldown: 0)
        )
        try expect(recognizer.process(gestureSample(time: 1, delta: -50, momentum: true), trayIsVisible: false) == nil)
        var away = gestureSample(time: 2, delta: -50)
        away.pointer.y = gestureTestFrame.maxY - 5
        try expect(recognizer.process(away, trayIsVisible: false) == nil)
    },
    UnitTest("Gesture: coarse mouse wheel uses line scaling") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 20, cooldown: 0)
        )
        try expectEqual(
            recognizer.process(gestureSample(time: 1, delta: -2, precise: false), trayIsVisible: false),
            .reveal(screenIdentifier: "main"))
    },
    UnitTest("Gesture: upward scroll hides visible tray") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 20, hideThreshold: 12, cooldown: 0)
        )
        try expectEqual(
            recognizer.process(
                gestureSample(time: 1, delta: 12), trayIsVisible: true, pointerIsInsideVisibleTray: true), .hide)
    },
    UnitTest("Gesture: cooldown and display changes reset state") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 10, hideThreshold: 5, cooldown: 1)
        )
        try expectEqual(
            recognizer.process(gestureSample(time: 1, delta: -10), trayIsVisible: false),
            .reveal(screenIdentifier: "main"))
        try expect(recognizer.process(gestureSample(time: 1.5, delta: -20), trayIsVisible: false) == nil)
        var other = gestureSample(time: 2.1, delta: -6)
        other.screenIdentifier = "other"
        try expect(recognizer.process(other, trayIsVisible: false) == nil)
        other.timestamp = 2.2
        other.scrollingDeltaY = -4
        try expectEqual(recognizer.process(other, trayIsVisible: false), .reveal(screenIdentifier: "other"))
    },
    UnitTest("Gesture: idle coarse wheel deltas do not accumulate forever") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 20, cooldown: 0)
        )
        try expect(
            recognizer.process(
                gestureSample(time: 1, delta: -1, precise: false),
                trayIsVisible: false
            ) == nil
        )
        try expect(
            recognizer.process(
                gestureSample(time: 2, delta: -1, precise: false),
                trayIsVisible: false
            ) == nil
        )
    },
    UnitTest("Gesture: resolves side-by-side displays including negative origins") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "left",
                frame: CGRect(x: -1_920, y: -120, width: 1_920, height: 1_080)
            ),
            TopEdgeDisplayGeometry(
                identifier: "main",
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
            ),
        ]

        try expectEqual(
            TopEdgeDisplayResolver.display(
                at: CGPoint(x: -900, y: 958),
                among: displays,
                activationDistance: 4
            )?.identifier,
            "left"
        )
        try expectEqual(
            TopEdgeDisplayResolver.display(
                at: CGPoint(x: 700, y: 898),
                among: displays,
                activationDistance: 4
            )?.identifier,
            "main"
        )
    },
    UnitTest("Gesture: vertical display seam belongs to the lower top edge") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "lower",
                frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
            ),
            TopEdgeDisplayGeometry(
                identifier: "upper",
                frame: CGRect(x: 0, y: 900, width: 1_440, height: 900)
            ),
        ]

        let result = TopEdgeDisplayResolver.display(
            at: CGPoint(x: 720, y: 900),
            among: displays,
            activationDistance: 4
        )
        try expectEqual(result?.identifier, "lower")
    },
    UnitTest("Gesture: display resolver includes exact outer top boundaries") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "upper-negative",
                frame: CGRect(x: -800, y: 900, width: 1_600, height: 1_000)
            )
        ]
        let result = TopEdgeDisplayResolver.display(
            at: CGPoint(x: 0, y: 1_900),
            among: displays,
            activationDistance: 4
        )
        try expectEqual(result?.identifier, "upper-negative")
    },
    UnitTest("Gesture: display handoff resets partial threshold distance") {
        var recognizer = TopEdgeGestureRecognizer(
            configuration: .init(revealThreshold: 20, cooldown: 0)
        )
        var left = gestureSample(time: 1, delta: -12, phase: .began)
        left.screenIdentifier = "left"
        left.screenFrame = CGRect(x: -1_440, y: 0, width: 1_440, height: 900)
        left.pointer = CGPoint(x: -720, y: 898)
        try expect(recognizer.process(left, trayIsVisible: false) == nil)

        var right = gestureSample(time: 1.1, delta: -9)
        right.screenIdentifier = "right"
        right.screenFrame = CGRect(x: 0, y: -200, width: 1_920, height: 1_080)
        right.pointer = CGPoint(x: 960, y: 878)
        try expect(recognizer.process(right, trayIsVisible: false) == nil)
        right.timestamp = 1.2
        right.scrollingDeltaY = -11
        try expectEqual(
            recognizer.process(right, trayIsVisible: false),
            .reveal(screenIdentifier: "right")
        )
    },
    UnitTest("Gesture: seam ownership stays stable when top edges overlap") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "left",
                frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
            ),
            TopEdgeDisplayGeometry(
                identifier: "right",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ),
        ]
        let result = TopEdgeDisplayResolver.display(
            at: CGPoint(x: 0, y: 799),
            among: displays,
            activationDistance: 4,
            preferredIdentifier: "right"
        )
        try expectEqual(result?.identifier, "right")
    },
    UnitTest("Gesture: crossing a horizontal seam overrides stale preference") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "left",
                frame: CGRect(x: -1_000, y: 0, width: 1_000, height: 800)
            ),
            TopEdgeDisplayGeometry(
                identifier: "right",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 800)
            ),
        ]
        let result = TopEdgeDisplayResolver.display(
            at: CGPoint(x: 0.25, y: 799),
            among: displays,
            activationDistance: 4,
            preferredIdentifier: "left"
        )
        try expectEqual(result?.identifier, "right")
    },
    UnitTest("Gesture: detects a display above before tray animation") {
        let lower = TopEdgeDisplayGeometry(
            identifier: "lower",
            frame: CGRect(x: 0, y: 0, width: 1_440, height: 900)
        )
        let upper = TopEdgeDisplayGeometry(
            identifier: "upper",
            frame: CGRect(x: 200, y: 900, width: 1_200, height: 900)
        )
        let side = TopEdgeDisplayGeometry(
            identifier: "side",
            frame: CGRect(x: 1_440, y: 0, width: 1_000, height: 900)
        )
        try expect(
            TopEdgeDisplayResolver.hasOverlappingDisplayAbove(
                lower,
                among: [lower, upper, side]
            )
        )
        try expect(
            !TopEdgeDisplayResolver.hasOverlappingDisplayAbove(
                upper,
                among: [lower, upper, side]
            )
        )
    },
    UnitTest("Gesture: nearest top edge wins after a display handoff") {
        let displays = [
            TopEdgeDisplayGeometry(
                identifier: "previous",
                frame: CGRect(x: -1_000, y: 0, width: 1_001, height: 800)
            ),
            TopEdgeDisplayGeometry(
                identifier: "current",
                frame: CGRect(x: 0, y: 0, width: 1_000, height: 802)
            ),
        ]
        let result = TopEdgeDisplayResolver.display(
            at: CGPoint(x: 0, y: 801),
            among: displays,
            activationDistance: 4,
            preferredIdentifier: "previous"
        )
        try expectEqual(result?.identifier, "current")
    },
]

private func gestureSample(
    time: TimeInterval,
    delta: Double,
    inverted: Bool = false,
    precise: Bool = true,
    phase: ScrollGesturePhase = .changed,
    momentum: Bool = false
) -> TopEdgeScrollSample {
    TopEdgeScrollSample(
        timestamp: time,
        screenIdentifier: "main",
        pointer: CGPoint(x: 720, y: gestureTestFrame.maxY - 2),
        screenFrame: gestureTestFrame,
        scrollingDeltaY: delta,
        isDirectionInvertedFromDevice: inverted,
        hasPreciseDeltas: precise,
        phase: phase,
        isMomentum: momentum
    )
}
