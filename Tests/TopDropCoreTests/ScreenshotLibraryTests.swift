import CoreGraphics
import Foundation
import ImageIO
import TopDropCore
import UniformTypeIdentifiers

let screenshotTests: [UnitTest] = [
    UnitTest("Screenshots: first selection baselines existing and imports new only") {
        try await testScreenshotNewOnlyBaseline()
    },
    UnitTest("Screenshots: explicit import supports PNG JPEG HEIC and TIFF") {
        try await testScreenshotFormatsAndDeduplication()
    },
    UnitTest("Screenshots: waits for partial writes to stabilize") {
        try await testScreenshotPartialWriteStabilization()
    },
    UnitTest("Screenshots: source deletion does not remove managed history") {
        try await testScreenshotSourceDeletionAndHistoryRemoval()
    },
    UnitTest("Screenshots: annotation persistence save-copy and exports are collision safe") {
        try await testScreenshotActionsAndCollisions()
    },
    UnitTest("Screenshots: FSEvents monitor lifecycle is reflected in snapshots") {
        try await testScreenshotMonitorLifecycle()
    },
    UnitTest("Screenshots: clipboard images prefer inline PNG normalize and deduplicate") {
        try await testClipboardImageImportAndFallback()
    },
    UnitTest("Screenshots: clipboard cache retains ten roots and preserves edited projects") {
        try await testClipboardCacheRetentionAndPrivacy()
    },
    UnitTest("Screenshots: deleting one clip removes only its exclusive unedited cache roots") {
        try await testClipboardItemCacheDeletion()
    },
    UnitTest("Screenshots: clearing clipboard cache preserves screenshots projects and aliases") {
        try await testClearUneditedClipboardCacheRetention()
    },
    UnitTest("Screenshots: transient cache is encrypted and watched files win dedupe races") {
        try await testClipboardCacheEncryptionAndDurableDedupe()
    },
    UnitTest("Screenshots: edit sessions create one durable version and restore is reversible") {
        try await testScreenshotAnnotationVersions()
    },
    UnitTest("Screenshots: old item metadata defaults to watched-folder provenance") {
        try testScreenshotOriginBackwardCompatibility()
    },
]

private func testScreenshotNewOnlyBaseline() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotBaseline")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let oldURL = source.appendingPathComponent("old.png")
    try writeSolidTestImage(to: oldURL, width: 80, height: 60, color: (1, 0, 0, 1), type: .png)

    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    let initiallyImported = try await library.configureSourceFolder(
        source,
        importExisting: false,
        startMonitoring: false
    )
    try expect(initiallyImported.isEmpty)
    let initialSnapshot = await library.snapshot()
    try expect(initialSnapshot.items.isEmpty)
    let baselineScan = try await library.scanNow()
    try expect(baselineScan.isEmpty, "Baseline files must not be imported by a rescan")

    let newURL = source.appendingPathComponent("new.png")
    try writeSolidTestImage(to: newURL, width: 120, height: 90, color: (0, 1, 0, 1), type: .png)
    let imported = try await library.scanNow()
    try expectEqual(imported.count, 1)
    let item = imported[0]
    try expectEqual(item.sourceURL.standardizedFileURL, newURL.standardizedFileURL)
    try expect(FileManager.default.fileExists(atPath: newURL.path))
    try expect(FileManager.default.fileExists(atPath: item.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: item.thumbnailURL.path))
    try expect(item.managedOriginalURL != item.sourceURL)
    let managedBytes = try Data(contentsOf: item.managedOriginalURL)
    let sourceBytes = try Data(contentsOf: newURL)
    try expectEqual(managedBytes, sourceBytes)

    let existing = try await library.importExistingScreenshots()
    try expectEqual(existing.count, 1)
    let afterExisting = await library.snapshot()
    try expectEqual(afterExisting.items.count, 2)

    let reloaded = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    let reloadedSnapshot = await reloaded.snapshot()
    try expectEqual(reloadedSnapshot.items.count, 2)

    let whileClosed = source.appendingPathComponent("while-closed.png")
    try writeSolidTestImage(to: whileClosed, width: 66, height: 44, color: (0, 0, 1, 1), type: .png)
    _ = try await reloaded.configureSourceFolder(source, startMonitoring: false)
    let caughtUp = try await reloaded.scanNow()
    try expectEqual(caughtUp.count, 1)
    try expectEqual(caughtUp.first?.sourceFilename, "while-closed.png")
}

