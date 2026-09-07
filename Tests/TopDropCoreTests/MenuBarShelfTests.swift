import Foundation
import TopDropCore

let menuBarShelfTests: [UnitTest] = [
    UnitTest("Scroll Shelf single divider is screen-aware and bounded") {
        try expectEqual(MenuBarShelfStateMachine.hiddenDividerLength(forWidestScreenWidth: 0), 500)
        try expectEqual(MenuBarShelfStateMachine.hiddenDividerLength(forWidestScreenWidth: 1_728), 3_456)
        try expectEqual(MenuBarShelfStateMachine.hiddenDividerLength(forWidestScreenWidth: 8_000), 10_000)
    },
    UnitTest("Scroll Shelf has hidden visible and arranging layouts") {
        var machine = MenuBarShelfStateMachine()
        try expectEqual(machine.state, .hidden)
        try expectEqual(machine.layout(forWidestScreenWidth: 1_000).dividerLength, 2_000)
        machine.reveal()
        try expectEqual(machine.state, .visible)
        try expectEqual(machine.layout(forWidestScreenWidth: 1_000).dividerLength, 18)
        machine.beginArranging()
        try expectEqual(machine.state, .arranging)
        try expectEqual(machine.layout(forWidestScreenWidth: 1_000).dividerLength, 30)
        machine.hide()
        try expectEqual(machine.state, .hidden)
    },
    UnitTest("Scroll Shelf auto-hide waits until the tray is dismissed") {
        try expect(!MenuBarShelfAutoCollapsePolicy.shouldSchedule(state: .visible, trayIsPresented: true, delay: 5))
        try expect(MenuBarShelfAutoCollapsePolicy.shouldSchedule(state: .visible, trayIsPresented: false, delay: 5))
        try expect(!MenuBarShelfAutoCollapsePolicy.shouldSchedule(state: .hidden, trayIsPresented: false, delay: 5))
        try expect(!MenuBarShelfAutoCollapsePolicy.shouldSchedule(state: .visible, trayIsPresented: false, delay: nil))
    },
    UnitTest("Scroll Shelf restores either removed TopDrop item") {
        try expect(
            !MenuBarShelfStatusItemRestoration.requiresReinstallation(controlIsVisible: true, dividerIsVisible: true))
        try expect(
            MenuBarShelfStatusItemRestoration.requiresReinstallation(controlIsVisible: false, dividerIsVisible: true))
        try expect(
            MenuBarShelfStatusItemRestoration.requiresReinstallation(controlIsVisible: true, dividerIsVisible: false))
    },
    UnitTest("Scroll Shelf auto-hide settings normalize unsafe delays") {
        try expectEqual(MenuBarShelfSettings(autoCollapseDelay: nil).autoCollapseDelay, nil)
        try expectEqual(MenuBarShelfSettings(autoCollapseDelay: 0).autoCollapseDelay, 1)
        try expectEqual(MenuBarShelfSettings(autoCollapseDelay: 5).autoCollapseDelay, 5)
        try expectEqual(MenuBarShelfSettings(autoCollapseDelay: 500).autoCollapseDelay, 60)
    },
    UnitTest("Scroll Shelf decorations normalize and preserve stable IDs") {
        let id = UUID()
        let label = MenuBarShelfDecoration.label(id: id, text: "  A very long accessory label  ")
        let spacer = MenuBarShelfDecoration.spacer(width: 500)
        try expectEqual(label.id, id)
        try expectEqual(label.statusItemAutosaveName, "TopDrop.ShelfDecoration.\(id.uuidString.lowercased())")
        if case .label(let text) = label.content {
            try expectEqual(text.count, MenuBarShelfDecoration.maximumLabelLength)
        } else {
            try expect(false)
        }
        if case .spacer(let width) = spacer.content {
            try expectEqual(width, MenuBarShelfDecoration.maximumSpacerWidth)
        } else {
            try expect(false)
        }
    },
    UnitTest("Scroll Shelf decoration coding is backwards compatible") {
        let settings = MenuBarShelfSettings(
            autoCollapseDelay: 2,
            reclaimApplicationMenus: false,
            decorations: [.label(text: "Work"), .spacer(width: 32)]
        )
        let decoded = try PropertyListDecoder().decode(
            MenuBarShelfSettings.self,
            from: PropertyListEncoder().encode(settings)
        )
        try expectEqual(decoded, settings)

        struct OldSettings: Encodable {
            let autoCollapseDelay = 5.0
            let reclaimApplicationMenus = true
        }
        let old = try PropertyListDecoder().decode(
            MenuBarShelfSettings.self,
            from: PropertyListEncoder().encode(OldSettings())
        )
        try expectEqual(old.decorations, [])
    },
    UnitTest("Single-divider accessory migration requires tutorial version five") {
        try expectEqual(MenuBarShelfSetup.currentVersion, 5)
        let settings = AppSettings(
            completedOnboarding: true,
            menuBarShelf: MenuBarShelfSettings(autoCollapseDelay: 10, reclaimApplicationMenus: false),
            menuBarShelfSetupVersion: 4
        )
        let decoded = try PropertyListDecoder().decode(
            AppSettings.self,
            from: PropertyListEncoder().encode(settings)
        )
        try expectEqual(decoded.menuBarShelfSetupVersion, 4)
        try expect(decoded.menuBarShelfSetupVersion < MenuBarShelfSetup.currentVersion)
        try expectEqual(decoded.menuBarShelf, settings.menuBarShelf)
    },
    UnitTest("Legacy setup completion maps to tutorial version one") {
        try expectEqual(MenuBarShelfSetup.migratedVersion(encodedVersion: nil, legacyCompleted: true), 1)
        try expectEqual(MenuBarShelfSetup.migratedVersion(encodedVersion: nil, legacyCompleted: false), 0)
        try expectEqual(MenuBarShelfSetup.migratedVersion(encodedVersion: 3, legacyCompleted: true), 3)
    },
    UnitTest("Scroll Shelf guide centers and clamps around the real divider") {
        let screen = MenuBarShelfGuideScreen(
            identifier: "main",
            frame: CGRect(x: 0, y: 0, width: 1_000, height: 800),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 770)
        )
        let centered = MenuBarShelfGuidePlacement.resolve(
            anchorFrame: CGRect(x: 490, y: 776, width: 20, height: 24),
            guideSize: CGSize(width: 360, height: 250),
            screens: [screen]
        )
        try expectEqual(centered?.screenIdentifier, "main")
        try expectEqual(centered?.pointerOffset, 0)

        let edge = MenuBarShelfGuidePlacement.resolve(
            anchorFrame: CGRect(x: 2, y: 776, width: 18, height: 24),
            guideSize: CGSize(width: 360, height: 250),
            screens: [screen]
        )
        try expect((edge?.panelFrame.minX ?? 0) >= 12)
        try expect((edge?.pointerOffset ?? 0) < 0)
        try expect(
            MenuBarShelfGuidePlacement.resolve(
                anchorFrame: .zero, guideSize: CGSize(width: 360, height: 250), screens: [screen]) == nil)
    },
    UnitTest("Scroll Shelf guide waits for stable status-item frames") {
        var stability = MenuBarShelfGuideAnchorStability()
        let frame = CGRect(x: -200, y: 900, width: 30, height: 24)
        try expect(!stability.record(frame))
        try expect(stability.record(frame.offsetBy(dx: 0.2, dy: 0)))
        stability.reset()
        try expect(!stability.record(nil))
    },
    UnitTest("Accessories default to a useful first-party row") {
        try expectEqual(TopDropAccessory.defaults.count, 4)
        let builtins = TopDropAccessory.defaults.compactMap { item -> TopDropBuiltinAccessory? in
            if case .builtin(let value) = item.kind { return value }
            return nil
        }
        try expectEqual(builtins, [.newNote, .cleanClipboard, .toggleClipboardHistory, .openSettings])
    },
    UnitTest("Accessory normalization removes duplicate IDs and built-ins") {
        let id = UUID()
        let normalized = TopDropAccessory.normalized([
            .builtin(.newNote, id: id),
            .builtin(.cleanClipboard, id: id),
            .builtin(.newNote),
            .shortcut(name: "My Shortcut"),
        ])
        try expectEqual(normalized.count, 2)
        try expectEqual(normalized.first?.id, id)
    },
    UnitTest("Apple Shortcut URLs safely encode names and clipboard input") {
        let url = TopDropShortcutURLBuilder.runURL(name: "  Capture & File  ", input: .clipboard)
        let components = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        try expectEqual(components?.scheme, "shortcuts")
        try expectEqual(components?.host, "run-shortcut")
        try expectEqual(components?.queryItems?.first(where: { $0.name == "name" })?.value, "Capture & File")
        try expectEqual(components?.queryItems?.first(where: { $0.name == "input" })?.value, "clipboard")
    },
    UnitTest("Accessories reorder by drag without creating copies") {
        let first = TopDropAccessory.shortcut(name: "First")
        let second = TopDropAccessory.shortcut(name: "Second")
        let third = TopDropAccessory.shortcut(name: "Third")
        let moved = TopDropAccessoryOrdering.move([first, second, third], id: third.id, onto: first.id)
        try expectEqual(moved.map(\.id), [third.id, first.id, second.id])
        try expectEqual(Set(moved.map(\.id)).count, 3)
        let movedDown = TopDropAccessoryOrdering.move([first, second, third], id: first.id, onto: third.id)
        try expectEqual(movedDown.map(\.id), [second.id, third.id, first.id])
    },
    UnitTest("Old settings gain default accessories and new settings persist order") {
        struct OldSettings: Encodable {
            let completedOnboarding = true
            let notesFolderName = "TopDrop"
        }
        let migrated = try PropertyListDecoder().decode(
            AppSettings.self,
            from: PropertyListEncoder().encode(OldSettings())
        )
        try expectEqual(migrated.accessories.count, TopDropAccessory.defaults.count)

        let custom = [TopDropAccessory.shortcut(name: "One"), .builtin(.newNote)]
        let original = AppSettings(accessories: custom)
        let decoded = try PropertyListDecoder().decode(
            AppSettings.self,
            from: PropertyListEncoder().encode(original)
        )
        try expectEqual(decoded.accessories, custom)
    },
    UnitTest("Termination reply remains exactly once and bounded") {
        var arbiter = TopDropTerminationReplyArbiter()
        try expect(arbiter.claim(.cleanupCompleted))
        try expect(!arbiter.claim(.deadlineReached))
        try expectEqual(TopDropTerminationPolicy.normalizedDeadline(.infinity), 5)
        try expectEqual(TopDropTerminationPolicy.normalizedDeadline(0), 0.1)
    },
]
