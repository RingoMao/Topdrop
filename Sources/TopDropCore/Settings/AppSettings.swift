import Foundation

public struct TopEdgeGestureConfiguration: Codable, Equatable, Sendable {
    public var activationDistance: Double
    public var revealThreshold: Double
    public var hideThreshold: Double
    public var cooldown: TimeInterval

    public init(
        activationDistance: Double = 4,
        revealThreshold: Double = 42,
        hideThreshold: Double = 28,
        cooldown: TimeInterval = 0.75
    ) {
        self.activationDistance = max(1, activationDistance)
        self.revealThreshold = max(1, revealThreshold)
        self.hideThreshold = max(1, hideThreshold)
        self.cooldown = max(0, cooldown)
    }
}

public struct CleanClipboardHotKeySettings: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var control: Bool
    public var option: Bool
    public var command: Bool
    public var shift: Bool

    /// ANSI V with Control-Option-Command.
    public init(
        keyCode: UInt32 = 9,
        control: Bool = true,
        option: Bool = true,
        command: Bool = true,
        shift: Bool = false
    ) {
        self.keyCode = keyCode
        self.control = control
        self.option = option
        self.command = command
        self.shift = shift
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public static let minimumPanelHeight = 420.0
    public static let maximumPanelHeight = 900.0

    public var gesture: TopEdgeGestureConfiguration
    public var panelHeight: Double
    public var clipboardPaused: Bool
    public var excludedClipboardBundleIdentifiers: Set<String>
    public var cleanClipboardHotKey: CleanClipboardHotKeySettings
    public var notesAccountIdentifier: String?
    public var notesAccountName: String?
    public var notesFolderIdentifier: String?
    public var notesFolderName: String
    public var screenshotFolderBookmark: Data?
    public var screenshotFolderDisplayPath: String?
    public var completedOnboarding: Bool
    public var menuBarShelf: MenuBarShelfSettings
    public var menuBarShelfSetupVersion: Int
    public var accessories: [TopDropAccessory]

    public init(
        gesture: TopEdgeGestureConfiguration = .init(),
        panelHeight: Double = 520,
        clipboardPaused: Bool = false,
        excludedClipboardBundleIdentifiers: Set<String> = [],
        cleanClipboardHotKey: CleanClipboardHotKeySettings = .init(),
        notesAccountIdentifier: String? = nil,
        notesAccountName: String? = nil,
        notesFolderIdentifier: String? = nil,
        notesFolderName: String = "TopDrop",
        screenshotFolderBookmark: Data? = nil,
        screenshotFolderDisplayPath: String? = nil,
        completedOnboarding: Bool = false,
        menuBarShelf: MenuBarShelfSettings = .init(),
        menuBarShelfSetupVersion: Int = 0,
        accessories: [TopDropAccessory] = TopDropAccessory.defaults
    ) {
        self.gesture = gesture
        self.panelHeight = Self.clampedPanelHeight(panelHeight)
        self.clipboardPaused = clipboardPaused
        self.excludedClipboardBundleIdentifiers = excludedClipboardBundleIdentifiers
        self.cleanClipboardHotKey = cleanClipboardHotKey
        self.notesAccountIdentifier = notesAccountIdentifier
        self.notesAccountName = notesAccountName
        self.notesFolderIdentifier = notesFolderIdentifier
        self.notesFolderName = notesFolderName
        self.screenshotFolderBookmark = screenshotFolderBookmark
        self.screenshotFolderDisplayPath = screenshotFolderDisplayPath
        self.completedOnboarding = completedOnboarding
        self.menuBarShelf = menuBarShelf
        self.menuBarShelfSetupVersion = max(0, menuBarShelfSetupVersion)
        self.accessories = TopDropAccessory.normalized(accessories)
    }

    private enum CodingKeys: String, CodingKey {
        case gesture
        case panelHeight
        case clipboardPaused
        case excludedClipboardBundleIdentifiers
        case cleanClipboardHotKey
        case notesAccountIdentifier
        case notesAccountName
        case notesFolderIdentifier
        case notesFolderName
        case screenshotFolderBookmark
        case screenshotFolderDisplayPath
        case completedOnboarding
        case menuBarShelf
        case menuBarShelfSetupVersion
        case accessories
        case legacyCompletedMenuBarShelfSetup = "completedMenuBarShelfSetup"
        /// Read-only migration key used by the former three-zone design.
        case legacyMenuBarZones = "menuBarZones"
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        gesture =
            try values.decodeIfPresent(
                TopEdgeGestureConfiguration.self,
                forKey: .gesture
            ) ?? .init()
        panelHeight = Self.clampedPanelHeight(
            try values.decodeIfPresent(Double.self, forKey: .panelHeight) ?? 520
        )
        clipboardPaused =
            try values.decodeIfPresent(
                Bool.self,
                forKey: .clipboardPaused
            ) ?? false
        excludedClipboardBundleIdentifiers =
            try values.decodeIfPresent(
                Set<String>.self,
                forKey: .excludedClipboardBundleIdentifiers
            ) ?? []
        cleanClipboardHotKey =
            try values.decodeIfPresent(
                CleanClipboardHotKeySettings.self,
                forKey: .cleanClipboardHotKey
            ) ?? .init()
        notesAccountIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .notesAccountIdentifier
        )
        notesAccountName = try values.decodeIfPresent(
            String.self,
            forKey: .notesAccountName
        )
        notesFolderIdentifier = try values.decodeIfPresent(
            String.self,
            forKey: .notesFolderIdentifier
        )
        notesFolderName =
            try values.decodeIfPresent(
                String.self,
                forKey: .notesFolderName
            ) ?? "TopDrop"
        screenshotFolderBookmark = try values.decodeIfPresent(
            Data.self,
            forKey: .screenshotFolderBookmark
        )
        screenshotFolderDisplayPath = try values.decodeIfPresent(
            String.self,
            forKey: .screenshotFolderDisplayPath
        )
        completedOnboarding =
            try values.decodeIfPresent(
                Bool.self,
                forKey: .completedOnboarding
            ) ?? false
        menuBarShelf =
            try values.decodeIfPresent(
                MenuBarShelfSettings.self,
                forKey: .menuBarShelf
            ) ?? values.decodeIfPresent(
                MenuBarShelfSettings.self,
                forKey: .legacyMenuBarZones
            ) ?? .init()
        menuBarShelfSetupVersion = MenuBarShelfSetup.migratedVersion(
            encodedVersion: try values.decodeIfPresent(
                Int.self,
                forKey: .menuBarShelfSetupVersion
            ),
            legacyCompleted: try values.decodeIfPresent(
                Bool.self,
                forKey: .legacyCompletedMenuBarShelfSetup
            )
        )
        accessories = TopDropAccessory.normalized(
            try values.decodeIfPresent([TopDropAccessory].self, forKey: .accessories)
                ?? TopDropAccessory.defaults
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(gesture, forKey: .gesture)
        try values.encode(Self.clampedPanelHeight(panelHeight), forKey: .panelHeight)
        try values.encode(clipboardPaused, forKey: .clipboardPaused)
        try values.encode(
            excludedClipboardBundleIdentifiers,
            forKey: .excludedClipboardBundleIdentifiers
        )
        try values.encode(cleanClipboardHotKey, forKey: .cleanClipboardHotKey)
        try values.encodeIfPresent(notesAccountIdentifier, forKey: .notesAccountIdentifier)
        try values.encodeIfPresent(notesAccountName, forKey: .notesAccountName)
        try values.encodeIfPresent(notesFolderIdentifier, forKey: .notesFolderIdentifier)
        try values.encode(notesFolderName, forKey: .notesFolderName)
        try values.encodeIfPresent(screenshotFolderBookmark, forKey: .screenshotFolderBookmark)
        try values.encodeIfPresent(
            screenshotFolderDisplayPath,
            forKey: .screenshotFolderDisplayPath
        )
        try values.encode(completedOnboarding, forKey: .completedOnboarding)
        try values.encode(menuBarShelf, forKey: .menuBarShelf)
        try values.encode(menuBarShelfSetupVersion, forKey: .menuBarShelfSetupVersion)
        try values.encode(TopDropAccessory.normalized(accessories), forKey: .accessories)
    }

    public static func clampedPanelHeight(_ value: Double) -> Double {
        min(max(value, minimumPanelHeight), maximumPanelHeight)
    }
}

public protocol SettingsPersisting: Sendable {
    func load() async -> AppSettings
    func save(_ settings: AppSettings) async throws
}

public actor UserDefaultsSettingsStore: SettingsPersisting {
    private let defaults: UserDefaults
    private let key: String
    private let encoder = PropertyListEncoder()
    private let decoder = PropertyListDecoder()

    public init(
        suiteName: String = TopDropCore.bundleIdentifier,
        key: String = "TopDrop.settings.v1"
    ) {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        self.key = key
    }

    public func load() -> AppSettings {
        guard
            let data = defaults.data(forKey: key),
            let settings = try? decoder.decode(AppSettings.self, from: data)
        else {
            return AppSettings()
        }
        return settings
    }

    public func save(_ settings: AppSettings) throws {
        defaults.set(try encoder.encode(settings), forKey: key)
    }
}