private func testScreenshotFormatsAndDeduplication() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotFormats")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    let fixtures: [(String, UTType, ScreenshotImageFormat, (Double, Double, Double, Double))] = [
        ("one.png", .png, .png, (1, 0, 0, 1)),
        ("two.jpg", .jpeg, .jpeg, (0, 1, 0, 1)),
        ("three.heic", .heic, .heic, (0, 0, 1, 1)),
        ("four.tiff", .tiff, .tiff, (1, 1, 0, 1)),
    ]
    var importedFormats = Set<ScreenshotImageFormat>()
    for (index, fixture) in fixtures.enumerated() {
        let url = source.appendingPathComponent(fixture.0)
        // The CLT 15.4 ImageIO runner can decode HEIC but has no HEIC encoder.
        // A PNG bitstream with a .heic name still exercises TopDrop's extension
        // classification and ImageIO sniffing; real HEIC decoding uses the same
        // production path.
        let encodedType: UTType = fixture.1 == .heic ? .png : fixture.1
        try writeSolidTestImage(
            to: url,
            width: 91 + index,
            height: 71 + index,
            color: fixture.3,
            type: encodedType
        )
        guard let item = try await library.importScreenshot(at: url) else {
            throw TestFailure(description: "Expected \(fixture.0) to import")
        }
        importedFormats.insert(item.format)
        try expectEqual(item.format, fixture.2)
    }
    try expectEqual(importedFormats, Set(ScreenshotImageFormat.allCases))

    let original = source.appendingPathComponent("one.png")
    let duplicate = source.appendingPathComponent("duplicate.png")
    try FileManager.default.copyItem(at: original, to: duplicate)
    let duplicateResult = try await library.importScreenshot(at: duplicate)
    try expect(duplicateResult == nil)
    let snapshot = await library.snapshot()
    try expectEqual(snapshot.items.count, 4)
}

private func testScreenshotPartialWriteStabilization() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotPartial")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let completeURL = root.appendingPathComponent("complete.png")
    try writeSolidTestImage(to: completeURL, width: 160, height: 100, color: (0.2, 0.4, 0.8, 1), type: .png)
    let completeData = try Data(contentsOf: completeURL)

    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: ScreenshotStabilizationPolicy(
            pollInterval: .milliseconds(30),
            requiredMatchingSamples: 3,
            maximumAttempts: 30,
            eventCoalescingDelay: .zero
        )
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)
    let partialURL = source.appendingPathComponent("partial.png")
    try Data(completeData.prefix(24)).write(to: partialURL)
    let writer = Task {
        try await Task.sleep(for: .milliseconds(45))
        try completeData.write(to: partialURL)
    }
    let imported = try await library.importScreenshot(at: partialURL)
    try await writer.value
    try expect(imported != nil)
    try expectEqual(imported?.pixelSize, PixelSize(width: 160, height: 100))
}

private func testScreenshotSourceDeletionAndHistoryRemoval() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotDeletion")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    let deletedSource = source.appendingPathComponent("deleted.png")
    try writeSolidTestImage(to: deletedSource, width: 30, height: 20, color: (1, 0, 1, 1), type: .png)
    let deletedItem = try requireScreenshot(try await library.importScreenshot(at: deletedSource))
    try FileManager.default.removeItem(at: deletedSource)
    let sourceAvailable = try await library.sourceIsAvailable(for: deletedItem.id)
    try expect(!sourceAvailable)
    try expect(FileManager.default.fileExists(atPath: deletedItem.managedOriginalURL.path))

    let retainedSource = source.appendingPathComponent("retained.png")
    try writeSolidTestImage(to: retainedSource, width: 31, height: 21, color: (0, 1, 1, 1), type: .png)
    let retainedItem = try requireScreenshot(try await library.importScreenshot(at: retainedSource))
    try await library.removeFromHistory(id: retainedItem.id)
    try expect(FileManager.default.fileExists(atPath: retainedSource.path), "Removing history must not delete source")
    try expect(!FileManager.default.fileExists(atPath: retainedItem.managedOriginalURL.path))
}

