import Foundation

/// Conversion rules shared by the AppleScript provider and the editor.
public enum NotesTextConverter {
    /// Notes' HTML-to-plaintext bridge can append one structural paragraph terminator.
    /// Do not trim: intentional trailing newlines, spaces and tabs remain significant.
    public static func matchesReadback(_ actual: String, expected: String) -> Bool {
        let actual = normalizeLineEndings(actual), expected = normalizeLineEndings(expected)
        return actual == expected || actual == expected + "\n"
    }
    public static let untitledTitle = "Untitled"

    /// Normalizes line endings without otherwise trimming the user's text.
    public static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// Splits Notes' `plaintext` property into TopDrop's title and body fields.
    /// The first line is always the title; every subsequent line is the body.
    public static func split(_ plainText: String) -> NotesDraft {
        let normalized = normalizeLineEndings(plainText)
        guard let newline = normalized.firstIndex(of: "\n") else {
            return NotesDraft(title: normalized.isEmpty ? untitledTitle : normalized, body: "")
        }

        let title = String(normalized[..<newline])
        let bodyStart = normalized.index(after: newline)
        let body = String(normalized[bodyStart...])
        return NotesDraft(title: title.isEmpty ? untitledTitle : title, body: body)
    }

    /// Combines editor fields into the exact plain-text form TopDrop expects from Notes.
    public static func join(title: String, body: String) -> String {
        let normalizedTitle = normalizeTitle(title)
        let normalizedBody = normalizeLineEndings(body)
        return normalizedBody.isEmpty ? normalizedTitle : "\(normalizedTitle)\n\(normalizedBody)"
    }

    /// Produces minimal, safely escaped HTML accepted by Notes' writable `body` property.
    /// No rich-text tags, links, scripts, or attachment markup are emitted.
    public static func minimalHTML(title: String, body: String) -> String {
        let plainText = join(title: title, body: body)
        let lines = plainText.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line in
            if line.isEmpty {
                return "<div><br></div>"
            }
            // Preserve literal spaces/tabs without replacing them with different Unicode characters.
            return "<div style=\"white-space:pre-wrap\">\(escapeHTML(String(line)))</div>"
        }.joined()
    }

    /// Escapes every character that can affect HTML parsing.
    public static func escapeHTML(_ text: String) -> String {
        var result = String()
        result.reserveCapacity(text.utf8.count)

        for character in text {
            switch character {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case "'": result += "&#39;"
            case "\t": result += "&#9;"
            default:
                // NUL and C0 controls other than tab are invalid in HTML text nodes.
                if let scalar = character.unicodeScalars.first,
                    character.unicodeScalars.count == 1,
                    scalar.value < 0x20
                {
                    continue
                }
                result.append(character)
            }
        }
        return result
    }

    private static func normalizeTitle(_ title: String) -> String {
        let normalized = normalizeLineEndings(title)
        let singleLine = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .joined(separator: " ")
        return singleLine.isEmpty ? untitledTitle : singleLine
    }
}
