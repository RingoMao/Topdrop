import Foundation
import TopDropCore

let trayPanelLayoutTests: [UnitTest] = [
    UnitTest("Small built-in displays use nearly their full visible width") {
        let thirteen = TrayDisplayMetrics(
            visibleFrame: CGRect(x: 0, y: 0, width: 1_440, height: 875),
            isBuiltIn: true,
            physicalSizeMillimeters: CGSize(width: 286, height: 186)
        )
        let fourteen = TrayDisplayMetrics(
            visibleFrame: CGRect(x: -1_512, y: 40, width: 1_512, height: 945),
            isBuiltIn: true,
            physicalSizeMillimeters: CGSize(width: 302, height: 196)
        )
        let first = TrayPanelLayoutPolicy.layout(
            for: thirteen,
            configuredHeight: 520,
            minimumHeight: 420
        )
        let second = TrayPanelLayoutPolicy.layout(
            for: fourteen,
            configuredHeight: 520,
            minimumHeight: 420
        )
        try expectEqual(first.frame.width, 1_432)
        try expectEqual(first.frame.minX, 4)
        try expectEqual(first.contentMode, .twoPane)
        try expectEqual(second.frame.width, 1_504)
        try expectEqual(second.frame.minX, -1_508)
    },
    UnitTest("Sixteen-inch and desktop displays use the centered width cap") {
        let displays = [
            TrayDisplayMetrics(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_728, height: 1_080),
                isBuiltIn: true,
                physicalSizeMillimeters: CGSize(width: 345, height: 224)
            ),
            TrayDisplayMetrics(
                visibleFrame: CGRect(x: 200, y: -40, width: 1_920, height: 1_080),
                isBuiltIn: false
            ),
            TrayDisplayMetrics(
                visibleFrame: CGRect(x: -2_560, y: 0, width: 2_560, height: 1_440),
                isBuiltIn: false
            ),
            TrayDisplayMetrics(
                visibleFrame: CGRect(x: 0, y: 0, width: 3_440, height: 1_320),
                isBuiltIn: false
            ),
            TrayDisplayMetrics(
                visibleFrame: CGRect(x: 0, y: 0, width: 1_920, height: 1_920),
                isBuiltIn: false
            ),
        ]
        for display in displays {
            let layout = TrayPanelLayoutPolicy.layout(
                for: display,
                configuredHeight: 520,
                minimumHeight: 420
            )
            try expectEqual(layout.frame.width, 1_320)
            try expectEqual(layout.frame.midX, display.visibleFrame.midX)
            try expectEqual(layout.contentMode, .twoPane)
        }
    },
    UnitTest("Portrait displays select valid responsive content modes") {
        let widePortrait = TrayPanelLayoutPolicy.layout(
            for: TrayDisplayMetrics(
                visibleFrame: CGRect(x: -1_080, y: 0, width: 1_080, height: 1_920),
                isBuiltIn: false
            ),
            configuredHeight: 700,
            minimumHeight: 420
        )
        let narrowPortrait = TrayPanelLayoutPolicy.layout(
            for: TrayDisplayMetrics(
                visibleFrame: CGRect(x: 0, y: 0, width: 900, height: 1_600),
                isBuiltIn: false
            ),
            configuredHeight: 700,
            minimumHeight: 420
        )
        try expectEqual(widePortrait.frame.width, 1_056)
        try expectEqual(widePortrait.contentMode, .twoPane)
        try expectEqual(narrowPortrait.frame.width, 876)
        try expectEqual(narrowPortrait.contentMode, .compact)
    },
    UnitTest("Tray height honors configuration up to available display height") {
        let metrics = TrayDisplayMetrics(
            visibleFrame: CGRect(x: -900, y: 30, width: 900, height: 600),
            isBuiltIn: false
        )
        let layout = TrayPanelLayoutPolicy.layout(
            for: metrics,
            configuredHeight: 900,
            minimumHeight: 420,
            topInset: 20
        )
        try expectEqual(layout.frame.height, 572)
        try expectEqual(layout.frame.minY, 36)
        try expectEqual(layout.frame.midX, metrics.visibleFrame.midX)
    },
    UnitTest("Persisted tray divider is clamped to 300 and 560 point pane minima") {
        let range = TrayPanelLayoutPolicy.notesFractionRange(for: 1_200)
        let available: CGFloat = 1_190
        try expectEqual(range.lowerBound, Double(300 / available))
        try expectEqual(range.upperBound, Double(1 - 560 / available))
        try expectEqual(
            TrayPanelLayoutPolicy.clampNotesFraction(0.05, workspaceWidth: 1_200),
            range.lowerBound
        )
        try expectEqual(
            TrayPanelLayoutPolicy.clampNotesFraction(0.95, workspaceWidth: 1_200),
            range.upperBound
        )
    },
    UnitTest("Clipboard header maps every watch state deterministically") {
        let now = Date(timeIntervalSince1970: 1_000)
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .idle,
                accessState: .allowed,
                isPaused: false,
                now: now
            ),
            .idle
        )
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .watching(startedAt: now, deadline: now.addingTimeInterval(22.2)),
                accessState: .allowed,
                isPaused: false,
                now: now
            ),
            .watching(secondsRemaining: 23)
        )
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .received(itemID: UUID(), receivedAt: now),
                accessState: .allowed,
                isPaused: false,
                now: now
            ),
            .received
        )
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .timedOut,
                accessState: .allowed,
                isPaused: false,
                now: now
            ),
            .timedOut
        )
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .idle,
                accessState: .allowed,
                isPaused: true,
                now: now
            ),
            .paused
        )
        try expectEqual(
            ClipboardUtilityWatchPolicy.state(
                arrivalWatch: .idle,
                accessState: .denied,
                isPaused: false,
                now: now
            ),
            .inaccessible
        )
        try expectEqual(ClipboardUtilityWatchState.received.systemImageName, "checkmark.circle.fill")
        try expectEqual(ClipboardUtilityWatchState.timedOut.systemImageName, "exclamationmark.triangle")
    },
]
