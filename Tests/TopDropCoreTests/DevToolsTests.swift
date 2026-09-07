import AppKit
import CoreGraphics
import CryptoKit
import Foundation
import TopDropCore

let devToolsTests: [UnitTest] = [
    UnitTest("Dev Tools: layouts preserve workspace minimums and use narrow popover") {
        for width in [300.0, 700, 819, 820, 900, 980, 1200, 1312, 1512] {
            for expanded in [true, false] {
                let layout = DevToolsLayout(innerWidth: width, expanded: expanded)
                try expectEqual(layout.usesPopover, width < 820)
                try expectEqual(layout.sidebarWidth, expanded && width >= 820 ? 240 : 0)
                try expect(layout.workspaceWidth >= 0)
                try expectEqual(layout.compactWorkspace, layout.workspaceWidth < 980)
                if width < 820 { try expectEqual(layout.workspaceWidth, width) }
            }
        }
        try expect(!DevToolsLayout(innerWidth: 1312, expanded: true).compactWorkspace)
        try expect(DevToolsLayout(innerWidth: 1200, expanded: true).compactWorkspace)
    },
    UnitTest("Dev Tools: Keep Awake idempotence failures stop and fresh launch") {
        try await testDevAwake()
    },
    UnitTest("Dev Tools: Hidden Files parses missing and invalid preferences") {
        try expectEqual(FinderHiddenFilesState.preference(nil), .unknown)
        try expectEqual(FinderHiddenFilesState.preference("bad"), .unknown)
        try expectEqual(FinderHiddenFilesState.preference(2), .unknown)
        try expectEqual(FinderHiddenFilesState.preference(false), .hidden)
        try expectEqual(FinderHiddenFilesState.preference("YES"), .shown)
    },
    UnitTest("Dev Tools: period follows current keyboard layout including shifted-only mapping") {
        try await MainActor.run {
            try expectEqual(NativeFinderHiddenFilesProvider.periodKeyCode(unshifted: [47: "."], shifted: [47: ">"]), 47)
            try expectEqual(NativeFinderHiddenFilesProvider.periodKeyCode(unshifted: [41: "."], shifted: [:]), 41)
            try expectEqual(NativeFinderHiddenFilesProvider.periodKeyCode(unshifted: [41: ";"], shifted: [41: "."]), 41)
            try expectEqual(
                NativeFinderHiddenFilesProvider.periodKeyCode(unshifted: [65: ".", 41: ";"], shifted: [41: "."]), 41)
            try expectEqual(NativeFinderHiddenFilesProvider.periodKeyCode(unshifted: [:], shifted: [:]), nil)
        }
    },
    UnitTest("Dev Tools: permission denial never closes tray or sends shortcut") {
        try await testDevHiddenPermission()
    },
    UnitTest("Dev Tools: Finder activation failure never sends shortcut") {
        try await testDevHiddenAction(active: false, changes: false)
    },
    UnitTest("Dev Tools: Hidden Files sends once and confirms observed change") {
        try await testDevHiddenAction(active: true, changes: true)
    },
    UnitTest("Dev Tools: unchanged preference is unconfirmed not optimistic") {
        try await testDevHiddenAction(active: true, changes: false)
    },
    UnitTest("Dev Tools: stop cancels pending Finder action") {
        try await testDevHiddenCancel()
    },
    UnitTest("Dev Tools: all blank templates valid PDF RTF JSON Plist and nonexecutable scripts") {
        try await testDevTemplates()
    },
    UnitTest("Dev Tools: conservative cleanup protects references and unknown files") {
        try await testDevTemplateCleanup()
    },
    UnitTest("Dev Tools: file writes exactly once and restores missing source without duplicate") {
        try await testDevFileClipboard()
    },
    UnitTest("Dev Tools: template generation and pasteboard failures preserve current history") {
        try await testDevFileFailure()
    },
    UnitTest("Dev Tools: generated metadata encrypted archive migration and activation") {
        try await testDevFileMetadata()
    },
    UnitTest("Dev Tools: real named pasteboard round-trips file NSURL for Finder") {
        try await testDevNativeFilePasteboard()
    },
]

@MainActor private final class FakeAwake: DisplayAwakeProviding {
    var acquires = 0
    var releases: [UInt32] = []
    var fails = false
    func acquire() throws -> UInt32 {
        if fails { throw DevToolsError.operationFailed }
        acquires += 1
        return 7
    }
    func release(_ id: UInt32) throws {
        if fails { throw DevToolsError.operationFailed }
        releases.append(id)
    }
}

@MainActor private func testDevAwake() throws {
    let fake = FakeAwake()
    let model = KeepAwakeController(provider: fake)
    try expect(!model.isEnabled)
    fake.fails = true
    model.setEnabled(true)
    try expect(!model.isEnabled)
    fake.fails = false
    model.setEnabled(true); model.setEnabled(true)
    try expectEqual(fake.acquires, 1)
    fake.fails = true
    model.setEnabled(false)
    try expect(model.isEnabled)
    fake.fails = false
    model.stop(); model.stop()
    try expectEqual(fake.releases, [7])
    try expect(!KeepAwakeController(provider: fake).isEnabled)
}

