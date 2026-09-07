import CoreGraphics
import Foundation
import ImageIO
import TopDropCore
import UniformTypeIdentifiers

let annotationTests: [UnitTest] = [
    UnitTest("Annotations: hex colors parse RGB and RGBA") {
        try testAnnotationColorHexParsing()
    },
    UnitTest("Annotations: hex colors format canonically and round trip") {
        try testAnnotationColorHexFormatting()
    },
    UnitTest("Annotations: malformed hex colors are rejected") {
        try testAnnotationColorHexRejection()
    },
    UnitTest("Annotations: quick palette contains stable opaque sRGB colors") {
        try testAnnotationQuickPalette()
    },
    UnitTest("Annotations: viewport transforms round trip source pixels") {
        let transform = AnnotationViewportTransform(
            sourcePixelSize: PixelSize(width: 6_000, height: 4_000),
            viewportPointSize: PixelSize(width: 900, height: 700),
            zoom: 2,
            panInViewPoints: PixelPoint(x: 31, y: -17)
        )
        let source = PixelRect(x: 1_234.5, y: 987.25, width: 777, height: 333)
        let roundTrip = transform.viewToSource(transform.sourceToView(source))
        try expectApproximatelyEqual(roundTrip.origin.x, source.origin.x)
        try expectApproximatelyEqual(roundTrip.origin.y, source.origin.y)
        try expectApproximatelyEqual(roundTrip.size.width, source.size.width)
        try expectApproximatelyEqual(roundTrip.size.height, source.size.height)
        // The fit is based only on view points, not a Retina backing scale.
        try expectApproximatelyEqual(transform.scale, 0.3)
    },
    UnitTest("Annotations: document move resize style delete undo and redo") {
        try await testAnnotationEditingAndHistory()
    },
    UnitTest("Annotations: arrows edit duplicate reorder and persist") {
        try await testArrowEditingAndPersistence()
    },
    UnitTest("Annotations: corner resize geometry preserves bounds") {
        try testAnnotationCornerResizeGeometry()
    },
    UnitTest("Annotations: rounded boxes default automatically and persist custom radius") {
        try await testRoundedRectangleEditingAndMigration()
    },
    UnitTest("Annotations: version-one JSON without arrow fields remains readable") {
        try await testLegacyAnnotationJSONCompatibility()
    },
    UnitTest("Annotations: Codable JSON persists editable pixel coordinates") {
        try await testAnnotationPersistence()
    },
    UnitTest("Annotations: renderer produces exact-size flattened PNG") {
        try testAnnotationRendering()
    },
    UnitTest("Annotations: clipboard PNG preserves palette RGB channels") {
        try testAnnotationPaletteColorRendering()
    },
    UnitTest("Annotations: renderer produces a one-page flattened PDF") {
        try testAnnotationPDFRendering()
    },
    UnitTest("Annotations: renderer honors source orientation metadata") {
        try testAnnotationOrientationRendering()
    },
    UnitTest("Annotations: renderer rejects a mismatched canvas") {
        try await testAnnotationRendererSizeMismatch()
    },
]

private func testAnnotationColorHexParsing() throws {
    guard let rgb = AnnotationColor(hexString: "  #336699\n") else {
        throw TestFailure(description: "Expected a six-digit color")
    }
    try expectApproximatelyEqual(rgb.red, 0x33.double / 255)
    try expectApproximatelyEqual(rgb.green, 0x66.double / 255)
    try expectApproximatelyEqual(rgb.blue, 0x99.double / 255)
    try expectApproximatelyEqual(rgb.alpha, 1)

    guard let rgba = AnnotationColor(hexString: "aBcDeF80") else {
        throw TestFailure(description: "Expected an eight-digit color without a leading hash")
    }
    try expectApproximatelyEqual(rgba.red, 0xAB.double / 255)
    try expectApproximatelyEqual(rgba.green, 0xCD.double / 255)
    try expectApproximatelyEqual(rgba.blue, 0xEF.double / 255)
    try expectApproximatelyEqual(rgba.alpha, 0x80.double / 255)
}

