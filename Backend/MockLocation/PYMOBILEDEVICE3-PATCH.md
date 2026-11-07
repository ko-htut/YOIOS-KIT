# YIOS-KIT pymobiledevice3 10.9.0 changes

`pymobiledevice3-wifi.patch` modifies `remote/userspace_tunnel.py`, `lockdown.py`,
and `remote/remote_service_discovery.py` from pymobiledevice3 10.9.0, licensed
GPL-3.0-or-later. Updated on 2026-11-08. The original source archive,
license, patch, and build/verification instructions accompany the payload.

The patch adds an optional `connection_type` argument (`USB` or `Network`) to
the existing no-root userspace tunnel. Service connections inherit that exact
transport from lockdown; YIOS-KIT disables RemotePairing fallback and automatic
pairing. A validated existing pairing is required before starting CoreDeviceProxy.
The backend separately attests the Network lockdown and RSD identity before any
location request. It also exposes a cancellation-safe `wait_closed()` observer,
retaining the upstream transport's closure task without changing tunnel routing.

An optional `auto_reconnect` argument preserves the upstream default of `True`.
YIOS-KIT passes `False` for every direct lockdown factory and userspace tunnel.
The policy propagates through RSD initialization into remote lockdown before its
first request. It disables both automatic request replay paths and rejects explicit
re-establishment, including the pairing SSL failure path, without sending another
request or changing transport.

No dependency version changes, privileged tunnel, network fallback, pairing,
retry, permanent phone-side persistence, or transport handoff are introduced.
Apple usbmuxd must discover the exact trusted device as `Network`, and the Mac
and iPhone must remain reachable on the same network. Wi-Fi loss may take the
underlying TCP/usbmux transport time to report; this is not a GPS read-back check.

| Source file | Original SHA-256 | Patched SHA-256 |
| --- | --- | --- |
| `remote/userspace_tunnel.py` | `6722ced375904f54d29fc5ea08c3635c65357c734a8e0f07e1aeb362d4a0d491` | `26864a4455325bf8660d2713fe4579deb1bac9b1224ac8789cb5fc9a870afe62` |
| `lockdown.py` | `3c61dab4566fae78eaba039d1111682474e4bdf604a129cbbbf60ee2d4a8de81` | `6aec9ece02b95f353626c1089f49fcaabffddfa2aa54d12d98ec7ca6973ceb9c` |
| `remote/remote_service_discovery.py` | `a522a76a0b36e2b3e7394c590b02b03039edc1d0189d65cf232a3d33efa54734` | `8114a251f4a80878d7855de1508c64b0ef812a57ce9343ca24498ce96fa4b434` |
