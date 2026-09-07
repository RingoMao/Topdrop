import Foundation
import TopDropCore

let screenColorSamplerTests: [UnitTest] = [
    UnitTest("Screen color input ignores launch click and confirms the next click") {
        let launching = ScreenColorSamplerInputSnapshot(
            leftMouseDown: true,
            rightMouseDown: false,
            escapeDown: false
        )
        var gate = ScreenColorSamplerInputGate(initial: launching)

        try expectEqual(gate.update(launching), .none)
        try expectEqual(gate.update(.released), .none)
        try expectEqual(gate.update(.leftClick), .confirm)
    },
    UnitTest("Screen color input cancels from Escape without window focus") {
        var gate = ScreenColorSamplerInputGate(initial: .released)
        try expectEqual(gate.update(.escape), .cancel)
    },
    UnitTest("Screen color input cancels from right click") {
        var gate = ScreenColorSamplerInputGate(initial: .released)
        try expectEqual(gate.update(.rightClick), .cancel)
    },
    UnitTest("Screen color sampler converts AppKit points to capture space") {
        let point = ScreenColorSamplerGeometry.capturePoint(
            fromAppKit: CGPoint(x: 240, y: 820),
            mainDisplayHeight: 1_000
        )
        try expectEqual(point, CGPoint(x: 240, y: 180))

        let aboveMainDisplay = ScreenColorSamplerGeometry.capturePoint(
            fromAppKit: CGPoint(x: -400, y: 1_250),
            mainDisplayHeight: 1_000
        )
        try expectEqual(aboveMainDisplay, CGPoint(x: -400, y: -250))
    },
    UnitTest("Screen color preview flips at display edges") {
        let screen = CGRect(x: 0, y: 0, width: 800, height: 600)
        let size = CGSize(width: 132, height: 158)

        let ordinary = ScreenColorSamplerGeometry.previewFrame(
            pointer: CGPoint(x: 200, y: 200),
            screenFrame: screen,
            previewSize: size
        )
        try expectEqual(ordinary.origin, CGPoint(x: 222, y: 222))

        let edge = ScreenColorSamplerGeometry.previewFrame(
            pointer: CGPoint(x: 790, y: 590),
            screenFrame: screen,
            previewSize: size
        )
        try expectEqual(edge.origin, CGPoint(x: 636, y: 410))
        try expect(screen.contains(edge), "Flipped preview should stay inside the display")
    },
    UnitTest("Screen color preview supports negative display origins") {
        let screen = CGRect(x: -1_200, y: -500, width: 900, height: 1_100)
        let frame = ScreenColorSamplerGeometry.previewFrame(
            pointer: CGPoint(x: -1_195, y: -495),
            screenFrame: screen,
            previewSize: CGSize(width: 132, height: 158)
        )
        try expectEqual(frame.minX, -1_173)
        try expectEqual(frame.minY, -473)
        try expect(screen.contains(frame), "Preview should clamp within a negative-origin display")
    },
]

private extension ScreenColorSamplerInputSnapshot {
    static let released = Self(leftMouseDown: false, rightMouseDown: false, escapeDown: false)
    static let leftClick = Self(leftMouseDown: true, rightMouseDown: false, escapeDown: false)
    static let rightClick = Self(leftMouseDown: false, rightMouseDown: true, escapeDown: false)
    static let escape = Self(leftMouseDown: false, rightMouseDown: false, escapeDown: true)
}
