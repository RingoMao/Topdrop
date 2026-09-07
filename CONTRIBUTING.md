# Contributing

Use small, focused changes and explain user-visible behavior. All contributions
are under GPL-3.0; preserve third-party notices and identify adapted source.

1. Use Apple silicon, macOS 26+, full Xcode 26+ and Swift 6.2+.
2. Run `Scripts/verify.sh` and `Scripts/build-app.sh`.
3. Format Swift with `xcrun swift format format -ir Sources Tests Scripts Package.swift`.
4. Add deterministic regression tests to `Tests/TopDropCoreTests`; register new
   test collections in TestRunner. `swift test` is not this project's runner.
5. Report manual UI/device checks separately from automated test results.

Never commit real notes, clipboard contents, screen captures of private data,
credentials, signing certificates, .build, dist or user preferences. Use generated
fixtures, named test pasteboards, and temporary test folders. CI must not access
real Apple Notes or request TCC permission.

Preserve bundle, Keychain, archive and status-item autosave identities. Test
backward decoding before changing a stored model. Keep platform effects behind
injectable providers and never log payloads or arbitrary error descriptions.

Public AppKit does not reparent another app's status item. Do not reintroduce
proxy/capture hacks, private Notes databases or fan-control code. New permissions
or dependencies require a documented design decision.

The repository uses macos-26 arm64 CI with read-only permissions and pinned
Actions. Update pins intentionally; no credentials are needed to build.
