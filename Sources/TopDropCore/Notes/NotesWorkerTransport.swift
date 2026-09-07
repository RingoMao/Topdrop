import Darwin
import Foundation

/// Serial worker channel. Nonblocking pipe I/O shares the process deadline;
/// an inherited pipe can never leave a drain task waiting indefinitely.
public final class NotesWorkerTransport: NotesWorkerTransporting, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.personal.TopDrop.notes-worker", qos: .utility)
    private let executable: URL
    private let timeout: TimeInterval
    private let maximumMessageBytes = 64 * 1_024 * 1_024

    public init(executable: URL? = nil, timeout: TimeInterval = 30) {
        self.executable =
            executable
            ?? (Bundle.main.executableURL ?? URL(fileURLWithPath: "/unavailable"))
            .deletingLastPathComponent().appendingPathComponent("TopDropNotesWorker")
        self.timeout = timeout.isFinite ? max(0.05, timeout) : 30
    }

    public func perform(_ request: NotesWorkerRequest) async throws -> NotesWorkerResponse {
        try Task.checkCancellation()
        let data = try JSONEncoder().encode(request)
        guard data.count <= maximumMessageBytes else { throw NotesProviderError.incompleteRead }
        let cancellation = WorkerCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in
                    do {
                        continuation.resume(
                            returning: try run(data, mutation: request.operation.isMutation, cancellation: cancellation)
                        )
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func run(_ data: Data, mutation: Bool, cancellation: WorkerCancellation) throws -> NotesWorkerResponse {
        guard !cancellation.isCancelled else { throw CancellationError() }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw NotesProviderError.workerUnavailable
        }
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = executable
        process.arguments = []
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        let readHandle = output.fileHandleForReading, writeHandle = input.fileHandleForWriting
        let readFD = readHandle.fileDescriptor, writeFD = writeHandle.fileDescriptor
        guard fcntl(readFD, F_SETFL, O_NONBLOCK) != -1,
            fcntl(writeFD, F_SETFL, O_NONBLOCK) != -1,
            fcntl(writeFD, F_SETNOSIGPIPE, 1) != -1
        else { throw NotesProviderError.workerUnavailable }
        var inputClosed = false
        defer {
            if !inputClosed { try? writeHandle.close() }
            try? readHandle.close()
            if process.isRunning {
                // Only the still-owned worker. Foundation reaps the process;
                // never wait synchronously beyond this request's deadline.
                kill(process.processIdentifier, SIGKILL)
            }
        }
        guard !cancellation.isCancelled else { throw CancellationError() }
        do { try process.run() } catch { throw NotesProviderError.workerUnavailable }
        try? input.fileHandleForReading.close()
        try? output.fileHandleForWriting.close()
        var written = 0, received = Data()
        var eof = false
        var buffer = [UInt8](repeating: 0, count: 65_536)
        let uncertain: NotesProviderError = mutation ? .resultUncertain : .notesUnavailable
        while true {
            guard !cancellation.isCancelled, ContinuousClock.now < deadline else { throw uncertain }
            var progressed = false
            if !inputClosed {
                let count = data.withUnsafeBytes { bytes in
                    Darwin.write(writeFD, bytes.baseAddress!.advanced(by: written), data.count - written)
                }
                if count > 0 {
                    written += count; progressed = true
                } else if count < 0 && errno != EAGAIN && errno != EINTR {
                    throw uncertain
                }
                if written == data.count { try? writeHandle.close(); inputClosed = true }
            }
            if !eof {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress!, $0.count) }
                if count > 0 {
                    guard received.count + count <= maximumMessageBytes else { throw uncertain }
                    received.append(contentsOf: buffer.prefix(count))
                    progressed = true
                } else if count == 0 {
                    eof = true
                } else if errno != EAGAIN && errno != EINTR {
                    throw uncertain
                }
            }
            if eof && !process.isRunning {
                guard inputClosed, process.terminationStatus == 0 else { throw uncertain }
                do { return try JSONDecoder().decode(NotesWorkerResponse.self, from: received) } catch {
                    throw mutation ? NotesProviderError.resultUncertain : NotesProviderError.incompleteRead
                }
            }
            if !progressed { Thread.sleep(forTimeInterval: 0.002) }
        }
    }
}

private final class WorkerCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}
