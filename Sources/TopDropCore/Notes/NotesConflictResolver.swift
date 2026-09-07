import Foundation

/// The save policy for TopDrop's temporary-note workspace.
///
/// Apple Notes remains the durable store, but an editable draft currently open in TopDrop is
/// authoritative. External text edits are therefore overwritten without interrupting the user.
/// Apple Notes protection state is always authoritative and can still prevent a write.
public enum NotesWritePolicy {
    public enum Decision: Sendable, Equatable {
        case alreadyMatches
        case writeTopDropDraft(remoteChanged: Bool)
        case readOnly([NotesReadOnlyReason])
    }

    /// Allows insignificant floating-point noise from the Apple Event date bridge when reporting
    /// whether Apple Notes changed. The result is diagnostic only and never blocks an editable save.
    public static let defaultDateTolerance: TimeInterval = 0.01

    public static func decision(
        expectedModificationDate: Date,
        remote: NotesNote,
        local: NotesDraft,
        dateTolerance: TimeInterval = defaultDateTolerance
    ) -> Decision {
        guard !remote.isReadOnly else {
            return .readOnly(remote.readOnlyReasons)
        }
        guard remote.plainText != local.plainText else {
            return .alreadyMatches
        }
        let remoteChanged =
            abs(
                remote.modificationDate.timeIntervalSince(expectedModificationDate)
            ) > dateTolerance
        return .writeTopDropDraft(remoteChanged: remoteChanged)
    }
}
