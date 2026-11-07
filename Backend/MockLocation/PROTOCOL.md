# YIOS Mock Location backend protocol

The app launches `yios-location-backend` with exactly one command: `version`,
`probe`, `set`, `set-persistent`, `clear`, or `reveal-developer-mode`. Except
for `version`, the first stdin line is a JSON request. Output is
newline-delimited JSON only. Identifiers, coordinates, tunnel addresses,
upstream error text, tracebacks, and pairing records are never returned.

Protocol version: `1`

## Requests

`probe` and `clear` accept exactly:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone12,8"}
```

`set` and the distinct opt-in `set-persistent` experiment also require finite
decimal coordinates:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone12,8","latitude":"16.8409","longitude":"96.1735"}
```

The Settings-only Developer Mode preparation request accepts exactly:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone12,8","expectedECID":"0x<1-16 uppercase hex digits>"}
```

`reveal-developer-mode` opens only the direct USB lockdown connection with
automatic pairing disabled, matches the returned UDID, ProductType, and ECID,
and checks the existing pairing. If Developer Mode is already enabled it emits
`developerModeAlreadyEnabled` / `alreadyEnabled` without sending a mutation.
Otherwise it emits `requestDispatched`, calls the pinned upstream AMFI
reveal-only method, then emits
`developerModeOptionRequested` / `settingsOptionExpected` after the phone
accepts that request. This response proves only that AMFI accepted the marker
that makes the Settings option expected. Close and reopen Settings on the
iPhone; the user must still turn Developer Mode on, approve the reboot, and
confirm it after restart. This command never enables Developer Mode, accepts
the post-restart prompt, reboots, pairs, mounts a DDI, opens a tunnel, or
retries.

Every valid operation starts with `hello`; exact RSD identity produces
`attested`, and an opened DVT location channel produces `ready`. A set or clear
emits `requestDispatched` before invoking the DVT method. Set emits `active`
after the method reply; clear emits `clearSent` after the stop frame is written.

`set-persistent` emits the same
`hello` → `attested` → `ready` → `requestDispatched` → `active`
sequence. Its final event also contains `"persistence":"experimental"`. It
then deliberately awaits DVT close followed by tunnel close exactly once each.
It exits `0` only if both closes succeed. If either close fails, it still
attempts the other close, emits one privacy-safe `error` with
`"code":"internal_failure"`, `"phase":"persistentTeardown"`, and
`"status":"uncertain"`, then exits nonzero. It never sends `clear`, waits for a
control object, forks, daemonizes, detaches, or retries. This tests whether the
device retains the override independently; it does not prove that persistence
occurred. The earlier `active` event acknowledges only the Set reply, not clean
teardown or persistent device state.

After `active`, a long-running `set` accepts one control object per line.
`clear` sends the stop-simulation request through the same DVT channel and
exits. `quit` closes the channel without claiming a reset; the app must keep the
simulation state marked uncertain.

```json
{"command":"clear"}
{"command":"quit"}
```

## Honest state labels

- `active` / `assumedActive`: Apple provides no read-back getter, so the backend
  does not claim the simulated location was independently confirmed.
- `set-persistent`: persistence after the acknowledged request and connection
  teardown is experimental and assumed only. Use a fresh location request on
  the phone to observe behavior, then reconnect the exact target and issue the
  normal one-shot `clear` request.
- `clearSent` / `realLocationExpected`: the stop request was sent; it is
  not a GPS read-back confirmation.
- An `internal_failure` after activation: the app must require review and offer
  an exact-target one-shot `clear`.

All error `code` and `phase` values are from fixed allowlists. The backend never
auto-pairs, auto-retries, enables Developer Mode, accepts the post-restart
prompt, reboots, mounts/downloads a Developer Disk Image, uses a privileged
tunnel, or falls back to RemotePairing. Its only Developer Mode mutation is the
separately confirmed reveal-only Settings marker described above.

The launcher replaces `HOME`/XDG data paths with a private owner-only directory
under YIOS-KIT's Application Support area before importing pymobiledevice3. It
keeps the app-provided `TMPDIR`, disables bytecode writes, ignores user-site and
environment Python paths, and never reports the private path over the protocol.
