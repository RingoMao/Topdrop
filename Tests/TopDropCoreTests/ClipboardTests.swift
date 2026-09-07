import AppKit
import Carbon
import CryptoKit
import Foundation
import TopDropCore

let clipboardTests: [UnitTest] = [
    UnitTest("Clipboard: unreadable archive is never overwritten and retry merges session clips") {
        try await testHistoryRecoveryGuard()
    },
    UnitTest("Clipboard: native write failure after clear invalidates Current") {
        try await testNativeWritePartialFailure()
    },
    UnitTest("OCR: one explicit text write preserves image and does not satisfy watch") {
        try await testOCRClipboardCommit()
    },
    UnitTest("Clipboard: converts every supported representation") {
        try await testClipboardSupportedRepresentations()
    },
    UnitTest("Clipboard: derives text excerpts and URL domains") {
        try await testClipboardPreviewMetadata()
    },
    UnitTest("Clipboard: skips payloads over 20 MB") {
        try await testClipboardOversizeLimit()
    },
    UnitTest("Clipboard: AES-GCM encryption round trips and authenticates") {
        try await testClipboardEncryption()
    },
    UnitTest("Clipboard: Keychain key is cached for the process lifetime") {
        try await testClipboardKeyProviderMemoryCache()
    },
    UnitTest("Clipboard: encrypted archive contains latest 20 only") {
        try await testEncryptedClipboardArchive()
    },
    UnitTest("Clipboard: monitor evicts to exactly 20 newest clips") {
        try await testClipboardMonitorEviction()
    },
    UnitTest("Clipboard: consecutive duplicates and own writes are suppressed") {
        try await testClipboardMonitorSuppression()
    },
    UnitTest("Clipboard: capture hook emits accepted new items only") {
        try await testClipboardMonitorCaptureHook()
    },
    UnitTest("Clipboard: observation hook rehydrates duplicate session consumers") {
        try await testClipboardMonitorObservationHook()
    },
    UnitTest("Clipboard: startup replays retained content for session consumers") {
        try await testClipboardMonitorReplaysRetainedContent()
    },
    UnitTest("Clipboard: startup replay honors pause and recorded-source exclusions") {
        try await testClipboardMonitorReplayGuards()
    },
    UnitTest("Clipboard: recognizes real macOS raster pasteboard flavors") {
        try await testMacOSImagePasteboardFlavors()
    },
    UnitTest("Clipboard: permissions, pause, and exclusions prevent reads") {
        try await testClipboardMonitorGuards()
    },
    UnitTest("Clipboard: restore and Clean Formatting suppress resulting writes") {
        try await testClipboardMonitorWrites()
    },
    UnitTest("Clipboard: explicit Hex text is written retained and previewable") {
        try await testClipboardExplicitHexWrite()
    },
    UnitTest("Clipboard: annotated PNG replaces and becomes current history") {
        try await testClipboardExplicitImageWrite()
    },
    UnitTest("Clipboard: promotion reorders without duplication and protects recent use") {
        try await testClipboardPromotionOrderingAndEviction()
    },
    UnitTest("Clipboard: failed promotion leaves current state and ordering unchanged") {
        try await testClipboardPromotionFailureIsAtomic()
    },
    UnitTest("Clipboard: current state follows retained and untracked changes") {
        try await testClipboardCurrentStateTransitions()
    },
    UnitTest("Clipboard: arrival watch succeeds, ignores owned writes, and times out") {
        try await testClipboardArrivalWatch()
    },
    UnitTest("Clipboard: activation metadata migrates and round trips") {
        try await testClipboardActivationMetadataMigration()
    },
    UnitTest("Clipboard: Clean Formatting preserves nontext flavors") {
        try await testSystemCleanFormatting()
    },
    UnitTest("Clipboard: default hotkey is Control-Option-Command-V") {
        let hotKey = ClipboardHotKeyConfiguration.cleanFormattingDefault
        try expectEqual(hotKey.keyCode, UInt32(kVK_ANSI_V))
        try expect(hotKey.modifiers & UInt32(controlKey) != 0)
        try expect(hotKey.modifiers & UInt32(optionKey) != 0)
        try expect(hotKey.modifiers & UInt32(cmdKey) != 0)
        try expectEqual(hotKey.displayString, "⌃⌥⌘V")
    },
]

@MainActor private func testOCRClipboardCommit() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let store = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard, sourceApplications: FakeClipboardSourceProvider(), historyStore: store)
    let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    try await monitor.setCurrentImagePNG(png)
    let imageID = monitor.items.first!.id
    monitor.beginArrivalWatch()
    let writesBefore = pasteboard.writtenPayloads.count
    let copier = ImageTextCopyController(recognizer: StubImageTextRecognizer(text: "OCR text"))
    await copier.copy(load: { png }, write: { try await monitor.setCurrentPlainText($0) })?.value
    try expectEqual(pasteboard.writtenPayloads.count, writesBefore + 1)
    try expectEqual(monitor.items.first?.preview.kind, .text)
    try expectEqual(monitor.snapshot.currentState.itemID, monitor.items.first?.id)
    try expect(monitor.items.contains { $0.id == imageID })
    if case .received = monitor.snapshot.arrivalWatch {
        throw TestFailure(description: "OCR must not satisfy the arrival watch")
    }
    let stored = try await store.load()
    try expectEqual(stored, monitor.items)
    monitor.cancelArrivalWatch()
}

