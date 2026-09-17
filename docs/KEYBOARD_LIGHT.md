# Keyboard status light

Settings → Keyboard provides On, Automatic/Manual, a manual color selector,
custom hue/saturation/brightness, and Refresh. Refresh cancels a pending HID
request, rereads the status feed, and resends the desired state. It preserves
manual settings. Off keeps the light off while TopDrop runs, including reconnects.
Quitting TopDrop sends Off; the firmware may restore its saved lighting after a
USB power cycle while TopDrop is not running.

## Status and recovery

Automatic reads the existing local Codex hook ledger at
`$CODEX_HOME/codex-keyboard-light/traffic-light-state.json`, falling back to
`~/.codex`. It reads only status and timestamps, never conversation text, and
never changes the hook ledger. Attention takes priority over working; otherwise
the light is mint (idle). An idle light is not proof a task succeeded.

Active hook entries are leases: attention expires after 15 minutes without a new
hook event and working after 30 minutes. This bounds missed Stop events. A long
silent tool or unanswered prompt can outlast its lease; new hooks restore the
state. The UI shows the latest event and expired-entry notice. Missing or corrupt
feeds turn the light off and show an error rather than silently showing success.

Writes run in a bundled helper, with a four-second deadline, serial dispatch,
cancellation, five-second reassertion, retry on failure, and wake refresh. A hung
helper is killed; a reconnect is rediscovered on the next attempt. Successful
HID writes are reported as "Last sent", not optical confirmation. The helper
reports partial multi-device failures so they are retried.

## Migration and recovery

The first explicit On transfers hardware control from the known
`com.openai.codex-keyboard-light` LaunchAgent to TopDrop. TopDrop disables and
unloads that exact job before writing. The plist, original binaries, and Codex
hooks remain intact. Failure to retire the old job prevents a competing writer.
A per-user lock prevents two TopDrop instances from controlling the keyboard.
Enable "Launch TopDrop at login" in General for automatic startup.

To return to the prior service, first quit TopDrop, then run:

```sh
launchctl enable "gui/$(id -u)/com.openai.codex-keyboard-light"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.openai.codex-keyboard-light.plist"
```

Off is still managed by TopDrop after migration. To keep using the restored
legacy service, leave TopDrop closed or reset `keyboardLight.managed` in saved
settings before relaunch. Do not run both controllers simultaneously.

## Provenance and protocol

`Sources/TopDropKeyboardLight/main.c` is adapted from the user's existing local
`codex-keyboard-traffic-light/host/codex_qmk_light.c` (July 2026), including the
verified Q11 and ST68 effect maps. The installed predecessor lives in
`~/.codex/codex-keyboard-light`. No opaque precompiled binary is redistributed.

Supported interfaces: Q11 ANSI `3434:01E0`, ST68 `342D:E4CE`, raw-HID usage
`FF60:61`. VIA RGB Matrix set-value reports are volatile, 32 bytes, command `07`,
channel `03`; fields 1/2/3/4 are brightness/effect/speed/color. Nothing saves to
EEPROM, changes key mappings, reads keystrokes, or flashes firmware. No new
network access, Input Monitoring request, or third-party runtime is required.
Other devices and wireless modes are not assumed compatible.

## Acceptance

Run `Scripts/verify.sh`, `Scripts/build-app.sh`, and `Scripts/verify-package.sh`.
The registered tests cover priority, expired events, malformed/oversized input,
settings migration, manual persistence, byte bounds, process deadlines, and
cancellation followed by recovery. With a physical supported keyboard, exercise
On/Off, all manual colors, Refresh, Automatic, sleep/wake, unplug/replug, and
quitting. Check that the legacy LaunchAgent is unloaded and only one app owns the
light. Device-write success alone does not verify perceived color or brightness.
