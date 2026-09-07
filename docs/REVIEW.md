# Source-readiness review — 2026-09-06

## Scope

Staged cleanup, not a replacement architecture. Bundle ID, Keychain services,
archive schemas, Notes bindings, shelf identities and user data stay unchanged.
The owner explicitly approved GPL-3.0 to replace the remote repository's initial
Apache-2.0 license. The initial Git commit is retained without rewriting history.

## Fixed regressions

1. Unreadable encrypted clipboard archives could be overwritten. Writes now wait
   for successful load/recovery; session clips merge on Retry History Recovery.
2. Failed pasteboard writes could leave a false Current badge after clearing the
   native clipboard. Current now invalidates without rolling back over other apps.
3. Notes worker deadlines did not cover inherited pipes. Nonblocking bounded pipe
   I/O now shares the process deadline; no indefinite drain wait.
4. Canceled queued Notes mutations could still execute. Cancellation is checked
   before launch; dispatched mutations retain uncertain-outcome semantics.
   The worker begins parent-liveness monitoring before reading its request.

All four regressions failed before the fixes and passed afterward.
The complete custom Swift runner passes **165/165** tests locally.

Clean-runner retesting also exposed partial screenshot files whose metadata
stopped changing before their image container was complete. Stabilization now
checks image readiness, and the partial-write test deliberately pauses longer
than the metadata window before completing its fixture.

## Cleanup

- Clipboard UI split into root/status/utilities/rows; annotation UI split into
  root/inspector/canvas. Removed declaration-only ScreenshotColumnView and unused
  ArrivalWatchBanner. No user screenshot files were removed.
- ScreenshotLibrary clipboard cache, editing and storage split into actor-isolated
  extensions; Keep Awake and Hidden Files split into their own providers.
- Shared Swift formatting, explicit source allowlist, privacy/architecture/
  contributor docs, bug template, pinned read-only macos-26 CI.
- Build helpers reconnected and tested. Publication uses validated atomic swaps,
  rejects unrelated files/symlinks and running target bundles.
- Installation retains the previous bundle; uninstall uses Trash. Neither kills
  apps, resets permissions nor deletes local user data.

## Automated evidence

- 165 Swift regressions, strict formatter and debug app build: passed locally.
- Build-lock 3/3; atomic publisher 7/7; exact-target runtime policy 3/3: passed.
- Isolated install/reinstall/backup/invalid-source/symlink tests: 5/5 passed.
- Clean-source validation exposed Foundation's temporary-path normalization;
  release helpers now compare actual filesystem paths. A CI-only watch-test
  timing assumption was replaced with a bounded wait for the real transition.
- Source credential/path/generated-file audit: passed (heuristic, not formal).
- Independent source-ZIP rebuild in a temporary path containing spaces: passed,
  including all 165 regressions and package verification. Both binaries are
  arm64, hardened, signature-valid and retain Apple Events entitlement; ZIPs
  pass integrity checks. The archive matches all 140 tracked source files.
- GitHub's clean macos-26 runner passed the complete pipeline at application
  commit \`5a1a7bd\` ([run](https://github.com/RingoMao/Topdrop/actions/runs/34074182110)).
  Official Actions were subsequently pinned to Node-24-based v7.0.1 to remove
  deprecated-runtime warnings. Package verification does not prove device behavior.

## Remaining release gates

This is **source-ready**, not a notarized public binary release. Ad-hoc hardened
signatures are for local testing and can require TCC reauthorization. Developer
ID, notarization, upgrade testing and human acceptance remain release gates.

The QA checklists separately track iPhone/iPad Notes sync, real Universal
Clipboard, all displays/notches/Spaces, VoiceOver, permissions and power behavior.
This cleanup does not claim new end-to-end verification of those cases.

macOS exposes neither cloud delivery nor clipboard provenance. Pasteboard writes
are not atomic against other apps. The five-second AppKit reply cannot execute
while the main run loop is completely blocked. Runtime checks prevent accidental
replacement but cannot lock out a user launching between final check and rename.
