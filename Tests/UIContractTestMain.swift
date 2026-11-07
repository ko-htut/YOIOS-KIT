import AppKit
import SwiftUI

private enum UIContractScenario: String, CaseIterable {
    case noDevice = "no-device"
    case normal
    case restoreOS = "restoreos"
    case recovery
    case dfu
    case usbUnavailable = "usb-unavailable"
    case multiple
    case postResetReview = "post-reset-review"
}

private struct AXNodeSnapshot {
    let identifier: String?
    let label: String?
    let enabled: Bool
}

@main
@MainActor
struct UIContractTestMain {
    private static let renderSize = NSSize(width: 1_040, height: 820)
    private static let testDefaults: UserDefaults = {
        let defaults = UserDefaults(suiteName: "local.minthanhtut.YIOSKit.UIContractTests")!
        defaults.set("system", forKey: "yoiosAppearance")
        return defaults
    }()
    private static var failures: [String] = []
    private static var usedNativeAccessibility = false

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        testDefaults.set("system", forKey: "yoiosAppearance")
        assertStaticSourceContracts()
        assertMotionPolicy()

        for scenario in UIContractScenario.allCases {
            let model = fixture(for: scenario)
            assertPureContract(model, scenario: scenario)

            let rendered = render(model: model, colorScheme: .light)
            expect(rendered.bitmapWasCreated, scenario, "ContentView did not produce an offscreen bitmap")

            let nodes = accessibilityTree(from: rendered.hostingView)
            if nodes.contains(where: { $0.identifier == "scanButton" }) &&
                nodes.contains(where: { $0.identifier == "primaryActionButton" }) {
                usedNativeAccessibility = true
                assertAccessibilityContract(nodes, model: model, scenario: scenario)
            }

            // A second construction in Dark Mode catches environment-dependent
            // view-builder failures without writing screenshots or invoking actions.
            let darkRendered = render(model: fixture(for: scenario), colorScheme: .dark)
            expect(darkRendered.bitmapWasCreated, scenario, "Dark Mode ContentView did not render offscreen")

            rendered.window.close()
            darkRendered.window.close()
        }

        let sectionModel = fixture(for: .normal)
        for section in [AppWorkspaceSection.evidence, .activity] {
            let rendered = render(model: sectionModel, colorScheme: .light, initialSection: section)
            expect(rendered.bitmapWasCreated, .normal, "\(section.rawValue) tab did not render offscreen")
            let nodes = accessibilityTree(from: rendered.hostingView)
            if usedNativeAccessibility {
                let expectedID = section == .evidence ? "deviceEvidenceView" : "deviceActivityView"
                expect(node(expectedID, in: nodes) != nil, .normal, "missing \(section.rawValue) accessibility container")
            }
            rendered.window.close()
        }

        let settingsRender = render(
            model: fixture(for: .normal),
            colorScheme: .light,
            initialDestination: .settings
        )
        expect(settingsRender.bitmapWasCreated, .normal, "Settings workspace did not render offscreen")
        if usedNativeAccessibility {
            let nodes = accessibilityTree(from: settingsRender.hostingView)
            for identifier in ["settingsWorkspace", "settingsDependencyPanel", "settingsCapabilitiesPanel", "settingsBackButton"] {
                expect(node(identifier, in: nodes) != nil, .normal, "missing Settings accessibility container \(identifier)")
            }
        }
        settingsRender.window.close()

        let devicesRender = render(
            model: fixture(for: .normal),
            colorScheme: .light,
            initialDestination: .devices
        )
        expect(devicesRender.bitmapWasCreated, .normal, "Devices workspace did not render offscreen")
        if usedNativeAccessibility {
            let nodes = accessibilityTree(from: devicesRender.hostingView)
            expect(node("deviceCenterOverview", in: nodes) != nil, .normal, "Devices workspace is missing the detailed Device Center")
        }
        devicesRender.window.close()

        let activityRoutes: [(AppSidebarDestination, String)] = [
            (.history, "deviceTimelinePanel"),
            (.moreTools, "backupCenterPanel"),
            (.logs, "diagnosticLogPanel")
        ]
        for (destination, priorityPanel) in activityRoutes {
            let activityRender = render(
                model: fixture(for: .normal),
                colorScheme: .light,
                initialDestination: destination
            )
            expect(activityRender.bitmapWasCreated, .normal, "\(destination.rawValue) workspace did not render offscreen")
            if usedNativeAccessibility {
                let nodes = accessibilityTree(from: activityRender.hostingView)
                expect(node("deviceActivityView", in: nodes) != nil, .normal, "\(destination.rawValue) is missing the Activity container")
                expect(node(priorityPanel, in: nodes) != nil, .normal, "\(destination.rawValue) is missing its priority panel")
            }
            activityRender.window.close()
        }

