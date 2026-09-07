import AppKit
import Foundation
import TopDropCore

@main enum TopDropNotesWorker {
    @MainActor static func mainThreadCheck() -> Bool { Thread.isMainThread }
    @MainActor static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let parentPID = getppid()
        guard parentPID > 1 else { exit(0) }
        let parentWatch = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit, queue: .global())
        parentWatch.setEventHandler { exit(0) }
        parentWatch.resume()
        let data = FileHandle.standardInput.readDataToEndOfFile()
        guard getppid() == parentPID else { exit(0) }
        Task { @MainActor in
            var response = NotesWorkerResponse()
            do {
                let request = try JSONDecoder().decode(NotesWorkerRequest.self, from: data)
                if request.operation == .diagnostics {
                    response.mainThread = mainThreadCheck()
                    if let directory = request.scriptDirectory {
                        for url in try FileManager.default.contentsOfDirectory(
                            at: directory, includingPropertiesForKeys: nil) where url.pathExtension == "applescript"
                        {
                            let source = try String(contentsOf: url, encoding: .utf8)
                            guard let script = NSAppleScript(source: source) else {
                                throw NotesProviderError.scriptCompilation(url.lastPathComponent)
                            }
                            var error: NSDictionary?
                            guard script.compileAndReturnError(&error) else {
                                throw NotesProviderError.scriptCompilation(url.lastPathComponent)
                            }
                        }
                    }
                } else {
                    let parent = Bundle.main.executableURL!.deletingLastPathComponent().deletingLastPathComponent()
                    let resources = parent.appendingPathComponent("Resources/TopDrop_TopDropApp.bundle")
                    let devResources = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent(
                        "TopDrop_TopDropApp.bundle")
                    let scripts =
                        request.scriptDirectory
                        ?? (FileManager.default.fileExists(atPath: resources.path) ? resources : devResources)
                    let service = NotesScriptService(scriptDirectory: scripts)
                    let permission = await service.automationPermission(
                        promptIfNeeded: request.operation == .permission && request.prompt)
                    if request.operation == .permission {
                        response.permission = permission
                    } else {
                        guard permission == .allowed else {
                            switch permission {
                            case .denied: throw NotesProviderError.automationDenied
                            case .promptRequired: throw NotesProviderError.automationPromptRequired
                            default: throw NotesProviderError.notesUnavailable
                            }
                        }
                        func note() throws -> NotesNote {
                            guard let note = request.note else { throw NotesProviderError.incompleteRead }; return note
                        }
                        func draft() throws -> NotesDraft {
                            guard let draft = request.draft else { throw NotesProviderError.incompleteRead };
                            return draft
                        }
                        switch request.operation {
                        case .permission, .diagnostics: break
                        case .accounts: response.accounts = try await service.listAccounts()
                        case .folders: response.folders = try await service.listFolders(accountID: request.accountID)
                        case .prepare:
                            response.folder = try await service.prepareTopDropFolder(
                                accountID: request.accountID, folderName: request.folderName)
                        case .fetch:
                            response.fetch = try await service.fetch(
                                accountID: request.accountID, folderID: request.folderID)
                        case .read: response.note = try await service.read(note())
                        case .create:
                            response.note = try await service.create(
                                draft(), accountID: request.accountID, folderID: request.folderID)
                        case .save: response.saved = try await service.save(draft(), replacing: note())
                        case .delete: response.deleted = try await service.delete(note())
                        case .open: try await service.openInAppleNotes(note())
                        }
                    }
                }
            } catch { response.error = error as? NotesProviderError ?? .incompleteRead }
            if let output = try? JSONEncoder().encode(response) {
                try? FileHandle.standardOutput.write(contentsOf: output)
            }
            exit(0)
        }
        application.run()
        withExtendedLifetime(parentWatch) {}
    }
}