@MainActor private final class FakeFinder: FinderHiddenFilesProviding {
    var state: FinderHiddenFilesState = .hidden
    var allowed = true
    var active = true
    var changes = true
    var requests = 0
    var sends = 0
    func readState() -> FinderHiddenFilesState { state }
    func hasPermission() -> Bool { allowed }
    func requestPermission() { requests += 1 }
    func activateFinder() async -> Bool { active }
    func sendShortcut() throws {
        guard active else { throw DevToolsError.finderNotActive }
        sends += 1
        if changes { state = .shown }
    }
}

@MainActor private func testDevHiddenPermission() throws {
    let fake = FakeFinder(); fake.allowed = false
    let model = HiddenFilesController(provider: fake)
    var closed = false
    model.perform { closed = true }
    try expect(!closed)
    try expectEqual(fake.sends, 0)
    try expectEqual(fake.requests, 1)
}

@MainActor private func testDevHiddenAction(active: Bool, changes: Bool) async throws {
    let fake = FakeFinder(); fake.active = active; fake.changes = changes
    let model = HiddenFilesController(provider: fake)
    var closes = 0
    model.perform { closes += 1 }
    model.perform { closes += 1 }
    for _ in 0..<50 {
        if !model.isBusy { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try expectEqual(closes, 1)
    try expectEqual(fake.sends, active ? 1 : 0)
    try expect(!model.isBusy)
    if active && !changes {
        try expectEqual(model.state, .hidden)
        try expect(model.message?.contains("State Not Confirmed") == true)
    }
    if active && changes { try expectEqual(model.state, .shown) }
}

@MainActor private func testDevHiddenCancel() async throws {
    let fake = FakeFinder()
    let model = HiddenFilesController(provider: fake)
    model.perform {}
    model.stop()
    try await Task.sleep(for: .milliseconds(300))
    try expectEqual(fake.sends, 0)
    try expect(!model.isBusy)
}

@MainActor private func testDevTemplates() throws {
    let root = try makeTemporaryTestDirectory(prefix: "dev-templates")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BlankFileTemplateStore(directory: root)
    for template in BlankFileTemplate.allCases {
        let url = try store.create(template)
        let data = try Data(contentsOf: url)
        try expectEqual(url.lastPathComponent, "Untitled.\(template.fileExtension)")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! NSNumber
        try expectEqual(permissions.intValue & 0o111, 0)
        switch template {
        case .pdf:
            let pdf = CGPDFDocument(CGDataProvider(data: data as CFData)!)
            try expectEqual(pdf?.numberOfPages, 1)
            try expect(abs((pdf?.page(at: 1)?.getBoxRect(.mediaBox).width ?? 0) - 595.2756) < 1)
        case .rtf:
            let text = try NSAttributedString(
                data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
            try expectEqual(text.string, "")
        case .json:
            let value = try JSONSerialization.jsonObject(with: data) as? [String: String]
            try expectEqual(value, [:])
        case .plist:
            let value = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
            try expectEqual(value, [:])
        case .html: try expect(String(decoding: data, as: UTF8.self).contains("<!doctype html>"))
        default: try expect(data.isEmpty)
        }
    }
    let a = try store.create(.txt), b = try store.create(.txt)
    try expect(a != b, "Repeated copy must not overwrite a file Finder may be using")
}

@MainActor private func testDevTemplateCleanup() throws {
    let root = try makeTemporaryTestDirectory(prefix: "dev-cleanup")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = BlankFileTemplateStore(directory: root)
    let retained = try store.create(.txt), orphan = try store.create(.pdf)
    let unknown = root.appendingPathComponent("Not-TopDrop.txt")
    try Data().write(to: unknown)
    try store.removeUnreferencedFiles(references: [], censusIsComplete: false)
    try expect(FileManager.default.fileExists(atPath: retained.path))
    try store.removeUnreferencedFiles(references: [retained], censusIsComplete: true)
    try expect(FileManager.default.fileExists(atPath: retained.path))
    try expect(!FileManager.default.fileExists(atPath: orphan.path))
    try expect(FileManager.default.fileExists(atPath: unknown.path))
}

@MainActor private final class DevPasteboard: ClipboardPasteboardClient {
    var changeCount = 0
    var accessState: ClipboardAccessState = .allowed
    var payloads: [ClipboardPayload] = []
    var fails = false
    func requestAccess() -> ClipboardAccessState { accessState }
    func readSupportedContents() throws -> ClipboardRawContents { .init(items: [], containsTopDropMarker: true) }
    func write(_ payload: ClipboardPayload) throws -> Int {
        if fails { throw ClipboardSubsystemError.pasteboardWriteFailed }
        payloads.append(payload); changeCount += 1; return changeCount
    }
    func cleanFormatting() throws -> ClipboardCleanFormattingOutcome { throw DevToolsError.operationFailed }
}
@MainActor private final class DevSource: ClipboardSourceApplicationProviding {
    func currentSourceApplication() -> ClipboardSourceApplication? { nil }
}
@MainActor private struct FailingBlankStore: BlankFileTemplateProviding {
    func create(_ template: BlankFileTemplate) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
}

@MainActor private func testDevFileClipboard() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "dev-clipboard")
    defer { try? FileManager.default.removeItem(at: root) }
    let pb = DevPasteboard()
    let history = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pb, sourceApplications: DevSource(), historyStore: history,
        blankFiles: BlankFileTemplateStore(directory: root))
    monitor.beginArrivalWatch()
    for template in BlankFileTemplate.allCases {
        let count = pb.payloads.count
        try await monitor.setCurrentFile(template: template)
        try expectEqual(pb.payloads.count, count + 1)
        try expectEqual(monitor.items.first?.generatedTemplate, template)
        try expectEqual(pb.payloads.last?.items.first?.representations.first?.kind, .fileURL)
    }
    let item = monitor.items.last!
    let source = URL(string: String(decoding: item.payload.items[0].representations[0].data, as: UTF8.self))!
    try FileManager.default.removeItem(at: source)
    let count = monitor.items.count
    try await monitor.makeCurrent(itemID: item.id)
    try expectEqual(monitor.items.count, count)
    try expectEqual(monitor.items.first?.id, item.id)
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: item.id))
    try expect(monitor.items[0].payload != item.payload)
    let restored = URL(
        string: String(decoding: monitor.items[0].payload.items[0].representations[0].data, as: UTF8.self))!
    try expect(FileManager.default.fileExists(atPath: restored.path))
    if case .watching = monitor.snapshot.arrivalWatch {
    } else {
        throw TestFailure(description: "File counted as Handoff")
    }
    monitor.stop()
}

