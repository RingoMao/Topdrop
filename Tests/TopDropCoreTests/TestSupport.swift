import Foundation
import TopDropCore

struct UnitTest: Sendable {
    let name: String
    let body: @Sendable () async throws -> Void

    init(_ name: String, body: @escaping @Sendable () async throws -> Void) {
        self.name = name
        self.body = body
    }
}

struct TestFailure: Error, CustomStringConvertible, Sendable {
    let description: String
}

@inline(__always)
func expect(
    _ condition: @autoclosure () -> Bool,
    _ message: @autoclosure () -> String = "Expectation failed",
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    guard condition() else {
        throw TestFailure(description: "\(file):\(line): \(message())")
    }
}

@inline(__always)
func expectEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    file: StaticString = #fileID,
    line: UInt = #line
) throws {
    let actualValue = actual()
    let expectedValue = expected()
    guard actualValue == expectedValue else {
        throw TestFailure(
            description:
                "\(file):\(line): expected \(String(describing: expectedValue)), got \(String(describing: actualValue))"
        )
    }
}

func expectThrows(
    file: StaticString = #fileID,
    line: UInt = #line,
    _ body: () async throws -> Void
) async throws {
    do {
        try await body()
        throw TestFailure(description: "\(file):\(line): expected an error")
    } catch is TestFailure {
        throw TestFailure(description: "\(file):\(line): expected a non-test error")
    } catch {
        return
    }
}

let coreTests: [UnitTest] = [
    UnitTest("Core constants") {
        try expectEqual(TopDropCore.maximumClipboardItemCount, 20)
        try expectEqual(TopDropCore.maximumClipboardPayloadBytes, 20_971_520)
    }
]
