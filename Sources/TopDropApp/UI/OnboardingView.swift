import SwiftUI
import TopDropCore

struct OnboardingView: View {
    @ObservedObject var settings: AppSettingsModel
    @ObservedObject var notes: NotesViewModel
    @ObservedObject var clipboard: ClipboardMonitor
    let chooseScreenshotFolder: () -> Void
    let finish: () -> Void

    @State private var selectedAccountID = ""
    @State private var folderName = AppleNotesProvider.defaultFolderName
    @State private var notesSetupError: String?
    @State private var isFinishing = false

    private var readiness: OnboardingSetupReadiness {
        OnboardingSetupReadiness(
            notesPermission: notes.permission,
            selectedAccountIdentifier: selectedAccountID,
            notesFolderName: folderName,
            hasScreenshotFolder: settings.value.screenshotFolderBookmark != nil
        )
    }

    private var notesFolderMatchesSelection: Bool {
        settings.value.notesAccountIdentifier == selectedAccountID
            && settings.value.notesFolderIdentifier != nil
            && settings.value.notesFolderName == folderName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Welcome to TopDrop")
                    .font(.largeTitle.bold())
                Text(
                    "Set up the three private data sources. TopDrop keeps Apple Notes as the source of truth. Its native Scroll Shelf uses one simple divider and needs no screen or Accessibility permission."
                )
                .foregroundStyle(.secondary)
            }

            setupCard(number: 1, title: "Apple Notes") {
                HStack {
                    Text("Automation: \(notes.permission.rawValue)")
                    Spacer()
                    Button("Allow / Recheck") {
                        Task {
                            await notes.requestAutomationAndLoadAccounts()
                            if selectedAccountID.isEmpty { selectedAccountID = notes.accounts.first?.id ?? "" }
                        }
                    }
                }
                Picker("iCloud account", selection: $selectedAccountID) {
                    Text("Select…").tag("")
                    ForEach(notes.accounts) { Text($0.name).tag($0.id) }
                }
                HStack {
                    TextField("Dedicated folder", text: $folderName)
                    Button("Set Up Now") {
                        Task {
                            _ = await provisionNotesFolder()
                        }
                    }
                    .disabled(
                        selectedAccountID.isEmpty
                            || folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || notes.permission != .allowed
                            || notes.isBusy
                            || isFinishing
                    )
                    .help("Optional: Finish Setup also creates or selects this folder automatically.")
                }
                if notesFolderMatchesSelection {
                    Label("TopDrop folder ready", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Text("Finish Setup will create or reuse this folder automatically. “Set Up Now” is optional.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let notesSetupError {
                    Text(notesSetupError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            setupCard(number: 2, title: "Screenshot Folder") {
                HStack {
                    Text(settings.value.screenshotFolderDisplayPath ?? "No folder selected")
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseScreenshotFolder)
                }
                Text(
                    "Use a screenshot-only folder, then choose the same location in macOS Screenshot Options (Shift-Command-5)."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                if let message = settings.lastErrorMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            setupCard(number: 3, title: "Clipboard") {
                HStack {
                    Text(clipboard.accessState.userMessage)
                        .font(.caption)
                    Spacer()
                    if clipboard.accessState != .allowed {
                        Button("Request Access") { _ = clipboard.requestPasteboardAccess() }
                    }
                }
                Text("Clean Formatting shortcut: ⌃⌥⌘V. It changes the clipboard only and never pastes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Copied images also enter the session-only 10-image cache in Screenshots & Images.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(footerMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await finishSetup() }
                } label: {
                    if isFinishing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Finishing…")
                        }
                    } else {
                        Text("Finish Setup")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    !readiness.canFinalize
                        || notes.isBusy
                        || isFinishing
                )
            }
        }
        .padding(24)
        .frame(minWidth: 680, minHeight: 650)
        .task {
            await notes.start()
            selectedAccountID =
                settings.value.notesAccountIdentifier
                ?? notes.accounts.first?.id
                ?? ""
            folderName = settings.value.notesFolderName
        }
        .onChange(of: selectedAccountID) {
            notesSetupError = nil
        }
        .onChange(of: folderName) {
            notesSetupError = nil
        }
    }

    private var footerMessage: String {
        switch readiness.missingRequirements.first {
        case .notesAutomation:
            "Allow Apple Notes automation to continue."
        case .notesAccount:
            "Select the iCloud Notes account to continue."
        case .notesFolderName:
            "Enter a name for the dedicated Notes folder."
        case .screenshotFolder:
            "Choose the screenshot-only folder to continue."
        case nil:
            "Ready. Finish Setup will verify the Notes folder automatically."
        }
    }

    @MainActor
    private func provisionNotesFolder() async -> Bool {
        notesSetupError = nil
        let succeeded = await notes.prepareDedicatedFolder(
            accountID: selectedAccountID,
            folderName: folderName
        )
        if !succeeded {
            notesSetupError =
                notes.statusMessage
                ?? "TopDrop could not create or select the Apple Notes folder."
        }
        return succeeded
    }

    @MainActor
    private func finishSetup() async {
        guard readiness.canFinalize, !isFinishing else { return }
        isFinishing = true
        defer { isFinishing = false }

        guard await provisionNotesFolder() else { return }
        settings.update { $0.completedOnboarding = true }
        finish()
    }

    private func setupCard<Content: View>(
        number: Int,
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label {
                Text(title).font(.headline)
            } icon: {
                Text("\(number)")
                    .font(.caption.bold())
                    .frame(width: 22, height: 22)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            content()
        }
        .padding(14)
        .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}