private func testAnnotationColorHexFormatting() throws {
    let opaque = AnnotationColor(red: 0.1, green: 0.5, blue: 1)
    try expectEqual(opaque.hexString, "#1A80FF")
    try expectEqual(opaque.hexString(includingAlpha: true), "#1A80FFFF")

    let translucent = AnnotationColor(red: 1, green: 0, blue: 0.2, alpha: 0.5)
    try expectEqual(translucent.hexString, "#FF003380")
    guard let roundTrip = AnnotationColor(hexString: translucent.hexString) else {
        throw TestFailure(description: "Expected canonical output to parse")
    }
    try expectEqual(roundTrip.hexString, translucent.hexString)

    let clamped = AnnotationColor(red: -1, green: 2, blue: .nan, alpha: .infinity)
    try expectEqual(clamped.hexString(includingAlpha: true), "#00FF0000")
}

private func testAnnotationColorHexRejection() throws {
    let invalidValues = [
        "", "#", "#123", "#1234", "#12345", "#1234567", "#123456789",
        "#GG0000", "##112233", "0x112233", "#12 3456",
    ]
    for value in invalidValues {
        try expect(
            AnnotationColor(hexString: value) == nil,
            "Expected \(value.debugDescription) to be rejected"
        )
    }
}

private func testAnnotationQuickPalette() throws {
    let palette: [(AnnotationColor, String)] = [
        (.black, "#0F0F12"),
        (.white, "#FFFFFF"),
        (.gray, "#808085"),
        (.red, "#FF1F14"),
        (.orange, "#FF9400"),
        (.yellow, "#FFC70D"),
        (.blue, "#0A85FF"),
        (.green, "#30D159"),
        (.purple, "#BF59F2"),
    ]
    try expectEqual(palette.map { $0.0.hexString }, palette.map(\.1))
    try expect(palette.allSatisfy { $0.0.alpha == 1 && $0.0.isValid })
}

private extension Int {
    var double: Double { Double(self) }
}

@MainActor
private func testAnnotationEditingAndHistory() throws {
    let document = try AnnotationDocument(sourcePixelSize: PixelSize(width: 1_000, height: 500))
    let rectangleID = try document.addRectangle(
        frame: PixelRect(x: 900, y: 450, width: 200, height: 100),
        color: .yellow,
        strokeWidth: 8
    )
    try expectEqual(document.annotations[0].frame, PixelRect(x: 800, y: 400, width: 200, height: 100))

    try document.move(id: rectangleID, by: PixelPoint(x: -250, y: -75))
    try expectEqual(document.annotations[0].frame.origin, PixelPoint(x: 550, y: 325))
    try document.resize(id: rectangleID, to: PixelRect(x: 990, y: 490, width: 30, height: 30))
    try expectEqual(document.annotations[0].frame, PixelRect(x: 970, y: 470, width: 30, height: 30))
    try document.setStrokeWidth(12, for: rectangleID)
    try document.setColor(.white, for: rectangleID)

    let textID = try document.addText(
        frame: PixelRect(x: 50, y: 60, width: 400, height: 100),
        text: "TopDrop",
        fontSize: 42
    )
    try document.setText("Edited text", for: textID)
    try document.setFontSize(54, for: textID)
    document.setZoom(3)
    try expectEqual(document.zoom, 3)

    let beforeDelete = document.annotations
    try document.delete(id: rectangleID)
    try expectEqual(document.annotations.count, 1)
    try expect(document.undo())
    try expectEqual(document.annotations, beforeDelete)
    try expect(document.redo())
    try expectEqual(document.annotations.count, 1)
    try expect(document.undo())
    _ = try document.addRectangle(frame: PixelRect(x: 0, y: 0, width: 10, height: 10))
    try expect(!document.canRedo, "A new edit must clear redo history")
}

@MainActor
private func testArrowEditingAndPersistence() throws {
    let document = try AnnotationDocument(sourcePixelSize: PixelSize(width: 640, height: 480))
    let arrowID = try document.addArrow(
        start: PixelPoint(x: 40, y: 400),
        end: PixelPoint(x: 420, y: 80),
        color: .yellow,
        strokeWidth: 9
    )
    try document.setArrowEndpoints(
        start: PixelPoint(x: 20, y: 460),
        end: PixelPoint(x: 600, y: 30),
        for: arrowID
    )
    try document.move(id: arrowID, by: PixelPoint(x: 100, y: 100))
    guard let moved = document.annotations.first else {
        throw TestFailure(description: "Expected an arrow")
    }
    try expectEqual(moved.startPoint, PixelPoint(x: 60, y: 480))
    try expectEqual(moved.endPoint, PixelPoint(x: 640, y: 50))
    try document.setStrokeWidth(12, for: arrowID)
    try document.setColor(.white, for: arrowID)
    let duplicateID = try document.duplicate(id: arrowID)
    try expectEqual(document.annotations.count, 2)
    try document.sendBackward(id: duplicateID)
    try expectEqual(document.annotations.first?.id, duplicateID)
    try document.bringForward(id: duplicateID)
    try expectEqual(document.annotations.last?.id, duplicateID)

    let data = try document.encodedJSON(prettyPrinted: true)
    let decoded = try AnnotationDocument(jsonData: data)
    try expectEqual(decoded.snapshot(), document.snapshot())
    try expect(decoded.annotations.allSatisfy { $0.kind == .arrow })
}

