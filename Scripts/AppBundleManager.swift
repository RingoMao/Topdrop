import Darwin
import Foundation

@main
struct AppBundleManager {
    static let fm = FileManager.default
    static func validate(_ app: URL) throws {
        let values = try app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
            app.pathExtension == "app",
            Bundle(url: app)?.bundleIdentifier == "com.personal.TopDrop"
        else { throw SafetyError("Refusing a non-TopDrop bundle or symbolic target") }
    }
    static func checkSignature(_ app: URL) throws {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        task.arguments = ["--verify", "--deep", "--strict", app.path]
        try task.run(); task.waitUntilExit()
        guard task.terminationStatus == 0 else { throw SafetyError("App signature verification failed") }
    }
    static func main() {
        do {
            let args = Array(CommandLine.arguments.dropFirst())
            guard args.count >= 2 else {
                throw SafetyError("usage: AppBundleManager install <source> <target> | trash <target>")
            }
            let mode = args[0]
            if mode == "trash", args.count == 2 {
                let target = URL(fileURLWithPath: args[1])
                try validate(target); try requireStopped(target)
                var trashed: NSURL?
                try fm.trashItem(at: target, resultingItemURL: &trashed)
                print("Moved TopDrop to Trash; Notes, history and settings were kept.")
                return
            }
            guard mode == "install", args.count == 3 else { throw SafetyError("Invalid operation") }
            let source = URL(fileURLWithPath: args[1])
            let target = URL(fileURLWithPath: args[2])
            guard target.lastPathComponent == "TopDrop.app",
                target.path != source.path,
                !source.path.hasPrefix(target.path + "/")
            else { throw SafetyError("Invalid installation target") }
            let parent = target.deletingLastPathComponent()
            guard canonicalPath(parent.path) == parent.path,
                fm.fileExists(atPath: parent.path)
            else { throw SafetyError("Installation parent must exist and not be symbolic") }
            try validate(source); try checkSignature(source); try requireStopped(target)
            let exists = fm.fileExists(atPath: target.path)
            if exists { try validate(target) }
            let stage = parent.appendingPathComponent(".TopDrop.backup-" + UUID().uuidString + ".app")
            try fm.copyItem(at: source, to: stage)
            var committed = false
            defer { if !committed { try? fm.removeItem(at: stage) } }
            try validate(stage); try checkSignature(stage); try requireStopped(target)
            let flags = UInt32((exists ? RENAME_SWAP : RENAME_EXCL) | RENAME_NOFOLLOW_ANY)
            guard renamex_np(stage.path, target.path, flags) == 0 else {
                throw SafetyError("Atomic install failed; the prior app is unchanged")
            }
            committed = true
            print("Installed " + target.path)
            if exists { print("Previous app retained at " + stage.path) }
        } catch { fputs("TopDrop: \(error)\n", stderr); exit(1) }
    }
}