private func testScreenshotActionsAndCollisions() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotActions")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let downloads = root.appendingPathComponent("Desktop", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)
    let sourceURL = source.appendingPathComponent("Screen Shot.png")
    try writeSolidTestImage(to: sourceURL, width: 200, height: 120, color: (1, 1, 1, 1), type: .png)
    let item = try requireScreenshot(try await library.importScreenshot(at: sourceURL))
    let originalBytes = try Data(contentsOf: item.managedOriginalURL)
    let annotations = AnnotationDocumentSnapshot(
        sourcePixelSize: item.pixelSize,
        annotations: [
            .rectangle(frame: PixelRect(x: 10, y: 10, width: 80, height: 50))
        ]
    )
    try await library.saveAnnotations(annotations, for: item.id)
    let loadedAnnotations = try await library.loadAnnotations(for: item.id)
    try expectEqual(loadedAnnotations, annotations)
    let annotationURL = try await library.annotationURL(for: item.id)
    try expect(FileManager.default.fileExists(atPath: annotationURL.path))

    let savedOne = try await library.saveCopy(id: item.id, annotations: annotations)
    let savedTwo = try await library.saveCopy(id: item.id, annotations: annotations)
    try expect(savedOne != savedTwo)
    try expectEqual(savedOne.lastPathComponent, "Screen Shot Annotated.png")
    try expectEqual(savedTwo.lastPathComponent, "Screen Shot Annotated 2.png")
    let unchangedOriginalBytes = try Data(contentsOf: item.managedOriginalURL)
    try expectEqual(unchangedOriginalBytes, originalBytes)

    let downloadOne = try await library.downloadToDesktop(
        id: item.id,
        destinationDirectory: downloads
    )
    let downloadTwo = try await library.downloadToDesktop(
        id: item.id,
        destinationDirectory: downloads
    )
    try expectEqual(downloadOne.lastPathComponent, "Screen Shot.png")
    try expectEqual(downloadTwo.lastPathComponent, "Screen Shot 2.png")
    let downloadedBytes = try Data(contentsOf: downloadOne)
    try expectEqual(downloadedBytes, originalBytes)

    let annotatedDownload = try await library.downloadToDesktop(
        id: item.id,
        annotations: annotations,
        destinationDirectory: downloads
    )
    try expectEqual(annotatedDownload.lastPathComponent, "Screen Shot Annotated.png")

    let explicitPNG = downloads.appendingPathComponent("Custom.png")
    let explicitPDF = downloads.appendingPathComponent("Custom.pdf")
    _ = try await library.export(
        id: item.id,
        annotations: annotations,
        format: .png,
        destinationURL: explicitPNG
    )
    _ = try await library.export(
        id: item.id,
        annotations: annotations,
        format: .pdf,
        destinationURL: explicitPDF
    )
    try expect(FileManager.default.fileExists(atPath: explicitPNG.path))
    let pdfData = try Data(contentsOf: explicitPDF)
    guard let provider = CGDataProvider(data: pdfData as CFData),
        let pdf = CGPDFDocument(provider)
    else {
        throw TestFailure(description: "Explicit screenshot PDF was invalid")
    }
    try expectEqual(pdf.numberOfPages, 1)
}

private func testScreenshotMonitorLifecycle() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotMonitor")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)
    do {
        try await library.startMonitoring()
        let running = await library.snapshot()
        try expect(running.isMonitoring)
        await library.stopMonitoring()
        let stopped = await library.snapshot()
        try expect(!stopped.isMonitoring)
    } catch {
        // FSEventStreamStart returns false in the hermetic command-line test
        // runner because its fseventsd service is unavailable. The important
        // failure invariant is that the actor never reports a phantom watcher.
        let stopped = await library.snapshot()
        try expect(!stopped.isMonitoring)
    }
}

private func testClipboardImageImportAndFallback() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotClipboardImport")
    defer { try? FileManager.default.removeItem(at: root) }
    let pngURL = root.appendingPathComponent("preferred.png")
    let tiffURL = root.appendingPathComponent("alternate.tiff")
    let fileURL = root.appendingPathComponent("fallback.jpg")
    let unrotatedURL = root.appendingPathComponent("unrotated.jpg")
    let orientedURL = root.appendingPathComponent("oriented.jpg")
    try writeSolidTestImage(to: pngURL, width: 41, height: 31, color: (1, 0, 0, 1), type: .png)
    try writeSolidTestImage(to: tiffURL, width: 87, height: 61, color: (0, 1, 0, 1), type: .tiff)
    try writeSolidTestImage(to: fileURL, width: 53, height: 37, color: (0, 0, 1, 1), type: .jpeg)
    try writeSolidTestImage(to: unrotatedURL, width: 60, height: 30, color: (0.6, 0.2, 0.8, 1), type: .jpeg)
    try writeOrientationTaggedImage(sourceURL: unrotatedURL, destinationURL: orientedURL, orientation: 6)

    let payload = ClipboardPayload(items: [
        ClipboardPayloadItem(representations: [
            ClipboardRepresentation(
                kind: .image,
                pasteboardType: UTType.tiff.identifier,
                data: try Data(contentsOf: tiffURL)
            ),
            ClipboardRepresentation(
                kind: .image,
                pasteboardType: UTType.png.identifier,
                data: try Data(contentsOf: pngURL)
            ),
        ]),
        ClipboardPayloadItem(representations: [
            ClipboardRepresentation(
                kind: .fileURL,
                pasteboardType: UTType.fileURL.identifier,
                data: Data(fileURL.absoluteString.utf8)
            )
        ]),
        ClipboardPayloadItem(representations: [
            ClipboardRepresentation(
                kind: .image,
                pasteboardType: UTType.jpeg.identifier,
                data: try Data(contentsOf: orientedURL)
            )
        ]),
        ClipboardPayloadItem(representations: [
            ClipboardRepresentation(
                kind: .image,
                pasteboardType: UTType.png.identifier,
                data: Data(
                    repeating: 0,
                    count: TopDropCore.maximumClipboardScreenshotBytes + 1
                )
            )
        ]),
    ])
    let clipboardItem = makeClipboardItem(payload: payload, capturedAt: Date(timeIntervalSince1970: 100))
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )

    // OCR resolves full-size logical images without creating projects/cache roots.
    let ocrPNG = try await library.clipboardOriginalImageData(from: clipboardItem, logicalIndex: 0)
    let ocrFile = try await library.clipboardOriginalImageData(from: clipboardItem, logicalIndex: 1)
    let ocrRotated = try await library.clipboardOriginalImageData(from: clipboardItem, logicalIndex: 2)
    let ocrSizes = try [ocrPNG, ocrFile, ocrRotated].map { try AnnotationRenderer.sourcePixelSize(data: $0) }
    try expectEqual(
        ocrSizes,
        [PixelSize(width: 41, height: 31), PixelSize(width: 53, height: 37), PixelSize(width: 30, height: 60)])
    let beforeImport = await library.snapshot()
    try expect(beforeImport.items.isEmpty, "Reading for OCR must not create a cache or edit project")
    try await expectThrows { _ = try await library.clipboardOriginalImageData(from: clipboardItem, logicalIndex: 99) }
    let imported = try await library.importClipboardImages(from: clipboardItem)
    try expect(imported.count == 3, "Oversized actual image data must be skipped")
    try expectEqual(imported[0].pixelSize, PixelSize(width: 41, height: 31))
    try expectEqual(imported[1].pixelSize, PixelSize(width: 53, height: 37))
    try expect(
        imported[2].pixelSize == PixelSize(width: 30, height: 60),
        "Canonical PNG conversion must bake EXIF orientation into pixels"
    )
    for item in imported {
        try expectEqual(item.origin, .clipboardCache)
        try expectEqual(item.format, .png)
        try expectEqual(item.managedOriginalURL.pathExtension, "png")
        try expect(item.byteCount <= Int64(TopDropCore.maximumClipboardScreenshotBytes))
    }
    let duplicate = try await library.importClipboardImages(from: clipboardItem)
    try expect(duplicate.isEmpty, "Canonical clipboard image digests must suppress duplicates")
}