private func testAnnotationCornerResizeGeometry() throws {
    let canvas = PixelSize(width: 500, height: 300)
    let original = PixelRect(x: 100, y: 80, width: 200, height: 100)
    try expectEqual(
        original.resized(
            from: .topLeading,
            by: PixelPoint(x: 40, y: 20),
            minimumSize: 20,
            canvas: canvas
        ),
        PixelRect(x: 140, y: 100, width: 160, height: 80)
    )
    let clamped = original.resized(
        from: .bottomTrailing,
        by: PixelPoint(x: 900, y: 900),
        minimumSize: 20,
        canvas: canvas
    )
    try expectEqual(clamped.maxX, canvas.width)
    try expectEqual(clamped.maxY, canvas.height)
}

@MainActor
private func testRoundedRectangleEditingAndMigration() throws {
    let document = try AnnotationDocument(sourcePixelSize: PixelSize(width: 500, height: 300))
    let id = try document.addRectangle(
        frame: PixelRect(x: 20, y: 30, width: 180, height: 90),
        strokeWidth: 8
    )
    guard let automatic = document.annotations.first(where: { $0.id == id }) else {
        throw TestFailure(description: "Expected rounded rectangle")
    }
    try expectEqual(automatic.cornerRadius, nil)
    try expectApproximatelyEqual(automatic.effectiveCornerRadius, 14)

    try document.setCornerRadius(28, for: id)
    try expectEqual(document.annotations.first?.cornerRadius, 28)
    let encoded = try document.encodedJSON()
    let decoded = try AnnotationDocument(jsonData: encoded)
    try expectEqual(decoded.annotations.first?.cornerRadius, 28)

    try document.setCornerRadius(nil, for: id)
    try expectEqual(document.annotations.first?.cornerRadius, nil)
    try expect((document.annotations.first?.effectiveCornerRadius ?? 0) > 0)
}

@MainActor
private func testLegacyAnnotationJSONCompatibility() throws {
    let legacy = """
        {
          "version" : 1,
          "sourcePixelSize" : { "width" : 320, "height" : 180 },
          "annotations" : [
            {
              "id" : "D00FE123-A4B5-4C6D-8E9F-000000000001",
              "kind" : "rectangle",
              "frame" : {
                "origin" : { "x" : 10, "y" : 12 },
                "size" : { "width" : 80, "height" : 60 }
              },
              "color" : { "red" : 1, "green" : 0, "blue" : 0, "alpha" : 1 },
              "strokeWidth" : 4
            }
          ]
        }
        """
    let decoded = try AnnotationDocument(jsonData: Data(legacy.utf8))
    try expectEqual(decoded.annotations.count, 1)
    try expectEqual(decoded.annotations[0].kind, .rectangle)
    try expectEqual(decoded.annotations[0].startPoint, nil)
    try expectEqual(decoded.annotations[0].endPoint, nil)
}

@MainActor
private func testAnnotationPersistence() throws {
    let document = try AnnotationDocument(sourcePixelSize: PixelSize(width: 800, height: 600))
    _ = try document.addRectangle(frame: PixelRect(x: 12.5, y: 20.25, width: 300, height: 200))
    _ = try document.addText(
        frame: PixelRect(x: 100, y: 300, width: 500, height: 120),
        text: "Typed ✓",
        color: .yellow,
        fontSize: 48
    )
    let encoded = try document.encodedJSON(prettyPrinted: true)
    let decoded = try AnnotationDocument(jsonData: encoded)
    try expectEqual(decoded.snapshot(), document.snapshot())
    let json = String(decoding: encoded, as: UTF8.self)
    try expect(json.contains("12.5"))
    try expect(json.contains("Typed"))
}

