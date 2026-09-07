# Privacy and data handling

TopDrop has no analytics SDK, telemetry endpoint or backend. It does not upload
OCR input or screen-picker pixels. Apple Notes/iCloud and user-invoked Shortcuts
operate under their own service/privacy policies.

| Data | Handling |
| --- | --- |
| Clipboard history | Latest 20 distinct clips by capture/activation; AES-GCM archive, local Keychain key. Exclusions, size limits and pause enforced. |
| Unsaved Notes drafts | Encrypted local recovery journal only, separate non-synchronizing Keychain key; confirmed revisions removed. |
| Apple Notes library | Public AppleScript through one isolated worker request at a time. Body is carried over anonymous pipes, not arguments or logs. |
| Clipboard image cache | Managed encrypted transient cache; explicitly saved edit projects/exports are ordinary local files. |
| Color picker / OCR | In-memory processing; picker needs Screen Recording, OCR on supplied image data does not. |
| Blank file templates | Ordinary files in local Application Support; kept while referenced so Finder paste works after quit. |
| Logs | Operation/status/count diagnostics only; never payloads, note bodies or key material. |

Paths and identifiers are documented in the user guide. They remain unchanged in
this cleanup. A failed history load now blocks archive writes and offers Retry
History Recovery; new clips remain session-only until recovery succeeds.

Accessibility is optional for sending Finder's hidden-files shortcut; denial
leaves manual shortcut instructions. Input Monitoring is separate, for the global
edge gesture. Notes Automation authorization may need reapproval after an ad-hoc
rebuild. No build/install script resets permissions or deletes encryption keys.

TopDrop cannot prove a clip came from another device, nor confirm cloud delivery
after writing Apple Notes. Do not interpret its status labels as such proof.