private func testClipboardCacheRetentionAndPrivacy() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotClipboardRetention")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    var firstTen: [ScreenshotItem] = []
    for index in 0..<TopDropCore.maximumClipboardScreenshotCount {
        let imageURL = root.appendingPathComponent("cache-\(index).png")
        try writeSolidTestImage(
            to: imageURL,
            width: 20 + index,
            height: 20,
            color: (Double(index) / 12, 0.2, 0.7, 1),
            type: .png
        )
        let payload = ClipboardPayload(items: [
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .image,
                    pasteboardType: UTType.png.identifier,
                    data: try Data(contentsOf: imageURL)
                )
            ])
        ])
        let imported = try await library.importClipboardImages(
            from: makeClipboardItem(
                payload: payload,
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        )
        try expectEqual(imported.count, 1)
        firstTen.append(imported[0])
    }

    let projectRoot = firstTen[0]
    let editSession = try await library.beginEditSession(for: projectRoot.id)
    let promotedBeforeMutation = try await library.item(id: projectRoot.id)
    try expectEqual(promotedBeforeMutation.origin, .clipboardProject)
    let edited = AnnotationDocumentSnapshot(
        sourcePixelSize: projectRoot.pixelSize,
        annotations: [.rectangle(frame: PixelRect(x: 1, y: 1, width: 8, height: 8))]
    )
    try await library.saveAnnotations(edited, for: projectRoot.id, editSession: editSession)
    await library.endEditSession(editSession)
    let promotedItem = try await library.item(id: projectRoot.id)
    try expectEqual(promotedItem.origin, .clipboardProject)

    for index in 10..<12 {
        let imageURL = root.appendingPathComponent("cache-\(index).png")
        try writeSolidTestImage(
            to: imageURL,
            width: 20 + index,
            height: 21,
            color: (0.8, Double(index - 10) / 3, 0.1, 1),
            type: .png
        )
        let payload = ClipboardPayload(items: [
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .image,
                    pasteboardType: UTType.png.identifier,
                    data: try Data(contentsOf: imageURL)
                )
            ])
        ])
        _ = try await library.importClipboardImages(
            from: makeClipboardItem(
                payload: payload,
                capturedAt: Date(timeIntervalSince1970: TimeInterval(index))
            )
        )
    }

    let snapshot = await library.snapshot()
    try expectEqual(snapshot.items.filter { $0.origin == .clipboardCache }.count, 10)
    try expectEqual(snapshot.items.filter { $0.origin == .clipboardProject }.count, 1)
    try expect(snapshot.items.contains { $0.id == projectRoot.id })
    try expectEqual(snapshot.annotationVersionCount(for: projectRoot.id), 1)
    try expect(snapshot.items.count == 11, "Annotation aliases are not screenshot roots")

    let metadataURL = managed.appendingPathComponent("library.json")
    let metadataText = String(decoding: try Data(contentsOf: metadataURL), as: UTF8.self)
    try expect(!metadataText.contains(projectRoot.id.uuidString))
    try expect(!metadataText.contains("clipboardCache"))
    try expect(!metadataText.contains("clipboardProject"))

    let projectOriginalURL = projectRoot.managedOriginalURL
    let transientFlattenedURL = try await library.saveCopy(
        id: projectRoot.id,
        annotations: edited
    )
    try expect(transientFlattenedURL.path.contains("/Flattened/"))
    try expect(!transientFlattenedURL.path.contains("/SessionCache/"))
    let reloaded = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    let reloadedSnapshot = await reloaded.snapshot()
    try expect(reloadedSnapshot.items.allSatisfy { $0.origin == .watchedFolder })
    try expect(!FileManager.default.fileExists(atPath: projectOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: transientFlattenedURL.path))
}