private func testAnnotationRendering() throws {
    let directory = try makeTemporaryTestDirectory(prefix: "AnnotationRender")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    try writeSolidTestImage(
        to: source,
        width: 320,
        height: 180,
        color: (1, 1, 1, 1),
        type: UTType.png
    )
    let snapshot = AnnotationDocumentSnapshot(
        sourcePixelSize: PixelSize(width: 320, height: 180),
        annotations: [
            .rectangle(
                frame: PixelRect(x: 10, y: 8, width: 120, height: 70),
                color: .red,
                strokeWidth: 8
            ),
            .text(
                frame: PixelRect(x: 145, y: 20, width: 160, height: 100),
                text: "Hi",
                color: .red,
                fontSize: 54
            ),
            .arrow(
                start: PixelPoint(x: 15, y: 160),
                end: PixelPoint(x: 285, y: 120),
                color: .red,
                strokeWidth: 7
            ),
        ]
    )
    let png = try AnnotationRenderer.flattenedPNGData(
        sourceImageURL: source,
        snapshot: snapshot
    )
    guard let imageSource = CGImageSourceCreateWithData(png as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        throw TestFailure(description: "Could not decode rendered PNG")
    }
    try expectEqual(image.width, 320)
    try expectEqual(image.height, 180)
    try expect(countStrongRedPixels(in: image) > 300, "Expected visible rectangle/text pixels")
    try expect(
        countStrongRedPixels(in: image, xRange: 140..<320) > 100,
        "Expected the asymmetric text glyphs inside their right-side frame"
    )
}

private func testAnnotationPaletteColorRendering() throws {
    let directory = try makeTemporaryTestDirectory(prefix: "AnnotationColor")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    try writeSolidTestImage(
        to: source,
        width: 420,
        height: 90,
        color: (0.22, 0.22, 0.23, 1),
        type: .png
    )
    let palette: [AnnotationColor] = [
        .black, .white, .gray, .red, .orange, .yellow, .blue, .green, .purple,
    ]
    let annotations = palette.enumerated().map { index, color in
        Annotation.rectangle(
            frame: PixelRect(x: Double(index * 46 + 5), y: 12, width: 38, height: 62),
            color: color,
            strokeWidth: 10,
            cornerRadius: 9
        )
    }
    let png = try AnnotationRenderer.flattenedPNGData(
        sourceImageURL: source,
        snapshot: AnnotationDocumentSnapshot(
            sourcePixelSize: PixelSize(width: 420, height: 90),
            annotations: annotations
        )
    )
    guard let imageSource = CGImageSourceCreateWithData(png as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        throw TestFailure(description: "Could not decode color-managed annotation PNG")
    }
    let pixels = try rgbaPixels(in: image)
    for color in palette {
        let expected = (
            UInt8((color.red * 255).rounded()),
            UInt8((color.green * 255).rounded()),
            UInt8((color.blue * 255).rounded())
        )
        let count = pixels.count { pixel in
            abs(Int(pixel.0) - Int(expected.0)) <= 3
                && abs(Int(pixel.1) - Int(expected.1)) <= 3
                && abs(Int(pixel.2) - Int(expected.2)) <= 3
                && pixel.3 == 255
        }
        try expect(count > 30, "Expected preserved pixels for \(color.hexString); found \(count)")
    }
}

private func testAnnotationPDFRendering() throws {
    let directory = try makeTemporaryTestDirectory(prefix: "AnnotationPDF")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    try writeSolidTestImage(
        to: source,
        width: 240,
        height: 160,
        color: (1, 1, 1, 1),
        type: UTType.png
    )
    let snapshot = AnnotationDocumentSnapshot(
        sourcePixelSize: PixelSize(width: 240, height: 160),
        annotations: [
            .arrow(
                start: PixelPoint(x: 20, y: 130),
                end: PixelPoint(x: 210, y: 30),
                color: .red,
                strokeWidth: 8
            )
        ]
    )
    let pdf = try AnnotationRenderer.flattenedPDFData(
        sourceImageURL: source,
        snapshot: snapshot
    )
    guard let provider = CGDataProvider(data: pdf as CFData),
        let document = CGPDFDocument(provider),
        let page = document.page(at: 1)
    else {
        throw TestFailure(description: "Could not decode rendered PDF")
    }
    try expectEqual(document.numberOfPages, 1)
    let box = page.getBoxRect(.mediaBox)
    try expectApproximatelyEqual(box.width, 240)
    try expectApproximatelyEqual(box.height, 160)
}