@MainActor
private func testClipboardSupportedRepresentations() throws {
    let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let raw = ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [
            .init(pasteboardType: NSPasteboard.PasteboardType.string.rawValue, data: Data("plain".utf8)),
            .init(pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue, data: Data("{\\rtf1\\ansi rich}".utf8)),
            .init(pasteboardType: NSPasteboard.PasteboardType.html.rawValue, data: Data("<b>html</b>".utf8)),
            .init(pasteboardType: NSPasteboard.PasteboardType.URL.rawValue, data: Data("https://example.com/a".utf8)),
            .init(pasteboardType: NSPasteboard.PasteboardType.png.rawValue, data: png),
            .init(pasteboardType: NSPasteboard.PasteboardType.pdf.rawValue, data: Data("%PDF-1.4\n%%EOF".utf8)),
            .init(
                pasteboardType: NSPasteboard.PasteboardType.fileURL.rawValue, data: Data("file:///tmp/example.txt".utf8)
            ),
        ])
    ])
    guard case let .item(item) = ClipboardContentConverter().convert(raw, sourceApplication: nil) else {
        throw TestFailure(description: "Expected converted clipboard item")
    }
    try expectEqual(Set(item.payload.items[0].representations.map(\.kind)), Set(ClipboardRepresentationKind.allCases))
    try expectEqual(item.preview.kind, .image)
    try expectEqual(item.payload.byteCount, raw.items[0].flavors.reduce(0) { $0 + $1.data.count })
}

@MainActor
private func testClipboardPreviewMetadata() throws {
    let textRaw = rawText("  First line\n\nsecond   line  ")
    guard case let .item(textItem) = ClipboardContentConverter().convert(textRaw, sourceApplication: nil) else {
        throw TestFailure(description: "Expected text item")
    }
    try expectEqual(textItem.preview.excerpt, "First line second line")

    let urlRaw = ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [
            .init(
                pasteboardType: NSPasteboard.PasteboardType.URL.rawValue,
                data: Data("https://sub.example.org/path".utf8))
        ])
    ])
    guard case let .item(urlItem) = ClipboardContentConverter().convert(urlRaw, sourceApplication: nil) else {
        throw TestFailure(description: "Expected URL item")
    }
    try expectEqual(urlItem.preview.kind, .url)
    try expectEqual(urlItem.preview.urlDomain, "sub.example.org")
}

@MainActor
private func testClipboardOversizeLimit() throws {
    let limit = TopDropCore.maximumClipboardPayloadBytes
    let raw = ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [
            .init(
                pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
                data: Data(repeating: 0x61, count: limit + 1)
            )
        ])
    ])
    guard
        case let .oversized(byteCount, reportedLimit) = ClipboardContentConverter().convert(raw, sourceApplication: nil)
    else {
        throw TestFailure(description: "Expected oversized conversion result")
    }
    try expectEqual(byteCount, limit + 1)
    try expectEqual(reportedLimit, limit)
}

private func testClipboardEncryption() async throws {
    let key = SymmetricKey(size: .bits256)
    let plaintext = Data("clipboard secret".utf8)
    let sealed = try ClipboardCryptoBox.seal(plaintext, using: key)
    try expect(sealed != plaintext)
    let opened = try ClipboardCryptoBox.open(sealed, using: key)
    try expectEqual(opened, plaintext)

    var corrupted = sealed
    corrupted[corrupted.index(before: corrupted.endIndex)] ^= 0x01
    try await expectThrows {
        _ = try ClipboardCryptoBox.open(corrupted, using: key)
    }
}