@MainActor private func testDevFileFailure() async throws {
    let pb = DevPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pb, sourceApplications: DevSource(), historyStore: MemoryClipboardHistoryStore(),
        blankFiles: FailingBlankStore())
    try await monitor.setCurrentPlainText("preserve")
    let before = monitor.items
    do {
        try await monitor.setCurrentFile(template: .pdf); throw TestFailure(description: "Expected failure")
    } catch is CocoaError {}
    try expectEqual(pb.payloads.count, 1)
    try expectEqual(monitor.items, before)

    let root = try makeTemporaryTestDirectory(prefix: "dev-failed-write")
    defer { try? FileManager.default.removeItem(at: root) }
    let writer = ClipboardMonitor(
        pasteboard: pb, sourceApplications: DevSource(), historyStore: MemoryClipboardHistoryStore(),
        blankFiles: BlankFileTemplateStore(directory: root))
    try await writer.setCurrentPlainText("keep")
    let previous = writer.items, state = writer.snapshot.currentState
    pb.fails = true
    do {
        try await writer.setCurrentFile(template: .txt); throw TestFailure(description: "Expected write failure")
    } catch is ClipboardSubsystemError {}
    try expectEqual(writer.items, previous)
    try expectEqual(writer.snapshot.currentState, state)
}

@MainActor private func testDevFileMetadata() async throws {
    let pb = DevPasteboard()
    let root = try makeTemporaryTestDirectory(prefix: "dev-metadata")
    defer { try? FileManager.default.removeItem(at: root) }
    let monitor = ClipboardMonitor(
        pasteboard: pb, sourceApplications: DevSource(), historyStore: MemoryClipboardHistoryStore(),
        blankFiles: BlankFileTemplateStore(directory: root))
    try await monitor.setCurrentFile(template: .pdf)
    let item = monitor.items[0]
    let encoded = try JSONEncoder().encode(item)
    let decoded = try JSONDecoder().decode(ClipboardItem.self, from: encoded)
    try expectEqual(decoded.activated(at: Date()).generatedTemplate, .pdf)
    var old = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
    old.removeValue(forKey: "generatedTemplate")
    let migrated = try JSONDecoder().decode(ClipboardItem.self, from: JSONSerialization.data(withJSONObject: old))
    try expectEqual(migrated.generatedTemplate, nil)
    let archive = root.appendingPathComponent("history.tdclip")
    let store = EncryptedClipboardHistoryStore(fileURL: archive, keyProvider: DevTestKey())
    try await store.save([item])
    let saved = try await store.load()
    try expectEqual(saved, [item])
    let ciphertext = try Data(contentsOf: archive)
    try expect(ciphertext.range(of: Data("generatedTemplate".utf8)) == nil)
}

private struct DevTestKey: ClipboardEncryptionKeyProviding {
    func encryptionKey() async throws -> SymmetricKey { SymmetricKey(data: Data(repeating: 27, count: 32)) }
}

@MainActor private func testDevNativeFilePasteboard() throws {
    let root = try makeTemporaryTestDirectory(prefix: "dev-native-pasteboard")
    defer { try? FileManager.default.removeItem(at: root) }
    let url = try BlankFileTemplateStore(directory: root).create(.pdf)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let client = SystemClipboardPasteboardClient(pasteboard: board)
    let payload = ClipboardPayload(items: [
        .init(representations: [
            .init(kind: .fileURL, pasteboardType: "public.file-url", data: Data(url.absoluteString.utf8))
        ])
    ])
    _ = try client.write(payload)
    let files = board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]
    try expectEqual(files, [url])
}
