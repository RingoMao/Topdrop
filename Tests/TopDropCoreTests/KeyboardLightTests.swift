import Foundation
import TopDropCore

let keyboardLightTests: [UnitTest] = [
    UnitTest("Keyboard light priority expires stale attention without hiding live work") {
        let data = Data(
            """
            {"sessions":{"old":{"status":"attention","updated_at":1},
            "live":{"status":"working","updated_at":1999},
            "done":{"status":"done","updated_at":1999}}}
            """.utf8)
        let snapshot = try KeyboardLightLedger.read(data, now: Date(timeIntervalSince1970: 2000))
        try expectEqual(snapshot.state, .working)
        try expectEqual(snapshot.expiredCount, 1)
        try expectEqual(snapshot.activeCount, 1)
    },
    UnitTest("Keyboard light fresh attention wins and dead working leases expire") {
        let data = Data(
            """
            {"sessions":{"a":{"status":"attention","updated_at":4999},
            "b":{"status":"working","updated_at":1}}}
            """.utf8)
        let snapshot = try KeyboardLightLedger.read(data, now: Date(timeIntervalSince1970: 5000))
        try expectEqual(snapshot.state, .attention)
        try expectEqual(snapshot.expiredCount, 1)
    },
    UnitTest("Keyboard light ignores corrupt rows and implausible future timestamps") {
        let data = Data(
            """
            {"sessions":{"a":false,"b":{"status":"attention","updated_at":999999},
            "c":{"status":"custom","updated_at":99}}}
            """.utf8)
        let snapshot = try KeyboardLightLedger.read(data, now: Date(timeIntervalSince1970: 100))
        try expectEqual(snapshot.state, .done)
        try expectEqual(snapshot.activeCount, 0)
    },
    UnitTest("Keyboard light rejects missing ledger structure and oversized input") {
        for data in [Data("{}".utf8), Data(repeating: 32, count: KeyboardLightLedger.maximumBytes + 1)] {
            var rejected = false
            do { _ = try KeyboardLightLedger.read(data) } catch { rejected = true }
            try expect(rejected)
        }
    },
    UnitTest("Keyboard light old settings remain opt-in and manual override persists") {
        let migrated = try PropertyListDecoder().decode(
            AppSettings.self, from: PropertyListEncoder().encode(["completedOnboarding": true]))
        try expect(!migrated.keyboardLight.enabled && !migrated.keyboardLight.managed)
        var settings = migrated
        settings.keyboardLight.managed = true
        settings.keyboardLight.enabled = true
        settings.keyboardLight.mode = .manual
        settings.keyboardLight.color = .attention
        let roundtrip = try PropertyListDecoder().decode(AppSettings.self, from: PropertyListEncoder().encode(settings))
        try expectEqual(roundtrip.keyboardLight, settings.keyboardLight)
        try expectEqual(roundtrip.keyboardLight.manualArguments, ["attention-solid"])
    },
    UnitTest("Keyboard light custom values cannot escape byte ranges") {
        var settings = KeyboardLightSettings()
        settings.color = .custom
        settings.hue = .nan
        settings.saturation = -10
        settings.brightness = 999
        try expectEqual(settings.manualArguments, ["hsv", "0", "0", "255"])
    },
    UnitTest("Keyboard light hung helper times out and following command still runs") {
        let runner = KeyboardLightProcess()
        let start = ContinuousClock.now
        let hung = await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"], timeout: 0.1)
        try expect(hung.timedOut)
        try expect(ContinuousClock.now - start < .seconds(2))
        let next = await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        try expect(next.succeeded)
    },
    UnitTest("Keyboard light cancellation stops old work before a manual override") {
        let runner = KeyboardLightProcess()
        let task = Task { await runner.run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["10"]) }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()
        let result = await task.value
        try expect(!result.succeeded)
        let next = await runner.run(URL(fileURLWithPath: "/usr/bin/true"), arguments: [])
        try expect(next.succeeded)
    },
]