private func testClipboardKeyProviderMemoryCache() async throws {
    let persistedKeyData = Data(repeating: 0x5A, count: 32)
    let existingStore = CountingClipboardKeyDataStore(keyData: persistedKeyData)
    let existingProvider = KeychainClipboardKeyProvider(
        service: "test.cache.existing",
        account: "archive-key",
        keyDataStore: existingStore
    )

    let returnedKeys = try await withThrowingTaskGroup(of: Data.self) { group in
        for _ in 0..<24 {
            group.addTask {
                let key = try await existingProvider.encryptionKey()
                return key.withUnsafeBytes { Data($0) }
            }
        }
        var keys: [Data] = []
        for try await key in group {
            keys.append(key)
        }
        return keys
    }

    try expectEqual(returnedKeys.count, 24)
    try expect(returnedKeys.allSatisfy { $0 == persistedKeyData })
    try expectEqual(existingStore.readCallCount, 1)
    try expectEqual(existingStore.insertCallCount, 0)

    let emptyStore = CountingClipboardKeyDataStore()
    let newProvider = KeychainClipboardKeyProvider(
        service: "test.cache.new",
        account: "archive-key",
        keyDataStore: emptyStore
    )
    let firstNewKey = try await newProvider.encryptionKey().withUnsafeBytes { Data($0) }
    let secondNewKey = try await newProvider.encryptionKey().withUnsafeBytes { Data($0) }

    try expectEqual(firstNewKey.count, 32)
    try expectEqual(secondNewKey, firstNewKey)
    try expectEqual(emptyStore.readCallCount, 1)
    try expectEqual(emptyStore.insertCallCount, 1)

    let retryStore = CountingClipboardKeyDataStore(keyData: persistedKeyData, readFailures: 1)
    let retryProvider = KeychainClipboardKeyProvider(
        service: "test.cache.retry",
        account: "archive-key",
        keyDataStore: retryStore
    )
    try await expectThrows {
        _ = try await retryProvider.encryptionKey()
    }
    _ = try await retryProvider.encryptionKey()
    _ = try await retryProvider.encryptionKey()
    try expectEqual(retryStore.readCallCount, 2)

    let racedKeyData = Data(repeating: 0xA5, count: 32)
    let duplicateStore = CountingClipboardKeyDataStore(duplicateKeyData: racedKeyData)
    let duplicateProvider = KeychainClipboardKeyProvider(
        service: "test.cache.duplicate",
        account: "archive-key",
        keyDataStore: duplicateStore
    )
    let duplicateResult = try await duplicateProvider.encryptionKey().withUnsafeBytes { Data($0) }
    let cachedDuplicateResult = try await duplicateProvider.encryptionKey().withUnsafeBytes { Data($0) }
    try expectEqual(duplicateResult, racedKeyData)
    try expectEqual(cachedDuplicateResult, racedKeyData)
    try expectEqual(duplicateStore.readCallCount, 2)
    try expectEqual(duplicateStore.insertCallCount, 1)
}

private func testEncryptedClipboardArchive() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TopDropClipboardTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let fileURL = directory.appendingPathComponent("history.tdclip")
    let keyData = Data(repeating: 0x42, count: 32)
    let store = EncryptedClipboardHistoryStore(
        fileURL: fileURL,
        keyProvider: StaticClipboardKeyProvider(keyData: keyData)
    )
    let items = try await MainActor.run {
        try (0..<22).map { index in
            guard
                case let .item(item) = ClipboardContentConverter().convert(
                    rawText("secret-\(index)"), sourceApplication: nil)
            else {
                throw TestFailure(description: "Could not construct archive fixture")
            }
            return item
        }
    }
    try await store.save(items)
    let encrypted = try Data(contentsOf: fileURL)
    try expect(encrypted.range(of: Data("secret-0".utf8)) == nil)
    let loaded = try await store.load()
    try expectEqual(loaded.count, 20)
    try expectEqual(loaded.map(\.fingerprint), Array(items.prefix(20)).map(\.fingerprint))
}

@MainActor
private func testClipboardMonitorEviction() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let store = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: store
    )

    for index in 0...20 {
        pasteboard.simulateCopy(rawText("clip-\(index)"))
        await monitor.pollNow()
    }
    try expectEqual(monitor.items.count, 20)
    try expectEqual(monitor.items.first?.preview.excerpt, "clip-20")
    try expectEqual(monitor.items.last?.preview.excerpt, "clip-1")
    let persisted = try await store.load()
    try expectEqual(persisted.count, 20)
}

@MainActor
private func testClipboardMonitorSuppression() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore()
    )

    pasteboard.simulateCopy(rawText("same"))
    await monitor.pollNow()
    pasteboard.simulateCopy(rawText("same"))
    await monitor.pollNow()
    try expectEqual(monitor.items.count, 1)

    pasteboard.simulateCopy(ClipboardRawContents(items: rawText("owned").items, containsTopDropMarker: true))
    await monitor.pollNow()
    try expectEqual(monitor.items.count, 1)
}

@MainActor
private func testClipboardMonitorCaptureHook() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let source = FakeClipboardSourceProvider()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: source,
        historyStore: MemoryClipboardHistoryStore(),
        configuration: .init(sensitiveApplicationBundleIdentifiers: ["com.example.Secret"])
    )
    var captured: [ClipboardItem] = []
    monitor.onItemCaptured = { captured.append($0) }

    pasteboard.simulateCopy(rawText("accepted"))
    await monitor.pollNow()
    try expectEqual(captured.count, 1)

    pasteboard.simulateCopy(rawText("accepted"))
    await monitor.pollNow()
    pasteboard.simulateCopy(
        ClipboardRawContents(items: rawText("owned").items, containsTopDropMarker: true)
    )
    await monitor.pollNow()
    try expectEqual(captured.count, 1)

    monitor.setPaused(true)
    pasteboard.simulateCopy(rawText("paused"))
    await monitor.pollNow()
    monitor.setPaused(false)
    try expectEqual(captured.count, 1)

    source.source = ClipboardSourceApplication(
        bundleIdentifier: "com.example.Secret",
        displayName: "Secret"
    )
    pasteboard.simulateCopy(rawText("excluded"))
    await monitor.pollNow()
    try expectEqual(captured.count, 1)
}

