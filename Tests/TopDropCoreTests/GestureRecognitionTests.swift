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
                gestureSample(time: 1, delta: 12), trayIsVisible: true), .hide)
    },
    UnitTest("Gesture: defaults preserve reveal effort and require a stronger close") {
        let config = TopEdgeGestureConfiguration()
        try expectEqual(config.revealThreshold, 42)
        try expectEqual(config.hideThreshold, 50)
        var recognizer = TopEdgeGestureRecognizer(configuration: config)
        try expect(recognizer.process(gestureSample(time: 1, delta: 42), trayIsVisible: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.1, delta: 7), trayIsVisible: true) == nil)
        try expectEqual(recognizer.process(gestureSample(time: 1.2, delta: 1), trayIsVisible: true), .hide)
    },
    UnitTest("Gesture: content and scrollbar scroll never close the tray") {
        for precise in [true, false] {
            var recognizer = TopEdgeGestureRecognizer(configuration: .init(cooldown: 0))
            for index in 0..<20 {
                var sample = gestureSample(time: 1 + Double(index) * 0.05, delta: 100, precise: precise)
                sample.pointer.y = 600
                try expect(recognizer.process(sample, trayIsVisible: true, pointerIsInsideVisibleTray: true) == nil)
            }
        }
    },
    UnitTest("Gesture: content gesture cannot turn into close after pointer reaches top") {
        var recognizer = TopEdgeGestureRecognizer(configuration: .init(cooldown: 0))
        var content = gestureSample(time: 1, delta: 10, phase: .began)
        content.pointer.y = 600
        try expect(recognizer.process(content, trayIsVisible: true, pointerIsInsideVisibleTray: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.1, delta: 200), trayIsVisible: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.2, delta: 200, momentum: true), trayIsVisible: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.3, delta: 0, phase: .ended), trayIsVisible: true) == nil)
        try expectEqual(
            recognizer.process(gestureSample(time: 1.4, delta: 50, phase: .began), trayIsVisible: true), .hide)
    },
    UnitTest("Gesture: coarse content sequence needs idle gap before top-edge closing") {
        var recognizer = TopEdgeGestureRecognizer(configuration: .init(cooldown: 0))
        let content = gestureSample(time: 1, delta: 1, precise: false, phase: .none)
        try expect(recognizer.process(content, trayIsVisible: true, pointerIsInsideVisibleTray: true) == nil)
        try expect(
            recognizer.process(gestureSample(time: 1.1, delta: 7, precise: false, phase: .none), trayIsVisible: true)
                == nil)
        try expectEqual(
            recognizer.process(gestureSample(time: 2, delta: 7, precise: false, phase: .none), trayIsVisible: true),
            .hide)
    },
    UnitTest("Gesture: leaving top edge discards partial close distance") {
        var recognizer = TopEdgeGestureRecognizer(configuration: .init(cooldown: 0))
        try expect(recognizer.process(gestureSample(time: 1, delta: 30), trayIsVisible: true) == nil)
        var away = gestureSample(time: 1.1, delta: 100)
        away.pointer.y = 700
        try expect(recognizer.process(away, trayIsVisible: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.2, delta: 20), trayIsVisible: true) == nil)
    },
    UnitTest("Gesture: legacy close default upgrades without changing opening preferences") {
        let data = Data(#"{"activationDistance":6,"revealThreshold":55,"hideThreshold":28,"cooldown":1}"#.utf8)
        let config = try JSONDecoder().decode(TopEdgeGestureConfiguration.self, from: data)
        try expectEqual(config.revealThreshold, 55)
        try expectEqual(config.activationDistance, 6)
        try expectEqual(config.cooldown, 1)
        try expectEqual(config.hideThreshold, 50)
        let previousDefault = TopEdgeGestureConfiguration(hideThreshold: 84)
        let migrated = try JSONDecoder().decode(
            TopEdgeGestureConfiguration.self, from: JSONEncoder().encode(previousDefault))
        try expectEqual(migrated.hideThreshold, 50)
        let custom = TopEdgeGestureConfiguration(revealThreshold: 31, hideThreshold: 110)
        let roundTrip = try JSONDecoder().decode(TopEdgeGestureConfiguration.self, from: JSONEncoder().encode(custom))
        try expectEqual(roundTrip, custom)
    },
    UnitTest("Gesture: scrollbar protection has 24-point hit slop but preserves screen edge") {
        for origin in [CGPoint.zero, CGPoint(x: -1440, y: 900)] {
            let screen = CGRect(origin: origin, size: gestureTestFrame.size)
            let tray = CGRect(x: origin.x + 12, y: origin.y + 350, width: 1416, height: 520)
            for offset in [CGPoint(x: -20, y: 100), CGPoint(x: 1436, y: 100), CGPoint(x: 600, y: -20)] {
                try expect(
                    TrayScrollProtection.contains(
                        CGPoint(x: tray.minX + offset.x, y: tray.minY + offset.y),
                        trayFrame: tray, screenFrame: screen, activationDistance: 4))
            }
            try expect(
                !TrayScrollProtection.contains(
                    CGPoint(x: tray.minX - 30, y: tray.midY), trayFrame: tray, screenFrame: screen,
                    activationDistance: 4))
            let nearlyFullHeight = CGRect(x: origin.x + 4, y: origin.y + 100, width: 1432, height: 794)
            try expect(
                !TrayScrollProtection.contains(
                    CGPoint(x: screen.midX, y: screen.maxY - 2), trayFrame: nearlyFullHeight,
                    screenFrame: screen, activationDistance: 4))
        }
        try expect(
            !TrayScrollProtection.contains(
                .zero, trayFrame: .zero, screenFrame: gestureTestFrame, activationDistance: 4))
    },
    UnitTest("Gesture: scrolling content during reveal cooldown remains protected") {
        var recognizer = TopEdgeGestureRecognizer()
        try expectEqual(
            recognizer.process(gestureSample(time: 1, delta: -42), trayIsVisible: false),
            .reveal(screenIdentifier: "main"))
        try expect(
            recognizer.process(
                gestureSample(time: 1.1, delta: 10), trayIsVisible: true, pointerIsInsideVisibleTray: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.4, delta: 10), trayIsVisible: true) == nil)
        try expect(recognizer.process(gestureSample(time: 1.8, delta: 100), trayIsVisible: true) == nil)
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