private func testClipboardItemCacheDeletion() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotClipboardItemDeletion")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    let watchedURL = source.appendingPathComponent("watched.png")
    let sharedURL = root.appendingPathComponent("shared.png")
    let projectURL = root.appendingPathComponent("project.png")
    let exclusiveURL = root.appendingPathComponent("exclusive.png")
    try writeSolidTestImage(to: watchedURL, width: 72, height: 48, color: (0.1, 0.3, 0.8, 1), type: .png)
    try writeSolidTestImage(to: sharedURL, width: 51, height: 37, color: (0.8, 0.2, 0.1, 1), type: .png)
    try writeSolidTestImage(to: projectURL, width: 52, height: 38, color: (0.2, 0.8, 0.1, 1), type: .png)
    try writeSolidTestImage(to: exclusiveURL, width: 53, height: 39, color: (0.7, 0.1, 0.8, 1), type: .png)
    let watched = try requireScreenshot(try await library.importScreenshot(at: watchedURL))

    let deletedClip = makeClipboardItem(
        payload: try clipboardImagePayload(urls: [sharedURL, projectURL, exclusiveURL]),
        capturedAt: Date(timeIntervalSince1970: 100)
    )
    let deletedResolutions = try await library.resolveClipboardImages(from: deletedClip)
    try expectEqual(deletedResolutions.count, 3)

    let sharedClip = makeClipboardItem(
        payload: try clipboardImagePayload(urls: [sharedURL]),
        capturedAt: Date(timeIntervalSince1970: 101)
    )
    let retainedResolutions = try await library.resolveClipboardImages(from: sharedClip)
    try expectEqual(retainedResolutions.count, 1)

    guard let projectRoot = deletedResolutions.first(where: { $0.logicalIndex == 1 })?.screenshotItem,
        let exclusiveRoot = deletedResolutions.first(where: { $0.logicalIndex == 2 })?.screenshotItem,
        let sharedRoot = deletedResolutions.first(where: { $0.logicalIndex == 0 })?.screenshotItem
    else {
        throw TestFailure(description: "Expected all clipboard image resolutions")
    }
    let editSession = try await library.beginEditSession(for: projectRoot.id)
    let edited = AnnotationDocumentSnapshot(
        sourcePixelSize: projectRoot.pixelSize,
        annotations: [.rectangle(frame: PixelRect(x: 2, y: 2, width: 12, height: 9))]
    )
    try await library.saveAnnotations(edited, for: projectRoot.id, editSession: editSession)
    await library.endEditSession(editSession)
    let projectVersions = try await library.annotationVersions(for: projectRoot.id)
    try expectEqual(projectVersions.count, 1)

    let removed = try await library.removeUneditedClipboardCache(
        associatedWith: deletedClip.id,
        resolutions: deletedResolutions,
        retainingContentDigests: Set(retainedResolutions.map(\.contentDigest))
    )
    try expectEqual(removed, Set([exclusiveRoot.id]))

    let snapshot = await library.snapshot()
    try expect(snapshot.items.contains { $0.id == watched.id && $0.origin == .watchedFolder })
    try expect(snapshot.items.contains { $0.id == sharedRoot.id && $0.origin == .clipboardCache })
    try expect(snapshot.items.contains { $0.id == projectRoot.id && $0.origin == .clipboardProject })
    try expect(!snapshot.items.contains { $0.id == exclusiveRoot.id })
    try expectEqual(snapshot.annotationVersionCount(for: projectRoot.id), 1)
    try expect(FileManager.default.fileExists(atPath: watched.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: sharedRoot.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: projectRoot.managedOriginalURL.path))
    try expect(!FileManager.default.fileExists(atPath: exclusiveRoot.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: projectVersions[0].annotationURL.path))
}

