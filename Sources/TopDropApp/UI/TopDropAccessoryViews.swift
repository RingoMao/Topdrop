import SwiftUI
import TopDropCore

/// Compact, TopDrop-owned actions shown inside the tray. These are separate
/// from the native Scroll Shelf, so they remain reliable and customizable.
struct TopDropAccessoryShelfView: View {
    @ObservedObject var manager: TopDropAccessoryManager
    var compact = false

    /// Actions with direct Notes/Clipboard header controls are intentionally
    /// omitted from the shared footer to avoid duplicate controls.
    private var trayItems: [TopDropAccessory] {
        manager.items.filter { accessory in
            guard case .builtin(let builtin) = accessory.kind else { return true }
            switch builtin {
            case .newNote, .cleanClipboard, .toggleClipboardHistory, .openSettings:
                return false
            case .refreshNotes, .chooseScreenshotFolder, .importScreenshots:
                return true
            }
        }
    }

    @ViewBuilder
    var body: some View {
        if trayItems.isEmpty {
            EmptyView()
        } else if compact {
            Menu {
                ForEach(trayItems) { accessory in
                    Button {
                        manager.invoke(accessory)
                    } label: {
                        Label(accessory.kind.title, systemImage: accessory.kind.symbolName)
                    }
                }
            } label: {
                Image(systemName: "sparkles.rectangle.stack")
                    .frame(width: 20, height: 20)
            }
            .menuStyle(.borderlessButton)
            .help("TopDrop Accessories")
        } else {
            HStack(spacing: 2) {
                ForEach(Array(trayItems.prefix(7))) { accessory in
                    accessoryButton(accessory)
                        .draggable(accessory.id.uuidString)
                        .dropDestination(for: String.self) { values, _ in
                            guard let value = values.first,
                                let id = UUID(uuidString: value)
                            else { return false }
                            manager.move(id: id, onto: accessory.id)
                            return true
                        }
                }
                if trayItems.count > 7 {
                    Menu {
                        ForEach(trayItems.dropFirst(7)) { accessory in
                            Button {
                                manager.invoke(accessory)
                            } label: {
                                Label(accessory.kind.title, systemImage: accessory.kind.symbolName)
                            }
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .frame(width: 20, height: 20)
                    }
                    .menuStyle(.borderlessButton)
                    .help("More Accessories")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("TopDrop Accessories")
        }
    }

    private func accessoryButton(_ accessory: TopDropAccessory) -> some View {
        Button {
            manager.invoke(accessory)
        } label: {
            Image(systemName: accessory.kind.symbolName)
                .symbolVariant(manager.activeAccessoryID == accessory.id ? .fill : .none)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(accessory.kind.title)
        .accessibilityLabel(accessory.kind.title)
    }
}

struct TopDropAccessoryStoreView: View {
    @ObservedObject var manager: TopDropAccessoryManager
    @State private var shortcutName = ""
    @State private var shortcutInput = TopDropShortcutInput.none

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Accessories").font(.title2.bold())
                    Text(
                        "Build your own drag-reorderable action row inside TopDrop. Built-ins run directly; Apple Shortcuts open through Apple's documented Shortcuts URL scheme."
                    )
                    .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Installed").font(.headline)
                    if manager.items.isEmpty {
                        Text("No accessories installed.").foregroundStyle(.secondary).padding(.vertical, 12)
                    } else {
                        ForEach(manager.items) { accessory in
                            installedRow(accessory)
                                .draggable(accessory.id.uuidString)
                                .dropDestination(for: String.self) { values, _ in
                                    guard let value = values.first,
                                        let id = UUID(uuidString: value)
                                    else { return false }
                                    manager.move(id: id, onto: accessory.id)
                                    return true
                                }
                            if accessory.id != manager.items.last?.id { Divider() }
                        }
                    }
                    Text("Drag a row onto another row to reorder it. The tray updates immediately.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .accessoryCard()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Built-in Accessories").font(.headline)
                    if manager.availableBuiltins.isEmpty {
                        Text("All built-in accessories are installed.").foregroundStyle(.secondary)
                    } else {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 210), spacing: 8)], spacing: 8) {
                            ForEach(manager.availableBuiltins, id: \.self) { builtin in
                                Button {
                                    manager.addBuiltin(builtin)
                                } label: {
                                    HStack {
                                        Image(systemName: builtin.symbolName)
                                        Text(builtin.title)
                                        Spacer()
                                        Image(systemName: "plus")
                                    }
                                    .padding(.horizontal, 10).frame(height: 34)
                                    .overlay { RoundedRectangle(cornerRadius: 7).stroke(Color.primary.opacity(0.25)) }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .accessoryCard()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Apple Shortcut").font(.headline)
                            Text("Enter the shortcut name exactly as it appears in the Shortcuts app.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open Shortcuts") { manager.openShortcuts() }
                    }
                    HStack {
                        TextField("Shortcut name", text: $shortcutName)
                        Picker("Input", selection: $shortcutInput) {
                            Text("No input").tag(TopDropShortcutInput.none)
                            Text("Clipboard").tag(TopDropShortcutInput.clipboard)
                        }
                        .frame(width: 145)
                        Button("Add") {
                            if manager.addShortcut(name: shortcutName, input: shortcutInput) {
                                shortcutName = ""
                                shortcutInput = .none
                            }
                        }
                        .buttonStyle(MonochromeProminentButtonStyle())
                    }
                    Text(
                        "TopDrop does not enumerate your private Shortcuts library. Shortcut names are stored locally; running one may show any confirmation Apple Shortcuts itself requires."
                    )
                    .font(.caption).foregroundStyle(.secondary)
                    if let message = manager.lastErrorMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessoryCard()
            }
            .padding(.bottom, 8)
        }
        .tint(.primary)
    }

    private func installedRow(_ accessory: TopDropAccessory) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "line.3.horizontal")
                .foregroundStyle(.secondary)
                .help("Drag to reorder")
            Image(systemName: accessory.kind.symbolName).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(accessory.kind.title).fontWeight(.semibold)
                Text(accessoryDescription(accessory))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Run") { manager.invoke(accessory) }
            Button(role: .destructive) {
                manager.remove(id: accessory.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 5)
    }

    private func accessoryDescription(_ accessory: TopDropAccessory) -> String {
        switch accessory.kind {
        case .builtin: "TopDrop built-in"
        case .shortcut(_, let input): input == .clipboard ? "Apple Shortcut · clipboard input" : "Apple Shortcut"
        }
    }
}

private extension View {
    func accessoryCard() -> some View {
        padding(14)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
            .overlay { RoundedRectangle(cornerRadius: 11).stroke(Color.primary.opacity(0.16), lineWidth: 1) }
    }
}
