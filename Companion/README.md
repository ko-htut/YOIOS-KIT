# YIOS-KIT Companion

A small native SwiftUI app for a personally owned iPhone running iOS 17 or later. It previews coordinates on Apple Maps, stores up to 200 places locally, shares a selected coordinate, and reads the location reported by iOS only after an explicit request. Yangon is included as a starting preset. No Apple Account credentials or Mac pairing records are transferred to the app.

The physical-iPhone build does **not** set or resume system-wide Mock Location. It does not sync saved places, run a developer VPN, or preserve a location simulation through an iPhone reboot. Those need a separate developer-service implementation and real-device verification. The installed app, saved coordinates, and an active simulated-location session are different things.

## Simulator

From the repository root:

```sh
./Scripts/build-companion.sh --simulator
```

The unsigned simulator build is written to `build/Companion/Simulator/YIOS-KIT Companion.app`. Install it into a selected, already booted simulator with `xcrun simctl install DEVICE_UUID 'build/Companion/Simulator/YIOS-KIT Companion.app'`, then launch bundle ID `local.minthanhtut.YIOSKitCompanion`. Simulator builds never install on the physical phone and are rejected by the Mac installer's payload verification.

### Mock Location in Simulator

The simulator build adds a **Mock Location** tab. A private loopback bridge on the Mac applies Set/Clear through Apple's simulator tool to one explicitly selected, booted iPhone simulator. The app labels a Set as verified only after a fresh Core Location callback matches the requested coordinate within 20 metres and iOS reports a software-simulated source. Command acknowledgement, observed coordinate, and readback evidence are separate. Clear discards previous observations and reports only the accepted clear; a simulator has no physical GPS fix to prove.

```sh
./Scripts/build-companion.sh --simulator
./Scripts/start-companion-simulator.sh EXACT_BOOTED_IPHONE_SIMULATOR_UUID
```

The bridge remains running in that terminal. Open **Mock Location** in the app, select or enter a coordinate, and choose **Set Simulator Location**. Use **Clear Simulator Location** when finished. Reopening the app never automatically resends coordinates, and backgrounding discards prior verification evidence. The launcher's private session configuration is supplied only to the simulator; no relay credentials or HTTP transport are compiled into the physical-phone build.

Run the actual button-driven UI checks, including Core Location readback, with:

```sh
./Scripts/test-companion-simulator.sh --simulator EXACT_BOOTED_IPHONE_SIMULATOR_UUID
```

The test script owns its bridge, builds the simulator UI test target, runs against the exact destination without parallel simulator clones, and sends an explicit Clear before closing its bridge. Private logs and XCTest screenshots are under `build/CompanionSimulator/ui-run-*/`. More protocol and offline-test details are in [the simulator bridge guide](../Backend/CompanionSimulator/README.md). Simulator results do not establish physical-iPhone developer-service support or reboot persistence.

Local verification on 2026-11-08 used an iPhone 17 simulator running iOS 27.0: all five UI tests and nineteen host tests passed. The UI flow verified fresh software-simulated Yangon and Singapore locations, Clear, reopening without cached proof, invalid coordinates, missing configuration, wrong sessions, and denied permission. The first-use authorization timing and denied-permission status races found during these runs were corrected. A separate unsigned physical-device build compiled successfully and excluded the simulator bridge configuration and localhost transport exception; it was not installed or used to change a phone.

## Signed iPhone build

Open `Companion/YIOSKitCompanion.xcodeproj` in Xcode and select your own team in Signing & Capabilities. Alternatively supply the team only to the local build command; the project contains no developer identity or provisioning profile:

```sh
./Scripts/build-companion.sh --device --team YOURTEAMID
```

`YIOS_COMPANION_TEAM` can supply the team instead of `--team`. This command uses existing signing assets and does not authorize provisioning updates. If an app-specific profile needs to be created using the Apple Account already signed in to Xcode, explicitly add `--allow-provisioning-updates`. This permits Xcode's provisioning workflow; it does not collect passwords, install on the phone, enable Developer Mode, or register a new device automatically. No `-allowProvisioningDeviceRegistration` flag is used.

The signed result is written to `build/Companion/Device/YIOS-KIT Companion.app`. The build script verifies its bundle identity, iPhone platform, code signature, signing certificate, registered-device profile and expiry before replacing that output. Its local build log is under `build/Companion/` and can contain private signing-account identifiers; do not publish it.

A free Personal Team profile normally expires after seven days. A paid Developer Program's normal development/ad hoc profile generally lasts around a year; use the actual profile's expiration date. This project does not promise automatic renewal or unlimited app validity. First installation still needs the iPhone unlocked, Trust approved, and Developer Mode enabled for a development-signed app.

## Mac packaging contract

The Mac app embeds only the **verified signed device build** at `Contents/Resources/Companion/YIOS-KIT Companion.app`. Preserve the iPhone bundle's existing signature and embedded profile. Never replace its signature with the Mac app's ad hoc signature. Simulator and unprovisioned builds cannot be used for automatic installation.

The stable bundle ID is `local.minthanhtut.YIOSKitCompanion`, marketing version `1.1`, build `2`. Increase the build number for an installer-managed update. The Mac installer checks the exact trusted target and its profile eligibility before sending an install request.

## Icon

`Tools/generate-icon.swift` draws the project's original phone-and-pin artwork. Regenerate the source asset on macOS with:

```sh
xcrun swift Companion/Tools/generate-icon.swift Companion/YIOSKitCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
