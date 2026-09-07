import SwiftUI
import TopDropCore

struct MenuBarQuickSettingsView: View {
    @ObservedObject var shelf: MenuBarShelfController
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    let toggleTray: () -> Void
    let cleanClipboard: () -> Void
    let toggleClipboardPause: () -> Void
    let showSettings: () -> Void
    let quit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "tray.full")
                    .font(.title2)
                VStack(alignment: .leading, spacing: 1) {
                    Text("TopDrop").font(.headline)
                    Text(shelfStateText).font(.caption).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(shelf.state == .hidden ? "Reveal Native Shelf" : "Hide Native Shelf") {
                    shelf.toggleShelfVisibility()
                }
                .buttonStyle(MonochromeProminentButtonStyle())
                Button("Toggle Tray", action: toggleTray)
                Button("Arrange") { shelf.beginArranging() }
            }

            HStack {
                Text("Auto-hide shelf")
                Spacer()
                Picker("Auto-hide shelf", selection: autoCollapseBinding) {
                    Text("Never").tag(0.0)
                    Text("2 seconds").tag(2.0)
                    Text("5 seconds").tag(5.0)
                    Text("10 seconds").tag(10.0)
                }
                .labelsHidden()
                .frame(width: 130)
            }

            Button("Open macOS Menu Bar Settings") { MenuBarSystemSettings.open() }
            Divider()
            Button("Clean Clipboard Formatting", action: cleanClipboard)
            Button(
                clipboard.isPaused ? "Resume Clipboard History" : "Pause Clipboard History",
                action: toggleClipboardPause)
            Toggle(
                "Launch at Login",
                isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
            Divider()
            HStack {
                Button("Settings…", action: showSettings)
                Spacer()
                Button("Quit", action: quit)
            }
        }
        .padding(14)
        .frame(width: 310)
        .tint(.primary)
    }

    private var shelfStateText: String {
        switch shelf.state {
        case .hidden: "Native shelf hidden"
        case .visible: "Native shelf visible"
        case .arranging: "Arranging native items"
        }
    }

    private var autoCollapseBinding: Binding<Double> {
        Binding(
            get: { shelf.settings.autoCollapseDelay ?? 0 },
            set: { shelf.setAutoCollapseDelay($0 == 0 ? nil : $0) }
        )
    }
}

struct MenuBarShelfSettingsView: View {
    @ObservedObject var shelf: MenuBarShelfController
    let previewTopDrop: () -> Void
    @State private var previewMode = MenuBarShelfPreviewMode.hidden

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Native Scroll Shelf").font(.title2.bold())
                    Text(
                        "A reliable Hidden Bar-style divider for genuine third-party menu-bar items. No Accessibility or Screen Recording is needed."
                    )
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Picker("Preview", selection: $previewMode) {
                        ForEach(MenuBarShelfPreviewMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 290)
                    MenuBarShelfPreview(decorations: shelf.settings.decorations, mode: previewMode)
                    Text("Illustration only. The highlighted marker in Arrange mode is TopDrop's real divider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 12) {
                    Text("How it works").font(.title3.bold())
                    Text(
                        "Hold Command and drag native tools you want on demand—such as Sip—to the left of TopDrop's divider. Keep always-visible items to its right. macOS remembers each genuine item independently."
                    )
                    .foregroundStyle(.secondary)
                    shelfDiagram
                    HStack {
                        Button("Arrange Native Shelf") { shelf.beginArranging() }
                            .buttonStyle(MonochromeProminentButtonStyle())
                        Button("Preview TopDrop", action: previewTopDrop)
                        Button(shelf.state == .hidden ? "Show Shelf" : "Hide Shelf") {
                            shelf.toggleShelfVisibility()
                        }
                        Spacer()
                        Button("Set Up Again") { shelf.beginFreshArrangement() }
                    }
                }
                .settingsCard()

                decorationsSection

                VStack(alignment: .leading, spacing: 12) {
                    Text("Behavior").font(.headline)
                    HStack {
                        Text("Auto-hide native shelf")
                        Spacer()
                        Picker("Auto-hide native shelf", selection: autoCollapseBinding) {
                            Text("Never").tag(0.0)
                            Text("After 2 seconds").tag(2.0)
                            Text("After 5 seconds").tag(5.0)
                            Text("After 10 seconds").tag(10.0)
                        }
                        .labelsHidden().frame(width: 170)
                    }
                    Divider()
                    Toggle(
                        "Replace the foreground application's menus while the tray is open",
                        isOn: Binding(
                            get: { shelf.settings.reclaimApplicationMenus },
                            set: { shelf.setReclaimApplicationMenus($0) }
                        )
                    )
                    Text(
                        "This creates more menu-bar room while TopDrop is open, then restores the previous application."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                }
                .settingsCard()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Remove unwanted clutter").font(.headline)
                    Text(
                        "Disable unwanted items individually in macOS 26 Menu Bar Settings. TopDrop does not take control of another application's status item."
                    )
                    .font(.callout).foregroundStyle(.secondary)
                    Button("Open macOS Menu Bar Settings") { MenuBarSystemSettings.open() }
                }
                .settingsCard()
            }
            .padding(.bottom, 8)
        }
        .tint(.primary)
    }

    private var shelfDiagram: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading) {
                Text("ON DEMAND").font(.caption2.bold()).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "eyedropper"); Image(systemName: "scope"); Image(systemName: "camera.viewfinder")
                }
            }
            Spacer()
            HStack(spacing: 3) {
                Image(systemName: "arrow.left")
                Rectangle().frame(width: 2, height: 24)
                Image(systemName: "arrow.right")
            }
            VStack {
                Text("TOPDROP").font(.caption2.bold()); Text("DIVIDER").font(.caption2.bold())
            }
            .foregroundStyle(.secondary)
            Spacer()
            VStack(alignment: .trailing) {
                Text("ALWAYS VISIBLE").font(.caption2.bold()).foregroundStyle(.secondary)
                HStack {
                    Image(systemName: "wifi"); Image(systemName: "battery.75percent"); Image(systemName: "tray.full")
                }
            }
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
        .overlay { RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(0.2), lineWidth: 1) }
    }

    private var decorationsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Native Labels & Spacers").font(.headline)
                    Text("Optional TopDrop-owned items; Command-drag each independently.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Add Label") { _ = shelf.addLabel() }
                Button("Add Spacer") { _ = shelf.addSpacer() }
            }
            if shelf.settings.decorations.isEmpty {
                Text("No labels or spacers.").foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                ForEach(shelf.settings.decorations) { decoration in
                    MenuBarShelfDecorationRow(decoration: decoration, shelf: shelf)
                    if decoration.id != shelf.settings.decorations.last?.id { Divider() }
                }
            }
        }
        .settingsCard()
    }

    private var autoCollapseBinding: Binding<Double> {
        Binding(
            get: { shelf.settings.autoCollapseDelay ?? 0 },
            set: { shelf.setAutoCollapseDelay($0 == 0 ? nil : $0) }
        )
    }
}

