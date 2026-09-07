import CoreGraphics
import Foundation

public struct MenuBarShelfDecoration: Codable, Equatable, Identifiable, Sendable {
    public enum Content: Codable, Equatable, Sendable {
        case spacer(width: Double)
        case label(text: String)

        private enum CodingKeys: String, CodingKey {
            case kind
            case width
            case text
        }

        private enum Kind: String, Codable {
            case spacer
            case label
        }

        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            switch try values.decode(Kind.self, forKey: .kind) {
            case .spacer:
                self = .spacer(
                    width: MenuBarShelfDecoration.normalizedSpacerWidth(
                        try values.decodeIfPresent(Double.self, forKey: .width)
                            ?? MenuBarShelfDecoration.defaultSpacerWidth
                    )
                )
            case .label:
                self = .label(
                    text: MenuBarShelfDecoration.normalizedLabel(
                        try values.decodeIfPresent(String.self, forKey: .text) ?? "Label"
                    )
                )
            }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .spacer(let width):
                try values.encode(Kind.spacer, forKey: .kind)
                try values.encode(
                    MenuBarShelfDecoration.normalizedSpacerWidth(width),
                    forKey: .width
                )
            case .label(let text):
                try values.encode(Kind.label, forKey: .kind)
                try values.encode(
                    MenuBarShelfDecoration.normalizedLabel(text),
                    forKey: .text
                )
            }
        }
    }

    public static let defaultSpacerWidth = 24.0
    public static let minimumSpacerWidth = 8.0
    public static let maximumSpacerWidth = 80.0
    public static let maximumLabelLength = 20

    public let id: UUID
    public var content: Content

    public init(id: UUID = UUID(), content: Content) {
        self.id = id
        switch content {
        case .spacer(let width):
            self.content = .spacer(width: Self.normalizedSpacerWidth(width))
        case .label(let text):
            self.content = .label(text: Self.normalizedLabel(text))
        }
    }

    public static func spacer(
        id: UUID = UUID(),
        width: Double = defaultSpacerWidth
    ) -> Self {
        Self(id: id, content: .spacer(width: width))
    }

    public static func label(id: UUID = UUID(), text: String = "Label") -> Self {
        Self(id: id, content: .label(text: text))
    }

    public static func normalizedSpacerWidth(_ width: Double) -> Double {
        guard width.isFinite else { return defaultSpacerWidth }
        return min(max(width, minimumSpacerWidth), maximumSpacerWidth)
    }

    public static func normalizedLabel(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.isEmpty ? "Label" : trimmed
        return String(value.prefix(maximumLabelLength))
    }

    public var statusItemAutosaveName: String {
        "TopDrop.ShelfDecoration.\(id.uuidString.lowercased())"
    }

    public var statusItemDefaultsKeys: [String] {
        [
            "NSStatusItem Preferred Position \(statusItemAutosaveName)",
            "NSStatusItem Visible \(statusItemAutosaveName)",
            "NSStatusItem VisibleCC \(statusItemAutosaveName)",
        ]
    }
}

public struct MenuBarShelfSettings: Codable, Equatable, Sendable {
    /// A nil delay keeps the shelf visible until the user collapses it.
    public var autoCollapseDelay: TimeInterval?
    public var reclaimApplicationMenus: Bool
    public var decorations: [MenuBarShelfDecoration]

    public init(
        autoCollapseDelay: TimeInterval? = 5,
        reclaimApplicationMenus: Bool = true,
        decorations: [MenuBarShelfDecoration] = []
    ) {
        self.autoCollapseDelay = Self.normalizedDelay(autoCollapseDelay)
        self.reclaimApplicationMenus = reclaimApplicationMenus
        self.decorations = Self.normalizedDecorations(decorations)
    }

    public static func normalizedDelay(_ value: TimeInterval?) -> TimeInterval? {
        guard let value else { return nil }
        return min(max(value, 1), 60)
    }

