# YIOS-KIT — iPhone Device & Recovery Center

A native, Apple-silicon macOS app for source-attributed iPhone inspection and recovery. One exact, trusted iPhone with a valid ProductType can use the non-destructive Normal-iOS-to-Recovery transition. Factory Reset, Revive, custom-firmware Restore, and the other catalog-bound write workflows remain bounded to fourteen explicitly reviewed **iPhone 8 through iPhone SE (2nd generation)** ProductType/board variants. A separate **DFU Factory Restore** can erase and reinstall Apple's latest signed iOS on an exact iPhone DFU target that the installed Apple Configurator and YIOS-KIT's identity attestation can currently recognize. The app includes its own pinned libimobiledevice/libirecovery command-line toolchain, so the user does not need Homebrew. Apple Configurator remains an optional, separately installed Apple component required for official erase/firmware operations. Mock Location accepts any valid iPhone ProductType, with exact-target attestation and a successful developer-service check on iOS 17.4 or later. No jailbreak, exploit, activation bypass, or unsigned firmware path is included.

## What the app does

- Uses one grouped sidebar for all eleven screens, a current-page breadcrumb, clear page headings, and a shared light/dark visual system. Dashboard, device details, reports, history, Recovery, DFU / Restore, Mock Location, tools, guides, logs, and settings each focus on their own task. Cards and controls adapt to compact and wide windows.
- Includes a **Dependency Doctor** that reports the exact built-in tool source/version, optional installed fallback, and which capabilities are ready. A complete built-in suite is always preferred; tools from different installations are never mixed within one capability.
- Adds a **Backup Center** in More Tools that hands control to Finder. The app does not automate, start, observe, or claim completion of a backup and never asks for a backup password.
- Adds an explicit, exact-target **Crash & Panic Reports** copy workflow. It requires one supported, trusted iPhone in Normal iOS, creates a new local folder with verified private permissions, always uses `idevicecrashreport --keep`, never requests deletion, never uploads through this app, and never retries automatically.
- Adds a bounded, structured **USB & Recovery Timeline** for the current app session. It records observed mode/PID transitions and this app's Apple-operation events without scraping iPhone syslog or inferring cable/hardware failure.
- Adds guarded **Mock Location** for one exact, trusted iPhone running iOS 17.4 or later, independently of the reviewed recovery-model catalog. The backend must attest the requested iPhone ProductType and exact target, then successfully open its developer location service. It uses a no-root, in-process userspace tunnel and the DVT location service; it never auto-pairs, enables Developer Mode, mounts/downloads a Developer Disk Image, or falls back to a privileged/RemotePairing tunnel.
- Builds one timestamped Device Center snapshot from current USB/mode evidence and, only in verified trusted Normal iOS, read-only lockdownd and targeted Configurator properties.
- Shows available identity and software data such as device/model name, ProductType, hardware model, iOS/build, serial, CPID/BDID, model/region, baseband, ECID and UDID.
- Shows available cellular/network data such as IMEI 1/2 and device-reported Wi-Fi/Bluetooth addresses. Linkable or personal values are masked until the user explicitly reveals them for 60 seconds.
- Shows current charge/charging state and approximate total/free/category storage only when a device source returned coherent values. It never converts missing values to zero or “Normal.”
- Shows source and evidence status for every fact and exports a local, permission-0600 report with identifiers masked by default.
- Adds guarded **Restart** and **Shut Down** controls for one exact, supported, trusted iPhone in Normal iOS. They require confirmation plus exact model, ECID, UDID, USB-port, mode, and Trust rechecks; they are unavailable in Recovery, DFU, RestoreOS, or USB-only states.
- Opens Apple's official coverage page without automatically sending the serial number.
- Requires exactly one connected Apple mobile device.
- Pins the target ECID and rechecks it before every Apple operation.
- Proves Normal iOS with `ideviceinfo`; a normal-looking USB PID alone is not enough.
- Proves Recovery/DFU with `irecovery`; a Recovery/DFU-looking PID alone cannot enable a write.
- Detects the stuck RestoreOS intermediate state and blocks direct restore from it.
- Shows a live Recovery/DFU button guide while monitoring the exact ECID.
- Sends at most one exact-UDID Recovery request after two fresh identity and Trust checks; failures and timeouts are never retried automatically.
- Includes a model-aware **DFU Assistant** for Home-button iPhones, iPhone 7/7 Plus, and iPhone 8-or-later button families. It arms a passive exact-target USB watcher; physical buttons remain required.
- Offers Apple **Revive** first in verified Recovery Mode.
- Offers full Apple **Restore** for reviewed devices in verified Recovery/DFU, plus model-generic **DFU Factory Restore — Erase & Reinstall iOS** for an exact attested iPhone DFU/KIS target. The generic path always uses Apple's latest signed iOS and requires a data-loss acknowledgement plus the target-bound phrase `ERASE <ECID suffix>`.
- Offers **Factory Reset — Erase All Content & Settings** only for one paired, exactly identified supported iPhone in Normal iOS.
- Never retries a failed flash automatically.
- Attempts to keep the Mac awake during an active Apple operation and prevents normal app quit.

