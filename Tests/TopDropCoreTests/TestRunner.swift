import Foundation
import TopDropCore

@main
enum TopDropTestRunner {
    static func main() async {
        let allTests =
            coreTests + gestureTests + notesTests + notesSyncTests + clipboardTests + screenshotTests + annotationTests
            + onboardingTests + menuBarShelfTests + unifiedMediaFeedTests + trayPanelLayoutTests
            + screenColorSamplerTests + imageTextRecognitionTests + devToolsTests
        let filters = CommandLine.arguments.dropFirst()
        let tests =
            filters.isEmpty
            ? allTests
            : allTests.filter { test in
                filters.contains { test.name.localizedCaseInsensitiveContains($0) }
            }
        guard !tests.isEmpty else {
            print("No tests matched: \(filters.joined(separator: ", "))")
            exit(EXIT_FAILURE)
        }
        var failures = 0
        let started = ContinuousClock.now

        for test in tests {
            do {
                try await test.body()
                print("PASS  \(test.name)")
            } catch {
                failures += 1
                print("FAIL  \(test.name): \(error)")
            }
        }

        let duration = started.duration(to: .now)
        print("\n\(tests.count - failures)/\(tests.count) tests passed in \(duration)")
        if failures > 0 {
            exit(EXIT_FAILURE)
        }
    }
}
