import AppKit
import SwiftUI

private enum UIContractScenario: String, CaseIterable {
    case noDevice = "no-device"
    case normal
    case restoreOS = "restoreos"
    case recovery
    case dfu
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
    private static var failures: [String] = []
    private static var usedNativeAccessibility = false

    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)

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

        let crashReviewModel = fixture(for: .normal)
        crashReviewModel.crashCopyReviewRequired = true
        crashReviewModel.crashReportSummary = CrashReportCopySummary(
            copiedAt: Date(timeIntervalSince1970: 1_700_000_010),
            directoryURL: URL(fileURLWithPath: "/private/fixture/SE2-Crash-Reports", isDirectory: true),
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
            // successful light/dark construction, and the source-level identifier/
            // binding contract. This performs no action and starts no device probe.
            assertSourceContractFallback()
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
        let model = RecoveryModel(autoSelectFirmware: false)

        switch scenario {
        case .noDevice:
            model.snapshot = DeviceSnapshot(mode: .notDetected, deviceCount: 0)
            model.statusText = "No iPhone detected"
            model.detailText = "Connect one iPhone SE (2nd generation), then scan again."

        case .normal:
            applyNormalFixture(to: model)
            model.statusText = "Normal iOS mode verified"
            model.detailText = "The exact SE2 is communicating in Normal iOS."

        case .restoreOS:
            model.snapshot = recoveryFixture(mode: .restoreOS, pid: 0x12AC, verified: false)
            model.statusText = "RestoreOS intermediate mode detected"
            model.detailText = "Direct restore is blocked; enter verified Recovery or DFU first."

        case .recovery:
            model.snapshot = recoveryFixture(mode: .recovery, pid: 0x1281, verified: true)
            model.statusText = "Recovery Mode verified"
            model.detailText = "Try Apple Revive first, or explicitly choose Full Restore."

        case .dfu:
            model.snapshot = recoveryFixture(mode: .dfu, pid: 0x1227, verified: true)
            model.statusText = "DFU Mode verified"
            model.detailText = "DFU is verified; only the explicit Restore path is available."

        case .postResetReview:
            applyNormalFixture(to: model)
            model.snapshot.activationState = "Unactivated"
            model.postResetReviewRequired = true
            model.statusText = "Factory Reset accepted — check the iPhone"
            model.detailText = "Confirm the Hello screen before the manual Scan action."
        }

        return model
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
            modeVerified: true
        )
    }

    private static func recoveryFixture(
        mode: DeviceMode,
        pid: Int,
        verified: Bool
    ) -> DeviceSnapshot {
        DeviceSnapshot(
            mode: mode,
            deviceCount: 1,
            usbPID: pid,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: nil,
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: verified
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

        case .normal:
            expect(model.primaryActionEnabled, scenario, "Normal iOS Recovery entry must be enabled")
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

        case .recovery:
            expect(model.primaryActionTitle == "Try Apple Revive (keep data)", scenario, "wrong primary label")
            expect(model.canRevive == configuratorReady, scenario, "Revive availability must match Configurator")
            expect(model.canRestore == configuratorReady, scenario, "Restore availability must match Configurator")
            expect(!model.canFactoryReset, scenario, "Factory Reset must be disabled in Recovery")

        case .dfu:
            expect(model.primaryActionTitle == "DFU confirmed — choose Restore below", scenario, "wrong primary label")
            expect(!model.primaryActionEnabled, scenario, "DFU directive must not be an actionable primary button")
            expect(!model.canRevive && !model.canFactoryReset, scenario, "DFU must block Revive and Factory Reset")
            expect(model.canRestore == configuratorReady, scenario, "DFU Restore availability must match Configurator")

        case .postResetReview:
            expect(model.primaryActionTitle == "I checked the iPhone — Scan", scenario, "wrong manual-review label")
            expect(model.primaryActionEnabled, scenario, "manual review Scan must be enabled")
            expect(!model.canChooseIPSW, scenario, "firmware selection must remain locked")
            expect(!model.canFactoryReset && !model.canRevive && !model.canRestore, scenario, "all write actions must remain locked")
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
            "statusPanel",
            "workspacePicker"
        ]
        for identifier in commonIdentifiers {
            expect(node(identifier, in: nodes) != nil, scenario, "missing accessibility identifier \(identifier)")
        }

        let defaultShowsOverview = scenario == .noDevice || scenario == .normal
        if defaultShowsOverview {
            let overviewIdentifiers = [
                "deviceCenterOverview",
                "deviceCenterDetailStatus",
                "deviceHeroPanel",
                "refreshDeviceDetailsButton",
                "copyDeviceSummaryButton",
                "exportDeviceReportButton",
                "appleCoverageButton",
                "restartIPhoneButton",
                "shutDownIPhoneButton"
            ]
            for identifier in overviewIdentifiers {
                expect(node(identifier, in: nodes) != nil, scenario, "missing overview accessibility identifier \(identifier)")
            }
        } else {
            let recoveryIdentifiers = [
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

        let expectsGuide = scenario == .restoreOS
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

        assertButton(
            "scanButton",
            expectedLabel: "Scan",
            expectedEnabled: !model.operationRunning && !model.destructiveWorkflowActive &&
                !model.postResetReviewRequired && !model.isScanning && !model.isMonitoring &&
                !model.isValidatingFirmware && !model.isLoadingDeviceCenter,
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

    private static func node(_ identifier: String, in nodes: [AXNodeSnapshot]) -> AXNodeSnapshot? {
        nodes.first { $0.identifier == identifier }
    }

    private static func render(
        model: RecoveryModel,
        colorScheme: ColorScheme,
        initialSection: AppWorkspaceSection? = nil
    ) -> (window: NSWindow, hostingView: NSHostingView<some View>, bitmapWasCreated: Bool) {
        let root = ContentView(model: model, initialSection: initialSection)
            .frame(width: renderSize.width, height: renderSize.height)
            .environment(\.colorScheme, colorScheme)
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

    private static func assertSourceContractFallback() {
        let testURL = URL(fileURLWithPath: #filePath)
        let sourceURL = testURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ContentView.swift")
        let deviceCenterURL = sourceURL.deletingLastPathComponent().appendingPathComponent("DeviceCenterViews.swift")
        let modelURL = sourceURL.deletingLastPathComponent().appendingPathComponent("RecoveryModel.swift")
        let supportURL = sourceURL.deletingLastPathComponent().appendingPathComponent("SupportFeatures.swift")
        guard let contentSource = try? String(contentsOf: sourceURL, encoding: .utf8),
              let deviceCenterSource = try? String(contentsOf: deviceCenterURL, encoding: .utf8),
              let modelSource = try? String(contentsOf: modelURL, encoding: .utf8),
              let supportSource = try? String(contentsOf: supportURL, encoding: .utf8) else {
            failures.append("fallback could not read \(sourceURL.path)")
            return
        }
        let source = contentSource + "\n" + deviceCenterSource

        let identifiers = [
            "scanButton",
            "statusPanel",
            "workspacePicker",
            "deviceCenterOverview",
            "deviceHeroPanel",
            "refreshDeviceDetailsButton",
            "copyDeviceSummaryButton",
            "exportDeviceReportButton",
            "restartIPhoneButton",
            "shutDownIPhoneButton",
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
            "firmwareMenu",
            "reviveButton",
            "restoreButton",
            "factoryResetPanel",
            "factoryResetButton"
        ]
        for identifier in identifiers {
            if !source.contains(".accessibilityIdentifier(\"\(identifier)\")") {
                failures.append("source contract is missing accessibility identifier \(identifier)")
            }
        }

        let bindings = [
            ".disabled(model.operationRunning || model.destructiveWorkflowActive || model.postResetReviewRequired || model.isScanning || model.isMonitoring || model.isValidatingFirmware || model.isLoadingDeviceCenter)",
            ".disabled(!model.canRefreshDeviceCenter)",
            ".disabled(!model.canUseNormalDeviceUtilities)",
            ".disabled(!model.canOpenFinderBackup)",
            ".disabled(!model.canCopyCrashReports)",
            ".disabled(!model.primaryActionEnabled)",
            ".disabled(!model.canChooseIPSW)",
            ".disabled(!model.canRevive)",
            ".disabled(!model.canRestore)",
            ".disabled(!model.canFactoryReset)"
        ]
        for binding in bindings where !source.contains(binding) {
            failures.append("source contract is missing enabled-state binding \(binding)")
        }

        let labelBindings = [
            "Label(\"Scan\", systemImage: \"arrow.clockwise\")",
            "Button(model.primaryActionTitle)",
            "Menu(\"Firmware\")",
            "Button(\"Try Revive\")",
            "Button(\"Erase & Restore…\")",
            "Button(\"Factory Reset…\")"
        ]
        for labelBinding in labelBindings where !source.contains(labelBinding) {
            failures.append("source contract is missing control-label binding \(labelBinding)")
        }

        let forbiddenClaims = ["No issues found", "Motherboard Status", "Find My OFF", "iCloud OFF"]
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
