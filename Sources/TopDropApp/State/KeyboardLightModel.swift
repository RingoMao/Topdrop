@preconcurrency import AppKit
import Darwin
import Foundation
import TopDropCore

@MainActor
final class KeyboardLightModel: ObservableObject {
    @Published private(set) var status = "Off"
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var latestEvent: Date?

    private let runner = KeyboardLightProcess()
    private let helper: URL
    private let ledger: URL
    private var configuration = KeyboardLightSettings()
    private var loop: Task<Void, Never>?
    private var ownerFD: Int32 = -1
    private var prepared = false
    private var stopping = false
    private var wakeObserver: NSObjectProtocol?

    init() {
        helper = (Bundle.main.executableURL ?? URL(fileURLWithPath: "/unavailable"))
            .deletingLastPathComponent().appendingPathComponent("TopDropKeyboardLight")
        let home = FileManager.default.homeDirectoryForCurrentUser
        let codexHome =
            ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0) }
            ?? home.appendingPathComponent(".codex")
        ledger = codexHome.appendingPathComponent("codex-keyboard-light/traffic-light-state.json")
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.refresh() } }
    }

    func apply(_ value: KeyboardLightSettings) {
        guard value != configuration || (value.managed && loop == nil) else { return }
        configuration = value
        refresh()
    }

    func refresh() {
        guard !stopping else { return }
        loop?.cancel()
        // An untouched installation remains opt-in. Once claimed, Off keeps
        // reasserting lights-out, including after reconnect and wake.
        guard configuration.managed || ownerFD >= 0 else { status = "Off — turn on to connect"; return }
        status = "Refreshing…"
        loop = Task { [weak self] in await self?.monitor() }
    }

    private func acquireOwnership() -> Bool {
        if ownerFD >= 0 { return true }
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("TopDrop", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fd = open(
                directory.appendingPathComponent("keyboard-light.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { return false }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); return false }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            ownerFD = fd
            return true
        } catch { return false }
    }

    private func prepare() async -> Bool {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            status = "Keyboard helper missing — reinstall TopDrop"; return false
        }
        guard acquireOwnership() else { status = "Another TopDrop is controlling the light"; return false }
        if prepared { return true }
        let plist = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.openai.codex-keyboard-light.plist")
        if FileManager.default.fileExists(atPath: plist.path) {
            // Only retire the known predecessor. Preserve its plist and hooks for
            // recovery; don't edit arbitrary launch jobs or the shared ledger.
            guard let data = try? Data(contentsOf: plist),
                let object = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                let arguments = object["ProgramArguments"] as? [String],
                arguments.contains(where: { $0.hasSuffix("/codex-keyboard-light/codex-light-daemon") })
            else { status = "Existing light service is unfamiliar — cannot take over"; return false }
            let target = "gui/\(getuid())/com.openai.codex-keyboard-light"
            let launchctl = URL(fileURLWithPath: "/bin/launchctl")
            let disabled = await runner.run(launchctl, arguments: ["disable", target], timeout: 2)
            guard !Task.isCancelled else { return false }
            guard disabled.succeeded else {
                status = "Could not pause the old light service — retry Refresh"; return false
            }
            _ = await runner.run(launchctl, arguments: ["bootout", target], timeout: 2)
            guard !Task.isCancelled else { return false }
            let check = await runner.run(launchctl, arguments: ["print", target], timeout: 2)
            guard check.status == 113 && !check.timedOut else {
                status = "Old light service is still active — retry Refresh"; return false
            }
        }
        prepared = true
        return true
    }

    private func monitor() async {
        var previous: [String]?
        var lastSend = ContinuousClock.now.advanced(by: .seconds(-60))
        while !Task.isCancelled && !stopping {
            guard await prepare(), !Task.isCancelled else {
                if Task.isCancelled { return }
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                continue
            }
            var label: String
            var arguments: [String]
            if !configuration.enabled {
                arguments = ["off"]; label = "Off"
            } else if configuration.mode == .manual {
                arguments = configuration.manualArguments;
                label = "Manual · \(configuration.color.rawValue.capitalized)"
            } else {
                do {
                    let snapshot = try KeyboardLightLedger.read(url: ledger)
                    latestEvent = snapshot.latestEvent
                    let state = snapshot.state
                    arguments = [state == .attention ? "attention-solid" : state.rawValue]
                    label = state == .done ? "Automatic · Idle" : "Automatic · \(state.rawValue.capitalized)"
                    if snapshot.expiredCount > 0 { label += " · stale events ignored" }
                } catch {
                    // Fail visibly and extinguish an obsolete red/orange state.
                    arguments = ["off"]; label = "Status feed unavailable · light off · retrying"
                    latestEvent = nil
                }
            }
            if arguments != previous || ContinuousClock.now - lastSend >= .seconds(5) {
                let result = await runner.run(helper, arguments: arguments)
                guard !Task.isCancelled else { return }
                if result.succeeded {
                    previous = arguments; lastSend = .now
                    status = label; lastUpdated = Date()
                } else {
                    previous = nil
                    status =
                        result.timedOut
                        ? "Keyboard timed out · reconnecting"
                        : result.status == 69
                            ? "Keyboard disconnected · retrying"
                            : "Keyboard unavailable (\(result.status)) · retrying"
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                }
            }
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
        }
    }

    func beginTermination() {
        stopping = true
        loop?.cancel()
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
    }

    func shutdown() async {
        beginTermination()
        if prepared { _ = await runner.run(helper, arguments: ["off"], timeout: 1) }
        if ownerFD >= 0 { flock(ownerFD, LOCK_UN); close(ownerFD); ownerFD = -1 }
    }
}