struct MenuBarShelfSetupGuideView: View {
    @ObservedObject var shelf: MenuBarShelfController
    let done: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            MenuBarGuidePointer()
                .fill(Color.primary.opacity(0.85))
                .frame(width: 16, height: 8)
                .offset(x: shelf.setupGuidePointerOffset)
            VStack(alignment: .leading, spacing: 12) {
                Text("Arrange Your Native Scroll Shelf").font(.headline.bold())
                Text("The highlighted divider directly above this pointer is the real boundary.")
                    .font(.caption).foregroundStyle(.secondary)
                instruction(1, "Hold Command and drag on-demand native items left of the divider.")
                instruction(2, "Keep items you always need visible on its right.")
                instruction(3, "Scroll down at the top edge to reveal the shelf and TopDrop tray.")
                HStack {
                    Button("Add Label") { _ = shelf.addLabel() }
                    Button("Add Spacer") { _ = shelf.addSpacer() }
                    Spacer()
                    Button("Done", action: done).buttonStyle(MonochromeProminentButtonStyle())
                }
            }
            .padding(14)
            .background { TopDropNeutralGlass() }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.28), lineWidth: 1) }
        }
        .frame(maxWidth: .infinity, minHeight: 250, maxHeight: 250, alignment: .top)
        .tint(.primary)
    }

    private func instruction(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text("\(number)").font(.caption.bold()).frame(width: 20, height: 20)
                .background(Color.primary.opacity(0.08), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.35), lineWidth: 1) }
            Text(text).font(.callout)
        }
    }
}

private struct MenuBarShelfDecorationRow: View {
    let decoration: MenuBarShelfDecoration
    @ObservedObject var shelf: MenuBarShelfController
    @State private var labelDraft: String

    init(decoration: MenuBarShelfDecoration, shelf: MenuBarShelfController) {
        self.decoration = decoration
        self.shelf = shelf
        _labelDraft = State(
            initialValue: {
                if case .label(let text) = decoration.content { return text }
                return ""
            }())
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: decorationSymbol).frame(width: 22).foregroundStyle(.secondary)
            switch decoration.content {
            case .label:
                TextField("Label", text: $labelDraft)
                    .onSubmit { shelf.renameLabel(id: decoration.id, text: labelDraft) }
            case .spacer(let width):
                Text("Blank space")
                Slider(
                    value: Binding(
                        get: { width },
                        set: { shelf.resizeSpacer(id: decoration.id, width: $0) }
                    ), in: 8...80, step: 4)
                Text("\(Int(width)) pt").font(.caption.monospacedDigit()).frame(width: 42)
            }
            Button(role: .destructive) {
                shelf.removeDecoration(id: decoration.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private var decorationSymbol: String {
        switch decoration.content {
        case .label: "textformat";
        case .spacer: "arrow.left.and.right"
        }
    }
}

private enum MenuBarShelfPreviewMode: String, CaseIterable, Identifiable {
    case hidden, visible, arrange
    var id: String { rawValue }
    var title: String {
        switch self {
        case .hidden: "Hidden";
        case .visible: "Visible";
        case .arrange: "Arrange"
        }
    }
}

private struct MenuBarShelfPreview: View {
    let decorations: [MenuBarShelfDecoration]
    let mode: MenuBarShelfPreviewMode

    var body: some View {
        HStack(spacing: 8) {
            if mode == .hidden {
                Label("Native shelf off-screen", systemImage: "arrow.left.to.line")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Image(systemName: "eyedropper")
                Image(systemName: "scope")
                ForEach(decorations) { decoration in
                    switch decoration.content {
                    case .label(let text): Text(text).font(.caption)
                    case .spacer(let width): Color.clear.frame(width: min(width, 40))
                    }
                }
            }
            Spacer()
            HStack(spacing: 2) {
                if mode == .arrange { Image(systemName: "arrow.left") }
                Rectangle().frame(width: mode == .arrange ? 2 : 1, height: 18)
                if mode == .arrange { Image(systemName: "arrow.right") }
            }
            Image(systemName: "wifi")
            Image(systemName: "battery.75percent")
            Divider().frame(height: 15)
            Image(systemName: "tray.full")
            Text("TopDrop").font(.caption.bold())
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background { TopDropNeutralGlass() }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.18), lineWidth: 1) }
    }
}

private struct MenuBarGuidePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path(); path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY)); path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath(); return path
    }
}

private extension View {
    func settingsCard() -> some View {
        padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.16), lineWidth: 1) }
    }
}
