import Foundation

public struct DevToolsLayout: Equatable, Sendable {
    public let usesPopover: Bool
    public let sidebarWidth: Double
    public let workspaceWidth: Double
    public var compactWorkspace: Bool { workspaceWidth < 980 }

    public init(innerWidth: Double, expanded: Bool) {
        let width = max(0, innerWidth.isFinite ? innerWidth : 0)
        usesPopover = width < 820
        sidebarWidth = expanded && !usesPopover ? 240 : 0
        workspaceWidth = max(0, width - (sidebarWidth > 0 ? sidebarWidth + 9 : 0))
    }
}
