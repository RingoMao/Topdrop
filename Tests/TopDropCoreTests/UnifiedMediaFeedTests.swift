import Foundation
import TopDropCore
import UniformTypeIdentifiers

let unifiedMediaFeedTests: [UnitTest] = [
    UnitTest("Unified media: merges clipboard images without duplicate rows") {
        try testUnifiedMediaMergeAndFilters()
    },
    UnitTest("Unified media: keeps evicted multi-image rows lazily editable") {
        try await testUnifiedMediaLazyImageResolution()
    },
    UnitTest("Unified media: activity sorting and pinned-current exclusion") {
        try testUnifiedMediaActivityAndCurrentExclusion()
    },
]

private func testUnifiedMediaMergeAndFilters() throws {
    let textClip = unifiedTextClip(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        capturedAt: Date(timeIntervalSince1970: 400)
    )
    let imageClip = unifiedImageClip(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
        capturedAt: Date(timeIntervalSince1970: 300),
        imageData: [Data([1]), Data([2])]
    )
    let cache = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
        digest: "alpha",
        importedAt: imageClip.capturedAt,
        origin: .clipboardCache
    )
    let project = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000012")!,
        digest: "beta",
        importedAt: imageClip.capturedAt,
        origin: .clipboardProject
    )
    let matchingWatched = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000013")!,
        digest: "beta",
        importedAt: Date(timeIntervalSince1970: 250),
        origin: .watchedFolder
    )
    let standaloneWatched = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000014")!,
        digest: "gamma",
        importedAt: Date(timeIntervalSince1970: 200),
        origin: .watchedFolder
    )
    let resolutions = [
        imageClip.id: [
            ClipboardImageResolution(
                clipboardItemID: imageClip.id,
                logicalIndex: 0,
                contentDigest: "alpha",
                screenshotItem: cache
            ),
            ClipboardImageResolution(
                clipboardItemID: imageClip.id,
                logicalIndex: 1,
                contentDigest: "beta",
                screenshotItem: project
            ),
        ]
    ]
    let screenshots = [cache, project, matchingWatched, standaloneWatched]

    let all = UnifiedMediaFeedBuilder.build(
        clipboardItems: [textClip, imageClip],
        screenshotItems: screenshots,
        resolutions: resolutions,
        filter: .all
    )
    try expectEqual(all.count, 4)
    try expectEqual(all.filter(isRawClipboard).count, 1)
    let allImages = all.compactMap(imageEntry)
    try expectEqual(allImages.count, 3)
    try expectEqual(allImages.filter { $0.clipboardItem?.id == imageClip.id }.count, 2)
    try expectEqual(allImages.filter { $0.screenshotItem?.id == matchingWatched.id }.count, 0)
    try expectEqual(allImages.filter { $0.screenshotItem?.id == standaloneWatched.id }.count, 1)

    let text = UnifiedMediaFeedBuilder.build(
        clipboardItems: [textClip, imageClip],
        screenshotItems: screenshots,
        resolutions: resolutions,
        filter: .text
    )
    try expectEqual(text.count, 1)
    try expect(text.allSatisfy(isRawClipboard))

    let images = UnifiedMediaFeedBuilder.build(
        clipboardItems: [textClip, imageClip],
        screenshotItems: screenshots,
        resolutions: resolutions,
        filter: .images
    )
    try expectEqual(images.count, 3)

    let unresolved = UnifiedMediaFeedBuilder.build(
        clipboardItems: [imageClip],
        screenshotItems: [],
        resolutions: [:],
        filter: .all
    )
    try expectEqual(unresolved.compactMap(imageEntry).map(\.logicalIndex), [0, 1])
    try expect(unresolved.compactMap(imageEntry).allSatisfy { $0.screenshotItem == nil })
}

private func testUnifiedMediaLazyImageResolution() async throws {
    let root = try makeTemporaryTestDirectory(prefix: "UnifiedMediaLazy")
    defer { try? FileManager.default.removeItem(at: root) }
    let firstURL = root.appendingPathComponent("first.png")
    let secondURL = root.appendingPathComponent("second.png")
    try writeSolidTestImage(
        to: firstURL,
        width: 31,
        height: 21,
        color: (0.8, 0.1, 0.2, 1),
        type: .png
    )
    try writeSolidTestImage(
        to: secondURL,
        width: 47,
        height: 29,
        color: (0.1, 0.4, 0.9, 1),
        type: .png
    )
    let clip = unifiedImageClip(
        id: UUID(),
        capturedAt: Date(timeIntervalSince1970: 100),
        imageData: [try Data(contentsOf: firstURL), try Data(contentsOf: secondURL)]
    )
    let library = try ScreenshotLibrary(
        libraryDirectory: root.appendingPathComponent("Managed"),
        stabilizationPolicy: .immediateForTesting
    )

    let selected = try await library.resolveClipboardImage(from: clip, logicalIndex: 1)
    try expectEqual(selected?.logicalIndex, 1)
    try expectEqual(selected?.screenshotItem.origin, .clipboardProject)
    try expectEqual(selected?.screenshotItem.pixelSize, PixelSize(width: 47, height: 29))
    try expectEqual(selected?.screenshotItem.sourceFilename, "Clipboard Image 2.png")
    let afterSelected = await library.snapshot()
    try expectEqual(afterSelected.items.count, 1)
    try expectEqual(afterSelected.items.first?.origin, .clipboardProject)

    let all = try await library.resolveClipboardImages(from: clip)
    try expectEqual(all.map(\.logicalIndex), [0, 1])
    let afterAll = await library.snapshot()
    try expectEqual(afterAll.items.filter { $0.origin == .clipboardCache }.count, 1)
    try expectEqual(afterAll.items.filter { $0.origin == .clipboardProject }.count, 1)
}

