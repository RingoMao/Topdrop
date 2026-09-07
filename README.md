# TopDrop

A lightweight, local-first menu-bar workspace for **Apple silicon · macOS 26+**.
Scroll down at the top edge to open Notes, clipboard history, image tools and
a compact set of developer utilities.

**Source preview:** GPL-3.0, Apple frameworks only, no third-party runtime
dependencies. Builds are ad-hoc signed and hardened, **not Developer ID signed
or notarized**. This is not a claim of production readiness.

## What it does

- Apple Notes integration with revision-safe autosave and encrypted pending-draft recovery.
- Encrypted clipboard history, one-click Make Current, formatting cleanup and color previews.
- Image annotations, undo/redo, PNG/PDF export and on-device Vision OCR.
- Live screen color picker with hexadecimal preview.
- One-divider native Scroll Shelf: original third-party menu items stay in macOS.
- Keep Awake, Finder hidden-file shortcut, and blank files you can paste in Finder.

TopDrop does not implement fan control or a captured third-party proxy bar.
Universal Clipboard origin and delivery to another Notes device cannot be verified
by TopDrop; its UI reports only what reached or was written on this Mac.

## Build and verify

Install full Xcode 26+ (Swift 6.2+, macOS SDK 26+) and select it using Xcode's
Command Line Tools setting. Intel Macs are not supported.

```sh
git clone https://github.com/RingoMao/Topdrop.git
cd Topdrop
Scripts/verify.sh
Scripts/build-app.sh
```

Outputs: `dist/TopDrop.app`, `dist/TopDrop.app.zip`, `dist/TopDrop-source.zip`.
To keep existing artifacts, use an absolute alternate destination:

```sh
TOPDROP_OUTPUT_DIR="$PWD/dist/review-ready" Scripts/build-app.sh
```

Publication refuses unrelated files in the destination or an app running from
that exact target. It never stops other installations. Source archives use an
explicit allowlist and can build without Git metadata or local caches.

Optional installation, **after quitting the destination app**:

```sh
Scripts/install-app.sh dist/TopDrop.app
# Optional second argument: "$HOME/Applications/TopDrop.app" (parent must exist)
```

The installer retains the old bundle as a hidden backup. It does not launch the
app or grant permissions. `Scripts/uninstall-app.sh` moves the stopped app to
Trash without deleting Notes, settings, history or keys. Do not disable
Gatekeeper globally; follow macOS's app-specific approval flow for local builds.

## Permissions and privacy

Notes Automation, clipboard access, optional Input Monitoring (global edge
gesture), Screen Recording (color picker only), and optional Accessibility
(Hidden Files shortcut) are separate permissions. OCR needs no screen-capture
permission. Do not reset Keychain keys to fix a permission problem.

- [User guide](docs/UserGuide.md)
- [Privacy and local storage](docs/PRIVACY.md)
- [Architecture and invariants](docs/ARCHITECTURE.md)
- [Review and validation record](docs/REVIEW.md)
- [Contributing](CONTRIBUTING.md) · [Security](SECURITY.md)
- [License](LICENSE) · [Third-party notices](THIRD_PARTY_NOTICES.md)

No telemetry or TopDrop backend. Apple Notes/iCloud and shortcuts you invoke may
use Apple services or their own network actions.
