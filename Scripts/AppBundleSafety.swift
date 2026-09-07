import Darwin
import Foundation

/// Exact executable paths, not process names: other TopDrop checkouts may keep running.
func requireStopped(_ bundle: URL) throws {
    let prefix = bundle.resolvingSymlinksInPath().standardizedFileURL.path + "/"
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { throw SafetyError("Could not inspect running processes") }
    var pids = [pid_t](repeating: 0, count: Int(count) + 256)
    let actual = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
    guard actual > 0, actual < pids.count else { throw SafetyError("Process list changed; retry") }
    for pid in pids.prefix(Int(actual)) where pid > 0 {
        // PROC_PIDPATHINFO_MAXSIZE is a C expression macro (4 * MAXPATHLEN).
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let size = buffer.withUnsafeMutableBytes { proc_pidpath(pid, $0.baseAddress, UInt32($0.count)) }
        if size > 0 {
            let executable = URL(fileURLWithPath: String(cString: buffer)).resolvingSymlinksInPath().path
            if executable.hasPrefix(prefix) { throw SafetyError("Quit the target TopDrop app before replacing it") }
        }
    }
}
struct SafetyError: Error, CustomStringConvertible {
    let description: String; init(_ text: String) { description = text }
}

#if !APP_BUNDLE_LIBRARY
    @main
    struct AppBundleSafety {
        static func main() {
            do {
                guard CommandLine.arguments.count == 2 else { throw SafetyError("usage: AppBundleSafety <app-path>") }
                try requireStopped(URL(fileURLWithPath: CommandLine.arguments[1]))
            } catch { fputs("TopDrop: \(error)\n", stderr); exit(1) }
        }
    }
#endif