    private enum CodingKeys: String, CodingKey {
        case autoCollapseDelay
        case reclaimApplicationMenus
        case decorations
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        autoCollapseDelay = Self.normalizedDelay(
            try values.decodeIfPresent(TimeInterval.self, forKey: .autoCollapseDelay)
        )
        reclaimApplicationMenus =
            try values.decodeIfPresent(
                Bool.self,
                forKey: .reclaimApplicationMenus
            ) ?? true
        decorations = Self.normalizedDecorations(
            try values.decodeIfPresent(
                [MenuBarShelfDecoration].self,
                forKey: .decorations
            ) ?? []
        )
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encodeIfPresent(autoCollapseDelay, forKey: .autoCollapseDelay)
        try values.encode(reclaimApplicationMenus, forKey: .reclaimApplicationMenus)
        try values.encode(Self.normalizedDecorations(decorations), forKey: .decorations)
    }

    private static func normalizedDecorations(
        _ decorations: [MenuBarShelfDecoration]
    ) -> [MenuBarShelfDecoration] {
        var seen = Set<UUID>()
        return decorations.compactMap { decoration in
            guard seen.insert(decoration.id).inserted else { return nil }
            return MenuBarShelfDecoration(id: decoration.id, content: decoration.content)
        }
    }
}

public enum MenuBarShelfSetup {
    /// Version 5 returns to the reliable one-divider native shelf and adds the
    /// first-party accessory shelf. Existing proxy-divider placement is not
    /// reused because it represented a different topology.
    public static let currentVersion = 5

    public static func migratedVersion(
        encodedVersion: Int?,
        legacyCompleted: Bool?
    ) -> Int {
        if let encodedVersion {
            return max(0, encodedVersion)
        }
        return legacyCompleted == true ? 1 : 0
    }
}

public enum MenuBarShelfPresentationState: String, Codable, Equatable, Sendable {
    case hidden
    case visible
    case arranging
}

public struct MenuBarShelfLayout: Equatable, Sendable {
    public var dividerLength: Double

    public init(dividerLength: Double) {
        self.dividerLength = dividerLength
    }
}

public struct MenuBarShelfStateMachine: Equatable, Sendable {
    public static let visibleDividerLength = 18.0
    public static let arrangingDividerLength = 30.0

    public private(set) var state: MenuBarShelfPresentationState

    public init(state: MenuBarShelfPresentationState = .hidden) {
        self.state = state
    }

    public mutating func reveal() {
        state = .visible
    }

    public mutating func beginArranging() {
        state = .arranging
    }

    public mutating func hide() {
        state = .hidden
    }

    public func layout(forWidestScreenWidth width: Double) -> MenuBarShelfLayout {
        switch state {
        case .hidden:
            MenuBarShelfLayout(
                dividerLength: Self.hiddenDividerLength(forWidestScreenWidth: width)
            )
        case .visible:
            MenuBarShelfLayout(dividerLength: Self.visibleDividerLength)
        case .arranging:
            MenuBarShelfLayout(dividerLength: Self.arrangingDividerLength)
        }
    }

    public static func hiddenDividerLength(forWidestScreenWidth width: Double) -> Double {
        max(500, min(max(0, width) * 2, 10_000))
    }
}

public enum MenuBarShelfAutoCollapsePolicy {
    public static func shouldSchedule(
        state: MenuBarShelfPresentationState,
        trayIsPresented: Bool,
        delay: TimeInterval?
    ) -> Bool {
        state == .visible && !trayIsPresented && delay != nil
    }
}

public enum MenuBarShelfStatusItemRestoration {
    public static func requiresReinstallation(
        controlIsVisible: Bool,
        dividerIsVisible: Bool
    ) -> Bool {
        !controlIsVisible || !dividerIsVisible
    }
}

public struct MenuBarShelfGuideScreen: Equatable, Sendable {
    public let identifier: String
    public let frame: CGRect
    public let visibleFrame: CGRect

    public init(identifier: String, frame: CGRect, visibleFrame: CGRect) {
        self.identifier = identifier
        self.frame = frame
        self.visibleFrame = visibleFrame
    }
}

public struct MenuBarShelfGuidePlacement: Equatable, Sendable {
    public static let screenMargin: CGFloat = 12
    public static let anchorGap: CGFloat = 6
    public static let pointerEdgeInset: CGFloat = 22

