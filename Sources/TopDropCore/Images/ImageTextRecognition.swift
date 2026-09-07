import Foundation
import Combine
import ImageIO
@preconcurrency import Vision

public protocol ImageTextRecognizing: Sendable {
    func recognizeText(in data: Data) async throws -> String
}

public enum ImageTextRecognitionError: Error { case invalidImage, recognitionFailed }

/// All Vision work (including image decoding) runs off the UI thread. Captures and
/// recognized content never leave memory or enter diagnostics.
public struct VisionImageTextRecognizer: ImageTextRecognizing {
    private static let queue = DispatchQueue(label: "com.personal.TopDrop.ocr", qos: .userInitiated)
    public init() {}

    public static func languages(preferred: [String], supported: [String]) -> [String] {
        var result: [String] = []
        // Chinese models also recognize Latin glyphs. Putting a Latin-only
        // model first can turn short Chinese runs in mixed screenshots into
        // Latin guesses even when automatic detection is enabled.
        for language in ["zh-Hans", "zh-Hant"] + preferred + ["en-US"] {
            let match =
                supported.first { $0 == language }
                ?? supported.first { $0.split(separator: "-").first == language.split(separator: "-").first }
            if let match, !result.contains(match) { result.append(match) }
        }
        return result
    }

    public func recognizeText(in data: Data) async throws -> String {
        try Task.checkCancellation()
        let cancellation = OCRCancellation()
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async {
                    do {
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
                        else {
                            throw ImageTextRecognitionError.invalidImage
                        }
                        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
                        let rawOrientation = (properties?[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
                        let orientation = CGImagePropertyOrientation(rawValue: rawOrientation) ?? .up
                        let request = VNRecognizeTextRequest()
                        cancellation.attach(request)
                        defer { cancellation.detach() }
                        request.recognitionLevel = .accurate
                        request.automaticallyDetectsLanguage = true
                        request.usesLanguageCorrection = false
                        request.recognitionLanguages = Self.languages(
                            preferred: Locale.preferredLanguages,
                            supported: try request.supportedRecognitionLanguages()
                        )
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        try VNImageRequestHandler(cgImage: image, orientation: orientation).perform([request])
                        guard !cancellation.isCancelled else { throw CancellationError() }
                        // Preserve Vision's reading order and line boundaries; do not
                        // sort columns solely by Y or apply prose/code correction.
                        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                        continuation.resume(returning: lines.joined(separator: "\n"))
                    } catch {
                        continuation.resume(
                            throwing: error is CancellationError
                                ? CancellationError() : ImageTextRecognitionError.recognitionFailed)
                    }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
        try Task.checkCancellation()
        return text
    }
}

private final class OCRCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var request: VNRequest?
    var isCancelled: Bool { lock.withLock { cancelled } }
    func attach(_ request: VNRequest) {
        let shouldCancel = lock.withLock {
            self.request = request; return cancelled
        }
        if shouldCancel { request.cancel() }
    }
    func detach() { lock.withLock { request = nil } }
    func cancel() {
        let active = lock.withLock {
            cancelled = true; return request
        }
        active?.cancel()
    }
}

public enum ImageTextCopyState: Equatable, Sendable {
    case idle, recognizing, copied, noText, failed
    public var message: String {
        switch self {
        case .idle: "Copy Text from Image"
        case .recognizing: "Recognizing Text…"
        case .copied: "Text Copied"
        case .noText: "No Text Found"
        case .failed: "Could Not Copy Text — Retry"
        }
    }
}

/// One action owner per image view/editor. Immutable load closures identify the
/// original image; generation checks prevent stale results from changing pasteboard.
@MainActor
public final class ImageTextCopyController: ObservableObject {
    @Published public private(set) var state: ImageTextCopyState = .idle
    private let recognizer: any ImageTextRecognizing
    private var generation = UUID()
    private var task: Task<Void, Never>?
    public init(recognizer: any ImageTextRecognizing = VisionImageTextRecognizer()) { self.recognizer = recognizer }
    deinit { task?.cancel() }

    @discardableResult
    public func copy(
        load: @escaping @MainActor () async throws -> Data,
        write: @escaping @MainActor (String) async throws -> Void
    ) -> Task<Void, Never>? {
        guard state != .recognizing else { return nil }
        cancel()
        let token = generation
        state = .recognizing
        task = Task { [weak self, recognizer] in
            do {
                let data = try await load()
                try Task.checkCancellation()
                let text = try await recognizer.recognizeText(in: data)
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    self.state = .noText
                    return
                }
                // MainActor writer starts the synchronous pasteboard transaction
                // before its first suspension; no intervening UI change can race it.
                try await write(text)
                guard self.generation == token, !Task.isCancelled else { return }
                self.state = .copied
            } catch is CancellationError {
                if let self, self.generation == token { self.state = .idle }
            } catch {
                if let self, self.generation == token, !Task.isCancelled { self.state = .failed }
            }
        }
        return task
    }

    public func cancel() {
        generation = UUID()
        task?.cancel()
        task = nil
        state = .idle
    }
}