private func testClearUneditedClipboardCacheRetention() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotClipboardClearRetention")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    let watchedURL = source.appendingPathComponent("watched.png")
    let projectURL = root.appendingPathComponent("edited.png")
    let cacheOneURL = root.appendingPathComponent("cache-one.png")
    let cacheTwoURL = root.appendingPathComponent("cache-two.png")
    try writeSolidTestImage(to: watchedURL, width: 81, height: 61, color: (0.2, 0.4, 0.9, 1), type: .png)
    try writeSolidTestImage(to: projectURL, width: 61, height: 41, color: (0.9, 0.3, 0.2, 1), type: .png)
    try writeSolidTestImage(to: cacheOneURL, width: 62, height: 42, color: (0.3, 0.9, 0.2, 1), type: .png)
    try writeSolidTestImage(to: cacheTwoURL, width: 63, height: 43, color: (0.8, 0.2, 0.9, 1), type: .png)
    let watched = try requireScreenshot(try await library.importScreenshot(at: watchedURL))
    let clip = makeClipboardItem(
        payload: try clipboardImagePayload(urls: [projectURL, cacheOneURL, cacheTwoURL]),
        capturedAt: Date(timeIntervalSince1970: 200)
    )
    let resolutions = try await library.resolveClipboardImages(from: clip)
    try expectEqual(resolutions.count, 3)
    guard let projectRoot = resolutions.first(where: { $0.logicalIndex == 0 })?.screenshotItem else {
        throw TestFailure(description: "Expected project clipboard root")
    }
    let cacheRoots =
        resolutions
        .filter { $0.logicalIndex != 0 }
        .map(\.screenshotItem)

    let session = try await library.beginEditSession(for: projectRoot.id)
    let edited = AnnotationDocumentSnapshot(
        sourcePixelSize: projectRoot.pixelSize,
        annotations: [
            .text(
                frame: PixelRect(x: 3, y: 3, width: 30, height: 16),
                text: "keep"
            )
        ]
    )
    try await library.saveAnnotations(edited, for: projectRoot.id, editSession: session)
    await library.endEditSession(session)
    let versions = try await library.annotationVersions(for: projectRoot.id)
    try expectEqual(versions.count, 1)

    let removed = try await library.clearUneditedClipboardCache()
    try expectEqual(removed, Set(cacheRoots.map(\.id)))
    let snapshot = await library.snapshot()
    try expectEqual(snapshot.items.filter { $0.origin == .clipboardCache }.count, 0)
    try expect(snapshot.items.contains { $0.id == watched.id && $0.origin == .watchedFolder })
    try expect(snapshot.items.contains { $0.id == projectRoot.id && $0.origin == .clipboardProject })
    try expectEqual(snapshot.annotationVersionCount(for: projectRoot.id), 1)
    try expect(FileManager.default.fileExists(atPath: watched.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: projectRoot.managedOriginalURL.path))
    try expect(FileManager.default.fileExists(atPath: versions[0].annotationURL.path))
    for cacheRoot in cacheRoots {
        try expect(!FileManager.default.fileExists(atPath: cacheRoot.managedOriginalURL.path))
        try expect(!FileManager.default.fileExists(atPath: cacheRoot.thumbnailURL.path))
    }
}