    public let screenIdentifier: String
    public let panelFrame: CGRect
    /// Horizontal pointer offset from the panel's center.
    public let pointerOffset: CGFloat

    public init(screenIdentifier: String, panelFrame: CGRect, pointerOffset: CGFloat) {
        self.screenIdentifier = screenIdentifier
        self.panelFrame = panelFrame
        self.pointerOffset = pointerOffset
    }

    public static func resolve(
        anchorFrame: CGRect,
        guideSize: CGSize,
        screens: [MenuBarShelfGuideScreen]
    ) -> Self? {
        guard isUsable(anchorFrame), isUsable(guideSize), !screens.isEmpty else { return nil }
        let anchorPoint = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)
        let selected =
            screens.first(where: { containsInclusively($0.frame, anchorPoint) })
            ?? screens
            .map { ($0, $0.frame.intersection(anchorFrame).area) }
            .filter { $0.1 > 0 }
            .max { left, right in
                if left.1 == right.1 { return left.0.identifier > right.0.identifier }
                return left.1 < right.1
            }?.0
        guard let selected else { return nil }

        let bounds = selected.visibleFrame.insetBy(dx: screenMargin, dy: screenMargin)
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let width = min(guideSize.width, bounds.width)
        let height = min(guideSize.height, bounds.height)
        let desiredX = anchorFrame.midX - width / 2
        let x = min(max(desiredX, bounds.minX), bounds.maxX - width)
        let desiredTop = min(anchorFrame.minY - anchorGap, selected.visibleFrame.maxY)
        let y = min(max(desiredTop - height, bounds.minY), bounds.maxY - height)
        let panelFrame = CGRect(x: x, y: y, width: width, height: height).integral
        let maximumPointerOffset = max(0, panelFrame.width / 2 - pointerEdgeInset)
        let pointerOffset = min(
            max(anchorFrame.midX - panelFrame.midX, -maximumPointerOffset),
            maximumPointerOffset
        )
        return Self(
            screenIdentifier: selected.identifier,
            panelFrame: panelFrame,
            pointerOffset: pointerOffset
        )
    }

    private static func isUsable(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite
            && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }

    private static func isUsable(_ size: CGSize) -> Bool {
        size.width.isFinite && size.height.isFinite && size.width > 0 && size.height > 0
    }

    private static func containsInclusively(_ rect: CGRect, _ point: CGPoint) -> Bool {
        point.x >= rect.minX && point.x <= rect.maxX
            && point.y >= rect.minY && point.y <= rect.maxY
    }
}

public struct MenuBarShelfGuideAnchorStability: Equatable, Sendable {
    public let requiredSamples: Int
    public let tolerance: CGFloat
    public private(set) var candidate: CGRect?
    public private(set) var matchingSampleCount = 0

    public init(requiredSamples: Int = 2, tolerance: CGFloat = 0.75) {
        self.requiredSamples = max(1, requiredSamples)
        self.tolerance = max(0, tolerance)
    }

    public mutating func record(_ frame: CGRect?) -> Bool {
        guard let frame, frame.width > 0, frame.height > 0,
            frame.origin.x.isFinite, frame.origin.y.isFinite
        else {
            reset()
            return false
        }
        if let candidate, approximatelyEqual(candidate, frame) {
            matchingSampleCount += 1
        } else {
            candidate = frame
            matchingSampleCount = 1
        }
        return matchingSampleCount >= requiredSamples
    }

    public mutating func reset() {
        candidate = nil
        matchingSampleCount = 0
    }

    private func approximatelyEqual(_ left: CGRect, _ right: CGRect) -> Bool {
        abs(left.minX - right.minX) <= tolerance
            && abs(left.minY - right.minY) <= tolerance
            && abs(left.width - right.width) <= tolerance
            && abs(left.height - right.height) <= tolerance
    }
}

private extension CGRect {
    var area: CGFloat {
        guard !isNull, !isInfinite else { return 0 }
        return max(0, width) * max(0, height)
    }
}
