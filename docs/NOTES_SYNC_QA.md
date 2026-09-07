# Notes reliability verification — 2026-09-05

## Verified automatically

- Full suite: 135/135 passing, using synthetic Notes providers and temporary files.
- Regression coverage includes refresh/input races, cross-note writes, newer drafts
  during save, old-folder callbacks, incomplete lists, protected notes, missing notes,
  crash recovery, uncertain creation/update, and readback failure after a known creation.
- AES-GCM round-trip, authenticated corruption detection and preservation of the
  original unreadable archive.
- Worker runs on the main thread; every bundled Notes script compiles in the worker.
- Worker request serialization, pre-launch failure and forced timeout/reaping.
- Apple's Foundation HTML importer preserves the synthetic spaces, tabs, blank
  lines, Chinese, emoji and escaped markup. This is not a Notes.app round-trip test.

The full suite needs access to Apple's `com.apple.textkit.nsattributedstringagent`
service. A restricted command sandbox blocks the HTML test with Cocoa error 4099;
the complete suite passes when run outside that command sandbox.

## Still requires user permission / real-device verification

- Packaged worker non-prompting preflight returned `promptRequired`.
- Real Notes CRUD, offline recovery and GUI-launched worker TCC attribution were
  not marked passed; no real notes were changed by this verification.
- Mac↔iPhone/iPad arrival, Notes-specific HTML normalization, allow/deny/re-enable
  and cold launch must be checked using the exact installed app and a dedicated
  test folder. Local readback is not evidence of iCloud delivery.
- UI/VoiceOver testing and interacting with the user's actual existing notes remain
  manual checklist items in `MANUAL_QA.md`.

Install the complete `dist/TopDrop.app`, then use Settings > Notes > Request /
Recheck Permission. Allow Notes Automation if macOS prompts. The separate recovery
key uses Keychain service `com.personal.TopDrop.notes`; its authorization is cached
for that process lifetime. A denied key never causes plaintext fallback.

## Packaging

The release build script signs both TopDrop and its on-demand Notes worker with
hardened runtime and the Apple Events entitlement. The worker has the stable code
identifier `com.personal.TopDrop.NotesWorker`. The fixture worker is test-only and
is not copied into the app. No privileged helper, LaunchAgent or new permission
category is introduced. App/source ZIPs are verified by the packaging script.
