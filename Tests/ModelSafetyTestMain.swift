import AppKit
import Foundation

@main
@MainActor
struct ModelSafetyTestMain {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let model = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture()
        )
        expect(!model.canRestore, "no-device state must not allow Restore")
        expect(!model.canRevive, "no-device state must not allow Revive")
        expect(!model.canFactoryReset, "no-device state must not allow Factory Reset")
        expect(!model.canOpenFinderBackup, "no-device state must not allow a target-labelled Finder backup handoff")
        expect(!model.canCopyCrashReports, "no-device state must not allow crash-report collection")

        model.isValidatingFirmware = false
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
        expect(!model.canRestore, "RestoreOS must never allow Restore")
        expect(!model.canFactoryReset, "RestoreOS must never allow Factory Reset")

        model.snapshot.productType = nil
        model.snapshot.hardwareModel = nil
        expect(model.primaryActionEnabled, "one ECID-pinned RestoreOS device must allow the read-only physical watcher even before identity enrichment")
        model.snapshot.productType = "iPhone12,8"
        model.snapshot.hardwareModel = "d79ap"

        model.snapshot.mode = .recovery
        expect(!model.canRestore, "unverified Recovery PID must not allow Restore")
        expect(!model.canRevive, "unverified Recovery PID must not allow Revive")
        expect(!model.canFactoryReset, "Recovery must never allow Factory Reset")

        model.snapshot.modeVerified = true
        model.snapshot.chipID = "0x8030"
        model.snapshot.boardID = "0x10"
        expect(!model.canRestore && !model.canRevive, "Recovery writes must remain blocked until the complete irecovery identity query is verified")
        model.snapshot.recoveryIdentityQueryVerified = true
        expect(model.canRestore == ToolPaths.hasConfigurator, "fully verified SE2 Recovery should depend only on Configurator availability")
        expect(model.canRevive == ToolPaths.hasConfigurator, "fully verified SE2 Recovery should allow Revive when Configurator exists")

        model.snapshot.productType = "iPhone12,1"
        model.snapshot.hardwareModel = "n104ap"
        model.snapshot.boardID = "0x04"
        expect(model.canRestore == ToolPaths.hasConfigurator, "iPhone 11 is inside the supported Recovery range")
        expect(model.canRevive == ToolPaths.hasConfigurator, "iPhone 11 is inside the supported Revive range")

        model.snapshot.productType = "iPhone13,1"
        model.snapshot.hardwareModel = "d52gap"
        model.snapshot.chipID = "0x8101"
        model.snapshot.boardID = "0x0A"
        expect(!model.canRestore, "iPhone 12 mini must remain above the supported Restore boundary")
        expect(!model.canRevive, "iPhone 12 mini must remain above the supported Revive boundary")
        expect(model.primaryActionTitle == "Recovery verified — restore unsupported", "verified unsupported Recovery must not advertise Revive")
        model.snapshot.mode = .dfu
        expect(model.primaryActionTitle == "DFU verified — restore unsupported", "verified unsupported DFU must not advertise Restore")

        let genericDFUModel = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture()
        )
        genericDFUModel.snapshot = DeviceSnapshot(
            mode: .dfu,
            deviceCount: 1,
            usbPID: 0x1227,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            productType: "iPhone18,3",
            hardwareModel: "d93ap",
            modeVerified: true,
            chipID: "0x8301",
            boardID: "0x0A",
            recoveryIdentityQueryTargetVerified: true
        )
        expect(genericDFUModel.isGenericDFURestoreTarget, "complete exact future-iPhone DFU evidence must create only a generic restore target")
        expect(genericDFUModel.currentSupportedModel == nil, "generic DFU eligibility must not add an unreviewed model to the supported-device catalog")
        expect(genericDFUModel.canRestore == ToolPaths.hasConfigurator, "generic DFU Restore availability must depend on Apple Configurator")
        expect(!genericDFUModel.canRevive && !genericDFUModel.canFactoryReset, "generic DFU eligibility must not broaden Revive or Normal Factory Reset")
        expect(!genericDFUModel.canChooseIPSW, "generic DFU targets must not expose custom IPSW selection")
        expect(genericDFUModel.restoreButtonTitle == "Erase & Reinstall…", "generic DFU must use honest erase-and-reinstall wording")
        expect(genericDFUModel.restoreFirmwareSummary.localizedCaseInsensitiveContains("latest signed iOS"), "generic DFU must identify Apple-latest firmware")
        expect(genericDFUModel.primaryActionTitle == (ToolPaths.hasConfigurator ? "DFU target verified — erase & reinstall below" : "DFU target verified — Apple Configurator required"), "generic DFU primary guidance is incorrect")

        let customFirmware = IPSWInfo(
            url: URL(fileURLWithPath: "/private/tmp/fixture.ipsw"),
            productVersion: "99.0",
            buildVersion: "99A1",
            compatibleModels: [SupportedDeviceCatalog.se2],
            fileSize: 1,
            modificationDate: Date(timeIntervalSince1970: 0),
            sampledSHA256: "fixture"
        )
        genericDFUModel.selectedIPSW = customFirmware
        expect(!genericDFUModel.canRestore, "a custom or stale IPSW must block generic DFU Restore")
        genericDFUModel.selectedIPSW = nil

        genericDFUModel.operationRunning = true
        expect(!genericDFUModel.canRestore, "an active operation must block generic DFU Restore")
        genericDFUModel.operationRunning = false
        genericDFUModel.destructiveWorkflowActive = true
        expect(!genericDFUModel.canRestore, "a destructive workflow must block generic DFU Restore")
        genericDFUModel.destructiveWorkflowActive = false
        genericDFUModel.postResetReviewRequired = true
        expect(!genericDFUModel.canRestore, "post-reset review must block generic DFU Restore")
        genericDFUModel.postResetReviewRequired = false
        genericDFUModel.crashCopyReviewRequired = true
        expect(!genericDFUModel.canRestore, "crash-copy review must block generic DFU Restore")
        genericDFUModel.crashCopyReviewRequired = false
        genericDFUModel.isScanning = true
        expect(!genericDFUModel.canRestore, "USB scanning must block generic DFU Restore")
        genericDFUModel.isScanning = false
        genericDFUModel.isMonitoring = true
        expect(!genericDFUModel.canRestore, "USB monitoring must block generic DFU Restore")
        genericDFUModel.isMonitoring = false
        genericDFUModel.isValidatingFirmware = true
        expect(!genericDFUModel.canRestore, "firmware validation must block generic DFU Restore")
        genericDFUModel.isValidatingFirmware = false
        genericDFUModel.isLoadingDeviceCenter = true
        expect(!genericDFUModel.canRestore, "Device Center collection must block generic DFU Restore")
        genericDFUModel.isLoadingDeviceCenter = false

        var genericRecovery = genericDFUModel.snapshot
        genericRecovery.mode = .recovery
        genericRecovery.usbPID = 0x1281
        genericDFUModel.snapshot = genericRecovery
        expect(!genericDFUModel.canRestore && !genericDFUModel.canRevive, "the same unreviewed identity in Recovery must remain ineligible for Restore and Revive")
        var genericNormal = genericRecovery
        genericNormal.mode = .normal
        genericNormal.usbPID = 0x12A8
        genericNormal.udid = "00008301-0001399A1401402E"
        genericDFUModel.snapshot = genericNormal
        expect(!genericDFUModel.canFactoryReset && !genericDFUModel.canRestore && !genericDFUModel.canRevive, "the same unreviewed identity in Normal iOS must not gain destructive eligibility")

        let kisDFUModel = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture()
        )
        kisDFUModel.snapshot = DeviceSnapshot(
            mode: .dfu,
            deviceCount: 1,
            usbPID: 0x1881,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            modeVerified: false,
            chipID: "0x8030",
            boardID: "0x10",
            recoveryIdentityQueryVerified: true,
            configuratorDFURestoreVerified: true
        )
        expect(kisDFUModel.currentSupportedModel == SupportedDeviceCatalog.se2, "KIS fixture must exercise a ProductType already present in the reviewed catalog")
        expect(kisDFUModel.isGenericDFURestoreTarget, "even a known catalog model over KIS must route through exact Configurator generic-DFU proof")
        expect(kisDFUModel.canRestore == ToolPaths.hasConfigurator, "Configurator-attested KIS Restore availability must match Configurator")
        expect(!kisDFUModel.canChooseIPSW, "KIS generic restore must block custom IPSW even when ProductType is known to the reviewed catalog")
        kisDFUModel.snapshot.configuratorDFURestoreVerified = false
        expect(!kisDFUModel.isGenericDFURestoreTarget && !kisDFUModel.canRestore, "raw KIS PID and ProductType must fail closed without Configurator attestation")

        model.snapshot.productType = "iPhone12,8"
        model.snapshot.hardwareModel = "d79ap"
        model.snapshot.chipID = "0x8030"
        model.snapshot.boardID = "0x10"
        model.snapshot.mode = .normal
        expect(!model.canRestore && !model.canRevive, "Normal iOS must not expose Recovery/DFU write actions")
        model.snapshot.udid = "00008030-0001399A1401402E"
        model.snapshot.locationID = 1_048_576
        model.snapshot.modeVerified = true
        expect(model.canFactoryReset == (ToolPaths.hasConfigurator && ToolPaths.idevicePair != nil), "verified Normal SE2 should allow Factory Reset when required tools exist")

        model.snapshot.modeVerified = false
        expect(!model.canFactoryReset, "unverified Normal USB must block Factory Reset")
        model.snapshot.modeVerified = true
        model.snapshot.udid = nil
        expect(!model.canFactoryReset, "missing UDID must block Factory Reset")
        model.snapshot.udid = "00008030-0001399A1401402E"
        model.snapshot.locationID = nil
        expect(!model.canFactoryReset, "missing USB location must block Factory Reset")
        model.snapshot.locationID = 1_048_576
        model.snapshot.productType = "iPhone12,1"
        model.snapshot.hardwareModel = "n104ap"
        model.snapshot.boardID = "0x04"
        expect(model.canFactoryReset == (ToolPaths.hasConfigurator && ToolPaths.idevicePair != nil), "iPhone 11 is inside the supported Normal-iOS Factory Reset range")
        model.snapshot.productType = "iPhone13,1"
        model.snapshot.hardwareModel = "d52gap"
        model.snapshot.chipID = "0x8101"
        model.snapshot.boardID = "0x0A"
        expect(!model.canFactoryReset, "iPhone 12 mini must remain above the supported Factory Reset boundary")
        expect(model.primaryActionEnabled, "a valid exact iPhone outside the destructive catalog must still allow non-destructive Recovery entry")
        expect(model.primaryActionTitle == (ToolPaths.enterRecovery == nil ? "Guide me to Recovery" : "Enter Recovery (keep data)"), "unsupported-model Normal iOS must expose Recovery or its physical fallback honestly")
        expect(model.canStartDFUAssistant, "a valid exact iPhone outside the destructive catalog must allow the passive DFU Assistant")
        expect(!model.canRestore && !model.canRevive, "broad Recovery/DFU guidance must not broaden destructive eligibility")
        model.snapshot.productType = "iPhone12,8"
        model.snapshot.hardwareModel = "d79ap"
        model.snapshot.chipID = "0x8030"
        model.snapshot.boardID = "0x10"

        model.snapshot.mode = .multiple
        model.snapshot.deviceCount = 2
        expect(!model.canRestore && !model.canRevive, "multiple-device state must block every Apple operation")
        expect(!model.canFactoryReset, "multiple devices must block Factory Reset")

        model.snapshot.deviceCount = 1
        model.snapshot.mode = .dfu
        model.snapshot.usbPID = 0x1227
        model.snapshot.recoveryIdentityQueryVerified = true
        expect(model.canRestore == ToolPaths.hasConfigurator, "fully verified SE2 DFU should allow only Restore when Configurator exists")
        expect(!model.canRevive, "DFU must never allow Revive")

        model.operationRunning = true
        expect(!model.canRestore, "an active operation must disable a second Restore")
        expect(!model.canFactoryReset, "an active operation must disable Factory Reset")
        model.operationRunning = false
        model.isValidatingFirmware = true
        expect(!model.canRestore, "firmware validation must block Restore")
        expect(!model.canChooseIPSW, "firmware validation must freeze firmware selection")
        expect(!model.canFactoryReset, "firmware validation must block Factory Reset on the serial work queue")
        model.isValidatingFirmware = false
        model.destructiveWorkflowActive = true
        expect(!model.canRestore, "an armed destructive workflow must block a second Restore")
        expect(!model.canChooseIPSW, "an armed restore workflow must freeze firmware selection")
        expect(!model.canFactoryReset, "an armed destructive workflow must block Factory Reset")

        let factoryModel = RecoveryModel(
            autoSelectFirmware: false,
            mockLocationController: MockLocationController.offlineFixture()
        )
        factoryModel.snapshot = DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: "00008030-0001399A1401402E",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true,
            deviceName: "Pre-Erase Private Name",
            serialNumber: "PREERASESERIAL"
        )
        let factoryToolsReady = ToolPaths.hasConfigurator && ToolPaths.idevicePair != nil
        let utilityToolsReady = ToolPaths.ideviceDiagnostics != nil && ToolPaths.idevicePair != nil
        let crashToolsReady = ToolPaths.ideviceCrashReport != nil && ToolPaths.idevicePair != nil
        expect(factoryModel.canFactoryReset == factoryToolsReady, "Factory Reset busy-state fixture must begin eligible when tools exist")
        expect(factoryModel.canUseNormalDeviceUtilities == utilityToolsReady, "Normal device utilities must require the diagnostics and pairing tools")
        expect(factoryModel.canOpenFinderBackup, "verified Normal SE2 should allow only the user-controlled Finder handoff")
        expect(factoryModel.canCopyCrashReports == crashToolsReady, "verified Normal SE2 crash collection must require keep-capable crash and pairing tools")
        expect(factoryModel.canStartDFUAssistant, "exact Normal fixture must begin eligible for the passive DFU Assistant")
        factoryModel.crashCopyReviewRequired = true
        expect(!factoryModel.canCopyCrashReports, "a keep/privacy/target review lock must block another crash-copy attempt")
        expect(!factoryModel.canOpenFinderBackup, "a crash-copy review lock must freeze target-labelled support handoffs until manual review")
        expect(!factoryModel.canStartDFUAssistant, "a crash-copy review lock must block the DFU Assistant")
        factoryModel.crashCopyReviewRequired = false
        let oldPrivateFact = DeviceFact(
            id: "deviceName", group: .identity, label: "Device name", value: "Pre-Erase Private Name",
            status: .reported, source: "lockdownd / ideviceinfo", explanation: "fixture", sensitivity: .personal
        )
        factoryModel.deviceCenterSnapshot = DeviceCenterSnapshot(
            capturedAt: Date(), mode: .normal,
            targetECID: factoryModel.snapshot.ecid, targetUDID: factoryModel.snapshot.udid,
            facts: [oldPrivateFact], batteryPercent: nil, isCharging: nil,
            totalStorageBytes: nil, availableStorageBytes: nil, notes: []
        )
        expect(factoryModel.displayedDeviceCenterSnapshot.fact("deviceName") != nil, "current private detail fixture must be visible before erase review")
        factoryModel.postResetReviewRequired = true
        expect(factoryModel.displayedDeviceCenterSnapshot.fact("deviceName") == nil, "post-erase review must never display the pre-erase private snapshot")
        expect(factoryModel.displayedDeviceCenterSnapshot.fact("serialNumber") == nil, "post-erase review must discard the pre-erase serial observation")
        expect(factoryModel.displayedDeviceCenterSnapshot.fact("productVersion") == nil, "post-erase review must discard the pre-erase software observation until a fresh scan")
        expect(factoryModel.displayedDeviceCenterSnapshot.fact("activationState") == nil, "post-erase review must discard the pre-erase activation state")
        let scrubbedEvidence = DeviceCenterCollector.postMutationDeviceEvidence(for: factoryModel.snapshot)
        expect(scrubbedEvidence.udid == nil && scrubbedEvidence.deviceName == nil && scrubbedEvidence.serialNumber == nil, "post-mutation model evidence must remove private identifiers")
        expect(scrubbedEvidence.productVersion == nil && scrubbedEvidence.buildVersion == nil && scrubbedEvidence.activationState == nil, "post-mutation model evidence must remove stale software and activation values")
        factoryModel.postResetReviewRequired = false
        factoryModel.operationRunning = true
        expect(!factoryModel.canFactoryReset, "an active operation must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "an active operation must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "an active operation must block every Support Center target action")
        expect(!factoryModel.canStartDFUAssistant, "an active operation must block the DFU Assistant")
        factoryModel.operationRunning = false
        factoryModel.isScanning = true
        expect(!factoryModel.canFactoryReset, "scanning must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "scanning must block Normal device utilities")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "scanning must block Support Center target actions")
        expect(!factoryModel.canStartDFUAssistant, "scanning must block the DFU Assistant")
        factoryModel.isScanning = false
        factoryModel.isMonitoring = true
        expect(!factoryModel.canFactoryReset, "USB monitoring must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "USB monitoring must block Normal device utilities")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "USB monitoring must block Support Center target actions")
        expect(!factoryModel.canStartDFUAssistant, "an active USB watcher must block another DFU Assistant")
        factoryModel.isMonitoring = false
        factoryModel.isValidatingFirmware = true
        expect(!factoryModel.canFactoryReset, "firmware validation must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "firmware validation must block Normal device utilities")
        expect(!factoryModel.canStartDFUAssistant, "firmware validation must block the DFU Assistant")
        factoryModel.isValidatingFirmware = false
        factoryModel.isLoadingDeviceCenter = true
        expect(!factoryModel.canFactoryReset, "Device Center collection must block Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "Device Center collection must block Restart and Shut Down")
        expect(!factoryModel.canStartDFUAssistant, "Device Center collection must block the DFU Assistant")
        factoryModel.isLoadingDeviceCenter = false
        factoryModel.destructiveWorkflowActive = true
        expect(!factoryModel.canFactoryReset, "a destructive workflow must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canStartDFUAssistant, "a destructive workflow must block the DFU Assistant")
        factoryModel.destructiveWorkflowActive = false
        factoryModel.postResetReviewRequired = true
        expect(!factoryModel.canFactoryReset, "pending Hello-screen review must block another Factory Reset")
        expect(!factoryModel.canChooseIPSW, "pending Hello-screen review must freeze unrelated firmware controls")
        expect(factoryModel.primaryActionTitle == "I checked the iPhone — Scan", "pending post-reset review must expose only a manual Scan action")
        expect(!factoryModel.canUseNormalDeviceUtilities, "pending Hello-screen review must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "pending Hello-screen review must block Finder handoff and crash collection")
        expect(!factoryModel.canStartDFUAssistant, "pending Hello-screen review must block the DFU Assistant")
        factoryModel.scan()
        expect(factoryModel.postResetReviewRequired, "ordinary scan() must never clear the post-reset Hello-screen interlock")
        expect(!factoryModel.isScanning, "ordinary scan() must not start a device query during post-reset review")

        factoryModel.postResetReviewRequired = false
        factoryModel.snapshot.mode = .recovery
        expect(!factoryModel.canUseNormalDeviceUtilities, "Recovery Mode must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "Recovery Mode must block Normal-mode support actions")
        factoryModel.snapshot.mode = .dfu
        expect(!factoryModel.canUseNormalDeviceUtilities, "DFU Mode must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "DFU Mode must block Normal-mode support actions")
        factoryModel.snapshot.mode = .restoreOS
        expect(!factoryModel.canUseNormalDeviceUtilities, "RestoreOS must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "RestoreOS must block Normal-mode support actions")

        let mockTargetSnapshot = DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: "00008030-0001399A1401402E",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true
        )
        if let exactTarget = try? MockLocationExactTarget(snapshot: mockTargetSnapshot) {
            let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
            let recovered = MockLocationJournalRecord(
                state: .assumedActive,
                pin: exactTarget.pin,
                stablePin: exactTarget.stablePin,
                requestDispatched: true,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            let mockReviewModel = RecoveryModel(
                autoSelectFirmware: false,
                mockLocationController: MockLocationController.offlineFixture(recoveredRecord: recovered)
            )
            mockReviewModel.snapshot = mockTargetSnapshot
            expect(mockReviewModel.mockLocationBlocksDeviceMutation, "an interrupted Mock Location journal must arm the global mutation interlock")
            expect(!mockReviewModel.canRestore && !mockReviewModel.canRevive && !mockReviewModel.canFactoryReset, "Mock Location review must block every Apple write path")
            expect(!mockReviewModel.canUseNormalDeviceUtilities, "Mock Location review must block restart and shutdown")
            expect(!mockReviewModel.canCopyCrashReports && !mockReviewModel.canOpenFinderBackup, "Mock Location review must block support-device operations")
            expect(!mockReviewModel.canChooseIPSW && !mockReviewModel.canRefreshDeviceCenter, "Mock Location review must freeze firmware and Device Center mutation paths")
            expect(!mockReviewModel.primaryActionEnabled, "Mock Location review must disable Recovery entry from the generic primary action")
            expect(!mockReviewModel.canStartDFUAssistant, "Mock Location review must block the DFU Assistant watcher")

            let persistentRecord = MockLocationJournalRecord(
                state: .assumedPersistent,
                pin: exactTarget.pin,
                stablePin: exactTarget.stablePin,
                setMode: .persistentUntilClearOrReboot,
                requestDispatched: true,
                createdAt: timestamp,
                updatedAt: timestamp
            )
            let persistentModel = RecoveryModel(
                autoSelectFirmware: false,
                mockLocationController: MockLocationController.offlineFixture(recoveredRecord: persistentRecord)
            )
            persistentModel.snapshot = mockTargetSnapshot
            expect(persistentModel.mockLocationController.isAssumedPersistent, "clean persistent journal must remain an explicit assumed-persistent state")
            expect(persistentModel.mockLocationBlocksDeviceMutation, "assumed persistent location must arm the global mutation interlock")
            expect(!persistentModel.canRestore && !persistentModel.canRevive && !persistentModel.canFactoryReset, "assumed persistent location must block every Apple write path")
            expect(!persistentModel.canUseNormalDeviceUtilities && !persistentModel.canCopyCrashReports, "assumed persistent location must block power and support-device operations")
            expect(!persistentModel.canChooseIPSW && !persistentModel.canRefreshDeviceCenter && !persistentModel.primaryActionEnabled, "assumed persistent location must freeze firmware, detail refresh, and generic actions")
            expect(!persistentModel.canStartDFUAssistant, "assumed persistent location must block the DFU Assistant watcher")
        } else {
            expect(false, "Mock Location safety fixture must produce an exact target")
        }

        if failures.isEmpty {
            print("MODEL SAFETY TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