private func testAnnotationRendererSizeMismatch() async throws {
    let directory = try makeTemporaryTestDirectory(prefix: "AnnotationMismatch")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.png")
    try writeSolidTestImage(
        to: source,
        width: 10,
        height: 10,
        color: (1, 1, 1, 1),
        type: UTType.png
    )
    try await expectThrows {
        _ = try AnnotationRenderer.flattenedPNGData(
            sourceImageURL: source,
            snapshot: AnnotationDocumentSnapshot(
                sourcePixelSize: PixelSize(width: 11, height: 10)
            )
        )
    }
}

private func testAnnotationOrientationRendering() throws {
    let directory = try makeTemporaryTestDirectory(prefix: "AnnotationOrientation")
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("oriented.jpg")
    try writeSolidTestImage(
        to: source,
        width: 40,
        height: 20,
        color: (0.2, 0.3, 0.4, 1),
        type: UTType.jpeg,
        properties: [kCGImagePropertyOrientation: 6] as CFDictionary
    )
    let orientedSize = try AnnotationRenderer.sourcePixelSize(at: source)
    try expectEqual(orientedSize, PixelSize(width: 20, height: 40))
    let rendered = try AnnotationRenderer.flattenedPNGData(
        sourceImageURL: source,
        snapshot: AnnotationDocumentSnapshot(sourcePixelSize: orientedSize)
    )
    guard let imageSource = CGImageSourceCreateWithData(rendered as CFData, nil),
        let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    else {
        throw TestFailure(description: "Could not decode orientation render")
    }
    try expectEqual(image.width, 20)
    try expectEqual(image.height, 40)
}

func makeTemporaryTestDirectory(prefix: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("TopDrop-\(prefix)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

func writeSolidTestImage(
    to url: URL,
    width: Int,
    height: Int,
    color: (Double, Double, Double, Double),
    type: UTType,
    properties: CFDictionary? = nil
) throws {
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        )
    else {
        throw TestFailure(description: "Could not create test bitmap")
    }
    context.setFillColor(
        CGColor(colorSpace: colorSpace, components: [color.0, color.1, color.2, color.3])!
    )
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
        let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            type.identifier as CFString,
            1,
            nil
        )
    else {
        throw TestFailure(description: "Could not create test image destination for \(type.identifier)")
    }
    CGImageDestinationAddImage(destination, image, properties)
    guard CGImageDestinationFinalize(destination) else {
        throw TestFailure(description: "Could not encode test image as \(type.identifier)")
    }
}

private func countStrongRedPixels(
    in image: CGImage,
    xRange: Range<Int>? = nil
) -> Int {
    let width = image.width
    let height = image.height
    var bytes = Data(count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let address = buffer.baseAddress,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: address,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { return 0 }
    return bytes.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: UInt8.self)
        var count = 0
        var index = 0
        while index + 3 < values.count {
            let pixelIndex = index / 4
            let x = pixelIndex % width
            if (xRange?.contains(x) ?? true),
                values[index] > 180,
                values[index + 1] < 100,
                values[index + 2] < 100
            {
                count += 1
            }
            index += 4
        }
        return count
    }
}

private func rgbaPixels(in image: CGImage) throws -> [(UInt8, UInt8, UInt8, UInt8)] {
    let width = image.width
    let height = image.height
    var bytes = Data(count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
        guard let address = buffer.baseAddress,
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: address,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            )
        else { return false }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return true
    }
    guard rendered else { throw TestFailure(description: "Could not read rendered RGBA pixels") }
    return bytes.withUnsafeBytes { raw in
        let values = raw.bindMemory(to: UInt8.self)
        return stride(from: 0, to: values.count, by: 4).map { index in
            (values[index], values[index + 1], values[index + 2], values[index + 3])
        }
    }
}

private func expectApproximatelyEqual(
    _ actual: Double,
    _ expected: Double,
    accuracy: Double = 0.000_001,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    try expect(
        abs(actual - expected) <= accuracy,
        "expected \(expected) ± \(accuracy), got \(actual)",
        file: file,
        line: line
    )
}
