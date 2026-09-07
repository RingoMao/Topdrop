import CoreServices
import Foundation

enum FSEventFolderWatcherError: Error {
    case streamCreationFailed
    case streamStartFailed
}

/// Small ownership wrapper around the C FSEvents API. The callback never
/// performs I/O; it only forwards paths to the ScreenshotLibrary actor.
final class FSEventFolderWatcher: @unchecked Sendable {
    private final class CallbackBox: @unchecked Sendable {
        let handler: @Sendable ([String]) -> Void

        init(handler: @escaping @Sendable ([String]) -> Void) {
            self.handler = handler
        }
    }

    private let callbackBox: CallbackBox
    private var stream: FSEventStreamRef?

    init(
        folderURL: URL,
        latency: CFTimeInterval = 0.2,
        handler: @escaping @Sendable ([String]) -> Void
    ) throws {
        callbackBox = CallbackBox(handler: handler)
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                { _, info, count, rawPaths, _, _ in
                    guard let info else { return }
                    let box = Unmanaged<CallbackBox>.fromOpaque(info).takeUnretainedValue()
                    let pointers = rawPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
                    var paths: [String] = []
                    paths.reserveCapacity(count)
                    for index in 0..<count {
                        if let pointer = pointers[index] {
                            paths.append(String(cString: pointer))
                        }
                    }
                    box.handler(paths)
                },
                &context,
                [folderURL.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        else {
            throw FSEventFolderWatcherError.streamCreationFailed
        }
        stream = created
        FSEventStreamSetDispatchQueue(created, DispatchQueue(label: "com.personal.TopDrop.screenshot-events"))
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            stream = nil
            throw FSEventFolderWatcherError.streamStartFailed
        }
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
