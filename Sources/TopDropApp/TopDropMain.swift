@preconcurrency import AppKit
import Foundation
import OSLog
import TopDropCore

@main
enum TopDropMain {
    @MainActor
    static func main() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
        _ = delegate
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var coordinator: ApplicationCoordinator?
    private var terminationInProgress = false
    private var terminationReplyArbiter = TopDropTerminationReplyArbiter()
    private var terminationCleanupTask: Task<Void, Never>?
    private var terminationDeadlineTask: Task<Void, Never>?
    private let logger = Logger(
        subsystem: TopDropCore.bundleIdentifier,
        category: "Termination"
    )

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            let coordinator = ApplicationCoordinator(
                screenshotLibrary: try ScreenshotLibrary()
            )
            self.coordinator = coordinator
            coordinator.start()
        } catch {
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = "TopDrop Could Not Start"
            alert.informativeText = error.localizedDescription
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let coordinator else { return .terminateNow }
        guard !terminationInProgress else { return .terminateLater }
        terminationInProgress = true
        coordinator.beginTermination()
        logger.info("Quit requested; starting bounded cleanup")

        terminationCleanupTask = Task { [weak self, weak sender] in
            await coordinator.finishTerminationCleanup()
            guard let self, let sender else { return }
            self.completeTermination(
                reason: .cleanupCompleted,
                sender: sender
            )
        }
        terminationDeadlineTask = Task { [weak self, weak sender] in
            do {
                try await Task.sleep(
                    for: .seconds(TopDropTerminationPolicy.deadline)
                )
            } catch {
                return
            }
            guard let self, let sender else { return }
            self.completeTermination(
                reason: .deadlineReached,
                sender: sender
            )
        }
        return .terminateLater
    }

    private func completeTermination(
        reason: TopDropTerminationReason,
        sender: NSApplication
    ) {
        guard terminationReplyArbiter.claim(reason) else { return }
        switch reason {
        case .cleanupCompleted:
            terminationDeadlineTask?.cancel()
            logger.info("Termination cleanup completed before deadline")
        case .deadlineReached:
            terminationCleanupTask?.cancel()
            logger.error("Termination cleanup exceeded five-second deadline; exiting")
        }
        sender.reply(toApplicationShouldTerminate: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