        let mockLocationModel = fixture(for: .normal)
        applyNormalFixture(to: mockLocationModel, supportedModel: SupportedDeviceCatalog.se2)
        let mockLocationRender = render(
            model: mockLocationModel,
            colorScheme: .light,
            initialDestination: .mockLocation
        )
        expect(mockLocationRender.bitmapWasCreated, .normal, "Mock Location workspace did not render offscreen")
        if usedNativeAccessibility {
            let nodes = accessibilityTree(from: mockLocationRender.hostingView)
            for identifier in [
                "mockLocationWorkspace", "mockLocationStatusPanel", "mockLocationTargetPanel",
                "mockLocationReadinessPanel", "mockLocationCoordinatePanel", "mockLocationSafetyPanel",
                "mockLocationLatitudeField", "mockLocationLongitudeField",
                "mockLocationPersistentModeToggle", "mockLocationCheckReadinessButton",
                "mockLocationSetButton", "mockLocationClearButton"
            ] {
                expect(node(identifier, in: nodes) != nil, .normal, "missing Mock Location accessibility container \(identifier)")
            }
            assertButton(
                "mockLocationSetButton",
                expectedLabel: "Start Mock Location",
                expectedEnabled: mockLocationModel.mockLocationController.canSetLocation,
                nodes: nodes,
                scenario: .normal
            )
            assertButton(
                "mockLocationClearButton",
                expectedLabel: "Return to Real Location",
                expectedEnabled: mockLocationModel.mockLocationController.canReturnToRealLocation,
                nodes: nodes,
                scenario: .normal
            )
        }
        mockLocationRender.window.close()

        for persistent in [false, true] {
            let lockedModel = lockedMockLocationModel(persistent: persistent)
            assertMockLocationInterlock(lockedModel, persistent: persistent)
            let lockedRender = render(
                model: lockedModel,
                colorScheme: .dark,
                initialDestination: .mockLocation,
                disableAnimations: true
            )
            let stateName = persistent ? "persistent" : "review"
            expect(lockedRender.bitmapWasCreated, .normal, "Mock Location \(stateName) state did not render with animations disabled")
            if usedNativeAccessibility {
                let nodes = accessibilityTree(from: lockedRender.hostingView)
                expect(node("mockLocationStatusPanel", in: nodes) != nil, .normal, "Mock Location \(stateName) warning/status panel is missing")
                assertButton(
                    "mockLocationSetButton",
                    expectedLabel: "Start Mock Location",
                    expectedEnabled: false,
                    nodes: nodes,
                    scenario: .normal
                )
                assertButton(
                    "mockLocationClearButton",
                    expectedLabel: "Return to Real Location",
                    expectedEnabled: lockedModel.mockLocationController.canReturnToRealLocation,
                    nodes: nodes,
                    scenario: .normal
                )
            }
            lockedRender.window.close()
        }

        let mismatchedRecordModel = mismatchedMockLocationRecordModel()
        expect(
            mismatchedRecordModel.mockLocationController.shouldOfferForgetUnavailableRecord,
            .normal,
            "different stable iPhone must expose the explicit local-record forget path"
        )
        expect(
            !mismatchedRecordModel.mockLocationController.shouldOfferDeveloperModeOptionRequest,
            .normal,
            "different stable iPhone must hide the Developer Mode request while the old record is locked"
        )
        let mismatchedRender = render(
            model: mismatchedRecordModel,
            colorScheme: .dark,
            initialDestination: .mockLocation,
            disableAnimations: true
        )
        expect(mismatchedRender.bitmapWasCreated, .normal, "mismatched Mock Location safety record did not render")
        if usedNativeAccessibility {
            let nodes = accessibilityTree(from: mismatchedRender.hostingView)
            expect(node("mockLocationForgetUnavailableRecordPanel", in: nodes) != nil, .normal, "mismatched record warning panel is missing")
            assertButton(
                "mockLocationForgetUnavailableRecordButton",
                expectedLabel: "Forget Unavailable iPhone Record",
                expectedEnabled: true,
                nodes: nodes,
                scenario: .normal
            )
            expect(node("mockLocationShowDeveloperModeButton", in: nodes) == nil, .normal, "Developer Mode request must not appear for a different locked phone")
        }
        mismatchedRender.window.close()

        let motionRender = render(
            model: fixture(for: .normal),
            colorScheme: .light,
            initialDestination: .dashboard,
            disableAnimations: false
        )
        expect(motionRender.bitmapWasCreated, .normal, "Motion-enabled dashboard did not render offscreen")
        motionRender.window.close()

        let crashReviewModel = fixture(for: .normal)
        crashReviewModel.crashCopyReviewRequired = true
        crashReviewModel.crashReportSummary = CrashReportCopySummary(
            copiedAt: Date(timeIntervalSince1970: 1_700_000_010),
            directoryURL: URL(fileURLWithPath: "/private/fixture/YIOS-KIT-Crash-Reports", isDirectory: true),
            fileCount: 3,
            panicNamedFileCount: 1,
            enumerationWasTruncated: false,
            privacySecured: false,
            securityIssueCount: 1,
            targetVerifiedAfterCopy: false
        )
        let crashReviewRender = render(
            model: crashReviewModel,
            colorScheme: .dark,
            initialSection: .activity
        )
        expect(crashReviewRender.bitmapWasCreated, .normal, "crash-review Activity state did not render")
        let crashReviewNodes = accessibilityTree(from: crashReviewRender.hostingView)
        if usedNativeAccessibility {
            expect(node("clearCrashReviewButton", in: crashReviewNodes) != nil, .normal, "crash-review state is missing its only unlock control")
            assertButton(
                "copyCrashReportsButton",
                expectedLabel: "Copy from iPhone",
                expectedEnabled: false,
                nodes: crashReviewNodes,
                scenario: .normal
            )
        }
        crashReviewRender.window.close()

        if !usedNativeAccessibility {
            // SwiftUI does not consistently vend its virtual AX hierarchy from an
            // offscreen NSHostingView on every macOS release. In that case, retain
            // deterministic protection by checking the compiled model contracts,
            // successful light/dark construction, and pure model contracts. Static
            // source contracts run unconditionally above on every host.
            print("UI CONTRACT NOTE: offscreen SwiftUI accessibility nodes were unavailable; pure contract fallback used.")
        }