The app does **not** use 3uTools, jailbreak/exploit tools, activation-lock bypasses, `idevicerestore`, or write-capable `irecovery` commands. It never bypasses Apple signing and cannot install unsigned or custom firmware.

### Recovery support matrix

The non-destructive software transition into Recovery accepts one exact, trusted Normal-iOS iPhone with a syntactically valid ProductType, canonical ECID, UDID, and stable USB location. It checks the same target and existing Trust twice, sends `ideviceenterrecovery` once with the exact UDID, never uses a shell string, and never retries. This capability is intentionally separate from the destructive catalog.

Inspection, guarded utilities, Factory Reset, Revive, Recovery-mode Restore, and custom IPSW selection continue to use the exact ProductType/board allowlist for **iPhone 8, 8 Plus, X, XS, XS Max, XR, 11, 11 Pro, 11 Pro Max, and SE (2nd generation)**, including their Apple hardware variants. iPhone 7/SE (1st generation) and iPhone 12 or later can still use broad Recovery entry and model-aware physical guidance. Outside the reviewed catalog, full DFU Restore is available only with Apple-latest firmware and only when two fresh exact-target checks and Apple Configurator's own restorable-DFU record agree. Mock Location separately accepts all valid iPhone models in verified Normal iOS when its iOS 17.4+ and developer-service requirements pass; this does not grant any other catalog-bound operation.

The DFU Assistant is not one-click DFU: macOS cannot press the required physical buttons. It selects Home-button, iPhone 7, or modern Volume-button guidance from the exact ProductType and watches the pinned ECID/USB location. Stable Recovery is reported as missed DFU timing and monitoring continues. Classic DFU PID `0x1227` must pass targeted protocol and complete `irecovery -q` identity verification. Newer-device KIS/Debug USB PID `0x1881` can qualify only when an exact ECID, USB location, iPhone ProductType, DFU state, and Apple Configurator `isRestorable` record all agree. Neither PID alone authorizes an erase.

## Requirements on this Mac

- Apple-silicon Mac, macOS 13 or later
- One iPhone connected directly with a reliable data cable

No Homebrew installation is required. The release app carries pinned arm64,
macOS-13-compatible builds of `libimobiledevice 1.4.0`, `libirecovery 1.3.1`,
and their runtime libraries. If a verified built-in helper is unavailable, an
existing `/opt/homebrew` or `/usr/local` installation may be used as an optional
fallback; a single operation never mixes helper suites.
The libimobiledevice helper set is treated atomically: if the built-in set is
incomplete or invalid, the app will use only a complete installed fallback or
disable the affected capabilities.

Mock Location is a separate app-private payload pinned to
`pymobiledevice3 10.9.0`. This personal build uses Apple's
`/usr/bin/python3 3.9` supplied on the current development Mac and bundles the
complete pinned Python package closure; it never imports Homebrew or user-site
packages. The build/package verifier fails closed if the interpreter, payload
checksum, architecture, signature, or pinned upstream version differs; runtime
selection additionally requires the canonical, non-writable in-app launcher.

Install **Apple Configurator** from Apple only if you need Apple Revive, full
Restore, or Factory Reset. Device inspection, Recovery/DFU verification,
Normal-to-Recovery transition, guarded restart/shutdown, and crash-report copy
use the built-in toolchain without Configurator. Finder remains the official
manual backup handoff.

## Use