@MainActor
private func testClipboardMonitorObservationHook() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore()
    )
    var observed: [ClipboardItem] = []
    var retained: [ClipboardItem] = []
    monitor.onContentObserved = { observed.append($0) }
    monitor.onItemCaptured = { retained.append($0) }

    pasteboard.simulateCopy(rawText("same eligible payload"))
    await monitor.pollNow()
    pasteboard.simulateCopy(rawText("same eligible payload"))
    await monitor.pollNow()

    try expectEqual(observed.count, 2)
    try expectEqual(retained.count, 1)
    try expectEqual(monitor.items.count, 1)
    try expectEqual(observed.map(\.id), [monitor.items[0].id, monitor.items[0].id])

    pasteboard.simulateCopy(
        ClipboardRawContents(items: rawText("owned").items, containsTopDropMarker: true)
    )
    await monitor.pollNow()
    try expect(observed.count == 2, "TopDrop-owned writes must not reach observers")
}

@MainActor
private func testClipboardMonitorReplaysRetainedContent() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let retainedContents = rawText("retained encrypted history")
    guard
        case let .item(previousItem) = ClipboardContentConverter().convert(
            retainedContents,
            sourceApplication: nil,
            capturedAt: Date(timeIntervalSince1970: 1)
        )
    else {
        throw TestFailure(description: "Expected fixture conversion")
    }
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore(items: [previousItem]),
        configuration: .init(pollingInterval: .seconds(60))
    )
    var observed: [ClipboardItem] = []
    var retained: [ClipboardItem] = []
    monitor.onContentObserved = { observed.append($0) }
    monitor.onItemCaptured = { retained.append($0) }

    monitor.start()
    for _ in 0..<50 where observed.isEmpty {
        await Task.yield()
    }
    monitor.stop()

    try expect(observed.count == 1, "Startup must replay retained history once")
    try expect(retained.isEmpty, "Matching persistent history must stay deduplicated")
    try expectEqual(monitor.items.count, 1)
    try expectEqual(pasteboard.readCount, 0)
}

@MainActor
private func testClipboardMonitorReplayGuards() async throws {
    let raw = rawText("sensitive retained history")
    let excludedSource = ClipboardSourceApplication(
        bundleIdentifier: "com.example.Secret",
        displayName: "Secret"
    )
    guard
        case let .item(excludedItem) = ClipboardContentConverter().convert(
            raw,
            sourceApplication: excludedSource
        ),
        case let .item(ordinaryItem) = ClipboardContentConverter().convert(
            raw,
            sourceApplication: nil
        )
    else {
        throw TestFailure(description: "Expected fixture conversions")
    }

    let excludedMonitor = ClipboardMonitor(
        pasteboard: FakeClipboardPasteboard(),
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore(items: [excludedItem]),
        configuration: .init(
            pollingInterval: .seconds(60),
            sensitiveApplicationBundleIdentifiers: ["com.example.Secret"]
        )
    )
    var excludedObservations = 0
    excludedMonitor.onContentObserved = { _ in excludedObservations += 1 }
    excludedMonitor.start()
    for _ in 0..<50 where excludedMonitor.items.isEmpty { await Task.yield() }
    excludedMonitor.stop()
    try expectEqual(excludedMonitor.items.count, 1)
    try expectEqual(excludedObservations, 0)

    let pausedMonitor = ClipboardMonitor(
        pasteboard: FakeClipboardPasteboard(),
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore(items: [ordinaryItem]),
        configuration: .init(pollingInterval: .seconds(60))
    )
    var pausedObservations = 0
    pausedMonitor.onContentObserved = { _ in pausedObservations += 1 }
    pausedMonitor.setPaused(true)
    pausedMonitor.start()
    for _ in 0..<50 where pausedMonitor.items.isEmpty { await Task.yield() }
    pausedMonitor.stop()
    try expectEqual(pausedMonitor.items.count, 1)
    try expectEqual(pausedObservations, 0)
}

@MainActor
private func testMacOSImagePasteboardFlavors() throws {
    // These are the standard raster flavors emitted by macOS screenshots,
    // browsers, Preview, Finder Quick Look, and image editors. On some macOS
    // releases the runtime UTI conformance graph is unavailable, so classification
    // must also use AppKit's decoder-advertised image type list.
    let imageTypes = [
        "public.png",
        "public.tiff",
        "public.jpeg",
        "public.heic",
        "public.heif",
        "org.webmproject.webp",
        "com.compuserve.gif",
        "com.microsoft.bmp",
    ]
    for pasteboardType in imageTypes {
        try expect(
            ClipboardContentConverter.kind(forPasteboardType: pasteboardType) == .image,
            "Expected \(pasteboardType) to be classified as an image"
        )
    }
    try expect(
        ClipboardContentConverter.kind(
            forPasteboardType: NSPasteboard.PasteboardType.pdf.rawValue
        ) == .pdf,
        "PDF must retain its dedicated representation despite NSImage support"
    )
}

