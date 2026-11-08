# YIOS-KIT Companion

A small native SwiftUI app for a personally owned iPhone running iOS 17 or later. It previews coordinates on Apple Maps, stores up to 200 places locally, shares a selected coordinate, and reads the location reported by iOS only after an explicit request. Yangon is included as a starting preset. No Apple Account credentials or Mac pairing records are transferred to the app.

The companion does **not** set or resume system-wide Mock Location. It does not create a live Mac connection, sync saved places, run a VPN, or preserve a location simulation through an iPhone reboot. Those need a separate developer-service implementation and real-device verification. The installed app, saved coordinates, and an active simulated-location session are different things.

## Simulator

From the repository root:

```sh
./Scripts/build-companion.sh --simulator
```

The unsigned simulator build is written to `build/Companion/Simulator/YIOS-KIT Companion.app`. Install it into a selected, already booted simulator with `xcrun simctl install DEVICE_UUID 'build/Companion/Simulator/YIOS-KIT Companion.app'`, then launch bundle ID `local.minthanhtut.YIOSKitCompanion`. Simulator builds never install on the physical phone and are rejected by the Mac installer's payload verification.

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

The stable bundle ID is `local.minthanhtut.YIOSKitCompanion`, marketing version `1.0`, build `1`. Increase the build number for an installer-managed update. The Mac installer checks the exact trusted target and its profile eligibility before sending an install request.

## Icon

`Tools/generate-icon.swift` draws the project's original phone-and-pin artwork. Regenerate the source asset on macOS with:

```sh
xcrun swift Companion/Tools/generate-icon.swift Companion/YIOSKitCompanion/Assets.xcassets/AppIcon.appiconset/AppIcon.png
```