1. Double-click the packaged **YIOS-KIT.app**.
2. Connect only one target iPhone and click **New Scan**. The Dashboard automatically loads richer details only after Normal iOS, exact model identity, and existing Trust are verified. Open **Devices** for the full snapshot.
3. Use **Reports** to filter facts and inspect their sources, **History** for the current session's timeline, **More Tools** for Finder backup and crash-report copy, and **Logs** for troubleshooting. **Guides** explains connection and physical-button sequences; **DFU / Restore** puts firmware operations first. Choose System, Light, or Dark appearance in **Settings**.
4. **Copy summary** and **Export report** are redacted by default. **Reveal for 60s** is required before sensitive values appear on screen.
5. For a usable phone already in verified Normal iOS, guarded **Restart**, **Shut Down**, or **Factory Reset** become available. Factory Reset irreversibly removes all content and settings without reinstalling or updating iOS.
6. In trusted Normal iOS, choose **Enter Recovery (keep data)** for one exact, twice-checked, single-attempt software transition. If the helper is unavailable or RestoreOS appears, use **Guide me to Recovery** and the model-specific physical sequence.
7. For DFU, expand the timing guide and choose **Start DFU Assistant**. Follow the physical steps; the assistant only watches and verifies the exact USB target. A black screen, timer, Recovery mode, or DFU/KIS USB PID alone is not DFU success.
8. If verified Recovery appears on a reviewed model, try **Apple Revive** first if data matters.
9. If data does not matter, choose **Erase & Restore** for a reviewed target or **DFU Factory Restore** for an exact generic DFU target. Verify the ECID and firmware, acknowledge permanent data loss, then type the displayed target-bound `ERASE <ECID suffix>` phrase exactly.
10. Keep the cable connected. After Factory Reset, wait for the Hello screen, then click **I checked the iPhone — Scan**; the app keeps other write actions and normal window closing blocked until this manual check.

### Mock Location

- Model selection is not limited to SE2 or to the reviewed recovery catalog. One verified Normal-iOS iPhone with an exact ECID, UDID, USB location, and valid ProductType can be checked. iOS 17.4 or later, existing pairing/Trust, Developer Mode, and matching developer services remain required; older iOS versions and an unavailable developer location service cannot be made compatible by removing the model restriction.
- First enable Developer Mode yourself on the iPhone and explicitly prepare the matching Developer Disk Image with trusted developer tooling. If the Developer Mode option is missing, YIOS-KIT can send one explicitly confirmed, twice-verified, exact-target Apple request that makes the Settings option expected. It does not enable Developer Mode, restart the iPhone, or claim that the option is visibly rendered; you must still turn it on and approve Apple's on-device restart and confirmation yourself.
- Run the read-only readiness check, enter finite decimal latitude/longitude values, verify the exact pinned target, and explicitly start the simulation. The coordinate affects location-aware apps on that iPhone.
- The default **USB live session** keeps the developer session open; choose **Return to Real Location** before disconnecting or quitting.
- **Wi-Fi live session** starts from one trusted, exact USB iPhone. Select Wi-Fi, explicitly choose **Enable Wi-Fi Connection**, then **Check Readiness** while the cable is attached. The setting persists on the phone and is enabled only after confirmation and two fresh USB identity/Trust checks. A successful setting request does not prove network discovery; the read-only probe must open a separate, strictly Network-only tunnel with matching UDID, ProductType, and ECID. There is no USB or RemotePairing fallback. iOS 17.4+, Developer Mode, and prepared matching developer services remain required.
- Keep USB attached until the Wi-Fi Set acknowledgement. After **Wi-Fi Mock Location session is active**, USB may be unplugged while the Mac stays awake, YIOS-KIT stays open, and both devices remain on the same network. **Return to Real Location** uses that same authenticated live channel even without USB or with another USB phone connected. This is an ongoing network session, not a permanent phone-side location change. Network discovery depends on Apple's device services and the local network; a missing Network device is reported rather than silently using the cable.
- If the live developer tunnel closes, YIOS-KIT reports connection loss and retains its review lock and privacy-safe journal. Reconnect the original iPhone over USB and send **Return to Real Location**. A new USB port can be accepted only when the stable ECID/UDID/ProductType fingerprint matches, with explicit confirmation and fresh Trust checks. Journal schemas 1 and 2 remain readable as USB sessions; schema 3 also records the transport and still never stores coordinates, raw identifiers, or network addresses.
- The opt-in **Persistent until Clear/Reboot (Experimental)** mode waits for Apple's Set acknowledgement and then closes the developer session without sending Clear. Retention after USB disconnect is an experiment, not a guarantee, and broad model eligibility does not prove that the override survives on a particular iOS build. There is no read-back getter. Reconnect the same stable iPhone and choose **Return to Real Location**. Rebooting is expected to restore phone-side GPS, but YIOS-KIT still keeps its safety record and device-write/quit lock until an exact-target Clear is recorded.
- **Apple Native (Experimental)** is a separate persistent driver using the installed, Apple-signed CoreDevice `devicectl` tool. Keep USB attached for readiness and Set: fresh USB identity, existing Trust, Developer Mode, the exact native UUID mapping, connected/paired state, and the location capability must agree. The command runs once, exits, and persistence remains assumed until checked on the iPhone with both USB and Wi-Fi disconnected. Apple may prepare its native developer support; this mode does not use the bundled DVT location channel or automatically enable Developer Mode or pairing. The native tool uses Apple's user databases, and its command arguments contain the target and coordinate while it runs; raw output never enters app logs or reports.
- Native Set/Clear are protected by the same controller and mutation locks. Journal schema 4 records the driver alongside the fingerprints and mode, defaults older schemas 1–3 to DVT, and contains no coordinates or raw identifiers. A recovered native record routes **only** to native Clear. Reconnect the same stable iPhone over USB and choose **Return to Real Location**; another driver's Clear cannot erase the native reset obligation.
- If the recorded iPhone is permanently unavailable and a different stable iPhone is connected, **Forget Unavailable iPhone Record** can explicitly delete only YIOS-KIT's local safety record after a critical, default-Cancel warning. It sends no command to either phone, does not prove the unavailable phone returned to real location, and keeps that phone's location state described as unknown. Persistent sessions continue to be journaled by default; records are never discarded automatically.
- Apple's developer service has no supported read-back getter. The app therefore says **assumed active** after the set call replies and **reset request sent — real GPS expected** after clear; it never claims either state was independently confirmed.
- An interrupted/unknown session remains locked for review and offers only an exact-target clear. Other write operations remain blocked until the reset request is recorded.

