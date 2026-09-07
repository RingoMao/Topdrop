import SwiftUI
import TopDropCore

struct SettingsView: View {
    @ObservedObject var settings: AppSettingsModel
    @ObservedObject var notes: NotesViewModel
    @ObservedObject var clipboard: ClipboardMonitor
    @ObservedObject var launchAtLogin: LaunchAtLoginManager
    @ObservedObject var hotKey: ClipboardHotKeyRegistrar
    @ObservedObject var menuBarShelf: MenuBarShelfController
    @ObservedObject var accessories: TopDropAccessoryManager
    let screenshotCount: Int
    let chooseScreenshotFolder: () -> Void
    let importExistingScreenshots: () -> Void
    let clearClipboardHistory: () -> Void
    let previewTopDrop: () -> Void

    @State private var selectedAccountID = ""

    var body: some View {
        TabView {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
            notesTab
                .tabItem { Label("Notes", systemImage: "note.text") }
            clipboardTab
                .tabItem { Label("Clipboard", systemImage: "clipboard") }
            screenshotsTab
                .tabItem { Label("Screenshots", systemImage: "photo.on.rectangle") }
            TopDropAccessoryStoreView(manager: accessories)
                .tabItem { Label("Accessories", systemImage: "sparkles.rectangle.stack") }
            MenuBarShelfSettingsView(
                shelf: menuBarShelf,
                previewTopDrop: previewTopDrop
            )
            .tabItem { Label("Menu Bar", systemImage: "menubar.rectangle") }
        }
        .padding(20)
        .frame(minWidth: 820, minHeight: 560)
        .onAppear {
            selectedAccountID =
                settings.value.notesAccountIdentifier
                ?? notes.accounts.first?.id
                ?? ""
            launchAtLogin.refresh()
        }
    }

