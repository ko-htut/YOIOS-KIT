# YIOS-KIT — SE2 Device & Recovery Center

A native, Apple-silicon macOS app for detailed, source-attributed inspection and official recovery of an **iPhone SE (2nd generation / iPhone12,8)**. The app includes its own pinned libimobiledevice/libirecovery command-line toolchain, so the user does not need Homebrew. Apple Configurator remains an optional, separately installed Apple component for official erase/firmware operations. No jailbreak, exploit, activation bypass, or unsigned firmware path is included.

## What the app does

- Uses a dashboard-style native interface with a grouped sidebar, **Overview**, **Recovery**, **Evidence**, and **Activity** workspaces, mode-aware status, Quick Actions, and source-labelled readiness cards.
- Includes a **Dependency Doctor** that reports the exact built-in tool source/version, optional installed fallback, and which capabilities are ready. A complete built-in suite is always preferred; tools from different installations are never mixed within one capability.
- Adds a **Backup Center** in Activity that hands control to Finder. The app does not automate, start, observe, or claim completion of a backup and never asks for a backup password.
- Adds an explicit, exact-target **Crash & Panic Reports** copy workflow. It requires one trusted Normal-mode SE2, creates a new local folder with verified private permissions, always uses `idevicecrashreport --keep`, never requests deletion, never uploads through this app, and never retries automatically.
- Adds a bounded, structured **USB & Recovery Timeline** for the current app session. It records observed mode/PID transitions and this app's Apple-operation events without scraping iPhone syslog or inferring cable/hardware failure.
- Builds one timestamped Device Center snapshot from current USB/mode evidence and, only in verified trusted Normal iOS, read-only lockdownd and targeted Configurator properties.
- Shows available identity and software data such as device/model name, ProductType, hardware model, iOS/build, serial, CPID/BDID, model/region, baseband, ECID and UDID.
- Shows available cellular/network data such as IMEI 1/2 and device-reported Wi-Fi/Bluetooth addresses. Linkable or personal values are masked until the user explicitly reveals them for 60 seconds.
- Shows current charge/charging state and approximate total/free/category storage only when a device source returned coherent values. It never converts missing values to zero or “Normal.”
- Shows source and evidence status for every fact and exports a local, permission-0600 report with identifiers masked by default.
- Adds guarded **Restart** and **Shut Down** controls for one exact, trusted Normal-mode SE2. They require confirmation plus exact ECID, UDID, USB-port, mode, and Trust rechecks; they are unavailable in Recovery, DFU, RestoreOS, or USB-only states.
- Opens Apple's official coverage page without automatically sending the serial number.
- Requires exactly one connected Apple mobile device.
- Pins the target ECID and rechecks it before every Apple operation.
- Proves Normal iOS with `ideviceinfo`; a normal-looking USB PID alone is not enough.
- Proves Recovery/DFU with `irecovery`; a Recovery/DFU-looking PID alone cannot enable a write.
- Detects the stuck RestoreOS intermediate state and blocks direct restore from it.
- Shows a live Recovery/DFU button guide while monitoring the exact ECID.
- Offers Apple **Revive** first in verified Recovery Mode.
- Offers full Apple **Restore** only in verified Recovery/DFU after the user types `ERASE`.
- Offers **Factory Reset — Erase All Content & Settings** only for one paired, verified SE2 in Normal iOS.
- Never retries a failed flash automatically.
- Attempts to keep the Mac awake during an active Apple operation and prevents normal app quit.

The app does **not** use 3uTools, jailbreak/exploit tools, activation-lock bypasses, `idevicerestore`, or write-capable `irecovery` commands. It never bypasses Apple signing and cannot install unsigned or custom firmware.

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

Install **Apple Configurator** from Apple only if you need Apple Revive, full
Restore, or Factory Reset. Device inspection, Recovery/DFU verification,
Normal-to-Recovery transition, guarded restart/shutdown, and crash-report copy
use the built-in toolchain without Configurator. Finder remains the official
manual backup handoff.

## Use

1. Double-click **SE2 Recovery Assistant.app**.
2. Connect only the target SE2 and click **New Scan**. The Overview automatically loads richer details only after Normal iOS and existing Trust are verified.
3. Use **Evidence** to see exactly which source supplied each fact. Use **Activity** for Backup Center, an explicit crash-report copy, the redacted USB/recovery timeline, the app log, and the exact last error.
4. **Copy summary** and **Export report** are redacted by default. **Reveal for 60s** is required before sensitive values appear on screen.
5. For a usable phone already in verified Normal iOS, guarded **Restart**, **Shut Down**, or **Factory Reset** become available. Factory Reset irreversibly removes all content and settings without reinstalling or updating iOS.
6. If the app reports RestoreOS, click **Guide me to Recovery** and follow the on-screen physical button sequence. Physical Recovery/DFU entry cannot be automated safely.
7. If verified Recovery appears, try **Apple Revive** first if data matters.
8. If data does not matter, choose **Erase & Restore**, verify the displayed ECID and firmware, then type the exact uppercase word `ERASE`.
9. Keep the cable connected. After Factory Reset, wait for the Hello screen, then click **I checked the iPhone — Scan**; the app keeps other write actions and normal window closing blocked until this manual check.

