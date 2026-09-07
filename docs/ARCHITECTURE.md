# Architecture

| Boundary | Responsibility and review invariant |
| --- | --- |
| TopDropApp | AppKit lifecycle, SwiftUI presentation, window/gesture routing; no private Notes database. |
| Core/Notes | Per-note revision/generation state, protected recovery journal and injected provider. A late save cannot overwrite another draft. |
| TopDropNotesWorker | One parameterized operation on its main thread. Parent serializes the channel; process and pipes share a bounded deadline. |
| Core/Clipboard + Security | Payload conversion, current state, watch, encrypted history. No archive writes following a failed load until recovery succeeds. |
| Core/Screenshots | Actor-isolated library. ClipboardCache, Editing and Storage extensions separate responsibilities without changing persisted formats. |
| Core/Annotations + Images | Editable object model/rendering and original-image Vision recognition. OCR never implicitly saves edits. |
| MenuBar + Layout + Gesture | Pure geometry/state policies plus native AppKit owner. One divider; third-party items remain native. |
| DevTools | Separate KeepAwake, HiddenFiles and template providers. No global preference mutation or fan control. |
| Lifecycle | Exactly-once termination reply, independent cleanup/deadline tasks, best-effort data flush. |
| Scripts | Locked builds, allowlisted source, validated staged publication, exact-target runtime guard and recoverable app installation. |

Clipboard UI is split into root workspace, status/current views, utility controls,
and history rows. Annotation UI is split into toolbar/root, inspector and canvas.
Core library extension helpers are module-internal, not added public API.

## Concurrency and failure contracts

- Every asynchronous completion validates immutable identity/revision or generation.
- Canceled worker requests that have not launched cannot mutate Notes.
- Cancellation/deadline after dispatch of a Notes mutation means outcome uncertain,
  not proof of rollback. Reconcile by ID before retrying.
- Partial reads preserve known notes. Local dirty drafts win; clean rows refresh.
- Pasteboard APIs can clear before a write fails. If changeCount moved, Current is
  invalidated rather than claiming the previous payload remains present.
- Clipboard persistence is serialized, and delayed load merges new session clips.
- Encryption/decryption failure never falls back to plaintext or replaces old
  ciphertext. In-memory state is not crash-durable.
- Quit's five-second deadline handles asynchronous hangs; a completely blocked
  main run loop still prevents AppKit callbacks. Keep blocking platform work off it.

See the QA checklists for permission, accessibility, display and real-device cases
that mocks cannot establish.
