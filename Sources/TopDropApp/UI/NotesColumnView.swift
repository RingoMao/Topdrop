import SwiftUI
import TopDropCore

struct NotesColumnView: View {
    @ObservedObject var model: NotesViewModel
    let showSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            if model.permission != .allowed && model.notes.isEmpty {
                collectionHeader
                permissionView
            } else if let note = model.selectedNote {
                editor(note)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            } else {
                collection
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(2)
            }
            if model.permission != .allowed && !model.notes.isEmpty {
                Button("Recheck Notes Permission — recovery drafts are retained") {
                    Task { await model.requestAutomationAndLoadAccounts() }
                }
                .font(.caption)
            }
        }
        .padding(12)
        .animation(.easeInOut(duration: 0.16), value: model.selectedNoteID)
    }

    private var collection: some View {
        VStack(spacing: 10) {
            collectionHeader
            if model.notes.isEmpty {
                emptyView
            } else {
                noteList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var collectionHeader: some View {
        VStack(spacing: 8) {
            HStack {
                Label("Notes", systemImage: "note.text")
                    .font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.reloadConfiguredFolder() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh from Apple Notes")
                Button {
                    Task { await model.createNote() }
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .help("New Apple Note")
            }
            TextField("Search notes", text: $model.searchText)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var permissionView: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text("Allow Apple Notes Automation")
                .font(.headline)
            Text("TopDrop only automates the dedicated folder you choose. Apple Notes remains the source of truth.")
                .font(.caption)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Request Permission") {
                Task { await model.requestAutomationAndLoadAccounts() }
            }
            .buttonStyle(.borderedProminent)
            Button("Open Settings", action: showSettings)
                .buttonStyle(.link)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    private var emptyView: some View {
        ContentUnavailableView {
            Label("No Notes", systemImage: "note")
        } description: {
            Text("Create a temporary note here, or configure the dedicated Apple Notes folder.")
        } actions: {
            HStack {
                Button("New Note") { Task { await model.createNote() } }
                Button("Settings", action: showSettings)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noteList: some View {
        ScrollView {
            LazyVStack(spacing: 3) {
                ForEach(model.filteredNotes) { note in
                    Button {
                        model.select(note)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(note.title.isEmpty ? "Untitled" : note.title)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                Spacer(minLength: 4)
                                if note.isReadOnly {
                                    Image(systemName: "lock.fill")
                                        .foregroundStyle(.secondary)
                                        .help(note.readOnlyReasons.map(\.rawValue).joined(separator: ", "))
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            Text(note.body.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button("Open in Apple Notes") {
                            model.select(note)
                            Task { await model.openSelectedInNotes() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func editor(_ note: NotesNote) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                Button {
                    model.showCollection()
                } label: {
                    Label("Notes", systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .help("Back to all notes")

                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button {
                    Task { await model.reloadConfiguredFolder() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh from Apple Notes")
                Button {
                    Task { await model.openSelectedInNotes() }
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                }
                .buttonStyle(.borderless)
                .help("Open in Apple Notes")
                Button(role: .destructive) {
                    Task { await model.deleteSelectedNote() }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(model.isSelectedReadOnly)
                .help(note.isReadOnly ? "Protected notes cannot be deleted in TopDrop" : "Delete note")
            }

            Divider()

            TextField(
                "Title",
                text: Binding(
                    get: { model.draftTitle },
                    set: { model.setDraftTitle($0) }
                )
            )
            .font(.title3.weight(.semibold))
            .textFieldStyle(.plain)
            .disabled(model.isSelectedReadOnly)

            TextEditor(
                text: Binding(
                    get: { model.draftBody },
                    set: { model.setDraftBody($0) }
                )
            )
            .font(.body)
            .scrollContentBackground(.hidden)
            .disabled(model.isSelectedReadOnly)
            .padding(6)
            .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.quaternary, lineWidth: 1)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                if note.isReadOnly {
                    Label("Read-only in Apple Notes", systemImage: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(model.saveStatus)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if model.hasRecoveryDraft {
                    Button("Retry / Check") { Task { await model.sync.retrySelected() } }
                        .help("Recheck an uncertain write without sending it again")
                    Menu("Recover") {
                        Button("Retry Secure Draft Recovery") { Task { await model.sync.retryRecoveryAccess() } }
                        Button("Save Draft as New Note…") {
                            let alert = NSAlert()
                            alert.messageText = "Create a separate note from this draft?"
                            alert.informativeText =
                                "If an earlier creation timed out, it may already exist in Apple Notes. Check Notes first to avoid duplicates. The original recovery draft is retained."
                            alert.addButton(withTitle: "Create New Note")
                            alert.addButton(withTitle: "Cancel")
                            if alert.runModal() == .alertFirstButtonReturn { model.sync.saveSelectedAsNew() }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