### Backup Center, crash reports, and timeline

- **Open Finder…** only foregrounds Finder. Select the iPhone under Locations and start/verify the backup yourself. For protected categories such as saved passwords and Health data, use Finder's encrypted local-backup option and keep its password safe.
- **Copy from iPhone…** is privacy-sensitive and available only for one exact, paired, trusted SE2 in verified Normal iOS. The app checks ECID, UDID, USB location, mode, model, and Trust both before and after confirmation. It requires a writable local volume, verifies current ownership, strips inherited extended ACLs, and enforces a 0700 folder before contact; afterward it repeats owner/ACL checks and enforces 0700/0600 on every enumerated directory/file. Permission, enumeration, target, or keep-contract uncertainty prevents a success claim and arms a manual-review lock. It passes mandatory `--keep`, exposes no remove command, and retains no raw tool output or report filename in the app log. This app does not upload, but another sync service may upload files if you select one of its folders.
- A filename containing `panic` is shown only as a filename observation. It is not proof of NAND, baseband, motherboard, or any other hardware failure.
- The **USB & Recovery Timeline** is passive, in-memory, limited to 200 current-session events, and never enables an action. Its optional export masks identifiers and local paths and is stored with permission 0600.

Do not run Finder Update/Restore, Apple Configurator, 3uTools, or another restore utility at the same time as this app. Finder itself normally stays open; close any device Update/Restore sheet before starting an operation here.

The app will never bypass Activation Lock. After restore, the legitimate owner's Apple Account may still be required.

## Accuracy and privacy boundaries

- `ActivationState: Activated` is displayed only as a device-reported activation fact. It does **not** prove Find My or Activation Lock is off.
- Warranty/AppleCare is not inferred. Use **Check coverage with Apple** and enter the serial yourself if desired.
- The app does not claim motherboard, display, camera, Touch ID, NAND, baseband, or parts authenticity/health. For SE2 battery parts history, check **Settings > General > About > Parts & Service History** on the iPhone.
- Current charge is not Apple's Battery Health/Maximum Capacity. Battery cycle count and health are shown as unavailable when no supported read-only source exposes them.
- Recovery/DFU/RestoreOS never reuses an older Normal-iOS battery, storage, SIM, or account snapshot as if it were current.
- Default reports omit full ECID/UDID/serial/IMEI/SIM/MAC/device-name values, app lists, crash contents, syslog, screenshots, backups, account data, and Mac paths.
- Copied crash reports remain highly sensitive even though the app stores them privately. Their raw content is deliberately excluded from Device Center reports, timelines, logs, and clipboard summaries.
- iOS Simulator cannot emulate iPhone USB PIDs, Trust/pairing, Recovery, DFU, RestoreOS, Configurator restore, or crashreportmover. UI and state-machine release tests therefore use sanitized fixtures; a connected phone is used only for separately scoped read-only verification unless the user explicitly starts a guarded action.

## Factory Reset versus Restore

**Factory Reset** uses Apple Configurator's targeted `erase` command on a paired SE2 that is fully booted in Normal iOS. It irreversibly removes user data and settings, keeps the currently installed iOS build, and does not download firmware. The app omits Configurator's eSIM-erasure option, so cellular eSIMs may remain. It blocks supervised devices because erase would remove supervision. This app cannot reliably verify Find My status, so you must sign out of Find My on the iPhone first. Factory Reset does not bypass Activation Lock and cannot repair a phone stuck in RestoreOS, Recovery, or DFU.

**Full Restore** is the Recovery/DFU path. It erases the phone and installs Apple-signed iOS firmware.

## Firmware

The default is the latest signed release obtained by Apple Configurator. You may explicitly choose **Use Configurator cache** to avoid downloading the same firmware again. Cached or manually chosen firmware receives a full ZIP integrity test, an `iPhone12,8` / `d79ap` BuildManifest compatibility check, and a sampled fingerprint plus pinned size and modification time; Apple still verifies signing during restore.

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
./build-app.sh
```

For a tested local release plus matching app-source and complete pinned
third-party-source archives, run:

```zsh
./Scripts/package-release.sh
```

The toolchain build downloads official release archives, verifies fixed SHA-256
digests, builds the complete dependency closure for `arm64-apple-macosx13.0`,
relocates every non-system dependency to bundle-relative `@rpath` paths, signs
the nested payload, and runs an offline verifier. It requires Xcode Command Line
Tools and `pkg-config` on the maintainer Mac; those are build requirements, not
end-user requirements. Exact source URLs, checksums, build flags, and full
license texts are shipped under `Contents/Resources/ThirdPartyNotices`.

The local build is ad-hoc signed for this Mac, not App Store notarized. A public
release should be signed with one Developer ID identity, notarized, and stapled.
The source and bundled tools intentionally target `arm64-apple-macosx13.0`.