@MainActor
private func testClipboardMonitorGuards() async throws {
    let pasteboard = FakeClipboardPasteboard(accessState: .promptRequired)
    let source = FakeClipboardSourceProvider()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: source,
        historyStore: MemoryClipboardHistoryStore(),
        configuration: .init(sensitiveApplicationBundleIdentifiers: ["com.bank.Safe"])
    )

    pasteboard.simulateCopy(rawText("prompted"))
    await monitor.pollNow()
    try expectEqual(pasteboard.readCount, 0)
    try expectEqual(monitor.accessState, .promptRequired)

    pasteboard.accessState = .allowed
    await monitor.pollNow()
    try expectEqual(monitor.items.count, 1)

    monitor.setPaused(true)
    pasteboard.simulateCopy(rawText("paused"))
    await monitor.pollNow()
    try expectEqual(monitor.items.count, 1)
    monitor.setPaused(false)

    source.source = ClipboardSourceApplication(bundleIdentifier: "com.bank.Safe", displayName: "Safe")
    pasteboard.simulateCopy(rawText("sensitive"))
    let priorReadCount = pasteboard.readCount
    await monitor.pollNow()
    try expectEqual(pasteboard.readCount, priorReadCount)
    try expectEqual(monitor.items.count, 1)
}

@MainActor
private func testClipboardMonitorWrites() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore()
    )
    pasteboard.simulateCopy(rawText("restore me"))
    await monitor.pollNow()
    let itemID = try require(monitor.items.first?.id, "Missing captured clip")
    try await monitor.restore(itemID: itemID)
    try expectEqual(pasteboard.writtenPayloads.count, 1)
    let readsBeforeOwnPoll = pasteboard.readCount
    await monitor.pollNow()
    try expectEqual(pasteboard.readCount, readsBeforeOwnPoll)

    pasteboard.cleaningResult = .cleaned(changeCount: 0)
    let result = try await monitor.cleanFormatting()
    guard case .cleaned = result else { throw TestFailure(description: "Expected cleaned outcome") }
    try expectEqual(pasteboard.cleanCount, 1)
    try expectEqual(monitor.snapshot.statusMessage, "Clipboard formatting removed. Paste normally when ready.")
}

@MainActor
private func testClipboardExplicitHexWrite() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let store = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: store
    )
    let source = ClipboardSourceApplication(
        bundleIdentifier: TopDropCore.bundleIdentifier,
        displayName: "TopDrop"
    )

    try await monitor.setCurrentPlainText("#336699", sourceApplication: source)
    let item = try require(monitor.items.first, "Missing retained sampled color")
    try expectEqual(pasteboard.writtenPayloads.count, 1)
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: item.id))
    try expectEqual(item.preview.excerpt, "#336699")
    try expectEqual(item.hexColorPreview, AnnotationColor(hexString: "#336699"))
    try expectEqual(item.sourceApplication?.displayName, "TopDrop")
    let persisted = try await store.load()
    try expectEqual(persisted, [item])

    try await monitor.setCurrentPlainText("#336699", sourceApplication: source)
    try expectEqual(monitor.items.count, 1)
    try expect(monitor.items[0].lastActivatedAt != nil)
    try expectEqual(pasteboard.writtenPayloads.count, 2)

    guard
        case let .item(sentence) = ClipboardContentConverter().convert(
            rawText("Use #336699 here"),
            sourceApplication: nil
        )
    else {
        throw TestFailure(description: "Expected sentence fixture")
    }
    try expectEqual(sentence.hexColorPreview, nil)
}

@MainActor
private func testClipboardExplicitImageWrite() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let store = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: store
    )
    let png = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    let source = ClipboardSourceApplication(
        bundleIdentifier: TopDropCore.bundleIdentifier,
        displayName: "TopDrop"
    )

    try await monitor.setCurrentImagePNG(png, sourceApplication: source)
    let item = try require(monitor.items.first, "Missing retained annotated image")
    try expectEqual(item.preview.kind, .image)
    try expectEqual(item.payload.items.count, 1)
    try expectEqual(item.payload.items[0].representations.first?.kind, .image)
    try expectEqual(item.payload.items[0].representations.first?.data, png)
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: item.id))
    try expectEqual(pasteboard.writtenPayloads.count, 1)
    let persisted = try await store.load()
    try expectEqual(persisted, [item])
}

