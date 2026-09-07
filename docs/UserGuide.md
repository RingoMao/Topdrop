# TopDrop

TopDrop is an open-source Apple-silicon macOS 26 menu-bar utility built with Swift
6, AppKit, SwiftUI, SwiftPM, and Apple frameworks only. It combines temporary
Apple Notes, encrypted clipboard history, screenshot/image history, a compact
annotation editor, a live screen color picker, a native one-divider Scroll
Shelf, and reorderable TopDrop accessories.

TopDrop has no CloudKit database, network service, analytics, App Store
packaging or third-party runtime dependency. Hidden Files optionally uses Accessibility.

## Build

Requirements:

- Apple silicon and macOS 26 or newer.
- Full Xcode 26 or newer with the macOS 26 SDK selected by `xcode-select`.

```sh
cd TopDrop
Scripts/run-tests.sh
Scripts/build-app.sh
```

The build produces an ad-hoc signed, hardened arm64 app and archives:

- `dist/TopDrop.app`
- `dist/TopDrop.app.zip`
- `dist/TopDrop-source.zip`

Build first, then run `Scripts/install-app.sh` to install in `/Applications`.
Quit the destination app first. Installation retains the previous app as a hidden
backup and does not launch it or change permissions. Because this personal package has no Developer ID, the first launch
may require Control-click > Open or **System Settings > Privacy & Security >
Open Anyway**. Do not disable Gatekeeper globally.

## First run and permissions

1. Allow Apple Notes automation, choose an iCloud Notes account, and let
   TopDrop create or reuse its dedicated `TopDrop` folder. Apple Notes remains
   the source of truth; TopDrop never reads the private Notes database.
2. Choose a screenshot-only folder. Open Shift-Command-5 > Options > Save to >
   Other Location and select the same folder. TopDrop watches normal screenshot
   output; it does not capture screenshots itself.
3. Choose **Always Allow** for clipboard access so history and arrival watching
   work in the background.
4. Enable Input Monitoring if top-edge scrolling does not work outside TopDrop.
5. Allow Screen Recording only for Screen Color Picker. While active, it reads
   a tiny region under the pointer for the magnifier and `#RRGGBB` preview; the
   pixels are not retained.
6. Keychain may ask for the clipboard archive key and the separate Notes recovery
   key. Authorized keys stay cached in memory for that launch. Denied Notes key
   access is not retried per keystroke; use Notes > Recover > Retry Secure Draft Recovery.

## Notes reliability and recovery

Notes drafts are keyed by account and note ID, not the current selection or title.
Editing is debounced for 650 ms, with a separate revision-checked save queue.
TopDrop keeps your pending edits when refreshing or switching notes. Local edits
win text conflicts; untouched notes adopt Apple Notes changes without a version dialog.

Only pending drafts are encrypted locally in
`~/Library/Application Support/TopDrop/Notes/pending-drafts.enc`, using AES-GCM
and the non-synchronizing Keychain service `com.personal.TopDrop.notes`. This is
a crash-recovery journal, not another notes database. First edits schedule an
immediate write and later edits coalesce for at most 250 ms; the last input before
a sudden crash may not yet be durable. A denied/locked key keeps drafts in memory
and preserves existing ciphertext, with an explicit warning.

The app bundles `Contents/MacOS/TopDropNotesWorker`. It runs parameterized scripts
on its own main thread through anonymous pipes (no shell or osascript), with one
request at a time, a 10-second Apple Event timeout and a 30-second request deadline.
The complete app, including this worker and its resource bundle, must be installed.
The worker and app retain the Apple Events entitlement. Verify/regrant Notes
Automation from the installed app after an ad-hoc rebuild; do not assume a standalone
command-line worker has the same permission attribution as the installed app.

Saved means **written and read back from Apple Notes on this Mac**, not confirmed
delivery to iCloud or another device. TopDrop refreshes at startup, tray reveal,
activation/wake, and every 15 seconds while visible. Read failures preserve old
rows. Settings > Notes > Find Previous TopDrop Folders lists recovery candidates;
only **Use This Folder** changes your binding. No automatic same-name rebinding occurs.

An Apple Event timeout can happen after Notes has already applied a change.
Uncertain writes are retained and checked by ID, never blindly replayed. An
uncertain creation stays as a recovery draft: check Apple Notes before choosing
**Recover > Save Draft as New Note** (which can create a duplicate). Protected,
missing or incompletely read notes keep unsaved drafts for recovery. Successful
readback clears only the acknowledged revision. Quit remains bounded to five
seconds, with local recovery attempted before remote flushing.

## Everyday use

- Put the pointer within the configured top-edge distance and deliberately
  scroll down to reveal TopDrop on that display. Scroll up, press Escape, click
  outside, or use Hide to dismiss it.
- Notes opens either the searchable collection or one full-space temporary
  note. TopDrop autosaves editable drafts to Apple Notes; protected, shared,
  locked, and attachment-containing notes are read-only.
- Clipboard keeps the 20 most recently captured or activated distinct clips.
  Payloads are AES-GCM encrypted using a Keychain key. Items over 20 MB,
  consecutive duplicates, TopDrop-owned writes, and excluded applications are
  skipped.
- Clipboard filters are **All**, **Text**, and **Images**. Historical items can
  become the current clipboard with one click. Image items expose a separate
  editor action.
