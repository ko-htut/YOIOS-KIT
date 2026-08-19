import AppKit
import SwiftUI

private enum VisualScenario: String, CaseIterable {
    case noDevice = "no-device"
    case normal
    case restoreOS = "restoreos"
    case restoreOSDFUExpanded = "restoreos-dfu-expanded"
    case recovery
    case dfu
    case postResetReview = "post-reset-review"
    case multiple
    case usbUnavailable = "usb-unavailable"
    case normalLogExpanded = "normal-log-expanded"
    case operationRunning = "operation-running"
    case operationFailed = "operation-failed"
    case crashReview = "crash-review"
}

@main
@MainActor
struct VisualTestMain {
    static func main() throws {
        guard CommandLine.arguments.count >= 3,
              let scenario = VisualScenario(rawValue: CommandLine.arguments[2]) else {
            let supported = VisualScenario.allCases.map(\.rawValue).joined(separator: ", ")
            fputs("Usage: visual-test <destination.png> <scenario> [width] [height] [light|dark] [top|full] [overview|recovery|evidence|activity]\n", stderr)
            fputs("Scenarios: \(supported)\n", stderr)
            exit(64)
        }

        let width = dimension(at: 3, defaultValue: 1040)
        let height = dimension(at: 4, defaultValue: 760)
        let appearance = CommandLine.arguments.count > 5 ? CommandLine.arguments[5] : "light"
        let capturePosition = CommandLine.arguments.count > 6 ? CommandLine.arguments[6] : "top"
        let sectionText = CommandLine.arguments.count > 7 ? CommandLine.arguments[7] : nil
        let initialSection = sectionText.flatMap { requested in
            AppWorkspaceSection.allCases.first { $0.rawValue.caseInsensitiveCompare(requested) == .orderedSame }
        }
        guard appearance == "light" || appearance == "dark",
              ["top", "full"].contains(capturePosition),
              sectionText == nil || initialSection != nil else {
            fputs("Appearance must be light/dark, capture position top/full, and section Overview/Recovery/Evidence/Activity.\n", stderr)
            exit(64)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)

        let model = RecoveryModel(autoSelectFirmware: false)
        configure(model, for: scenario)

        let root = ContentView(
            model: model,
            initiallyExpandDFUGuide: scenario == .restoreOSDFUExpanded,
            initiallyExpandLog: scenario == .normalLogExpanded,
            rendersFullContent: capturePosition == "full",
            initialSection: initialSection
        )
            .frame(width: width, height: height)
            .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)
        hosting.layoutSubtreeIfNeeded()

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "SE2VisualTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate UI snapshot."])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "SE2VisualTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode UI snapshot."])
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try png.write(to: destination, options: .atomic)
        print("\(scenario.rawValue) \(Int(width))x\(Int(height)) \(appearance) \(capturePosition): \(destination.path)")
    }

    private static func dimension(at index: Int, defaultValue: CGFloat) -> CGFloat {
        guard CommandLine.arguments.indices.contains(index) else { return defaultValue }
        guard let value = Double(CommandLine.arguments[index]), value >= 600 else {
            fputs("Width and height must be numeric values of at least 600.\n", stderr)
            exit(64)
        }
        return CGFloat(value)
    }

    private static func configure(_ model: RecoveryModel, for scenario: VisualScenario) {
        model.logText = "[03:20:00] State detection started.\n[03:20:01] Exact target identity pinned.\n[03:20:02] No destructive command has been started.\n"
        model.deviceTimeline = [
            DeviceTimelineEvent(
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                category: .app,
                title: "Assistant launched",
                detail: "Waiting for a stable USB scan."
            ),
            DeviceTimelineEvent(
                observedAt: Date(timeIntervalSince1970: 1_700_000_003),
                category: .usb,
                severity: .warning,
                title: "USB mode transition",
                detail: "USB evidence observed for the pinned target.",
                mode: .restoreOS,
                usbPID: 0x12AC
            ),
            DeviceTimelineEvent(
                observedAt: Date(timeIntervalSince1970: 1_700_000_006),
                category: .detection,
                severity: .success,
                title: "Recovery Mode",
                detail: "Protocol verified for the same SE2.",
                mode: .recovery,
                usbPID: 0x1281
            )
        ]

        switch scenario {
        case .noDevice:
            model.snapshot = DeviceSnapshot(mode: .notDetected, deviceCount: 0)
            model.statusText = "No iPhone detected"
            model.detailText = "Connect one iPhone SE (2nd generation) directly with a data-capable USB cable, then scan again."

        case .normal, .normalLogExpanded:
            applyNormalFixture(to: model)
            model.statusText = "Normal iOS mode verified"
            model.detailText = "The SE2 is trusted and communicating. Back up first if needed, enter Recovery for repair, or choose Factory Reset below."

        case .crashReview:
            applyNormalFixture(to: model)
            model.crashCopyReviewRequired = true
            model.crashReportSummary = CrashReportCopySummary(
                copiedAt: Date(timeIntervalSince1970: 1_700_000_010),
                directoryURL: URL(fileURLWithPath: "/private/fixture/SE2-Crash-Reports-20260819-060000", isDirectory: true),
                fileCount: 14,
                panicNamedFileCount: 2,
                enumerationWasTruncated: false,
                privacySecured: false,
                securityIssueCount: 1,
                targetVerifiedAfterCopy: false
            )
            model.statusText = "Crash-report copy outcome requires manual review"
            model.detailText = "Inspect the phone and private folder before clearing the one-session safety lock."

        case .restoreOS, .restoreOSDFUExpanded:
            model.snapshot = DeviceSnapshot(
                mode: .restoreOS,
                deviceCount: 1,
                usbPID: 0x12AC,
                locationID: 1_048_576,
                ecid: "0x1399A1401402E",
                udid: nil,
                productType: "iPhone12,8",
                hardwareModel: "d79ap",
                productVersion: nil,
                buildVersion: nil,
                activationState: nil,
                modeVerified: false
            )
            model.statusText = "RestoreOS intermediate mode detected"
            model.detailText = "Direct restore is blocked. Use the live button guide to reach verified Recovery or DFU first."

        case .recovery:
            model.snapshot = DeviceSnapshot(
                mode: .recovery,
                deviceCount: 1,
                usbPID: 0x1281,
                locationID: 1_048_576,
                ecid: "0x1399A1401402E",
                udid: nil,
                productType: "iPhone12,8",
                hardwareModel: "d79ap",
                productVersion: nil,
                buildVersion: nil,
                activationState: nil,
                modeVerified: true
            )
            model.statusText = "Recovery Mode verified"
            model.detailText = "The exact SE2 is ready. Try Apple Revive first to preserve data, or use Full Restore only if erasing is acceptable."

        case .dfu:
            model.snapshot = DeviceSnapshot(
                mode: .dfu,
                deviceCount: 1,
                usbPID: 0x1227,
                locationID: 1_048_576,
                ecid: "0x1399A1401402E",
                udid: nil,
                productType: "iPhone12,8",
                hardwareModel: "d79ap",
                productVersion: nil,
                buildVersion: nil,
                activationState: nil,
                modeVerified: true
            )
            model.statusText = "DFU Mode verified"
            model.detailText = "The display should remain black. DFU cannot use Revive; choose Full Restore below only if permanent erasure is acceptable."

        case .postResetReview:
            applyNormalFixture(to: model)
            model.snapshot.activationState = "Unactivated"
            model.postResetReviewRequired = true
            model.statusText = "Factory Reset accepted — check the iPhone"
            model.detailText = "Confirm that the Hello screen appeared for this exact SE2. Activation Lock may still require the legitimate Apple Account, and eSIMs may remain."
            model.logText += "[03:21:01] Reset transition observed for the same ECID.\n[03:21:03] Waiting for manual Hello-screen confirmation.\n"

        case .multiple:
            model.snapshot = DeviceSnapshot(mode: .multiple, deviceCount: 2)
            model.statusText = "Multiple Apple mobile devices detected"
            model.detailText = "Disconnect every phone except the target SE2. All write actions remain blocked."

        case .usbUnavailable:
            model.snapshot = DeviceSnapshot(
                mode: .usbUnavailable,
                deviceCount: 1,
                usbPID: 0x12A8,
                locationID: 1_048_576,
                ecid: "0x1399A1401402E",
                udid: nil,
                productType: "iPhone12,8",
                hardwareModel: "d79ap",
                productVersion: nil,
                buildVersion: nil,
                activationState: nil,
                modeVerified: false
            )
            model.statusText = "USB detected, iOS communication unavailable"
            model.detailText = "The phone is present over USB but lockdownd is unavailable. Writes are blocked; use the physical Recovery guide or scan again."

        case .operationRunning, .operationFailed:
            model.snapshot = DeviceSnapshot(
                mode: .recovery,
                deviceCount: 1,
                usbPID: 0x1281,
                locationID: 1_048_576,
                ecid: "0x1399A1401402E",
                udid: nil,
                productType: "iPhone12,8",
                hardwareModel: "d79ap",
                productVersion: nil,
                buildVersion: nil,
                activationState: nil,
                modeVerified: true
            )
            if scenario == .operationRunning {
                model.statusText = "Apple recovery in progress"
                model.detailText = "Keep the cable connected and prevent the Mac from sleeping until the operation finishes."
                model.operationRunning = true
                model.progress = 0.42
                model.operationStep = "Verifying device response…"
            } else {
                model.statusText = "Apple recovery stopped"
                model.detailText = "The operation was not retried. Review the exact error before deciding what to do next."
                model.lastError = "com.apple.MobileDevice code 4013: The iPhone disconnected while waiting for a response. Check the cable and USB port before retrying manually."
                model.operationRunning = false
                model.operationStep = ""
            }
        }
    }

    private static func applyNormalFixture(to model: RecoveryModel) {
        model.snapshot = DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x1C38A00A79802E",
            udid: "00008030-001C38A00A79802E",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true,
            deviceName: "Min's iPhone",
            serialNumber: "F17DK746PLJP",
            chipID: "0x8030",
            boardID: "0x10",
            usbLinkSpeed: 480_000_000,
            usbPowerSinkAllocation: 2_400
        )
        model.deviceCenterSnapshot = richNormalDetails(for: model.snapshot)
        model.deviceCenterStatusText = "Detailed read-only snapshot updated. Values are source-labelled and timestamped."
    }

    private static func richNormalDetails(for snapshot: DeviceSnapshot) -> DeviceCenterSnapshot {
        let captured = Date(timeIntervalSince1970: 1_787_091_600)
        let baseline = DeviceCenterCollector.baseline(for: snapshot, capturedAt: captured)
        let extra = [
            DeviceFact(id: "modelNumber", group: .identity, label: "Model number", value: "MHG63LL/A", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Device-reported model number.", sensitivity: .none),
            DeviceFact(id: "regionInfo", group: .identity, label: "Region info", value: "LL/A", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Device-reported sales-region code.", sensitivity: .none),
            DeviceFact(id: "cpuArchitecture", group: .identity, label: "CPU architecture", value: "arm64e", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Runtime architecture.", sensitivity: .none),
            DeviceFact(id: "basebandVersion", group: .software, label: "Baseband version", value: "7.00.01", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Modem firmware version, not a health test.", sensitivity: .none),
            DeviceFact(id: "imei1", group: .cellular, label: "IMEI 1", value: "356849110579414", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Linkable cellular identifier.", sensitivity: .identifier),
            DeviceFact(id: "imei2", group: .cellular, label: "IMEI 2", value: "356849110669678", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Linkable cellular identifier.", sensitivity: .identifier),
            DeviceFact(id: "wifiAddress", group: .cellular, label: "Wi-Fi address", value: "e8:7f:95:d3:60:2a", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Linkable network address.", sensitivity: .identifier),
            DeviceFact(id: "pairing", group: .security, label: "Pairing / Trust", value: "Validated", status: .verified, source: "idevicepair validate", explanation: "Existing Trust was validated.", sensitivity: .none),
            DeviceFact(id: "passcodeProtected", group: .security, label: "Passcode protection reported", value: "Yes", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Reported state.", sensitivity: .none),
            DeviceFact(id: "supervised", group: .security, label: "Supervised", value: "No", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Reported state.", sensitivity: .none),
            DeviceFact(id: "batteryPercent", group: .battery, label: "Current charge", value: "45%", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Current charge, not Battery Health.", sensitivity: .none),
            DeviceFact(id: "batteryCharging", group: .battery, label: "Charging", value: "Yes", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Current charging state.", sensitivity: .none),
            DeviceFact(id: "storageTotal", group: .storage, label: "Total capacity", value: "64 GB", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Approximate capacity.", sensitivity: .none),
            DeviceFact(id: "storageAvailable", group: .storage, label: "Available", value: "38.7 GB", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Approximate available space.", sensitivity: .none),
            DeviceFact(id: "storageUsed", group: .storage, label: "Used", value: "25.3 GB", status: .reported, source: "Calculated from reported capacity", explanation: "Approximate used space.", sensitivity: .none),
            DeviceFact(id: "storageApps", group: .storage, label: "Apps", value: "8.6 GB", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Approximate category.", sensitivity: .none),
            DeviceFact(id: "storagePhotos", group: .storage, label: "Photos", value: "4.2 GB", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Approximate category.", sensitivity: .none)
        ]
        return DeviceCenterSnapshot(
            capturedAt: captured,
            mode: snapshot.mode,
            targetECID: snapshot.ecid,
            targetUDID: snapshot.udid,
            facts: baseline.facts + extra,
            batteryPercent: 45,
            isCharging: true,
            totalStorageBytes: 64_000_000_000,
            availableStorageBytes: 38_661_283_840,
            notes: []
        )
    }
}