private func testUnifiedMediaActivityAndCurrentExclusion() throws {
    let current = unifiedImageClip(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000101")!,
        capturedAt: Date(timeIntervalSince1970: 100),
        imageData: [Data([1]), Data([2])]
    )
    let activatedHistory = unifiedTextClip(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000102")!,
        capturedAt: Date(timeIntervalSince1970: 200)
    ).activated(at: Date(timeIntervalSince1970: 600))
    let newerCapture = unifiedTextClip(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000103")!,
        capturedAt: Date(timeIntervalSince1970: 500)
    )
    let firstCache = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000111")!,
        digest: "current-a",
        importedAt: current.capturedAt,
        origin: .clipboardCache
    )
    let secondProject = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000112")!,
        digest: "current-b",
        importedAt: current.capturedAt,
        origin: .clipboardProject
    )
    let watched = unifiedScreenshot(
        id: UUID(uuidString: "00000000-0000-0000-0000-000000000113")!,
        digest: "watched",
        importedAt: Date(timeIntervalSince1970: 400),
        origin: .watchedFolder
    )
    let resolutions = [
        current.id: [
            ClipboardImageResolution(
                clipboardItemID: current.id,
                logicalIndex: 0,
                contentDigest: firstCache.contentDigest,
                screenshotItem: firstCache
            ),
            ClipboardImageResolution(
                clipboardItemID: current.id,
                logicalIndex: 1,
                contentDigest: secondProject.contentDigest,
                screenshotItem: secondProject
            ),
        ]
    ]

    let feed = UnifiedMediaFeedBuilder.build(
        clipboardItems: [current, newerCapture, activatedHistory],
        screenshotItems: [firstCache, secondProject, watched],
        resolutions: resolutions,
        filter: .all,
        excludingClipboardItemID: current.id
    )
    try expectEqual(feed.count, 3)
    try expectEqual(
        feed.map(\.id),
        [
            "clipboard:\(activatedHistory.id.uuidString)",
            "clipboard:\(newerCapture.id.uuidString)",
            "screenshot:\(watched.id.uuidString)",
        ])
    try expect(
        !feed.contains { entry in
            guard case let .image(image) = entry else { return false }
            return image.clipboardItem?.id == current.id
                || image.screenshotItem?.id == firstCache.id
                || image.screenshotItem?.id == secondProject.id
        })
}

private func unifiedTextClip(id: UUID, capturedAt: Date) -> ClipboardItem {
    ClipboardItem(
        id: id,
        capturedAt: capturedAt,
        sourceApplication: nil,
        payload: ClipboardPayload(items: [
            ClipboardPayloadItem(representations: [
                ClipboardRepresentation(
                    kind: .plainText,
                    pasteboardType: "public.utf8-plain-text",
                    data: Data("temporary note".utf8)
                )
            ])
        ]),
        preview: ClipboardPreview(kind: .text, excerpt: "temporary note"),
        fingerprint: Data([9])
    )
}

private func unifiedImageClip(
    id: UUID,
    capturedAt: Date,
    imageData: [Data]
) -> ClipboardItem {
    ClipboardItem(
        id: id,
        capturedAt: capturedAt,
        sourceApplication: nil,
        payload: ClipboardPayload(
            items: imageData.map { data in
                ClipboardPayloadItem(representations: [
                    ClipboardRepresentation(
                        kind: .image,
                        pasteboardType: UTType.png.identifier,
                        data: data
                    )
                ])
            }),
        preview: ClipboardPreview(kind: .image),
        fingerprint: Data([7])
    )
}

private func unifiedScreenshot(
    id: UUID,
    digest: String,
    importedAt: Date,
    origin: ScreenshotItemOrigin
) -> ScreenshotItem {
    ScreenshotItem(
        id: id,
        importedAt: importedAt,
        sourceCreatedAt: nil,
        sourceModifiedAt: nil,
        sourceURL: URL(fileURLWithPath: "/tmp/\(id.uuidString)-source.png"),
        sourceFilename: "\(digest).png",
        managedOriginalURL: URL(fileURLWithPath: "/tmp/\(id.uuidString)-original.png"),
        thumbnailURL: URL(fileURLWithPath: "/tmp/\(id.uuidString)-thumbnail.png"),
        format: .png,
        pixelSize: PixelSize(width: 100, height: 60),
        byteCount: 100,
        contentDigest: digest,
        origin: origin
    )
}

private func isRawClipboard(_ entry: UnifiedMediaFeedEntry) -> Bool {
    if case .clipboard = entry { return true }
    return false
}

private func imageEntry(_ entry: UnifiedMediaFeedEntry) -> UnifiedMediaImageEntry? {
    if case let .image(image) = entry { return image }
    return nil
}
