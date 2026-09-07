import Foundation

public enum TopDropBuiltinAccessory: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case newNote
    case refreshNotes
    case cleanClipboard
    case toggleClipboardHistory
    case openSettings
    case chooseScreenshotFolder
    case importScreenshots

    public var title: String {
        switch self {
        case .newNote: "New Note"
        case .refreshNotes: "Refresh Notes"
        case .cleanClipboard: "Clean Formatting"
        case .toggleClipboardHistory: "Pause or Resume Clipboard"
        case .openSettings: "Settings"
        case .chooseScreenshotFolder: "Choose Screenshot Folder"
        case .importScreenshots: "Import Screenshots"
        }
    }

    public var symbolName: String {
        switch self {
        case .newNote: "square.and.pencil"
        case .refreshNotes: "arrow.clockwise"
        case .cleanClipboard: "textformat"
        case .toggleClipboardHistory: "pause.play"
        case .openSettings: "gearshape"
        case .chooseScreenshotFolder: "folder"
        case .importScreenshots: "square.and.arrow.down"
        }
    }
}

public enum TopDropShortcutInput: String, Codable, CaseIterable, Equatable, Sendable {
    case none
    case clipboard
}

public enum TopDropAccessoryKind: Codable, Equatable, Sendable {
    case builtin(TopDropBuiltinAccessory)
    case shortcut(name: String, input: TopDropShortcutInput)

    private enum CodingKeys: String, CodingKey {
        case type
        case builtin
        case name
        case input
    }

    private enum Kind: String, Codable {
        case builtin
        case shortcut
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .type) {
        case .builtin:
            self = .builtin(try values.decode(TopDropBuiltinAccessory.self, forKey: .builtin))
        case .shortcut:
            self = .shortcut(
                name: Self.normalizedShortcutName(
                    try values.decodeIfPresent(String.self, forKey: .name) ?? "Shortcut"
                ),
                input: try values.decodeIfPresent(
                    TopDropShortcutInput.self,
                    forKey: .input
                ) ?? .none
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .builtin(let builtin):
            try values.encode(Kind.builtin, forKey: .type)
            try values.encode(builtin, forKey: .builtin)
        case .shortcut(let name, let input):
            try values.encode(Kind.shortcut, forKey: .type)
            try values.encode(Self.normalizedShortcutName(name), forKey: .name)
            try values.encode(input, forKey: .input)
        }
    }

    public static func normalizedShortcutName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return String((trimmed.isEmpty ? "Shortcut" : trimmed).prefix(80))
    }

    public var title: String {
        switch self {
        case .builtin(let builtin): builtin.title
        case .shortcut(let name, _): Self.normalizedShortcutName(name)
        }
    }

    public var symbolName: String {
        switch self {
        case .builtin(let builtin): builtin.symbolName
        case .shortcut: "command.square"
        }
    }
}

public struct TopDropAccessory: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: TopDropAccessoryKind

    public init(id: UUID = UUID(), kind: TopDropAccessoryKind) {
        self.id = id
        self.kind = kind
    }

    public static func builtin(
        _ builtin: TopDropBuiltinAccessory,
        id: UUID = UUID()
    ) -> Self {
        Self(id: id, kind: .builtin(builtin))
    }

    public static func shortcut(
        name: String,
        input: TopDropShortcutInput = .none,
        id: UUID = UUID()
    ) -> Self {
        Self(
            id: id,
            kind: .shortcut(
                name: TopDropAccessoryKind.normalizedShortcutName(name),
                input: input
            )
        )
    }

    public static let defaults: [Self] = [
        .builtin(.newNote),
        .builtin(.cleanClipboard),
        .builtin(.toggleClipboardHistory),
        .builtin(.openSettings),
    ]

    public static func normalized(_ accessories: [Self]) -> [Self] {
        var seenIDs = Set<UUID>()
        var seenBuiltins = Set<TopDropBuiltinAccessory>()
        return accessories.compactMap { accessory in
            guard seenIDs.insert(accessory.id).inserted else { return nil }
            if case .builtin(let builtin) = accessory.kind,
                !seenBuiltins.insert(builtin).inserted
            {
                return nil
            }
            return accessory
        }
    }
}

public enum TopDropShortcutURLBuilder {
    public static func runURL(
        name: String,
        input: TopDropShortcutInput
    ) -> URL? {
        var components = URLComponents()
        components.scheme = "shortcuts"
        components.host = "run-shortcut"
        var items = [
            URLQueryItem(
                name: "name",
                value: TopDropAccessoryKind.normalizedShortcutName(name)
            )
        ]
        if input == .clipboard {
            items.append(URLQueryItem(name: "input", value: "clipboard"))
        }
        components.queryItems = items
        return components.url
    }
}

public enum TopDropAccessoryOrdering {
    public static func move(
        _ accessories: [TopDropAccessory],
        id: UUID,
        onto targetID: UUID
    ) -> [TopDropAccessory] {
        guard id != targetID,
            let source = accessories.firstIndex(where: { $0.id == id }),
            let target = accessories.firstIndex(where: { $0.id == targetID })
        else { return accessories }
        var result = accessories
        let accessory = result.remove(at: source)
        // A drop means “move to the row/icon I dropped on.” Keeping the
        // target's original index makes downward and upward movement equally
        // useful and lets the last target move an item to the end.
        result.insert(accessory, at: min(target, result.count))
        return result
    }
}
