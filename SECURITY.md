# Security

This is an early source release, not a security-audited or notarized distribution.
Use the latest main branch for fixes; no older release support is promised yet.

Do not attach Notes text, clipboard archives, Keychain exports or unredacted
screenshots to public issues. Use GitHub's private vulnerability reporting when
available. If it is unavailable, open a content-free issue requesting a private
contact channel; do not disclose an exploit or sensitive data publicly.

Threat boundaries include pasteboard payloads, imported images, Apple Events,
Keychain access, filesystem paths and worker IPC. Inputs must be bounded, stored
content must not enter logs, and failed decryption must preserve ciphertext.
Ad-hoc signatures can change macOS permission attribution between local builds.

Encryption protects files at rest, not a compromised logged-in session. Exported
images/PDFs and intentionally generated blank files are normal unencrypted files.
No security or data-loss guarantee follows from passing unit tests.
