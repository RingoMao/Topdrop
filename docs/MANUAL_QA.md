# TopDrop manual verification

Run `Scripts/run-tests.sh` before this checklist and perform permission tests
with the exact packaged app from `dist/TopDrop.app`.

## Gestures and displays

- [ ] Trackpad and mouse wheel down-scroll reveal; natural scrolling is
      normalized and momentum is ignored.
- [ ] Firm up-scroll at the screen's top edge closes; down-scroll opening effort is unchanged.
- [ ] Scroll Notes/Clipboard and their scrollbars vigorously without closing, including 24 pt edge slack.
- [ ] Move to the screen edge during a content gesture: no close until a fresh gesture or wheel idle gap.
- [ ] Escape, outside click (including the scroll-only buffer), menu command, and Hide still dismiss correctly.
- [ ] Test every connected display, including negative origins, vertical
      stacking, portrait, square, notches, full screen, Spaces, Stage Manager,
      menu-bar auto-hide, and display hot-plug.
- [ ] Small built-in displays use nearly full width; large/external displays
      center at the configured cap with no overlap.

## Apple Notes

- [ ] Allow, deny, and re-enable Automation.
- [ ] Account/folder setup, list, search, create, edit, delete, refresh, and Open
      in Apple Notes work online and fail visibly offline.
- [ ] Older same-named TopDrop folders appear as explicit recovery candidates
      with paths and counts; no read failure changes the saved folder binding.
- [ ] Refresh while typing, rapidly switch A/B while saving, and change folders
      during refresh: newest drafts survive and never reach another note.
- [ ] Stop Notes or deny automation while editing, then relaunch TopDrop:
      encrypted pending drafts recover without overwriting the journal on failure.
- [ ] Verify whitespace against Apple Notes itself (not only Foundation HTML):
      consecutive spaces, tabs, empty lines, trailing newlines, Chinese and emoji.
- [ ] Test Mac-to-iPhone/iPad and the reverse using a dedicated QA folder; record
      local Notes readback separately from arrival on the second device.
- [ ] Leave Notes unresponsive: the UI remains usable, writes become uncertain,
      no automatic duplicate creation occurs, and Quit completes within five seconds.
- [ ] Repeat allow/deny/re-enable from the installed app with its bundled worker;
      command-line worker preflight alone is not proof of GUI TCC attribution.
- [ ] External edits do not present a version chooser; an open TopDrop draft
      autosaves as designed.
- [ ] Locked, shared, and attachment-containing notes remain read-only.

## Clipboard and color picker

- [ ] Allow, prompt, deny, and re-enable pasteboard access.
- [ ] Text, RTF, HTML, URL, image, PDF, and file URL clips preview and restore.
- [ ] Duplicate suppression, 20-item eviction, 20 MB limit, exclusions, pause,
      delete, clear, and clean formatting behave correctly.
- [ ] Current clipboard appears once; promotion performs one write, moves the
      same UUID, persists activation order, and gives clear non-color feedback.
- [ ] All/Text/Images filters contain the expected entries.
- [ ] Arrival Watch starts on reveal, handles cancel/retry/timeout, ignores
      TopDrop writes, and never claims a source device.
- [ ] Screen Color Picker shows a live magnifier and uppercase Hex value on each
      display. One click copies the value and exits immediately; Escape and
      right-click cancel immediately.
- [ ] Change Spaces, disconnect a display, or momentarily deny capture during
      sampling. A missing frame must skip safely rather than crash or strand an
      overlay.
- [ ] Sampled colors appear with a swatch in Current and History.

## Screenshots and annotations

- [ ] New-only baseline, explicit Import Existing, partial-write stabilization,
      source deletion, and PNG/JPEG/HEIC/TIFF importing.
- [ ] Clipboard images and watched screenshots remain distinct, deduplicate,
      and honor the 10-image temporary-cache limit.
- [ ] Create multiple rounded boxes, arrows, and text boxes; select, move,
      resize, recolor, reorder, duplicate, delete, zoom, undo, and redo.
- [ ] Black, white, gray, red, orange, yellow, blue, green, and purple shortcuts
      update the selected object and Hex editor together.
- [ ] Update Clipboard preserves sRGB color and immediately refreshes the
      clipboard image preview.
- [ ] PNG/PDF exports flatten correctly and use collision-safe names.

## Scroll Shelf and accessories

- [ ] Arrange mode highlights one native divider and follows it after
      Command-dragging.
- [ ] Genuine on-demand status items left of the divider reveal with TopDrop;
      items right of it remain visible and keep native click behavior.
- [ ] Labels and spacers persist and reorder independently.
- [ ] Built-in and Apple Shortcut accessories reorder, persist, and show errors
      without blocking Notes or Clipboard.

## Package inspection

- [ ] `dist/TopDrop.app` contains TopDrop and its on-demand Notes worker, no test fixture, and no background agents,
      privileged helpers, LaunchAgents, or LaunchDaemons.
- [ ] Both executables are arm64 with minimum macOS 26, hardened runtime, ad-hoc
      signature, and Apple Events entitlement.
- [ ] App and source ZIP integrity checks pass and neither archive contains
      generated build directories.
- [ ] Notes/clipboard contents are absent from OSLog diagnostics.
