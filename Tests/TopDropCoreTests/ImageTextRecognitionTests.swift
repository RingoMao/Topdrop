import AppKit
import ImageIO
import UniformTypeIdentifiers
import TopDropCore

struct StubImageTextRecognizer: ImageTextRecognizing {
    let text: String
    func recognizeText(in data: Data) async throws -> String { text }
}

private actor SuspendedTextRecognizer: ImageTextRecognizing {
    var pending: CheckedContinuation<String, Never>?
    func recognizeText(in data: Data) async throws -> String {
        await withCheckedContinuation { pending = $0 }
    }
    func isWaiting() -> Bool { pending != nil }
    func finish(_ text: String) { pending?.resume(returning: text); pending = nil }
}

let imageTextRecognitionTests: [UnitTest] = [
    UnitTest("OCR: filters supported languages without duplicates") {
        try expectEqual(
            VisionImageTextRecognizer.languages(
                preferred: ["en-GB", "zh-Hans", "xx-XX"], supported: ["en-US", "zh-Hans", "zh-Hant"]
            ), ["zh-Hans", "zh-Hant", "en-US"])
    },
    UnitTest("OCR: copies unmodified multiline text once") {
        try await testTextCopySuccess()
    },
    UnitTest("OCR: empty recognition preserves clipboard") {
        try await testTextCopyEmpty()
    },
    UnitTest("OCR: missing original and failed write remain retryable") {
        try await testTextCopyFailure()
    },
    UnitTest("OCR: duplicate activation rejected and cancelled late result ignored") {
        try await testTextCopyCancellation()
    },
    UnitTest("OCR: Vision rejects corrupted image") {
        try await expectThrows { _ = try await VisionImageTextRecognizer().recognizeText(in: Data([0, 1, 2])) }
    },
    UnitTest("OCR: Vision recognizes English code URL and Chinese from original pixels") {
        let data = await ocrFixture(
            text: "TopDrop OCR\nHello 世界\nlet value = 123\nhttps://example.com", size: CGSize(width: 1200, height: 500))
        let text = try await VisionImageTextRecognizer().recognizeText(in: data)
        try expect(text.contains("TopDrop"), "English not recognized")
        try expect(text.contains("世界"), "Synthetic fixture Chinese not recognized: \(text)")
        try expect(text.contains("123"), "Code number not recognized")
        try expect(text.contains("example.com"), "URL not recognized")
        try expect(text.contains("\n"), "Line breaks lost")
    },
    UnitTest("OCR: Vision respects EXIF orientation") {
        let upright = await ocrFixture(text: "ORIENTATION 123", size: CGSize(width: 1000, height: 240))
        let rotated = try rotatedOCRFixture(upright)
        let text = try await VisionImageTextRecognizer().recognizeText(in: rotated)
        try expect(text.contains("ORIENTATION"), "Image orientation not applied")
    },
    UnitTest("OCR: Vision blank image returns no text") {
        let data = await ocrFixture(text: "", size: CGSize(width: 300, height: 200))
        let text = try await VisionImageTextRecognizer().recognizeText(in: data)
        try expectEqual(text, "")
    },
    UnitTest("OCR: Vision reads small text in large Retina-sized image") {
        let data = await ocrFixture(text: "RETINA TEXT 2468", size: CGSize(width: 3200, height: 1800), fontSize: 24)
        let text = try await VisionImageTextRecognizer().recognizeText(in: data)
        try expect(text.contains("2468"), "Small text missing")
    },
]

@MainActor private func testTextCopySuccess() async throws {
    let expected = "  hello\n中文\t#123ABC  "
    let controller = ImageTextCopyController(recognizer: StubImageTextRecognizer(text: expected))
    var writes: [String] = []
    let task = controller.copy(load: { Data([1]) }, write: { writes.append($0) })
    await task?.value
    try expectEqual(writes, [expected])
    try expectEqual(controller.state, .copied)
}

@MainActor private func testTextCopyEmpty() async throws {
    let controller = ImageTextCopyController(recognizer: StubImageTextRecognizer(text: " \n\t"))
    var writes = 0
    await controller.copy(load: { Data() }, write: { _ in writes += 1 })?.value
    try expectEqual(writes, 0)
    try expectEqual(controller.state, .noText)
}

@MainActor private func testTextCopyFailure() async throws {
    let controller = ImageTextCopyController(recognizer: StubImageTextRecognizer(text: "hello"))
    var writes = 0
    await controller.copy(load: { throw AnnotationError.sourceImageUnavailable }, write: { _ in writes += 1 })?.value
    try expectEqual(writes, 0)
    try expectEqual(controller.state, .failed)
    await controller.copy(load: { Data() }, write: { _ in throw ClipboardSubsystemError.pasteboardWriteFailed })?.value
    try expectEqual(controller.state, .failed)
    await controller.copy(load: { Data() }, write: { _ in writes += 1 })?.value
    try expectEqual(writes, 1)
    try expectEqual(controller.state, .copied)
}

@MainActor private func testTextCopyCancellation() async throws {
    let recognizer = SuspendedTextRecognizer()
    let controller = ImageTextCopyController(recognizer: recognizer)
    var writes: [String] = []
    let first = controller.copy(load: { Data() }, write: { writes.append($0) })
    while !(await recognizer.isWaiting()) { await Task.yield() }
    try expect(controller.copy(load: { Data() }, write: { writes.append($0) }) == nil)
    controller.cancel()
    await recognizer.finish("stale")
    await first?.value
    try expectEqual(writes, [])
    try expectEqual(controller.state, .idle)
    let second = controller.copy(load: { Data() }, write: { writes.append($0) })
    while !(await recognizer.isWaiting()) { await Task.yield() }
    await recognizer.finish("new image")
    await second?.value
    try expectEqual(writes, ["new image"])
}

@MainActor private func ocrFixture(text: String, size: CGSize, fontSize: CGFloat = 48) -> Data {
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.white.setFill()
    NSRect(origin: .zero, size: size).fill()
    (text as NSString).draw(
        in: NSRect(x: 40, y: 30, width: size.width - 80, height: size.height - 60),
        withAttributes: [
            .font: NSFont.systemFont(ofSize: fontSize), .foregroundColor: NSColor.black,
        ])
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])!
}

private func rotatedOCRFixture(_ data: Data) throws -> Data {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    let context = CGContext(
        data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.translateBy(x: CGFloat(image.height), y: 0)
    context.rotate(by: .pi / 2)
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    let result = NSMutableData()
    let destination = CGImageDestinationCreateWithData(result, UTType.tiff.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, [kCGImagePropertyOrientation: 6] as CFDictionary)
    try expect(CGImageDestinationFinalize(destination))
    return result as Data
}