        if failures.isEmpty {
            print("UI CONTRACT TEST PASS (nativeAX=\(usedNativeAccessibility))")
            exit(0)
        }

        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(1)
    }

    private static func fixture(for scenario: UIContractScenario) -> RecoveryModel {
        let model = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture(),
            dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
        )

        switch scenario {
        case .noDevice:
            model.snapshot = DeviceSnapshot(mode: .notDetected, deviceCount: 0)
            model.statusText = "No iPhone detected"
            model.detailText = "Connect one supported iPhone (iPhone 8 through SE 2), then scan again."

        case .normal:
            applyNormalFixture(to: model)
            model.statusText = "Normal iOS mode verified"
            model.detailText = "The verified supported iPhone is communicating in Normal iOS."

        case .restoreOS:
            model.snapshot = recoveryFixture(
                mode: .restoreOS,
                pid: 0x12AC,
                verified: false,
                supportedModel: SupportedDeviceCatalog.model(productType: "iPhone12,3")!
            )
            model.statusText = "RestoreOS intermediate mode detected"
            model.detailText = "Direct restore is blocked; enter verified Recovery or DFU first."

        case .recovery:
            model.snapshot = recoveryFixture(
                mode: .recovery,
                pid: 0x1281,
                verified: true,
                supportedModel: SupportedDeviceCatalog.model(productType: "iPhone11,4")!
            )
            model.statusText = "Recovery Mode verified"
            model.detailText = "Try Apple Revive first, or explicitly choose Full Restore."

        case .dfu:
            model.snapshot = recoveryFixture(
                mode: .dfu,
                pid: 0x1227,
                verified: true,
                supportedModel: SupportedDeviceCatalog.model(productType: "iPhone10,4")!
            )
            model.statusText = "DFU Mode verified"
            model.detailText = "DFU is verified; only the explicit Restore path is available."

        case .usbUnavailable:
            model.snapshot = DeviceSnapshot(
                mode: .usbUnavailable,
                deviceCount: 1,
                usbPID: 0x12A8,
                locationID: 1_048_576,
                ecid: "0x123456789ABCDE",
                modeVerified: false
            )
            model.statusText = "Apple USB device detected"
            model.detailText = "The Apple protocol is unavailable; write actions remain blocked."

        case .multiple:
            model.snapshot = DeviceSnapshot(mode: .multiple, deviceCount: 2)
            model.statusText = "Multiple Apple mobile devices detected"
            model.detailText = "Disconnect every extra device before continuing."

        case .postResetReview:
            applyNormalFixture(to: model)
            model.snapshot.activationState = "Unactivated"
            model.postResetReviewRequired = true
            model.statusText = "Factory Reset accepted — check the iPhone"
            model.detailText = "Confirm the Hello screen before the manual Scan action."
        }

        return model
    }

    private static func applyNormalFixture(
        to model: RecoveryModel,
        supportedModel: SupportedDeviceModel = SupportedDeviceCatalog.model(productType: "iPhone12,1")!
    ) {
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
            marketingName: supportedModel.marketingName,
            chipID: String(format: "0x%X", supportedModel.chipID),
            boardID: String(format: "0x%X", supportedModel.boardID)
        )
    }

    private static func lockedMockLocationModel(persistent: Bool) -> RecoveryModel {
        let snapshot = DeviceSnapshot(
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
        guard let target = try? MockLocationExactTarget(snapshot: snapshot) else {
            return RecoveryModel(
                autoSelectFirmware: false,
                mockLocationController: MockLocationController.offlineFixture(),
                dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = MockLocationJournalRecord(
            state: persistent ? .assumedPersistent : .assumedActive,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: persistent ? .persistentUntilClearOrReboot : .liveSession,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let model = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture(recoveredRecord: record),
            dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
        )
        applyNormalFixture(to: model, supportedModel: SupportedDeviceCatalog.se2)
        return model
    }

    private static func mismatchedMockLocationRecordModel() -> RecoveryModel {
        let recordedSnapshot = DeviceSnapshot(
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
        guard let recordedTarget = try? MockLocationExactTarget(snapshot: recordedSnapshot) else {
            return RecoveryModel(
                autoSelectFirmware: false,
                mockLocationController: MockLocationController.offlineFixture(),
                dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
            )
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let record = MockLocationJournalRecord(
            state: .assumedPersistent,
            pin: recordedTarget.pin,
            stablePin: recordedTarget.stablePin,
            setMode: .persistentUntilClearOrReboot,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let model = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture(recoveredRecord: record),
            dependencyDoctorSnapshot: DashboardTestSupport.dependencyDoctorSnapshot
        )
        var connectedSnapshot = recordedSnapshot
        connectedSnapshot.ecid = "0xABCDEF12345678"
        connectedSnapshot.udid = "00008030-00ABCDEF12345678"
        model.snapshot = connectedSnapshot
        model.mockLocationController.refreshLocalState()
        return model
    }

    private static func assertMockLocationInterlock(_ model: RecoveryModel, persistent: Bool) {
        expect(!model.canChooseIPSW, .normal, "Mock Location \(persistent ? "persistent" : "review") state must block firmware selection")
        expect(!model.canRevive, .normal, "Mock Location lock must block Revive")
        expect(!model.canRestore, .normal, "Mock Location lock must block Restore")
        expect(!model.canFactoryReset, .normal, "Mock Location lock must block Factory Reset")
        expect(!model.canUseNormalDeviceUtilities, .normal, "Mock Location lock must block power controls")
        expect(!model.canOpenFinderBackup, .normal, "Mock Location lock must block Finder handoff")
        expect(!model.canCopyCrashReports, .normal, "Mock Location lock must block crash-copy contact")
        expect(!model.canRefreshDeviceCenter, .normal, "Mock Location lock must block detail refresh")
        expect(!model.primaryActionEnabled, .normal, "Mock Location lock must block the primary recovery action")
    }

    private static func recoveryFixture(
        mode: DeviceMode,
        pid: Int,
        verified: Bool,
        supportedModel: SupportedDeviceModel
    ) -> DeviceSnapshot {
        DeviceSnapshot(
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
            modeVerified: verified,
            marketingName: supportedModel.marketingName,
            chipID: String(format: "0x%X", supportedModel.chipID),
            boardID: String(format: "0x%X", supportedModel.boardID),
            recoveryIdentityQueryVerified: verified && (mode == .recovery || mode == .dfu)
        )
    }

    private static func assertPureContract(
        _ model: RecoveryModel,
        scenario: UIContractScenario
    ) {
        let configuratorReady = ToolPaths.hasConfigurator
        let pairingToolReady = ToolPaths.idevicePair != nil

        expect(!model.operationRunning, scenario, "fixture must never start an operation")
        expect(!model.isScanning, scenario, "fixture must never start a scan")
        expect(!model.isMonitoring, scenario, "fixture must never start USB monitoring")
        expect(!model.destructiveWorkflowActive, scenario, "fixture must never arm a destructive workflow")

        switch scenario {
        case .noDevice:
            expect(model.primaryActionTitle == "Scan for iPhone", scenario, "wrong primary label")
            expect(model.primaryActionEnabled, scenario, "Scan must be enabled")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "write actions must be disabled")
            expect(!model.canStartDFUAssistant, scenario, "DFU Assistant must require one exact target")

        case .normal:
            expect(model.primaryActionEnabled, scenario, "Normal iOS Recovery entry must be enabled")
            expect(model.canStartDFUAssistant, scenario, "exact Normal iOS must allow the passive DFU Assistant")
            expect(!model.canRevive && !model.canRestore, scenario, "Recovery/DFU writes must be disabled in Normal iOS")
            expect(
                model.canFactoryReset == (configuratorReady && pairingToolReady),
                scenario,
                "Factory Reset availability must match its installed-tool prerequisites"
            )

        case .restoreOS:
            expect(model.primaryActionTitle == "Guide me to Recovery", scenario, "wrong primary label")
            expect(model.primaryActionEnabled, scenario, "physical Recovery guide must be available")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "RestoreOS must block every write")
            expect(!model.snapshot.recoveryIdentityQueryVerified, scenario, "RestoreOS fixture must not claim a targeted Recovery/DFU query")
            expect(model.canStartDFUAssistant, scenario, "one exact RestoreOS target must allow the passive DFU Assistant")

        case .recovery:
            expect(model.snapshot.recoveryIdentityQueryVerified, scenario, "Recovery fixture must retain one complete targeted identity query")
            expect(model.snapshot.hasVerifiedSupportedDeviceIdentity, scenario, "Recovery fixture must include exact ProductType/HardwareModel/CPID/BDID evidence")
            expect(
                model.primaryActionTitle == (configuratorReady ? "Try Apple Revive (keep data)" : "Recovery verified — Apple Configurator required"),
                scenario,
                "wrong primary label"
            )
            expect(model.canRevive == configuratorReady, scenario, "Revive availability must match Configurator")
            expect(model.canRestore == configuratorReady, scenario, "Restore availability must match Configurator")
            expect(!model.canFactoryReset, scenario, "Factory Reset must be disabled in Recovery")
            expect(model.canStartDFUAssistant, scenario, "one exact Recovery target must allow another DFU timing attempt")

        case .dfu:
            expect(model.snapshot.recoveryIdentityQueryVerified, scenario, "DFU fixture must retain one complete targeted identity query")
            expect(model.snapshot.hasVerifiedSupportedDeviceIdentity, scenario, "DFU fixture must include exact ProductType/HardwareModel/CPID/BDID evidence")
            expect(
                model.primaryActionTitle == (configuratorReady ? "DFU confirmed — choose Restore below" : "DFU verified — Apple Configurator required"),
                scenario,
                "wrong primary label"
            )
            expect(!model.primaryActionEnabled, scenario, "DFU directive must not be an actionable primary button")
            expect(!model.canRevive && !model.canFactoryReset, scenario, "DFU must block Revive and Factory Reset")
            expect(model.canRestore == configuratorReady, scenario, "DFU Restore availability must match Configurator")
            expect(!model.canStartDFUAssistant, scenario, "DFU Assistant must stop once the target is already in DFU")

        case .usbUnavailable:
            expect(model.primaryActionTitle == "Guide me to Recovery", scenario, "wrong USB-unavailable primary label")
            expect(model.primaryActionEnabled, scenario, "physical Recovery guide must remain available")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "USB-unavailable state must block every write")
            expect(model.canStartDFUAssistant, scenario, "one exact USB target must allow the passive DFU watcher")

        case .multiple:
            expect(model.primaryActionTitle == "Disconnect extra devices", scenario, "wrong multiple-device primary label")
            expect(!model.primaryActionEnabled, scenario, "multiple-device state must not expose an action")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "multiple-device state must block every write")
            expect(!model.canStartDFUAssistant, scenario, "multiple devices must block the DFU Assistant")

        case .postResetReview:
            expect(model.primaryActionTitle == "I checked the iPhone — Scan", scenario, "wrong manual-review label")
            expect(model.primaryActionEnabled, scenario, "manual review Scan must be enabled")
            expect(!model.canChooseIPSW, scenario, "firmware selection must remain locked")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "all write actions must remain locked")
            expect(!model.canStartDFUAssistant, scenario, "manual review must block the DFU Assistant")
        }
    }

    private static func assertAccessibilityContract(
        _ nodes: [AXNodeSnapshot],
        model: RecoveryModel,
        scenario: UIContractScenario
    ) {
        let commonIdentifiers = [
            "appHeader",
            "scanButton",
            "workspacePicker",
            "appearanceButton",
            "settingsButton",
            "appSidebar",
            "sidebarReadinessButton",
            "sidebarReadinessCard",
            "localWorkspaceCard",
            "appFooter"
        ]
        for identifier in commonIdentifiers {
            expect(node(identifier, in: nodes) != nil, scenario, "missing accessibility identifier \(identifier)")
        }
        for destination in AppSidebarDestination.allCases {
            let identifier = sidebarIdentifier(for: destination)
            expect(node(identifier, in: nodes) != nil, scenario, "missing sidebar accessibility identifier \(identifier)")
        }

        let defaultShowsOverview = scenario == .noDevice || scenario == .normal
        if defaultShowsOverview {
            let overviewIdentifiers = [
                "deviceCenterOverview",
                "deviceCenterDetailStatus",
                "deviceSummaryPanel",
                "deviceHeroPanel",
                "quickActionsPanel",
                "dashboardReadinessPanel",
                "connectionEvidencePanel",
                "batteryPanel",
                "storagePanel",
                "refreshDeviceDetailsButton",
                "copyDeviceSummaryButton",
                "exportDeviceReportButton",
                "appleCoverageButton",
                "restartIPhoneButton",
                "shutDownIPhoneButton",
                "moreToolsButton"
            ]
            for identifier in overviewIdentifiers {
                expect(node(identifier, in: nodes) != nil, scenario, "missing overview accessibility identifier \(identifier)")
            }
            let shouldShowReveal = model.displayedDeviceCenterSnapshot.facts.contains {
                $0.sensitivity != .none
            }
            expect(
                (node("revealIdentifiersButton", in: nodes) != nil) == shouldShowReveal,
                scenario,
                "identifier reveal presence does not match sensitive dashboard facts"
            )
        } else {
            let recoveryIdentifiers = [
                "statusPanel",
                "identityRail", "actionColumn", "targetIdentityPanel",
                "systemReadinessPanel", "diagnosticLogToggle", "saveLogButton",
                "recommendedActionPanel", "primaryActionButton", "recoveryPanel",
                "firmwareMenu", "reviveButton", "restoreButton",
                "factoryResetPanel", "factoryResetButton"
            ]
            for identifier in recoveryIdentifiers {
                expect(node(identifier, in: nodes) != nil, scenario, "missing Recovery accessibility identifier \(identifier)")
            }
        }

        let expectsGuide: Bool
        switch scenario {
        case .restoreOS, .recovery, .usbUnavailable, .postResetReview:
            expectsGuide = true
        case .noDevice, .normal, .dfu, .multiple:
            expectsGuide = false
        }
        expect(
            (node("physicalButtonGuidePanel", in: nodes) != nil) == expectsGuide,
            scenario,
            "physical guide presence does not match the mode"
        )
        expect(
            (node("dfuTimingDisclosure", in: nodes) != nil) == expectsGuide,
            scenario,
            "DFU disclosure presence does not match the physical guide"
        )
        for identifier in ["dfuAssistantPanel", "startDFUAssistantButton", "dfuAssistantState", "recoveryGuideSteps"] {
            expect(
                (node(identifier, in: nodes) != nil) == expectsGuide,
                scenario,
                "\(identifier) presence does not match the model-aware physical guide"
            )
        }

        assertButton(
            "scanButton",
            expectedLabel: "New Scan",
            expectedEnabled: !model.operationRunning && !model.destructiveWorkflowActive &&
                !model.postResetReviewRequired && !model.crashCopyReviewRequired &&
                !model.isScanning && !model.isMonitoring && !model.isValidatingFirmware &&
                !model.isLoadingDeviceCenter && !model.mockLocationController.isBusy,
            nodes: nodes,
            scenario: scenario
        )
        if defaultShowsOverview {
            assertButton(
                "refreshDeviceDetailsButton",
                expectedLabel: "Refresh details",
                expectedEnabled: model.canRefreshDeviceCenter,
                nodes: nodes,
                scenario: scenario
            )
            assertButton(
                "restartIPhoneButton",
                expectedLabel: "Restart",
                expectedEnabled: model.canUseNormalDeviceUtilities,
                nodes: nodes,
                scenario: scenario
            )
            assertButton(
                "shutDownIPhoneButton",
                expectedLabel: "Shut Down",
                expectedEnabled: model.canUseNormalDeviceUtilities,
                nodes: nodes,
                scenario: scenario
            )
        } else {
            assertButton(
                "primaryActionButton",
                expectedLabel: model.primaryActionTitle,
                expectedEnabled: model.primaryActionEnabled,
                nodes: nodes,
                scenario: scenario
            )
            assertButton("firmwareMenu", expectedLabel: "Firmware", expectedEnabled: model.canChooseIPSW, nodes: nodes, scenario: scenario)
            assertButton("reviveButton", expectedLabel: "Try Revive", expectedEnabled: model.canRevive, nodes: nodes, scenario: scenario)
            assertButton("restoreButton", expectedLabel: "Erase & Restore", expectedEnabled: model.canRestore, nodes: nodes, scenario: scenario)
            assertButton("factoryResetButton", expectedLabel: "Factory Reset", expectedEnabled: model.canFactoryReset, nodes: nodes, scenario: scenario)
        }
    }

    private static func assertButton(
        _ identifier: String,
        expectedLabel: String,
        expectedEnabled: Bool,
        nodes: [AXNodeSnapshot],
        scenario: UIContractScenario
    ) {
        guard let element = node(identifier, in: nodes) else {
            expect(false, scenario, "missing button \(identifier)")
            return
        }
        let actualLabel = element.label ?? ""
        expect(
            normalizedLabel(actualLabel).contains(normalizedLabel(expectedLabel)),
            scenario,
            "\(identifier) label '\(actualLabel)' does not contain '\(expectedLabel)'"
        )
        expect(element.enabled == expectedEnabled, scenario, "\(identifier) enabled state is incorrect")
    }

    private static func normalizedLabel(_ value: String) -> String {
        value
            .replacingOccurrences(of: "…", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }

    private static func sidebarIdentifier(for destination: AppSidebarDestination) -> String {
        "sidebar" + destination.rawValue
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "/", with: "") + "Button"
    }

    private static func node(_ identifier: String, in nodes: [AXNodeSnapshot]) -> AXNodeSnapshot? {
        nodes.first { $0.identifier == identifier }
    }

    private static func render(
        model: RecoveryModel,
        colorScheme: ColorScheme,
        initialSection: AppWorkspaceSection? = nil,
        initialDestination: AppSidebarDestination? = nil,
        disableAnimations: Bool = true
    ) -> (window: NSWindow, hostingView: NSHostingView<some View>, bitmapWasCreated: Bool) {
        let root = ContentView(
            model: model,
            initialSection: initialSection,
            initialDestination: initialDestination
        )
            .frame(width: renderSize.width, height: renderSize.height)
            .environment(\.colorScheme, colorScheme)
            .transaction { transaction in
                if disableAnimations {
                    transaction.animation = nil
                    transaction.disablesAnimations = true
                }
            }
            .defaultAppStorage(testDefaults)
        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(origin: .zero, size: renderSize)

        let window = NSWindow(
            contentRect: NSRect(origin: NSPoint(x: -10_000, y: -10_000), size: renderSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = hosting
        window.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        window.orderFront(nil)

        hosting.needsLayout = true
        hosting.layoutSubtreeIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        for _ in 0..<2 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }

        let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds)
        if let bitmap {
            hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        }
        return (window, hosting, bitmap != nil)
    }

    private static func accessibilityTree<Root: View>(
        from hosting: NSHostingView<Root>
    ) -> [AXNodeSnapshot] {
        var output: [AXNodeSnapshot] = []
        var visited = Set<ObjectIdentifier>()

        func walk(_ raw: Any, depth: Int) {
            guard depth < 64, output.count < 4_096 else { return }
            let object = raw as AnyObject
            let identity = ObjectIdentifier(object)
            guard visited.insert(identity).inserted else { return }

            if let view = raw as? NSView {
                output.append(AXNodeSnapshot(
                    identifier: view.accessibilityIdentifier(),
                    label: view.accessibilityLabel(),
                    enabled: view.isAccessibilityEnabled()
                ))
                for child in view.accessibilityChildren() ?? [] {
                    walk(child, depth: depth + 1)
                }
                return
            }

            if let element = raw as? NSAccessibilityElement {
                output.append(AXNodeSnapshot(
                    identifier: element.accessibilityIdentifier(),
                    label: element.accessibilityLabel(),
                    enabled: element.isAccessibilityEnabled()
                ))
                for child in element.accessibilityChildren() ?? [] {
                    walk(child, depth: depth + 1)
                }
            }
        }

        walk(hosting, depth: 0)
        return output
    }

    private static func assertMotionPolicy() {
        if case .some = YIOSMotion.quick(reduceMotion: true) {
            failures.append("Reduce Motion must suppress quick UI animation")
        }
        if case .some = YIOSMotion.standard(reduceMotion: true) {
            failures.append("Reduce Motion must suppress standard UI animation")
        }
        if case .some = YIOSMotion.workspace(reduceMotion: true) {
            failures.append("Reduce Motion must suppress workspace animation")
        }
        if case .none = YIOSMotion.quick(reduceMotion: false) {
            failures.append("normal motion policy unexpectedly removed quick animation")
        }
        if case .none = YIOSMotion.standard(reduceMotion: false) {
            failures.append("normal motion policy unexpectedly removed standard animation")
        }
        if case .none = YIOSMotion.workspace(reduceMotion: false) {
            failures.append("normal motion policy unexpectedly removed workspace animation")
        }
    }

    private static func assertStaticSourceContracts() {
        let testURL = URL(fileURLWithPath: #filePath)
        let projectURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourcesURL = projectURL.appendingPathComponent("Sources", isDirectory: true)
        let modelURL = sourcesURL.appendingPathComponent("RecoveryModel.swift")
        let supportURL = sourcesURL.appendingPathComponent("SupportFeatures.swift")
        guard let sourceURLs = try? FileManager.default.contentsOfDirectory(
                  at: sourcesURL,
                  includingPropertiesForKeys: nil
              ).filter({ $0.pathExtension == "swift" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }),
              let sourceParts = try? sourceURLs.map({ try String(contentsOf: $0, encoding: .utf8) }),
              let modelSource = try? String(contentsOf: modelURL, encoding: .utf8),
              let supportSource = try? String(contentsOf: supportURL, encoding: .utf8) else {
            failures.append("fallback could not read Swift sources under \(sourcesURL.path)")
            return
        }
        let source = sourceParts.joined(separator: "\n")

        if let start = modelSource.range(of: "func startDFUAssistant()"),
           let end = modelSource.range(of: "func saveLog()", range: start.upperBound..<modelSource.endIndex) {
            let body = String(modelSource[start.lowerBound..<end.lowerBound])
            for forbidden in ["ProcessRunner", "ideviceDiagnostics", "beginAppleOperation", "tryRevive", "startRestore"] where body.contains(forbidden) {
                failures.append("DFU Assistant start path must remain passive; found \(forbidden)")
            }
            if !body.contains("startLiveMonitor(") || !body.contains("intent: .dfuOnly") {
                failures.append("DFU Assistant start path must arm only the DFU-only exact-target watcher")
            }
        } else {
            failures.append("could not isolate the passive DFU Assistant start path")
        }

        if let start = modelSource.range(of: "private func enterRecovery()"),
           let end = modelSource.range(of: "private func startLiveMonitor(", range: start.upperBound..<modelSource.endIndex) {
            let body = String(modelSource[start.lowerBound..<end.lowerBound])
            for forbidden in ["command.stdout", "command.stderr", "result.stdout", "result.stderr"] where body.contains(forbidden) {
                failures.append("Recovery transition must not retain raw helper output; found \(forbidden)")
            }
            if !body.contains("raw helper output was not retained") {
                failures.append("Recovery transition privacy contract is missing its no-raw-output audit log")
            }
        } else {
            failures.append("could not isolate the Recovery transition result handler")
        }

        let identifiers = [
            "scanButton",
            "statusPanel",
            "workspacePicker",
            "appearanceButton",
            "settingsButton",
            "appSidebar",
            "sidebarReadinessButton",
            "sidebarReadinessCard",
            "localWorkspaceCard",
            "appFooter",
            "settingsWorkspace",
            "settingsDependencyPanel",
            "settingsCapabilitiesPanel",
            "settingsBackButton",
            "deviceCenterOverview",
            "deviceCenterDetailStatus",
            "deviceSummaryPanel",
            "deviceHeroPanel",
            "quickActionsPanel",
            "dashboardReadinessPanel",
            "connectionEvidencePanel",
            "batteryPanel",
            "storagePanel",
            "refreshDeviceDetailsButton",
            "revealIdentifiersButton",
            "copyDeviceSummaryButton",
            "exportDeviceReportButton",
            "appleCoverageButton",
            "restartIPhoneButton",
            "shutDownIPhoneButton",
            "moreToolsButton",
            "deviceEvidenceView",
            "evidenceRefreshButton",
            "evidenceExportButton",
            "deviceActivityView",
            "backupCenterPanel",
            "openFinderBackupButton",
            "appleBackupGuideButton",
            "crashReportCenterPanel",
            "copyCrashReportsButton",
            "clearCrashReviewButton",
            "deviceTimelinePanel",
            "copyDeviceTimelineButton",
            "exportDeviceTimelineButton",
            "copyLastErrorButton",
            "activitySaveLogButton",
            "activityExportReportButton",
            "targetIdentityPanel",
            "systemReadinessPanel",
            "recommendedActionPanel",
            "primaryActionButton",
            "physicalButtonGuidePanel",
            "dfuTimingDisclosure",
            "dfuAssistantPanel",
            "startDFUAssistantButton",
            "dfuAssistantState",
            "dfuAssistantSteps",
            "recoveryGuideSteps",
            "firmwareMenu",
            "reviveButton",
            "restoreButton",
            "factoryResetPanel",
            "factoryResetButton",
            "mockLocationWorkspace",
            "mockLocationStatusPanel",
            "mockLocationTargetPanel",
            "mockLocationReadinessPanel",
            "mockLocationCoordinatePanel",
            "mockLocationPresetMenu",
            "mockLocationPersistentModeToggle",
            "mockLocationCheckReadinessButton",
            "mockLocationSetButton",
            "mockLocationClearButton",
            "mockLocationForgetUnavailableRecordPanel",
            "mockLocationForgetUnavailableRecordButton",
            "mockLocationSafetyPanel"
        ]
        for identifier in identifiers {
            if !source.contains(".accessibilityIdentifier(\"\(identifier)\")") {
                failures.append("source contract is missing accessibility identifier \(identifier)")
            }
        }

        for dynamicIdentifier in ["mockLocationLatitudeField", "mockLocationLongitudeField"] {
            if !source.contains("\"\(dynamicIdentifier)\"") {
                failures.append("source contract is missing dynamic accessibility identifier \(dynamicIdentifier)")
            }
        }

        if !source.contains(".accessibilityIdentifier(\"sidebar\\(") {
            failures.append("source contract is missing dynamic sidebar accessibility identifiers")
        }

        let bindings = [
            ".disabled(model.operationRunning || model.destructiveWorkflowActive || model.postResetReviewRequired || model.crashCopyReviewRequired || model.isScanning || model.isMonitoring || model.isValidatingFirmware || model.isLoadingDeviceCenter || model.mockLocationController.isBusy)",
            ".disabled(!model.canRefreshDeviceCenter)",
            ".disabled(!model.canUseNormalDeviceUtilities)",
            ".disabled(!model.canOpenFinderBackup)",
            ".disabled(!model.canCopyCrashReports)",
            ".disabled(!model.primaryActionEnabled)",
            ".disabled(!model.canChooseIPSW)",
            ".disabled(!model.canRevive)",
            ".disabled(!model.canRestore)",
            ".disabled(!model.canFactoryReset)",
            ".disabled(!model.canStartDFUAssistant)"
        ]
        for binding in bindings where !source.contains(binding) {
            failures.append("source contract is missing enabled-state binding \(binding)")
        }

        let labelBindings = [
            "Label(\"New Scan\", systemImage: \"arrow.clockwise\")",
            "Button(model.primaryActionTitle)",
            "Menu(\"Firmware\")",
            "Button(\"Try Revive\")",
            "Button(\"Erase & Restore…\")",
            "Button(\"Factory Reset…\")",
            "Button(\"Start DFU Assistant\")"
        ]
        for labelBinding in labelBindings where !source.contains(labelBinding) {
            failures.append("source contract is missing control-label binding \(labelBinding)")
        }

        let forbiddenClaims = [
            "No issues found",
            "healthy and ready",
            "One-click DFU",
            "Enter DFU automatically",
            "Motherboard Status",
            "Battery Status",
            "Screen Status",
            "Front Camera — Normal",
            "Rear Camera — Normal",
            "Fingerprint — Normal",
            "Find My OFF",
            "iCloud OFF",
            "Jailbreak No",
            "Battery Life",
            "Charge Cycles",
            "Hard Disk"
        ]
        for claim in forbiddenClaims where source.localizedCaseInsensitiveContains(claim) {
            failures.append("source contract contains unsupported claim \(claim)")
        }

        let destructiveContracts = [
            "alert.addButton(withTitle: \"Cancel\")\n        alert.addButton(withTitle: \"Erase All Content & Settings\")",
            "alert.addButton(withTitle: \"Cancel\")\n        alert.addButton(withTitle: \"Erase and Restore\")",
            "response == .alertSecondButtonReturn &&",
            "lastError = redact(error)",
            "lastError = line"
        ]
        for contract in destructiveContracts where !modelSource.contains(contract) {
            failures.append("RecoveryModel source contract is missing \(contract)")
        }

        let supportContracts = [
            "[\"--udid\", udid, \"--keep\", destination.path]",
            "!postResetReviewRequired",
            "confirmPostResetReviewAndScan()",
            "Finder was opened; the user remains in control of backup and encryption settings."
        ]
        let supportAndModelSource = supportSource + "\n" + modelSource
        for contract in supportContracts where !supportAndModelSource.contains(contract) {
            failures.append("Support feature source contract is missing \(contract)")
        }

        let mockLocationContracts = [
            "requestFreshEvidence:",
            "confirmForgetUnavailableRecord:",
            "confirmDeveloperModeOptionRequest:",
            "confirmSet:",
            "confirmReconnectedClear:",
            "reveal-developer-mode",
            "mockLocationShowDeveloperModeButton",
            "Persistent until Clear/Reboot (Experimental)",
            "operation: command.operation",
            "beginPersistentTeardownDeadline",
            "completion.completedCleanly",
            "state: .assumedPersistent",
            ".disabled(!controller.canCheckReadiness)",
            ".disabled(!controller.canRequestDeveloperModeOption)",
            ".disabled(!controller.canSetLocation)",
            ".disabled(!controller.canReturnToRealLocation)",
            ".disabled(!controller.canForgetUnavailableRecord)",
            "Connected token",
            "Recorded target",
            "Forget Unavailable iPhone Record",
            "!mockLocationBlocksDeviceMutation"
        ]
        for contract in mockLocationContracts where !source.contains(contract) {
            failures.append("Mock Location source contract is missing \(contract)")
        }

        let polishContracts = [
            "@Environment(\\.accessibilityReduceMotion)",
            "YIOSPressButtonStyle",
            ".yiosCardSurface(",
            "YIOSWorkspaceBackdrop"
        ]
        for contract in polishContracts where !source.contains(contract) {
            failures.append("UI polish source contract is missing \(contract)")
        }
        let activityRoutingContracts = [
            "DeviceActivityView(model: model, focus: .history)",
            "DeviceActivityView(model: model, focus: .tools)",
            "focus: model.crashCopyReviewRequired ? .crashReview : .logs",
            "case .crashReview:",
            "crashReportCenter\n            currentOperationPanel"
        ]
        for contract in activityRoutingContracts where !source.contains(contract) {
            failures.append("Activity routing source contract is missing \(contract)")
        }
        if source.contains(".repeatForever") {
            failures.append("UI polish must not introduce repeating animation")
        }
        for unavailableSymbol in ["battery.0percent", "battery.25percent", "battery.50percent", "battery.100percent", "shield.checkered"] where source.contains(unavailableSymbol) {
            failures.append("macOS 13 source contract contains unavailable symbol \(unavailableSymbol)")
        }

        let recoveryIdentityContracts = [
            "recoveryIdentityQueryVerified",
            "let requestedECID = snapshot.ecid",
            "parseRecoveryIdentityQuery(combined)",
            "evidence.exactModel(for: requestedECID)",
            "snapshot.supportedDeviceModel == queriedModel",
            "ProductType, board, CPID, and BDID"
        ]
        for contract in recoveryIdentityContracts where !source.contains(contract) {
            failures.append("Multi-model recovery identity source contract is missing \(contract)")
        }
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ scenario: UIContractScenario,
        _ message: String
    ) {
        if !condition() {
            failures.append("[\(scenario.rawValue)] \(message)")
        }
    }
}
