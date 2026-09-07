import Foundation
import TopDropCore

let notesTests: [UnitTest] = [
    UnitTest("Notes conversion: first line is title and remainder is body") {
        let fields = NotesTextConverter.split("Shopping\r\nMilk\rEggs\n")
        try expectEqual(fields.title, "Shopping")
        try expectEqual(fields.body, "Milk\nEggs\n")
        try expectEqual(fields.plainText, "Shopping\nMilk\nEggs\n")
    },
    UnitTest("Notes conversion: empty title receives a stable fallback") {
        try expectEqual(NotesTextConverter.split("").title, NotesTextConverter.untitledTitle)
        let fields = NotesTextConverter.split("\nBody")
        try expectEqual(fields.title, NotesTextConverter.untitledTitle)
        try expectEqual(fields.body, "Body")
    },
    UnitTest("Notes conversion: editor title is forced to one line") {
        let text = NotesTextConverter.join(title: "One\r\nTwo", body: "A\rB")
        try expectEqual(text, "One Two\nA\nB")
    },
    UnitTest("Notes conversion: minimal HTML escapes markup and keeps blank lines") {
        let html = NotesTextConverter.minimalHTML(
            title: "A<&\"'\nTitle",
            body: "one\n\n<script>&"
        )
        try expectEqual(
            html,
            "<div style=\"white-space:pre-wrap\">A&lt;&amp;&quot;&#39; Title</div><div style=\"white-space:pre-wrap\">one</div><div><br></div><div style=\"white-space:pre-wrap\">&lt;script&gt;&amp;</div>"
        )
        try expect(!html.contains("<script>"), "Unescaped markup reached Notes HTML")
    },
    UnitTest("Notes conversion: invalid HTML controls are dropped and tabs encoded") {
        try expectEqual(NotesTextConverter.escapeHTML("a\u{0}\tb"), "a&#9;b")
    },
    UnitTest("Notes models: protected note states are read-only") {
        let normal = makeTestNote()
        try expect(!normal.isReadOnly)

        let locked = makeTestNote(isLocked: true)
        try expect(locked.isReadOnly)
        try expectEqual(locked.readOnlyReasons, [.locked])

        let protected = makeTestNote(isShared: true, hasAttachments: true)
        try expect(protected.isReadOnly)
        try expectEqual(protected.readOnlyReasons, [.shared, .containsAttachments])
    },
    UnitTest("Notes write policy: a changed draft is saved even without an external edit") {
        let expected = Date(timeIntervalSince1970: 1_000)
        let remote = makeTestNote(title: "Remote", modificationDate: expected)
        let local = NotesDraft(title: "Local", body: "Body")
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: remote,
                local: local
            ),
            .writeTopDropDraft(remoteChanged: false)
        )
    },
    UnitTest("Notes write policy: TopDrop wins an external Apple Notes text edit") {
        let expected = Date(timeIntervalSince1970: 1_000)
        let remote = makeTestNote(
            title: "Apple Notes edit",
            body: "Remote body",
            modificationDate: expected.addingTimeInterval(5)
        )
        let local = NotesDraft(title: "My edit", body: "Local body")
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: remote,
                local: local
            ),
            .writeTopDropDraft(remoteChanged: true)
        )
    },
    UnitTest("Notes write policy: identical text avoids an unnecessary write") {
        let expected = Date(timeIntervalSince1970: 1_000)
        let local = NotesDraft(title: "Same", body: "Text")
        let remote = makeTestNote(
            title: local.title,
            body: local.body,
            modificationDate: expected.addingTimeInterval(20)
        )
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: remote,
                local: local
            ),
            .alreadyMatches
        )
    },
    UnitTest("Notes write policy: date tolerance only classifies remote-change diagnostics") {
        let expected = Date(timeIntervalSince1970: 1_000)
        let remote = makeTestNote(
            title: "Remote",
            modificationDate: expected.addingTimeInterval(0.005)
        )
        let local = NotesDraft(title: "Local", body: "")
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: remote,
                local: local
            ),
            .writeTopDropDraft(remoteChanged: false)
        )
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: remote,
                local: local,
                dateTolerance: 0.001
            ),
            .writeTopDropDraft(remoteChanged: true)
        )
    },
    UnitTest("Notes write policy: protected Apple Notes always remain read-only") {
        let expected = Date(timeIntervalSince1970: 1_000)
        let protected = makeTestNote(
            modificationDate: expected.addingTimeInterval(20),
            isShared: true,
            hasAttachments: true
        )
        try expectEqual(
            NotesWritePolicy.decision(
                expectedModificationDate: expected,
                remote: protected,
                local: NotesDraft(title: "Local", body: "Draft")
            ),
            .readOnly([.shared, .containsAttachments])
        )
    },
    UnitTest("Notes account: iCloud onboarding candidate is identified case-insensitively") {
        try expect(NotesAccount(id: "1", name: "iCLOUD", isUpgraded: true).isICloud)
        try expect(!NotesAccount(id: "2", name: "On My Mac", isUpgraded: true).isICloud)
    },
    UnitTest("Notes migration reads every same-named TopDrop folder") {
        let folders = [
            NotesFolder(id: "old", accountID: "icloud", name: "TopDrop", isShared: false),
            NotesFolder(id: "new", accountID: "icloud", name: "topdrop", isShared: false),
            NotesFolder(id: "other", accountID: "icloud", name: "Archive", isShared: false),
        ]
        try expectEqual(
            NotesFolderCompatibilityResolver.folderIDs(
                configuredFolderID: "new",
                configuredFolderName: "TopDrop",
                availableFolders: folders
            ),
            ["new", "old"]
        )
    },
    UnitTest("Notes migration keeps a stale configured folder as a recovery candidate") {
        try expectEqual(
            NotesFolderCompatibilityResolver.folderIDs(
                configuredFolderID: "stale",
                configuredFolderName: "TopDrop",
                availableFolders: [
                    NotesFolder(id: "recovered", accountID: "icloud", name: "TopDrop", isShared: false)
                ]
            ),
            ["stale", "recovered"]
        )
    },
]

private func makeTestNote(
    title: String = "Title",
    body: String = "Body",
    modificationDate: Date = Date(timeIntervalSince1970: 1_000),
    isLocked: Bool = false,
    isShared: Bool = false,
    hasAttachments: Bool = false
) -> NotesNote {
    NotesNote(
        id: "note-id",
        accountID: "account-id",
        folderID: "folder-id",
        title: title,
        body: body,
        creationDate: Date(timeIntervalSince1970: 900),
        modificationDate: modificationDate,
        isLocked: isLocked,
        isShared: isShared,
        hasAttachments: hasAttachments
    )
}