- **Aa** removes formatting from textual clipboard representations without
  pasting. The default global shortcut is Control-Option-Command-V and can be
  changed in Settings.
- Clipboard Watch observes the same general pasteboard used by local and
  Universal Clipboard changes. macOS does not expose device provenance, so
  TopDrop reports only that a change reached this Mac.
- Screen Color Picker hides TopDrop, shows a live magnifier and Hex preview,
  then copies one uppercase `#RRGGBB` value on click. Escape or right-click
  cancels.
- The image editor supports any number of independently colored rounded boxes,
  arrows, and text boxes; selection, move, resize, stacking, keyboard nudging,
  zoom, undo/redo, Update Clipboard, and flattened PNG/PDF export.
- The one-divider Scroll Shelf keeps original third-party status items native.
  In Arrange mode, Command-drag on-demand items left of TopDrop's divider and
  always-visible items to its right. TopDrop-owned labels, spacers, and tray
  accessories can be reordered separately.

## Dev Tools

The collapsible 240-point Dev Tools sidebar contains only Keep Awake, Hidden Files,
and New File. Below 820 points of available tray width it opens as a popover from
the footer instead. The remaining workspace uses the existing 980-point split-pane
breakpoint; changing layout does not replace the Notes or Clipboard models.

- **Keep Awake** owns an IOKit display-idle-sleep assertion, not a global power
  preference. It starts off on every launch and is released on exit. It uses more
  battery and does not prevent manual sleep, closing the lid, or safety sleep.
- **Hidden Files** displays Finder's saved `AppleShowAllFiles` preference, not an
  authoritative live UI state. The button requires Accessibility only when used.
  It dismisses TopDrop, activates Finder, verifies focus, and sends one layout-aware
  Command-Shift-period shortcut. No preference is written and Finder is not restarted.
  An unchanged or unreadable result is explicitly unconfirmed; use the manual
  shortcut if permission or keyboard-layout resolution is unavailable.
- **New File** copies a real file URL, not its text. TXT, Markdown, PDF, RTF, JSON,
  and YAML are immediately available; More includes CSV, Python, Shell, HTML, and
  Plist. Paste in Finder with Command-V, then rename `Untitled.ext`. PDF is a valid
  one-page A4 document; RTF/JSON/Plist/HTML are valid minimal documents, and scripts
  are not executable. Finder handles destination permissions and name conflicts.

Generated files live in local `Application Support/TopDrop/BlankFiles`, survive
TopDrop quitting, and contain only blank template content. Their optional template
identity is encrypted with clipboard history. Make Current regenerates a missing
source while preserving the history item's identity. Cleanup is conservative:
there is no timed deletion, and files are only eligible for deletion with a complete
clipboard/history reference census. An unreadable history must never cause cleanup.
No destination copy is deleted. iCloud Drive uses normal Finder copying; successful
local pasting does not imply that iCloud has finished uploading.

## Copy text from an image

Click the **Copy Text** (`text.viewfinder`) button beside an image in history or
the Current Clipboard row, or in the image editor toolbar. For a multi-image
clipboard, choose the logical image from its menu. Recognition uses Apple's
on-device Vision framework on the full-resolution original, never a thumbnail
or the editor's added boxes, arrows, or text. It needs no additional permission
or network service. Chinese/English mixed text and supported system-preferred
languages are recognized automatically; output is plain text with line breaks,
not a reconstructed table or document layout.

Successful recognition replaces the current clipboard with text (without
pasting), retains the image in history, and does not count as a Universal
Clipboard arrival. The spinner can be clicked to cancel; closing the originating
tray/editor also cancels. Empty results or failures leave the clipboard intact.
Intermediate OCR data stays in memory; copied text follows the existing encrypted
clipboard-history policy. OCR is not guaranteed to reproduce every glyph exactly.

## Screenshot and image storage

Normal screenshots are imported into the managed library without modifying or
deleting their source files. Clipboard images use a session-only encrypted
cache capped at 10 unedited images. Edited projects and their annotation data
do not consume that rolling limit. Save Copy creates a flattened PNG; Desktop
and Save-panel exports use collision-safe names.

Local paths:

- Clipboard archive: `~/Library/Application Support/TopDrop/Clipboard/history.tdclip`
- Image library: `~/Library/Application Support/com.personal.TopDrop/Screenshots/`
- Preferences: `~/Library/Preferences/com.personal.TopDrop.plist`
- Keychain service: `com.personal.TopDrop.clipboard`

OSLog diagnostics never include note text or clipboard payload contents.

## Permission reset after rebuilding

Ad-hoc rebuilding can change TopDrop's TCC identity. Reset only the affected
permissions, relaunch TopDrop, and grant them again:

```sh
tccutil reset AppleEvents com.personal.TopDrop
tccutil reset ListenEvent com.personal.TopDrop
tccutil reset Pasteboard com.personal.TopDrop
tccutil reset ScreenCapture com.personal.TopDrop
```

If `Pasteboard` is not accepted as a service name, remove or toggle TopDrop in
**System Settings > Privacy & Security > Pasteboard**. Keychain is separate from TCC. Do not delete encryption keys to fix permissions:
doing so makes existing encrypted history unreadable. Use the in-app recovery
retry and preserve ciphertext when access fails.

TopDrop is GPL-3.0 software. See `LICENSE` and `THIRD_PARTY_NOTICES.md`.
