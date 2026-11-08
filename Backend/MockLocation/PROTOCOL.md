# YIOS Mock Location backend protocol

The app launches `yios-location-backend` with exactly one command: `version`,
`probe`, `set`, `set-persistent`, `clear`, `reveal-developer-mode`, or `enable-wifi`. Except
for `version`, the first stdin line is a JSON request. Output is
newline-delimited JSON only. Identifiers, coordinates, tunnel addresses,
upstream error text, tracebacks, and pairing records are never returned.

Protocol version: `1`

Backend version: `1.3.1`

The backend accepts any syntactically valid iPhone ProductType rather than a
model allowlist. `expectedProductType` is the exact ProductType freshly read
from the selected iPhone, not a device-class wildcard: a request for
`iPhone15,2` cannot be attested by another iPhone model. Canonical values have
the form `iPhone<positive integer>,<nonnegative integer>`, with no leading
zeroes, spaces, alternate casing, or extra suffix. Non-iPhone devices are
rejected. The current transport still requires iOS 17.4 or later, existing
Trust, Developer Mode, and available matching developer services; accepting a
model identifier does not imply that older hardware can run the required OS.

## Requests

`probe` and `clear` accept exactly:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone15,2"}
```

`set` and the distinct opt-in `set-persistent` experiment also require finite
decimal coordinates:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone15,2","latitude":"16.8409","longitude":"96.1735"}
```

`probe`, `set`, and `clear` optionally accept `"transport":"usb"` (the
default) or `"transport":"wifi"`. Wi-Fi additionally requires `expectedECID`:

```json
{"udid":"<exact trusted UDID>","expectedProductType":"iPhone15,2","expectedECID":"0x<1-16 uppercase hex digits>","transport":"wifi"}
```

Wi-Fi `set` also includes the coordinate fields. `expectedECID` may optionally
be supplied on USB for the same additional RSD identity check. Every tunnel
explicitly selects `USB` or `Network`; there is no fallback, automatic pairing,
or transport handoff. A Wi-Fi request first opens the exact Network lockdown,
checks its actual mux transport, UDID, ProductType, ECID, existing pairing, and
supported OS, and closes it. The tunnel independently forces Network and checks
its pairing and actual mux transport before starting CoreDeviceProxy. Its RSD
must agree on UDID, ProductType, and ECID before opening the DVT location channel.
ECID attestation accepts Python integers and the SDK's signed/unsigned RemoteXPC
integer subclasses, compares their integer values, and rejects booleans,
floating-point values, and strings.
Any mismatch stops without sending a location request. The patched upstream
source and its modification notice accompany the payload.

YIOS-KIT passes `auto_reconnect=False` before lockdown initialization on direct
and tunneled connections, including RSD's remote lockdown. The pinned patch
propagates transport/session failures without reestablishing or replaying a
request; upstream defaults for other callers remain unchanged.

`enable-wifi` accepts exactly the same three identity fields as
`reveal-developer-mode`. It connects only over USB, attests the exact device and
actual USB transport, requires existing pairing, then reads
`get_enable_wifi_connections()`. After `hello` and `attested`, it emits
`requestDispatched`, calls `set_enable_wifi_connections(True)` only if needed,
reads the flag back after a change, and emits `wifiEnabled` / `ok` only when
the flag is true. This acknowledges the setting, not network
discovery or a working developer tunnel. It never opens DVT, reveals/enables
Developer Mode, pairs, or retries. The trusted iPhone must later appear as
`Network` in Apple usbmuxd and stay reachable from this Mac on the same network.

An initial `MissingValueError` for that flag is treated as an unset key: after
the existing exact-target confirmation, `enable-wifi` may send its one enable
write. No other initial read error permits a write. After writing, the getter
must return true; missing/false/failing readback emits an error and never
`wifiEnabled`. Neither the getter nor setter is automatically retried, and
upstream exception details remain private.

`set-persistent` remains a separate USB-only experiment. It rejects transport
fields, including Wi-Fi: keeping a live Wi-Fi session is not phone-side
persistence.

The Settings-only Developer Mode preparation request accepts exactly:

```json
{"udid":"<exact connected UDID>","expectedProductType":"iPhone15,2","expectedECID":"0x<1-16 uppercase hex digits>"}
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

Live `set` races a cancellable stdin pipe reader against the actual tunnel
transport's closure. Loss emits exactly an `error` with `status: uncertain`,
`code: connection_lost`, and `phase: transport`, exits nonzero, and closes its
contexts. It does not send Clear or retry after loss. Canceling a stdin/watcher
wait never leaves a blocked executor thread or cancels the tunnel reader.
Each context close has a five-second timeout. A silent Wi-Fi outage can take
the underlying TCP/usbmux transport time to report; the backend does not claim
instant independent network-health or GPS verification.

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