### Backup Center, crash reports, and timeline

- **Open Finder…** only foregrounds Finder. Select the iPhone under Locations and start/verify the backup yourself. For protected categories such as saved passwords and Health data, use Finder's encrypted local-backup option and keep its password safe.
- **Copy from iPhone…** is privacy-sensitive and available only for one exact, paired, trusted, supported iPhone in verified Normal iOS. The app checks model identity, ECID, UDID, USB location, mode, and Trust both before and after confirmation. It requires a writable local volume, verifies current ownership, strips inherited extended ACLs, and enforces a 0700 folder before contact; afterward it repeats owner/ACL checks and enforces 0700/0600 on every enumerated directory/file. Permission, enumeration, target, or keep-contract uncertainty prevents a success claim and arms a manual-review lock. It passes mandatory `--keep`, exposes no remove command, and retains no raw tool output or report filename in the app log. This app does not upload, but another sync service may upload files if you select one of its folders.
- A filename containing `panic` is shown only as a filename observation. It is not proof of NAND, baseband, motherboard, or any other hardware failure.
- The **USB & Recovery Timeline** is passive, in-memory, limited to 200 current-session events, and never enables an action. Its optional export masks identifiers and local paths and is stored with permission 0600.

Do not run Finder Update/Restore, Apple Configurator, 3uTools, or another restore utility at the same time as this app. Finder itself normally stays open; close any device Update/Restore sheet before starting an operation here.

The app will never bypass Activation Lock. After restore, the legitimate owner's Apple Account may still be required.

## Accuracy and privacy boundaries

