@preconcurrency import AppKit
import SwiftUI
import TopDropCore

struct TopDropTrayView: View {
    @ObservedObject var notes: NotesViewModel
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var screenshots: ScreenshotViewModel
    @ObservedObject var menuBarShelf: MenuBarShelfController
    @ObservedObject var accessories: TopDropAccessoryManager
    @ObservedObject var devTools: DevToolsModel
    let showSettings: () -> Void
    let toggleClipboardPause: () -> Void
    let pickScreenColor: () -> Void
    let editScreenshot: (ScreenshotItem) -> Void
    let hide: () -> Void

    @AppStorage(
        "TopDrop.tray.leftFraction",
        store: UserDefaults(suiteName: TopDropCore.bundleIdentifier)
    ) private var storedLeftFraction = 0.42
    @State private var dragStartFraction: Double?
    @State private var transientLeftFraction: Double?
    @State private var compactWorkspace = CompactWorkspace.clipboard
    @State private var toolsExpanded = true
    @State private var toolsPopover = false

    private let compactBreakpoint = TrayPanelLayoutPolicy.compactBreakpoint
    private let dashboardGap: CGFloat = 9
    /// Matches the density of the native macOS menu bar while keeping the
    /// workspace itself visually uninterrupted above it.
    private let bottomToolbarHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geometry in
            let layout = DevToolsLayout(innerWidth: geometry.size.width - 16, expanded: toolsExpanded)
            VStack(spacing: dashboardGap) {
                HStack(spacing: dashboardGap) {
                    Group {
                        if layout.compactWorkspace {
                            compactDashboard
                        } else {
                            splitDashboard(width: layout.workspaceWidth)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    if layout.sidebarWidth > 0 {
                        DashboardCard {
                            DevToolsView(
                                model: devTools, clipboard: clipboard, hide: hide,
                                collapse: { toolsExpanded = false })
                        }
                        .frame(width: layout.sidebarWidth)
                    }
                }
                DashboardCard(cornerRadius: 8) {
                    bottomToolbar(compact: layout.compactWorkspace, usesPopover: layout.usesPopover)
                }
                .frame(height: bottomToolbarHeight)
            }
            .padding(8)
        }
        .background { TopDropNeutralGlass() }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .tint(.primary)
        .padding(4)
    }

    private func splitDashboard(width: CGFloat) -> some View {
        let dividerWidth: CGFloat = 10
        let availableWidth = max(1, width - dividerWidth)
        let limits = fractionLimits(for: availableWidth)
        let proposed = transientLeftFraction ?? storedLeftFraction
        let fraction = min(max(proposed, limits.lowerBound), limits.upperBound)
        let leftWidth = availableWidth * fraction

        return VStack(spacing: dashboardGap) {
            HStack(spacing: 0) {
                DashboardCard {
                    NotesColumnView(model: notes, showSettings: showSettings)
                }
                .frame(width: leftWidth)

                dashboardDivider(availableWidth: availableWidth, limits: limits)

                DashboardCard {
                    ClipboardColumnView(
                        monitor: clipboard,
                        screenshots: screenshots,
                        togglePause: toggleClipboardPause,
                        pickScreenColor: pickScreenColor,
                        edit: editScreenshot
                    )
                }
                .frame(maxWidth: .infinity)
            }

        }
    }

    private var compactDashboard: some View {
        VStack(spacing: dashboardGap) {
            DashboardCard {
                switch compactWorkspace {
                case .notes:
                    NotesColumnView(model: notes, showSettings: showSettings)
                case .clipboard:
                    ClipboardColumnView(
                        monitor: clipboard,
                        screenshots: screenshots,
                        togglePause: toggleClipboardPause,
                        pickScreenColor: pickScreenColor,
                        edit: editScreenshot
                    )
                }
            }

        }
    }