@MainActor
private func testClipboardPromotionOrderingAndEviction() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let store = MemoryClipboardHistoryStore()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: store
    )

    pasteboard.simulateCopy(rawText("first"))
    await monitor.pollNow()
    let first = try require(monitor.items.first, "Missing first clip")
    pasteboard.simulateCopy(rawText("second"))
    await monitor.pollNow()
    let second = try require(monitor.items.first, "Missing second clip")

    try await monitor.makeCurrent(itemID: first.id)
    try expectEqual(monitor.items.count, 2)
    try expectEqual(monitor.items.map(\.id), [first.id, second.id])
    try expect(monitor.items[0].lastActivatedAt != nil)
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: first.id))
    try expectEqual(pasteboard.writtenPayloads.count, 1)

    for index in 0..<19 {
        pasteboard.simulateCopy(rawText("new-\(index)"))
        await monitor.pollNow()
    }
    try expectEqual(monitor.items.count, TopDropCore.maximumClipboardItemCount)
    try expect(monitor.items.contains(where: { $0.id == first.id }))
    try expect(!monitor.items.contains(where: { $0.id == second.id }))

    let persisted = try await store.load()
    try expectEqual(persisted.count, TopDropCore.maximumClipboardItemCount)
    try expect(persisted.contains(where: { $0.id == first.id && $0.lastActivatedAt != nil }))
}

@MainActor
private func testClipboardPromotionFailureIsAtomic() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore()
    )
    pasteboard.simulateCopy(rawText("one"))
    await monitor.pollNow()
    pasteboard.simulateCopy(rawText("two"))
    await monitor.pollNow()

    let beforeIDs = monitor.items.map(\.id)
    let beforeDates = monitor.items.map(\.lastActivatedAt)
    let beforeCurrent = monitor.snapshot.currentState
    pasteboard.writeError = .pasteboardWriteFailed
    var didThrow = false
    do {
        try await monitor.makeCurrent(itemID: beforeIDs[1])
    } catch {
        didThrow = true
    }
    try expect(didThrow, "Expected failed pasteboard write")
    try expectEqual(monitor.items.map(\.id), beforeIDs)
    try expectEqual(monitor.items.map(\.lastActivatedAt), beforeDates)
    try expectEqual(monitor.snapshot.currentState, beforeCurrent)
    try expectEqual(pasteboard.writtenPayloads.count, 0)
}

@MainActor
private func testClipboardCurrentStateTransitions() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let source = FakeClipboardSourceProvider()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: source,
        historyStore: MemoryClipboardHistoryStore(),
        configuration: .init(sensitiveApplicationBundleIdentifiers: ["com.example.Secret"])
    )
    try expectEqual(monitor.snapshot.currentState, .unknown)

    pasteboard.simulateCopy(rawText("tracked"))
    await monitor.pollNow()
    let trackedID = try require(monitor.items.first?.id, "Missing tracked clip")
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: trackedID))

    pasteboard.simulateCopy(rawText("tracked"))
    await monitor.pollNow()
    try expectEqual(monitor.items.count, 1)
    try expectEqual(monitor.snapshot.currentState, .tracked(itemID: trackedID))
    try expect(monitor.items[0].lastActivatedAt != nil)

    monitor.setPaused(true)
    pasteboard.simulateCopy(rawText("paused"))
    await monitor.pollNow()
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .changedWhilePaused))
    monitor.setPaused(false)

    source.source = ClipboardSourceApplication(
        bundleIdentifier: "com.example.Secret",
        displayName: "Secret"
    )
    pasteboard.simulateCopy(rawText("excluded"))
    await monitor.pollNow()
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .excludedApplication))
    source.source = nil

    pasteboard.simulateCopy(ClipboardRawContents(items: []))
    await monitor.pollNow()
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .unsupported))

    pasteboard.simulateCopy(
        ClipboardRawContents(
            items: rawText("owned").items,
            containsTopDropMarker: true
        ))
    await monitor.pollNow()
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .topDropOwnedWrite))

    try await monitor.makeCurrent(itemID: trackedID)
    await monitor.delete(itemID: trackedID)
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .removedFromHistory))
    pasteboard.simulateCopy(rawText("clear me"))
    await monitor.pollNow()
    await monitor.clearAll()
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .historyCleared))
}