- `ActivationState: Activated` is displayed only as a device-reported activation fact. It does **not** prove Find My or Activation Lock is off.
- Warranty/AppleCare is not inferred. Use **Check coverage with Apple** and enter the serial yourself if desired.
- The app does not claim motherboard, display, camera, Face ID/Touch ID, NAND, baseband, or parts authenticity/health. Check **Settings > General > About > Parts & Service History** on the iPhone when that model and iOS version expose it.
- Current charge is not Apple's Battery Health/Maximum Capacity. Battery cycle count and health are shown as unavailable when no supported read-only source exposes them.
- Recovery/DFU/RestoreOS never reuses an older Normal-iOS battery, storage, SIM, or account snapshot as if it were current.
- Default reports omit full ECID/UDID/serial/IMEI/SIM/MAC/device-name values, app lists, crash contents, syslog, screenshots, backups, account data, and Mac paths.
- Copied crash reports remain highly sensitive even though the app stores them privately. Their raw content is deliberately excluded from Device Center reports, timelines, logs, and clipboard summaries.
- iOS Simulator cannot emulate iPhone USB PIDs, Trust/pairing, Recovery, DFU, RestoreOS, Configurator restore, or crashreportmover. UI and state-machine release tests therefore use sanitized fixtures; a connected phone is used only for separately scoped read-only verification unless the user explicitly starts a guarded action.

## Factory Reset versus Restore

**Factory Reset** uses Apple Configurator's targeted `erase` command on one paired, exactly identified supported iPhone that is fully booted in Normal iOS. It irreversibly removes user data and settings, keeps the currently installed iOS build, and does not download firmware. The app omits Configurator's eSIM-erasure option, so cellular eSIMs may remain. It blocks supervised devices because erase would remove supervision. This app cannot reliably verify Find My status, so you must sign out of Find My on the iPhone first. Factory Reset does not bypass Activation Lock and cannot repair a phone stuck in RestoreOS, Recovery, or DFU.

**Full Restore** is the Recovery/DFU path. It permanently erases the phone and reinstalls Apple-signed iOS firmware; it is not Erase All Content & Settings. It does not bypass Activation Lock, so the legitimate owner's Apple Account may still be required. Apple documents that an eSIM may remain after restore and that a Configurator-supervised phone may become unsupervised.

For reviewed devices, Restore retains the existing exact model/board checks and may use a separately validated compatible IPSW. For devices outside that catalog, **DFU Factory Restore — Erase & Reinstall iOS** is available only when the current Apple Configurator and YIOS-KIT independently attest the same exact iPhone DFU target. That generic path uses one exact-ECID Configurator command, Apple-latest firmware only, and no automatic retry. This is deliberately not a promise that every future iPhone or every KIS transport will qualify.

## Firmware

The default is the latest signed release obtained by Apple Configurator. A model-generic DFU Factory Restore always uses that default; Configurator-cache and manually chosen IPSW options stay disabled for it. Reviewed devices may explicitly choose **Use Configurator cache** or a local IPSW. Cached or manually chosen firmware receives a full ZIP integrity test and an exact target check across `SupportedProductTypes`, consumer `BuildIdentity` DeviceClass, CPID, and BDID. Research identities are ignored for ordinary restores. The validated model, sampled fingerprint, file size, and modification time are pinned and rechecked before the operation; Apple still verifies signing during restore.

## About the earlier error

The earlier Configurator attempt failed before writing firmware with:

```text
Can't start a restore from restoreOS.
Failed to create standard state machine.
```

The direct experimental attempt also stopped before writing because RestoreOS did not expose AP/SEP nonces, so a fresh SHSH response could not be obtained. Those messages did not prove NAND, baseband, cable, or other hardware failure.

## Build from source

To rebuild the pinned third-party toolchain, then the app, run:

```zsh
./Scripts/build-bundled-tools.sh
./Scripts/build-location-backend.sh
./build-app.sh
```

For a tested local release plus matching app-source and the included pinned
third-party source/notice archives, run:

```zsh
./Scripts/package-release.sh
```

The toolchain builds download official release archives, verify fixed SHA-256
digests, builds the complete dependency closure for `arm64-apple-macosx13.0`,
relocates every non-system dependency to bundle-relative `@rpath` paths, signs
the nested payload, and runs an offline verifier. It requires Xcode Command Line
Tools and `pkg-config` on the maintainer Mac; those are build requirements, not
end-user requirements for the inspection/recovery toolchain. The Mock Location
payload additionally requires this Mac's `/usr/bin/python3 3.9` while building
and running. Exact source URLs, checksums, build flags, the complete
`pymobiledevice3` source archive, and license material are shipped inside the
app resources.

The local build is ad-hoc signed for this Mac, not App Store notarized. A public
release should be signed with one Developer ID identity, notarized, and stapled.
The current Mock Location dependency closure is intended for the owner's
personal use; complete transitive license/source and notarization review is
required before redistributing that payload.
The source and bundled tools intentionally target `arm64-apple-macosx13.0`.