    private func bottomToolbar(compact: Bool, usesPopover: Bool) -> some View {
        HStack(spacing: 7) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 15, height: 15)
                    .accessibilityHidden(true)
                Text("TopDrop")
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                shelfStateLabel
            }
            .fixedSize(horizontal: true, vertical: false)

            Spacer(minLength: 6)

            if compact {
                HStack(spacing: 2) {
                    compactWorkspaceButton(
                        .notes,
                        title: "Notes",
                        symbol: "note.text"
                    )
                    compactWorkspaceButton(
                        .clipboard,
                        title: "Clipboard & Images",
                        symbol: "clipboard"
                    )
                }
                .padding(2)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 6))
                .frame(maxWidth: 250)
                .layoutPriority(1)

                Spacer(minLength: 6)
            } else {
                TopDropAccessoryShelfView(manager: accessories)
                    .layoutPriority(1)
                Spacer(minLength: 6)
            }

            HStack(spacing: 1) {
                Button {
                    devTools.hiddenFiles.refresh()
                    if usesPopover { toolsPopover.toggle() } else { toolsExpanded.toggle() }
                } label: {
                    Label("Dev Tools", systemImage: "wrench.and.screwdriver")
                }
                .buttonStyle(.borderless)
                .help("Show or hide Dev Tools")
                .accessibilityLabel("Show or hide Dev Tools")
                .popover(isPresented: $toolsPopover, arrowEdge: .bottom) {
                    DevToolsView(
                        model: devTools, clipboard: clipboard,
                        hide: {
                            toolsPopover = false; hide()
                        },
                        collapse: { toolsPopover = false }
                    )
                    .frame(width: 240, height: 425)
                    .background { TopDropNeutralGlass() }
                }
                .onChange(of: usesPopover) { _, _ in toolsPopover = false }
                .onReceive(NotificationCenter.default.publisher(for: .topDropTrayDidHide)) { _ in
                    toolsPopover = false
                }
                if compact {
                    TopDropAccessoryShelfView(manager: accessories, compact: true)
                }

                Button(action: hide) {
                    Image(systemName: "xmark")
                        .frame(width: 19, height: 19)
                }
                .buttonStyle(.borderless)
                .help("Hide TopDrop")
            }
            .font(.caption)
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 7)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func compactWorkspaceButton(
        _ workspace: CompactWorkspace,
        title: String,
        symbol: String
    ) -> some View {
        let isSelected = compactWorkspace == workspace
        return Button {
            compactWorkspace = workspace
        } label: {
            Label(title, systemImage: symbol)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    isSelected ? Color.primary.opacity(0.12) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.primary.opacity(0.4), lineWidth: 1)
                    }
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shelfStateLabel: some View {
        Label(shelfStateText, systemImage: shelfStateSymbol)
            .labelStyle(.titleAndIcon)
            .font(.caption2)
            .foregroundStyle(menuBarShelf.state == .arranging ? Color.primary : Color.secondary)
            .fontWeight(menuBarShelf.state == .arranging ? .semibold : .regular)
            .lineLimit(1)
            .help("Native Scroll Shelf is \(shelfStateText.lowercased())")
    }

    private var shelfStateText: String {
        switch menuBarShelf.state {
        case .hidden: "Shelf Hidden"
        case .visible: "Shelf Visible"
        case .arranging: "Arranging"
        }
    }

    private var shelfStateSymbol: String {
        switch menuBarShelf.state {
        case .hidden: "rectangle.compress.vertical"
        case .visible: "rectangle.expand.vertical"
        case .arranging: "arrow.left.and.right"
        }
    }

    private func dashboardDivider(
        availableWidth: CGFloat,
        limits: ClosedRange<Double>
    ) -> some View {
        RoundedRectangle(cornerRadius: 1)
            .fill(Color.primary.opacity(0.14))
            .frame(width: 2)
            .frame(width: 10)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let start = dragStartFraction ?? storedLeftFraction
                        if dragStartFraction == nil { dragStartFraction = start }
                        transientLeftFraction = min(
                            max(start + value.translation.width / availableWidth, limits.lowerBound),
                            limits.upperBound
                        )
                    }
                    .onEnded { _ in
                        if let transientLeftFraction {
                            storedLeftFraction = min(
                                max(transientLeftFraction, limits.lowerBound),
                                limits.upperBound
                            )
                        }
                        self.transientLeftFraction = nil
                        dragStartFraction = nil
                    }
            )
            .accessibilityLabel("Resize Notes and Clipboard")
    }

    private func fractionLimits(for availableWidth: CGFloat) -> ClosedRange<Double> {
        TrayPanelLayoutPolicy.notesFractionRange(
            for: availableWidth + 10,
            dividerWidth: 10
        )
    }
}

private enum CompactWorkspace: String, Hashable {
    case notes
    case clipboard
}

private struct DashboardCard<Content: View>: View {
    let content: Content
    let cornerRadius: CGFloat

    init(cornerRadius: CGFloat = 11, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.cornerRadius = cornerRadius
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.primary.opacity(0.035))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.primary.opacity(0.09), lineWidth: 1)
            }
    }
}