private func testClipboardCacheEncryptionAndDurableDedupe() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotClipboardCrypto")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let firstURL = root.appendingPathComponent("first.unknown-image")
    try writeSolidTestImage(to: firstURL, width: 43, height: 29, color: (0.2, 0.7, 0.3, 1), type: .png)
    let firstData = try Data(contentsOf: firstURL)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)

    // File-URL fallback is content-sniffed by ImageIO, not extension-gated.
    let cached = try await library.importClipboardImages(
        from: makeClipboardItem(
            payload: ClipboardPayload(items: [
                ClipboardPayloadItem(representations: [
                    ClipboardRepresentation(
                        kind: .fileURL,
                        pasteboardType: UTType.fileURL.identifier,
                        data: Data(firstURL.absoluteString.utf8)
                    )
                ])
            ]),
            capturedAt: Date()
        ))
    try expectEqual(cached.count, 1)
    let cacheItem = cached[0]
    let diskOriginal = try Data(contentsOf: cacheItem.managedOriginalURL)
    let diskThumbnail = try Data(contentsOf: cacheItem.thumbnailURL)
    try expect(!diskOriginal.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    try expect(!diskThumbnail.starts(with: [0x89, 0x50, 0x4E, 0x47]))
    try expect(!diskOriginal.contains(Data("IHDR".utf8)))
    let decryptedOriginal = try await library.originalImageData(for: cacheItem.id)
    let decryptedSize = try AnnotationRenderer.sourcePixelSize(data: decryptedOriginal)
    try expectEqual(
        decryptedSize,
        PixelSize(width: 43, height: 29)
    )

    let session = try await library.beginEditSession(for: cacheItem.id)
    let annotation = AnnotationDocumentSnapshot(
        sourcePixelSize: cacheItem.pixelSize,
        annotations: [.text(frame: PixelRect(x: 1, y: 1, width: 20, height: 12), text: "secret")]
    )
    try await library.saveAnnotations(annotation, for: cacheItem.id, editSession: session)
    await library.endEditSession(session)
    let originalForOCR = try await library.originalImageData(for: cacheItem.id)
    try expectEqual(originalForOCR, decryptedOriginal)
    let annotationURL = try await library.annotationURL(for: cacheItem.id)
    let annotationCiphertext = try Data(contentsOf: annotationURL)
    try expect(!String(decoding: annotationCiphertext, as: UTF8.self).contains("secret"))
    let versions = try await library.annotationVersions(for: cacheItem.id)
    try expectEqual(versions.count, 1)
    let versionCiphertext = try Data(contentsOf: versions[0].annotationURL)
    try expect(!String(decoding: versionCiphertext, as: UTF8.self).contains("annotations"))

    // A promoted project is intentionally retained when the watched image arrives.
    let watchedProjectURL = source.appendingPathComponent("project.png")
    try firstData.write(to: watchedProjectURL)
    _ = try await library.importScreenshot(at: watchedProjectURL)
    let withProject = await library.snapshot()
    try expectEqual(withProject.items.filter { $0.origin == .clipboardProject }.count, 1)
    try expectEqual(withProject.items.filter { $0.origin == .watchedFolder }.count, 1)

    // For an unedited cache, durable import replaces the transient root.
    let secondURL = root.appendingPathComponent("second.png")
    try writeSolidTestImage(to: secondURL, width: 47, height: 31, color: (0.8, 0.1, 0.4, 1), type: .png)
    let secondData = try Data(contentsOf: secondURL)
    let secondCached = try await library.importClipboardImages(
        from: makeClipboardItem(
            payload: ClipboardPayload(items: [
                ClipboardPayloadItem(representations: [
                    ClipboardRepresentation(kind: .image, pasteboardType: UTType.png.identifier, data: secondData)
                ])
            ]),
            capturedAt: Date()
        ))
    try expectEqual(secondCached.count, 1)
    let watchedSecondURL = source.appendingPathComponent("second.png")
    try secondData.write(to: watchedSecondURL)
    _ = try await library.importScreenshot(at: watchedSecondURL)
    let afterClipboardFirst = await library.snapshot()
    try expect(!afterClipboardFirst.items.contains { $0.id == secondCached[0].id })
    try expect(
        afterClipboardFirst.items.contains {
            $0.origin == .watchedFolder && $0.sourceFilename == "second.png"
        })

    // Watched-first blocks a redundant clipboard root.
    let watchedFirstURL = source.appendingPathComponent("watched-first.png")
    try writeSolidTestImage(to: watchedFirstURL, width: 49, height: 33, color: (0.1, 0.3, 0.9, 1), type: .png)
    let watchedFirstData = try Data(contentsOf: watchedFirstURL)
    _ = try await library.importScreenshot(at: watchedFirstURL)
    let redundant = try await library.importClipboardImages(
        from: makeClipboardItem(
            payload: ClipboardPayload(items: [
                ClipboardPayloadItem(representations: [
                    ClipboardRepresentation(kind: .image, pasteboardType: UTType.png.identifier, data: watchedFirstData)
                ])
            ]),
            capturedAt: Date()
        ))
    try expect(redundant.isEmpty)

    var burstItems: [ClipboardPayloadItem] = []
    for index in 0..<12 {
        let url = root.appendingPathComponent("burst-\(index).png")
        try writeSolidTestImage(
            to: url,
            width: 60 + index,
            height: 40,
            color: (Double(index) / 20, 0.5, 0.2, 1),
            type: .png
        )
        burstItems.append(
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .image,
                    pasteboardType: UTType.png.identifier,
                    data: try Data(contentsOf: url)
                )
            ]))
    }
    let retainedBurst = try await library.importClipboardImages(
        from: makeClipboardItem(
            payload: ClipboardPayload(items: burstItems),
            capturedAt: Date(timeIntervalSince1970: 500)
        ))
    try expectEqual(retainedBurst.count, 10)
    let afterBurst = await library.snapshot()
    try expectEqual(afterBurst.items.filter { $0.origin == .clipboardCache }.count, 10)
}