    private var generalTab: some View {
        Form {
            Section("Tray") {
                valueSlider(
                    "Panel height",
                    value: panelHeightBinding,
                    range: AppSettings.minimumPanelHeight...AppSettings.maximumPanelHeight,
                    suffix: "pt"
                )
                valueSlider("Top-edge activation zone", value: activationDistanceBinding, range: 1...12, suffix: "pt")
                valueSlider("Reveal threshold", value: revealThresholdBinding, range: 10...120, suffix: "pt")
                valueSlider("Hide threshold (top edge)", value: hideThresholdBinding, range: 10...240, suffix: "pt")
                Text(
                    "Scroll inside the tray to browse. To close, move to the screen's top edge and scroll up firmly. Clicking outside still closes the tray."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                valueSlider("Gesture cooldown", value: cooldownBinding, range: 0...2, suffix: "s")
            }
            Section("System") {
                Toggle(
                    "Launch TopDrop at login",
                    isOn: Binding(
                        get: { launchAtLogin.isEnabled },
                        set: { launchAtLogin.setEnabled($0) }
                    ))
                if let message = launchAtLogin.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var notesTab: some View {
        Form {
            Section("Automation") {
                LabeledContent("Permission", value: notes.permission.rawValue)
                Button("Request / Recheck Permission") {
                    Task { await notes.requestAutomationAndLoadAccounts() }
                }
                Button("Retry Secure Draft Recovery") { Task { await notes.sync.retryRecoveryAccess() } }
                if let message = notes.statusMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Dedicated Apple Notes Folder") {
                Picker("iCloud account", selection: $selectedAccountID) {
                    Text("Select…").tag("")
                    ForEach(notes.accounts) { account in
                        Text(account.name).tag(account.id)
                    }
                }
                TextField("Folder name", text: settings.binding(for: \.notesFolderName))
                Button("Create or Select Folder") {
                    Task {
                        await notes.prepareDedicatedFolder(
                            accountID: selectedAccountID,
                            folderName: settings.value.notesFolderName
                        )
                    }
                }
                .disabled(selectedAccountID.isEmpty || notes.permission != .allowed || notes.isBusy)
                Button("Find Previous TopDrop Folders") { Task { await notes.findRecoveryFolders() } }
                ForEach(notes.recoveryCandidates) { candidate in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(
                            "\(settings.value.notesAccountName ?? "Account") / \(candidate.folder.path ?? candidate.folder.name) — \(candidate.count.map(String.init) ?? "unavailable") notes"
                        )
                        Text(candidate.folder.id).font(.caption2).foregroundStyle(.secondary)
                        Button("Use This Folder") { Task { await notes.chooseRecoveryFolder(candidate.folder) } }
                    }
                }
                if let account = settings.value.notesAccountName,
                    let folder = settings.value.notesFolderIdentifier
                {
                    LabeledContent("Configured", value: "\(account) / \(settings.value.notesFolderName)")
                    Text("Folder ID: \(folder)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var clipboardTab: some View {
        Form {
            Section("History") {
                LabeledContent("Pasteboard access", value: clipboard.accessState.rawValue)
                if clipboard.accessState != .allowed {
                    Button("Request Access") { _ = clipboard.requestPasteboardAccess() }
                }
                Toggle(
                    "Pause clipboard history",
                    isOn: Binding(
                        get: { clipboard.isPaused },
                        set: { newValue in
                            clipboard.setPaused(newValue)
                            settings.update { $0.clipboardPaused = newValue }
                        }
                    ))
                Button(
                    "Clear Encrypted History",
                    role: .destructive,
                    action: clearClipboardHistory
                )
            }
            Section("Clean Formatting") {
                HStack {
                    Text("Global shortcut")
                    Spacer()
                    HotKeyRecorderView(settings: settings.binding(for: \.cleanClipboardHotKey))
                        .frame(width: 170)
                }
                Text(
                    "Click the shortcut field, then type a new shortcut. TopDrop only replaces textual representations with plain UTF-8; it never pastes automatically."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let error = hotKey.lastError {
                    Text(error.localizedDescription)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Section("Sensitive Applications") {
                Text(
                    "Enter bundle identifiers separated by commas or new lines. Clipboard changes from the frontmost matching app are discarded."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                TextEditor(text: excludedApplicationsBinding)
                    .font(.body.monospaced())
                    .frame(height: 90)
            }
        }
        .formStyle(.grouped)
    }

    private var screenshotsTab: some View {
        Form {
            Section("Screenshot-Only Folder") {
                LabeledContent(
                    "Folder",
                    value: settings.value.screenshotFolderDisplayPath ?? "Not selected"
                )
                Button("Choose Folder", action: chooseScreenshotFolder)
                Text(
                    "Set macOS Screenshot Options to save into this same folder. TopDrop watches files made by normal macOS shortcuts and never captures the screen itself."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Library") {
                LabeledContent("Images currently shown", value: "\(screenshotCount)")
                Button("Import Existing Screenshots", action: importExistingScreenshots)
                Text(
                    "By default TopDrop starts at the current folder state and imports only new files. Existing import is always explicit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Section("Clipboard Image Cache") {
                Text(
                    "Copied images are cached automatically for this session. The newest 10 unedited images are retained; edited projects and their version aliases are outside that limit."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var panelHeightBinding: Binding<Double> { settings.binding(for: \.panelHeight) }
    private var activationDistanceBinding: Binding<Double> {
        Binding(
            get: { settings.value.gesture.activationDistance },
            set: { value in settings.update { $0.gesture.activationDistance = value } })
    }
    private var revealThresholdBinding: Binding<Double> {
        Binding(
            get: { settings.value.gesture.revealThreshold },
            set: { value in settings.update { $0.gesture.revealThreshold = value } })
    }
    private var hideThresholdBinding: Binding<Double> {
        Binding(
            get: { settings.value.gesture.hideThreshold },
            set: { value in settings.update { $0.gesture.hideThreshold = value } })
    }
    private var cooldownBinding: Binding<Double> {
        Binding(
            get: { settings.value.gesture.cooldown }, set: { value in settings.update { $0.gesture.cooldown = value } })
    }
    private var excludedApplicationsBinding: Binding<String> {
        Binding(
            get: { settings.value.excludedClipboardBundleIdentifiers.sorted().joined(separator: "\n") },
            set: { text in
                let separators = CharacterSet(charactersIn: ",\n")
                let identifiers = Set(
                    text.components(separatedBy: separators)
                        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty })
                settings.update { $0.excludedClipboardBundleIdentifiers = identifiers }
            }
        )
    }

    private func valueSlider(
        _ label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String
    ) -> some View {
        HStack {
            Text(label)
            Slider(value: value, in: range)
            Text("\(value.wrappedValue, specifier: "%.1f") \(suffix)")
                .font(.caption.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
        }
    }
}