@MainActor
private func testClipboardArrivalWatch() async throws {
    let pasteboard = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pasteboard,
        sourceApplications: FakeClipboardSourceProvider(),
        historyStore: MemoryClipboardHistoryStore()
    )

    monitor.beginArrivalWatch(duration: .seconds(1))
    guard case .watching = monitor.snapshot.arrivalWatch else {
        throw TestFailure(description: "Expected active arrival watch")
    }
    pasteboard.simulateCopy(
        ClipboardRawContents(
            items: rawText("owned").items,
            containsTopDropMarker: true
        ))
    await monitor.pollNow()
    guard case .watching = monitor.snapshot.arrivalWatch else {
        throw TestFailure(description: "TopDrop-owned write satisfied arrival watch")
    }

    pasteboard.simulateCopy(rawText("arrival"))
    await monitor.pollNow()
    let arrivalID = try require(monitor.items.first?.id, "Missing arrival clip")
    guard case let .received(itemID, _) = monitor.snapshot.arrivalWatch else {
        throw TestFailure(description: "Expected successful arrival watch")
    }
    try expectEqual(itemID, arrivalID)

    monitor.beginArrivalWatch(duration: .milliseconds(5))
    // The main executor can be delayed on a shared CI runner. Await the
    // observable transition with a bound, not an assumed scheduling latency.
    let timeout = ContinuousClock.now.advanced(by: .seconds(2))
    while monitor.snapshot.arrivalWatch != .timedOut && ContinuousClock.now < timeout {
        try await Task.sleep(for: .milliseconds(10))
    }
    try expectEqual(monitor.snapshot.arrivalWatch, .timedOut)

    monitor.setPaused(true)
    monitor.beginArrivalWatch(duration: .seconds(1))
    try expectEqual(monitor.snapshot.arrivalWatch, .unavailable(reason: .paused))
    monitor.setPaused(false)
    pasteboard.accessState = .denied
    await monitor.pollNow()
    monitor.beginArrivalWatch(duration: .seconds(1))
    try expectEqual(monitor.snapshot.arrivalWatch, .unavailable(reason: .accessRequired))
}

private func testClipboardActivationMetadataMigration() async throws {
    let original = ClipboardItem(
        id: UUID(),
        capturedAt: Date(timeIntervalSince1970: 100),
        sourceApplication: nil,
        payload: ClipboardPayload(items: [
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .plainText, pasteboardType: "public.utf8-plain-text", data: Data("legacy".utf8))
            ])
        ]),
        preview: ClipboardPreview(kind: .text, excerpt: "legacy"),
        fingerprint: Data([1, 2, 3])
    )
    let legacyData = try JSONEncoder().encode(original)
    let decodedLegacy = try JSONDecoder().decode(ClipboardItem.self, from: legacyData)
    try expectEqual(decodedLegacy.lastActivatedAt, nil)

    let activation = Date(timeIntervalSince1970: 200)
    let activated = original.activated(at: activation)
    let decodedActivated = try JSONDecoder().decode(
        ClipboardItem.self,
        from: JSONEncoder().encode(activated)
    )
    try expectEqual(decodedActivated.capturedAt, original.capturedAt)
    try expectEqual(decodedActivated.lastActivatedAt, activation)
    try expectEqual(decodedActivated.activityDate, activation)
}

@MainActor
private func testSystemCleanFormatting() throws {
    let originalNontext = Data([0x00, 0x01, 0x02, 0x03])
    let customType = "com.example.binary"
    let raw = ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [
            .init(
                pasteboardType: NSPasteboard.PasteboardType.rtf.rawValue,
                data: Data("{\\rtf1\\ansi Hello \\b world\\b0}".utf8)
            ),
            .init(pasteboardType: customType, data: originalNontext),
        ])
    ])
    guard case let .rewrite(outputItems) = try ClipboardFormattingCleaner.plan(for: raw),
        let output = outputItems.first
    else {
        throw TestFailure(description: "Expected formatting rewrite plan")
    }
    try expect(output.flavors.allSatisfy { $0.pasteboardType != NSPasteboard.PasteboardType.rtf.rawValue })
    let plain = output.flavors.first { $0.pasteboardType == NSPasteboard.PasteboardType.string.rawValue }
    try expectEqual(plain.flatMap { String(data: $0.data, encoding: .utf8) }, "Hello world")
    try expectEqual(output.flavors.first { $0.pasteboardType == customType }?.data, originalNontext)

    guard case .alreadyPlainText = try ClipboardFormattingCleaner.plan(for: rawText("plain")) else {
        throw TestFailure(description: "Expected already-plain result")
    }
    let nontext = ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [.init(pasteboardType: customType, data: originalNontext)])
    ])
    guard case .noText = try ClipboardFormattingCleaner.plan(for: nontext) else {
        throw TestFailure(description: "Expected no-text result")
    }
}

private func rawText(_ text: String) -> ClipboardRawContents {
    ClipboardRawContents(items: [
        ClipboardRawItem(flavors: [
            .init(pasteboardType: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8))
        ])
    ])
}

private func require<T>(_ value: T?, _ message: String) throws -> T {
    guard let value else { throw TestFailure(description: message) }
    return value
}

private struct StaticClipboardKeyProvider: ClipboardEncryptionKeyProviding {
    let keyData: Data

    func encryptionKey() async throws -> SymmetricKey {
        SymmetricKey(data: keyData)
    }
}

