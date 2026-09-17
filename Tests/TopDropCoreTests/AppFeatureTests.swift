import Foundation
import TopDropCore

let appFeatureTests: [UnitTest] = [
    UnitTest("Retired Hide Bar settings are ignored and no longer persisted") {
        struct LegacySettings: Encodable {
            let completedOnboarding = true
            let menuBarShelfSetupVersion = 5
            let completedMenuBarShelfSetup = true
            let menuBarZones = ["legacy"]
        }
        let decoded = try PropertyListDecoder().decode(
            AppSettings.self,
            from: PropertyListEncoder().encode(LegacySettings())
        )
        let encoded = try PropertyListEncoder().encode(decoded)
        let plist = String(decoding: encoded, as: UTF8.self)
        try expect(!plist.contains("menuBarShelf"))
        try expect(!plist.contains("completedMenuBarShelfSetup"))
        try expect(!plist.contains("menuBarZones"))
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
