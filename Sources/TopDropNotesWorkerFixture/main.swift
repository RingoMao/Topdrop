// Test-only subprocess. Never included in TopDrop.app.
import Foundation
import Darwin
let data = FileHandle.standardInput.readDataToEndOfFile()
let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
if request?["folderName"] as? String == "inherited-pipe" {
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["2"]
    child.standardOutput = FileHandle.standardOutput
    try child.run()
    exit(0)
}
let delay = request?["folderName"] as? String == "hang" ? 60.0 : 0.1
Thread.sleep(forTimeInterval: delay)
try FileHandle.standardOutput.write(contentsOf: Data("{\"mainThread\":true}".utf8))