private final class CountingClipboardKeyDataStore: ClipboardKeyDataStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var keyData: Data?
    private var storedReadCallCount = 0
    private var storedInsertCallCount = 0
    private var remainingReadFailures: Int
    private var duplicateKeyData: Data?

    init(
        keyData: Data? = nil,
        readFailures: Int = 0,
        duplicateKeyData: Data? = nil
    ) {
        self.keyData = keyData
        remainingReadFailures = readFailures
        self.duplicateKeyData = duplicateKeyData
    }

    var readCallCount: Int {
        lock.withLock { storedReadCallCount }
    }

    var insertCallCount: Int {
        lock.withLock { storedInsertCallCount }
    }

    func readKeyData(service _: String, account _: String) throws -> Data? {
        try lock.withLock {
            storedReadCallCount += 1
            if remainingReadFailures > 0 {
                remainingReadFailures -= 1
                throw ClipboardSubsystemError.keychain(status: -1)
            }
            return keyData
        }
    }

    func insertKeyData(
        _ data: Data,
        service _: String,
        account _: String
    ) throws -> ClipboardKeyDataInsertResult {
        lock.withLock {
            storedInsertCallCount += 1
            guard keyData == nil else { return .duplicate }
            if let duplicateKeyData {
                keyData = duplicateKeyData
                self.duplicateKeyData = nil
                return .duplicate
            }
            keyData = data
            return .inserted
        }
    }
}

@MainActor
private final class FakeClipboardSourceProvider: ClipboardSourceApplicationProviding {
    var source: ClipboardSourceApplication?

    init(source: ClipboardSourceApplication? = nil) {
        self.source = source
    }

    func currentSourceApplication() -> ClipboardSourceApplication? { source }
}

@MainActor
private final class FakeClipboardPasteboard: ClipboardPasteboardClient {
    var changeCount = 0
    var accessState: ClipboardAccessState
    var currentContents = ClipboardRawContents(items: [])
    var writtenPayloads: [ClipboardPayload] = []
    var cleaningResult: ClipboardCleanFormattingOutcome = .noText
    var readCount = 0
    var cleanCount = 0
    var writeError: ClipboardSubsystemError?
    var clearBeforeFailure = false

    init(accessState: ClipboardAccessState = .allowed) {
        self.accessState = accessState
    }

    func simulateCopy(_ contents: ClipboardRawContents) {
        currentContents = contents
        changeCount += 1
    }

    func requestAccess() -> ClipboardAccessState { accessState }

    func readSupportedContents() throws -> ClipboardRawContents {
        readCount += 1
        return currentContents
    }

    func write(_ payload: ClipboardPayload) throws -> Int {
        if let writeError {
            if clearBeforeFailure { changeCount += 1 }
            throw writeError
        }
        writtenPayloads.append(payload)
        changeCount += 1
        currentContents = ClipboardRawContents(items: [], containsTopDropMarker: true)
        return changeCount
    }

    func cleanFormatting() throws -> ClipboardCleanFormattingOutcome {
        cleanCount += 1
        switch cleaningResult {
        case .cleaned:
            changeCount += 1
            currentContents = ClipboardRawContents(items: [], containsTopDropMarker: true)
            return .cleaned(changeCount: changeCount)
        case .alreadyPlainText:
            return .alreadyPlainText
        case .noText:
            return .noText
        }
    }
}

private actor RecoveryHistoryStore: ClipboardHistoryPersisting {
    var records: [ClipboardItem]
    var denied = true
    var writes = 0
    init(_ records: [ClipboardItem]) { self.records = records }
    func load() async throws -> [ClipboardItem] {
        if denied { throw ClipboardSubsystemError.invalidArchive }
        return records
    }
    func save(_ items: [ClipboardItem]) async throws { writes += 1; records = items }
    func allow() { denied = false }
    func writeCount() -> Int { writes }
}

@MainActor private func testHistoryRecoveryGuard() async throws {
    let converter = ClipboardContentConverter()
    let raw = ClipboardRawContents(items: [
        .init(flavors: [.init(pasteboardType: "public.utf8-plain-text", data: Data("old".utf8))])
    ])
    guard case .item(let old) = converter.convert(raw, sourceApplication: nil) else {
        throw TestFailure(description: "fixture")
    }
    let store = RecoveryHistoryStore([old])
    let monitor = ClipboardMonitor(
        pasteboard: FakeClipboardPasteboard(), sourceApplications: FakeClipboardSourceProvider(), historyStore: store)
    try await monitor.setCurrentPlainText("session")
    let writes = await store.writeCount()
    try expect(writes == 0, "A failed load must block later saves")
    await store.allow()
    await monitor.retryHistoryRecovery()
    try expectEqual(Set(monitor.items.map(\.preview.excerpt)), Set(["old", "session"]))
}

@MainActor private func testNativeWritePartialFailure() async throws {
    let pb = FakeClipboardPasteboard()
    let monitor = ClipboardMonitor(
        pasteboard: pb, sourceApplications: FakeClipboardSourceProvider(), historyStore: MemoryClipboardHistoryStore())
    try await monitor.setCurrentPlainText("retain history")
    pb.writeError = .pasteboardWriteFailed
    pb.clearBeforeFailure = true
    do {
        try await monitor.setCurrentPlainText("new"); throw TestFailure(description: "expected failure")
    } catch is ClipboardSubsystemError {}
    try expectEqual(monitor.items.count, 1)
    try expectEqual(monitor.snapshot.currentState, .untracked(reason: .readFailed))
}
