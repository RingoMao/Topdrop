# Dev Tools validation — 2026-09-06

## Automated

- Full regression suite: 161/161 passed (`Scripts/run-tests.sh`).
- Tests cover layout thresholds, assertion lifecycle/failure/idempotence with a
  fake provider, hidden preference parsing, denied permission, failed activation,
  cancellation, one-shot shortcut delivery, unconfirmed state, and injected
  keyboard layouts (including a shifted-only period).
- Every template was parsed/inspected, including one-page A4 PDF, empty AppKit RTF,
  JSON and plist dictionaries, and no executable bits on scripts.
- Clipboard tests cover one write per file, unchanged state on generation/write
  failure, missing-source regeneration without duplicate history identity,
  encrypted archive round-trip/migration, and no Universal Clipboard watch success.
- A real isolated named NSPasteboard round-tripped the generated URL as NSURL.
- Cleanup tests protect retained files, incomplete reference censuses, and unknown
  files; production retention remains conservative rather than guessing references.

## UI and Finder checks

- Offscreen snapshots inspected at 700/850/1200/1320 points and light/dark appearance.
  The isolated harness disables native status-item installation and does not load
  user Notes, settings, or clipboard history. Its Notes permission empty state is
  intentional, not a live account result.
- Real Finder Command-V pasted `Untitled.txt` into a dedicated local test folder.
- A second paste presented Finder's collision dialog; Keep Both preserved the
  original and created `Untitled 2.txt`.
- Real Finder Command-V pasted a valid `Untitled.pdf` into the dedicated iCloud
  folder `TopDrop-DevTools-Test-20260906-es1lRe`. Finder showed Waiting to Upload:
  file creation is verified; remote-device receipt/upload completion is not.
- The file-paste probe used the same template store and system pasteboard writer
  as production. It preserved the original clipboard only in memory and restored
  it after testing. These checks do not claim a click-through test of the packaged
  Dev Tools UI.

## Remaining manual acceptance

Accessibility grant/revoke in the packaged app, physical non-US keyboards, actual
Keep Awake idle/sleep behavior, VoiceOver, different physical displays/scaling,
read-only destination UI, move-paste, and pasting after quitting the packaged app
remain manual checks. Deterministic tests are not substitutes for these checks.

The running OCR build is not replaced. Release output is isolated under
`dist/dev-tools-update`. Test files are confined to dedicated directories; no
existing Finder destination file was overwritten or removed.
