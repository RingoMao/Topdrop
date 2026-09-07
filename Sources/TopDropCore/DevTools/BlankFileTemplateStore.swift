import AppKit
import CoreGraphics
import Foundation

public enum BlankFileTemplate: String, Codable, CaseIterable, Sendable {
    case txt, markdown, pdf, rtf, json, yaml, csv, python, shell, html, plist

    public static let primary: [Self] = [.txt, .markdown, .pdf, .rtf, .json, .yaml]
    public static let more: [Self] = [.csv, .python, .shell, .html, .plist]
    public var title: String {
        switch self {
        case .markdown: "Markdown"
        case .python: "Python"
        case .shell: "Shell"
        case .plist: "Plist"
        default: rawValue.uppercased()
        }
    }
    public var fileExtension: String {
        switch self {
        case .markdown: "md"
        case .python: "py"
        case .shell: "sh"
        default: rawValue
        }
    }
}

@MainActor
public protocol BlankFileTemplateProviding {
    func create(_ template: BlankFileTemplate) throws -> URL
}

/// Contains only generated blank documents, never destination copies. Retention
/// is deliberately conservative: exit and history eviction do not delete files,
/// since Finder may still be using a previously copied URL.
@MainActor
public final class BlankFileTemplateStore: BlankFileTemplateProviding {
    public let directory: URL

    public init(directory: URL? = nil) {
        self.directory =
            directory
            ?? FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            )[0].appendingPathComponent("TopDrop/BlankFiles", isDirectory: true)
    }

    public func create(_ template: BlankFileTemplate) throws -> URL {
        let data = try Self.contents(for: template)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: folder, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let file = folder.appendingPathComponent("Untitled.\(template.fileExtension)")
        try data.write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    public static func contents(for template: BlankFileTemplate) throws -> Data {
        switch template {
        case .txt, .markdown, .yaml, .csv, .python, .shell: return Data()
        case .json: return Data("{}\n".utf8)
        case .html:
            return Data(
                "<!doctype html>\n<html lang=\"en\">\n<head><meta charset=\"utf-8\"><title></title></head>\n<body></body>\n</html>\n"
                    .utf8)
        case .plist:
            return try PropertyListSerialization.data(fromPropertyList: [String: String](), format: .xml, options: 0)
        case .rtf:
            return try NSAttributedString(string: "").data(
                from: NSRange(location: 0, length: 0),
                documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        case .pdf:
            let output = NSMutableData()
            var box = CGRect(x: 0, y: 0, width: 595.2756, height: 841.8898)
            guard let consumer = CGDataConsumer(data: output),
                let context = CGContext(consumer: consumer, mediaBox: &box, nil)
            else {
                throw CocoaError(.fileWriteUnknown)
            }
            context.beginPDFPage(nil)
            context.endPDFPage()
            context.closePDF()
            return output as Data
        }
    }

    /// Call only with a complete reference census (including the actual system
    /// clipboard). Never call when encrypted history could not be loaded.
    public func removeUnreferencedFiles(references: Set<URL>, censusIsComplete: Bool) throws {
        guard censusIsComplete else { return }
        let fm = FileManager.default
        guard fm.fileExists(atPath: directory.path) else { return }
        let retained = Set(references.map { $0.standardizedFileURL })
        for folder in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            guard UUID(uuidString: folder.lastPathComponent) != nil,
                try folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true
            else { continue }
            let files = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isSymbolicLinkKey])
            // Only delete the exact single-file shape created by this store.
            guard files.count == 1, let file = files.first,
                BlankFileTemplate.allCases.contains(where: { file.lastPathComponent == "Untitled.\($0.fileExtension)" }
                ),
                try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true,
                !retained.contains(file.standardizedFileURL)
            else { continue }
            try fm.removeItem(at: file)
            try fm.removeItem(at: folder)
        }
    }
}
