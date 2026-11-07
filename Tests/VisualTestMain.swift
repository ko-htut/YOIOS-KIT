import AppKit
import SwiftUI

private enum VisualScenario: String, CaseIterable {
    case noDevice = "no-device"
    case normal
    case dashboard
    case devices
    case reports
    case history
    case dfuRestore = "dfu-restore"
    case moreTools = "more-tools"
    case guides
    case logs
    case guidesMonitoring = "guides-monitoring"
    case dfuRestoreMonitoring = "dfu-restore-monitoring"
    case restoreOS = "restoreos"
    case restoreOSDFUExpanded = "restoreos-dfu-expanded"
    case recovery
    case dfu
    case genericDFU = "generic-dfu"
    case kisDFU = "kis-dfu"
    case postResetReview = "post-reset-review"
    case multiple
    case usbUnavailable = "usb-unavailable"
    case normalLogExpanded = "normal-log-expanded"
    case operationRunning = "operation-running"
    case operationFailed = "operation-failed"
    case crashReview = "crash-review"
    case settings
    case mockLocationIdle = "mock-location-idle"
    case mockLocationReview = "mock-location-review"
    case mockLocationPersistent = "mock-location-persistent"
}

@main
@MainActor
struct VisualTestMain {
    private static let testDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "local.minthanhtut.YIOSKit.VisualTests")!
        defaults.set("system", forKey: "yoiosAppearance")
        return defaults
    }()

    static func main() throws {
        guard CommandLine.arguments.count >= 3,
              let scenario = VisualScenario(rawValue: CommandLine.arguments[2]) else {
            let supported = VisualScenario.allCases.map(\.rawValue).joined(separator: ", ")
            fputs("Usage: visual-test <destination.png> <scenario> [width] [height] [light|dark] [top|full] [overview|recovery|evidence|activity]\n", stderr)
            fputs("Scenarios: \(supported)\n", stderr)
            exit(64)
        }

        let width = dimension(at: 3, defaultValue: 1040, minimum: 1_040)
        let height = dimension(at: 4, defaultValue: 760, minimum: 700)
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
        testDefaults.set("system", forKey: "yoiosAppearance")

        let model = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: mockLocationController(for: scenario),
            dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
        )
        configure(model, for: scenario)

        let initialDestination = destination(for: scenario)

        let root = ContentView(
            model: model,
            initiallyExpandDFUGuide: scenario == .restoreOSDFUExpanded,
            initiallyExpandLog: scenario == .normalLogExpanded,
            rendersFullContent: capturePosition == "full",
            initialSection: initialSection,
            initialDestination: initialDestination
        )
            .frame(width: width, height: height)
            .environment(\.colorScheme, appearance == "dark" ? .dark : .light)
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
            .defaultAppStorage(testDefaults)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: NSSize(width: width, height: height)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.orderFront(nil)

        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            throw NSError(domain: "YIOSKitVisualTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not allocate UI snapshot."])
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "YIOSKitVisualTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not encode UI snapshot."])
        }
        let destination = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try png.write(to: destination, options: .atomic)
        window.close()
        print("\(scenario.rawValue) \(Int(width))x\(Int(height)) \(appearance) \(capturePosition): \(destination.path)")
    }

    private static func dimension(at index: Int, defaultValue: CGFloat, minimum: CGFloat) -> CGFloat {
        guard CommandLine.arguments.indices.contains(index) else { return defaultValue }
        guard let value = Double(CommandLine.arguments[index]), value >= minimum else {
            fputs("Width must be at least 1040 and height must be at least 700.\n", stderr)
            exit(64)
        }
        return CGFloat(value)
    }

    private static func destination(for scenario: VisualScenario) -> AppSidebarDestination? {
        switch scenario {
        case .dashboard: return .dashboard
        case .devices: return .devices
        case .reports: return .reports
        case .history: return .history
        case .recovery: return .recovery
        case .dfuRestore, .dfuRestoreMonitoring: return .dfuRestore
        case .moreTools: return .moreTools
        case .guides, .guidesMonitoring: return .guides
        case .logs, .operationFailed: return .logs
        case .settings: return .settings
        case .mockLocationIdle, .mockLocationReview, .mockLocationPersistent: return .mockLocation
        default: return nil
        }
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
                detail: "Protocol and exact supported-device identity verified.",
                mode: .recovery,
                usbPID: 0x1281
            )
        ]

        switch scenario {
        case .noDevice:
            model.snapshot = DeviceSnapshot(mode: .notDetected, deviceCount: 0)
            model.statusText = "No iPhone detected"
            model.detailText = "Connect one iPhone directly with a data-capable USB cable, then choose New Scan to read its mode and available actions."

        case .normal, .dashboard, .devices, .reports, .history, .moreTools, .guides, .logs, .normalLogExpanded, .settings:
            applyNormalFixture(to: model)
            model.statusText = "Normal iOS mode verified"
            model.detailText = "The supported iPhone is trusted and communicating. Back up first if needed, enter Recovery for repair, or choose Factory Reset below."

        case .guidesMonitoring, .dfuRestoreMonitoring:
            applyNormalFixture(to: model)
            model.isMonitoring = true
            model.statusText = "Watching the connected iPhone for Recovery or DFU"
            model.detailText = "Follow the physical button sequence. You can stop the USB watcher from any page."

        case .mockLocationIdle, .mockLocationReview, .mockLocationPersistent:
            applyNormalFixture(to: model, productType: "iPhone12,8")
            model.statusText = "Normal iOS mode verified"
            model.detailText = "The SE2-only Mock Location target is trusted and communicating."

        case .crashReview:
            applyNormalFixture(to: model)
            model.crashCopyReviewRequired = true
            model.crashReportSummary = CrashReportCopySummary(
                copiedAt: Date(timeIntervalSince1970: 1_700_000_010),
                directoryURL: URL(fileURLWithPath: "/private/fixture/YIOS-KIT-Crash-Reports-20260819-060000", isDirectory: true),
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
            model.snapshot = lowLevelFixture(
                mode: .restoreOS,
                productType: "iPhone12,3",
                pid: 0x12AC,
                modeVerified: false,
                identityQueryVerified: false
            )
            model.statusText = "RestoreOS intermediate mode detected"
            model.detailText = "Direct restore is blocked. Use the live button guide to reach verified Recovery or DFU first."

        case .recovery:
            model.snapshot = lowLevelFixture(
                mode: .recovery,
                productType: "iPhone11,4",
                pid: 0x1281,
                modeVerified: true,
                identityQueryVerified: true
            )
            model.statusText = "Recovery Mode verified"
            model.detailText = "The exact supported iPhone is ready. Try Apple Revive first to preserve data, or use Full Restore only if erasing is acceptable."

        case .dfu, .dfuRestore:
            model.snapshot = lowLevelFixture(
                mode: .dfu,
                productType: "iPhone10,4",
                pid: 0x1227,
                modeVerified: true,
                identityQueryVerified: true
            )
            model.statusText = "DFU Mode verified"
            model.detailText = "The display should remain black. DFU cannot use Revive; choose Full Restore below only if permanent erasure is acceptable."

        case .genericDFU:
            model.snapshot = genericDFUFixture(kis: false)
            model.statusText = "Exact iPhone DFU target verified"
            model.detailText = "DFU Factory Restore can permanently erase this exact iPhone and reinstall Apple's latest compatible signed iOS. Activation Lock remains."

        case .kisDFU:
            model.snapshot = genericDFUFixture(kis: true)
            model.statusText = "Apple-restorable KIS DFU target verified"
            model.detailText = "Apple Configurator attested this exact Debug USB target. Raw KIS PID alone is never accepted for erase and reinstall."

        case .postResetReview:
            applyNormalFixture(to: model)
            model.snapshot.activationState = "Unactivated"
            model.postResetReviewRequired = true
            model.statusText = "Factory Reset accepted — check the iPhone"
            model.detailText = "Confirm that the Hello screen appeared for this exact supported iPhone. Activation Lock may still require the legitimate Apple Account, and eSIMs may remain."
            model.logText += "[03:21:01] Reset transition observed for the same ECID.\n[03:21:03] Waiting for manual Hello-screen confirmation.\n"

        case .multiple:
            model.snapshot = DeviceSnapshot(mode: .multiple, deviceCount: 2)
            model.statusText = "Multiple Apple mobile devices detected"
            model.detailText = "Disconnect every phone except the supported iPhone you intend to recover. All write actions remain blocked."

        case .usbUnavailable:
            model.snapshot = lowLevelFixture(
                mode: .usbUnavailable,
                productType: "iPhone12,1",
                pid: 0x12A8,
                modeVerified: false,
                identityQueryVerified: false
            )
            model.statusText = "USB detected, iOS communication unavailable"
            model.detailText = "The phone is present over USB but lockdownd is unavailable. Writes are blocked; use the physical Recovery guide or scan again."

        case .operationRunning, .operationFailed:
            model.snapshot = lowLevelFixture(
                mode: .recovery,
                productType: "iPhone12,5",
                pid: 0x1281,
                modeVerified: true,
                identityQueryVerified: true
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

    private static func lowLevelFixture(
        mode: DeviceMode,
        productType: String,
        pid: Int,
        modeVerified: Bool,
        identityQueryVerified: Bool
    ) -> DeviceSnapshot {
        let supportedModel = SupportedDeviceCatalog.model(productType: productType)!
        return DeviceSnapshot(
            mode: mode,
            deviceCount: 1,
            usbPID: pid,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: nil,
            productType: supportedModel.productType,
            hardwareModel: supportedModel.hardwareModel,
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: modeVerified,
            marketingName: supportedModel.marketingName,
            chipID: String(format: "0x%X", supportedModel.chipID),
            boardID: String(format: "0x%X", supportedModel.boardID),
            recoveryIdentityQueryVerified: identityQueryVerified
        )
    }

    private static func genericDFUFixture(kis: Bool) -> DeviceSnapshot {
        DeviceSnapshot(
            mode: .dfu,
            deviceCount: 1,
            usbPID: kis ? 0x1881 : 0x1227,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            productType: kis ? "iPhone12,8" : "iPhone18,3",
            hardwareModel: kis ? "d79ap" : "d93ap",
            modeVerified: !kis,
            chipID: kis ? "0x8030" : "0x8301",
            boardID: kis ? "0x10" : "0x0A",
            recoveryIdentityQueryVerified: kis,
            recoveryIdentityQueryTargetVerified: !kis,
            configuratorDFURestoreVerified: kis
        )
    }

    private static func mockLocationController(for scenario: VisualScenario) -> MockLocationController {
        guard scenario == .mockLocationReview || scenario == .mockLocationPersistent else {
            return MockLocationController.offlineFixture()
        }
        let snapshot = normalTargetFixture()
        guard let target = try? MockLocationExactTarget(snapshot: snapshot) else {
            return MockLocationController.offlineFixture()
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let isPersistent = scenario == .mockLocationPersistent
        let record = MockLocationJournalRecord(
            state: isPersistent ? .assumedPersistent : .assumedActive,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: isPersistent ? .persistentUntilClearOrReboot : .liveSession,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        return MockLocationController.offlineFixture(recoveredRecord: record)
    }

    private static func normalTargetFixture() -> DeviceSnapshot {
        DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: "00008030-00123456789ABCDE",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true
        )
    }

    private static func applyNormalFixture(
        to model: RecoveryModel,
        productType: String = "iPhone12,1"
    ) {
        let supportedModel = SupportedDeviceCatalog.model(productType: productType)!
        model.snapshot = DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: "00008030-00123456789ABCDE",
            productType: supportedModel.productType,
            hardwareModel: supportedModel.hardwareModel,
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true,
            deviceName: "Fixture iPhone",
            marketingName: supportedModel.marketingName,
            serialNumber: "SYNTHETIC0001",
            chipID: String(format: "0x%X", supportedModel.chipID),
            boardID: String(format: "0x%X", supportedModel.boardID),
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
            DeviceFact(id: "modelNumber", group: .identity, label: "Model number", value: snapshot.productType == "iPhone12,8" ? "MHG63LL/A" : "MWL72LL/A", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Device-reported model number.", sensitivity: .none),
            DeviceFact(id: "regionInfo", group: .identity, label: "Region info", value: "LL/A", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Device-reported sales-region code.", sensitivity: .none),
            DeviceFact(id: "cpuArchitecture", group: .identity, label: "CPU architecture", value: "arm64e", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Runtime architecture.", sensitivity: .none),
            DeviceFact(id: "basebandVersion", group: .software, label: "Baseband version", value: "7.00.01", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Modem firmware version, not a health test.", sensitivity: .none),
            DeviceFact(id: "imei1", group: .cellular, label: "IMEI 1", value: "356000000000001", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Linkable cellular identifier.", sensitivity: .identifier),
            DeviceFact(id: "imei2", group: .cellular, label: "IMEI 2", value: "356000000000002", status: .reported, source: "Apple Configurator / cfgutil", explanation: "Linkable cellular identifier.", sensitivity: .identifier),
            DeviceFact(id: "wifiAddress", group: .cellular, label: "Wi-Fi address", value: "02:00:00:00:00:01", status: .reported, source: "lockdownd / ideviceinfo", explanation: "Linkable network address.", sensitivity: .identifier),
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