private func testScreenshotAnnotationVersions() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "ScreenshotVersions")
    defer { try? FileManager.default.removeItem(at: root) }
    let source = root.appendingPathComponent("Source", isDirectory: true)
    let managed = root.appendingPathComponent("Managed", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    let sourceURL = source.appendingPathComponent("versioned.png")
    try writeSolidTestImage(to: sourceURL, width: 100, height: 80, color: (1, 1, 1, 1), type: .png)
    let library = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    _ = try await library.configureSourceFolder(source, startMonitoring: false)
    let item = try requireScreenshot(try await library.importScreenshot(at: sourceURL))

    let blank = AnnotationDocumentSnapshot(sourcePixelSize: item.pixelSize)
    let one = AnnotationDocumentSnapshot(
        sourcePixelSize: item.pixelSize,
        annotations: [.rectangle(frame: PixelRect(x: 2, y: 2, width: 20, height: 15))]
    )
    let two = AnnotationDocumentSnapshot(
        sourcePixelSize: item.pixelSize,
        annotations: one.annotations + [
            .text(frame: PixelRect(x: 5, y: 30, width: 50, height: 20), text: "two")
        ]
    )
    let three = AnnotationDocumentSnapshot(
        sourcePixelSize: item.pixelSize,
        annotations: two.annotations + [
            .rectangle(frame: PixelRect(x: 40, y: 10, width: 25, height: 25))
        ]
    )

    let firstSession = try await library.beginEditSession(for: item.id)
    try await library.saveAnnotations(blank, for: item.id, editSession: firstSession)
    let versionsAfterNoOp = try await library.annotationVersions(for: item.id)
    try expectEqual(versionsAfterNoOp.count, 0)
    try await library.saveAnnotations(one, for: item.id, editSession: firstSession)
    try await library.saveAnnotations(two, for: item.id, editSession: firstSession)
    let versionsAfterFirstSession = try await library.annotationVersions(for: item.id)
    try expectEqual(versionsAfterFirstSession.count, 1)
    await library.endEditSession(firstSession)

    let secondSession = try await library.beginEditSession(for: item.id)
    try await library.saveAnnotations(three, for: item.id, editSession: secondSession)
    await library.endEditSession(secondSession)
    let beforeRestore = try await library.annotationVersions(for: item.id)
    try expectEqual(beforeRestore.count, 2)
    guard let blankVersion = beforeRestore.first(where: { $0.annotationCount == 0 }) else {
        throw TestFailure(description: "Expected the original blank version")
    }
    let restored = try await library.restoreAnnotationVersion(id: blankVersion.id, for: item.id)
    try expectEqual(restored, blank)
    let versionsAfterRestore = try await library.annotationVersions(for: item.id)
    try expectEqual(versionsAfterRestore.count, 3)
    let afterRestoreSnapshot = await library.snapshot()
    try expectEqual(afterRestoreSnapshot.items.count, 1)
    try expectEqual(afterRestoreSnapshot.annotationVersionCount(for: item.id), 3)

    let versionURLs = try await library.annotationVersions(for: item.id).map(\.annotationURL)
    let reloaded = try ScreenshotLibrary(
        libraryDirectory: managed,
        stabilizationPolicy: .immediateForTesting
    )
    let reloadedSnapshot = await reloaded.snapshot()
    try expectEqual(reloadedSnapshot.items.count, 1)
    try expectEqual(reloadedSnapshot.annotationVersionCount(for: item.id), 3)
    try await reloaded.removeFromHistory(id: item.id)
    for url in versionURLs {
        try expect(!FileManager.default.fileExists(atPath: url.path))
    }
    try expect(FileManager.default.fileExists(atPath: sourceURL.path))
}

private func testScreenshotOriginBackwardCompatibility() throws {
    let item = ScreenshotItem(
        id: UUID(),
        importedAt: Date(timeIntervalSince1970: 10),
        sourceCreatedAt: nil,
        sourceModifiedAt: nil,
        sourceURL: URL(fileURLWithPath: "/tmp/old.png"),
        sourceFilename: "old.png",
        managedOriginalURL: URL(fileURLWithPath: "/tmp/managed.png"),
        thumbnailURL: URL(fileURLWithPath: "/tmp/thumb.png"),
        format: .png,
        pixelSize: PixelSize(width: 10, height: 10),
        byteCount: 100,
        contentDigest: "old"
    )
    let encoded = try JSONEncoder().encode(item)
    guard var object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw TestFailure(description: "Expected screenshot JSON object")
    }
    object.removeValue(forKey: "origin")
    let oldData = try JSONSerialization.data(withJSONObject: object)
    let decoded = try JSONDecoder().decode(ScreenshotItem.self, from: oldData)
    try expectEqual(decoded.origin, .watchedFolder)
}

private func makeClipboardItem(
    payload: ClipboardPayload,
    capturedAt: Date
) -> ClipboardItem {
    ClipboardItem(
        capturedAt: capturedAt,
        sourceApplication: nil,
        payload: payload,
        preview: ClipboardPreview(kind: .image),
        fingerprint: Data()
    )
}

private func clipboardImagePayload(urls: [URL]) throws -> ClipboardPayload {
    ClipboardPayload(
        items: try urls.map { url in
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .image,
                    pasteboardType: UTType.png.identifier,
                    data: try Data(contentsOf: url)
                )
            ])
        })
}

private func writeOrientationTaggedImage(
    sourceURL: URL,
    destinationURL: URL,
    orientation: Int
) throws {
    guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
        let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        )
    else {
        throw TestFailure(description: "Could not create orientation-tagged image")
    }
    CGImageDestinationAddImageFromSource(
        destination,
        source,
        0,
        [kCGImagePropertyOrientation: orientation] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure(description: "Could not finalize orientation-tagged image")
    }
}

private func requireScreenshot(_ value: ScreenshotItem?) throws -> ScreenshotItem {
    guard let value else { throw TestFailure(description: "Expected imported screenshot") }
    return value
}
