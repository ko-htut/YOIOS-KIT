# Companion Mock Location simulator bridge

This development bridge changes the **system location of one exact iPhone Simulator** through Apple's simulator tool. The Companion's Mock Location tab sends a Set or Clear request to the bridge; its separate Core Location reader checks what iOS actually reports. A map preview alone is never treated as successful simulation. This is a simulator test path, not an on-device developer tunnel or proof of physical-iPhone compatibility.

## Run the simulator workspace

Build the simulator app, select the UUID of an already booted iPhone simulator, then launch:

```sh
./Scripts/build-companion.sh --simulator
./Scripts/start-companion-simulator.sh EXACT_BOOTED_IPHONE_SIMULATOR_UUID
```

The launcher installs only the simulator build and restarts only that simulator's YIOS-KIT app so it receives a new private bridge session. The host process stays in the terminal. In the app, use **Mock Location**, set a coordinate, then inspect the fresh location reported by Core Location. Select **Clear** before closing the workspace. Terminating the app or bridge does not silently clear a simulated location. The durable journal records a reset obligation without storing coordinates. A restarted bridge treats a prior Set as uncertain until an explicit Clear succeeds.

For automated tests, start only the bridge:

```sh
/usr/bin/python3 Backend/CompanionSimulator/yios_simulator_bridge.py \
  --simulator EXACT_BOOTED_IPHONE_SIMULATOR_UUID \
  --config "$PWD/build/CompanionSimulator/bridge-config.json" \
  --state-dir "$PWD/build/CompanionSimulator/state"
```

Read the mode-0600 configuration file locally and supply the **entire JSON document** as the environment variable `SIMCTL_CHILD_YIOS_SIMULATOR_BRIDGE_CONFIG` when invoking `simctl launch`. Inside the simulator app it is `YIOS_SIMULATOR_BRIDGE_CONFIG`. UI tests set that variable through `XCUIApplication.launchEnvironment` instead. Do not paste the token into logs or command arguments. Configuration contains protocol version, a loopback base URL, random token, session UUID and immutable simulator UUID. It is never embedded into the signed physical-phone app.

The default journal is under `~/Library/Application Support/YIOS-KIT/CompanionSimulator/UUID/`. Automated tests may explicitly use a private build directory. A fixed per-user, per-simulator process lock is independent of the journal directory, so different `--state-dir` choices cannot create concurrent controllers. Bridge startup and each new mutation require the exact available, booted iPhone Simulator. There is no `booted` alias, physical-device command, device fallback, or implicit device boot.

## Wire protocol

All endpoints require `Authorization: Bearer TOKEN`. The server binds only `127.0.0.1` on a random port. It rejects browser Origin requests and does not enable CORS.

| Request | Body |
| --- | --- |
| `GET /v1/status` | none |
| `POST /v1/set` | `{"requestID":"UUID","latitude":16.8409,"longitude":96.1735}` |
| `POST /v1/clear` | `{"requestID":"UUID"}` |

Successful response fields are `protocol:1`, `sessionID`, `simulatorID`, `state` and monotonic `revision`. Mutation responses additionally contain `requestID`, `operation` and `acknowledgement`. `acknowledgement:"accepted"` means simctl completed, **not** that the app independently observed GPS. A post-dispatch failure returns HTTP 409 with `acknowledgement:"uncertain"`. Clear acknowledgement is likewise not proof of a usable real-world GPS fix inside a simulator.

A repeated UUID with the same body returns the original result without executing again; changed-body reuse is rejected. A previously acknowledged request becomes stale after a later revision and cannot restore an old result. Uncertain outcomes are cached too. No nonce is evicted: a session accepts at most 128 distinct mutations, with one additional Clear reserved if its final operation may have left a location active. It then requires a new bridge session. Requests are serialized, coordinates must be finite WGS-84 values, body size is limited to 4 KiB, concurrent connections are bounded, and subprocess output/time limits include termination and reaping.

## Offline checks

```sh
cd Backend/CompanionSimulator
/usr/bin/python3 -m unittest -v test_yios_simulator_bridge
```

These use fake simulator data and commands except for bounded-process tests that launch local Python. They cover authentication, target changes, invalid coordinates, duplicate JSON, nonce replay, uncertain results, durable recovery, serialization, process limits, and request limits without contacting a phone or changing a simulator's location.
