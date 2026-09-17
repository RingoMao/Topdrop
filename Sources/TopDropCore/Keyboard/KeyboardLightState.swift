import Foundation

public enum KeyboardLightMode: String, Codable, CaseIterable, Sendable {
    case automatic, manual
}

public enum KeyboardLightColor: String, Codable, CaseIterable, Sendable {
    case working, attention, done, custom
}

public struct KeyboardLightSettings: Codable, Equatable, Sendable {
    public var managed = false
    public var enabled = false
    public var mode = KeyboardLightMode.automatic
    public var color = KeyboardLightColor.done
    public var hue = 109.0
    public var saturation = 125.0
    public var brightness = 180.0
    public init() {}

    public var manualArguments: [String] {
        if color != .custom { return [color == .attention ? "attention-solid" : color.rawValue] }
        func byte(_ value: Double) -> String { String(Int(value.isFinite ? min(255, max(0, value)) : 0)) }
        return ["hsv", byte(hue), byte(saturation), byte(brightness)]
    }
}

public struct KeyboardLightSnapshot: Equatable, Sendable {
    public let state: KeyboardLightColor
    public let latestEvent: Date?
    public let expiredCount: Int
    public let activeCount: Int
}

public enum KeyboardLightLedger {
    public static let maximumBytes = 1_048_576
    // Missing Stop hooks must not hold red/orange indefinitely. These are leases,
    // not proof a task has finished. Live hooks renew the lease automatically.
    public static let workingLease: TimeInterval = 30 * 60
    public static let attentionLease: TimeInterval = 15 * 60

    public static func read(_ data: Data, now: Date = Date()) throws -> KeyboardLightSnapshot {
        guard data.count <= maximumBytes,
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let sessions = root["sessions"] as? [String: Any]
        else { throw CocoaError(.fileReadCorruptFile) }
        var active = Set<KeyboardLightColor>()
        var latest: Date?
        var expired = 0, activeCount = 0
        for raw in sessions.values {
            guard let entry = raw as? [String: Any],
                let status = entry["status"] as? String,
                let color = KeyboardLightColor(rawValue: status), color != .custom,
                let updated = entry["updated_at"] as? Double, updated.isFinite
            else { continue }
            let age = now.timeIntervalSince1970 - updated
            guard age >= -60 else { expired += 1; continue }
            let date = Date(timeIntervalSince1970: updated)
            latest = max(latest ?? date, date)
            let lease: TimeInterval = color == .attention ? attentionLease : color == .working ? workingLease : 86_400
            guard age <= lease else { expired += 1; continue }
            active.insert(color)
            if color != .done { activeCount += 1 }
        }
        return KeyboardLightSnapshot(
            state: active.contains(.attention) ? .attention : active.contains(.working) ? .working : .done,
            latestEvent: latest, expiredCount: expired, activeCount: activeCount
        )
    }

    public static func read(url: URL, now: Date = Date()) throws -> KeyboardLightSnapshot {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return try read(handle.read(upToCount: maximumBytes + 1) ?? Data(), now: now)
    }
}
