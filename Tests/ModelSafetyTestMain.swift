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

        let model = RecoveryModel(autoSelectFirmware: false)
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
        expect(model.canRestore == ToolPaths.hasConfigurator, "verified SE2 Recovery should depend only on Configurator availability")
        expect(model.canRevive == ToolPaths.hasConfigurator, "verified SE2 Recovery should allow Revive when Configurator exists")

        model.snapshot.productType = "iPhone12,1"
        model.snapshot.hardwareModel = "n104ap"
        expect(!model.canRestore, "non-SE2 Recovery must not allow Restore")
        expect(!model.canRevive, "non-SE2 Recovery must not allow Revive")

        model.snapshot.productType = "iPhone12,8"
        model.snapshot.hardwareModel = "d79ap"
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
        expect(!model.canFactoryReset, "non-SE2 Normal device must block Factory Reset")
        model.snapshot.productType = "iPhone12,8"
        model.snapshot.hardwareModel = "d79ap"

        model.snapshot.mode = .multiple
        model.snapshot.deviceCount = 2
        expect(!model.canRestore && !model.canRevive, "multiple-device state must block every Apple operation")
        expect(!model.canFactoryReset, "multiple devices must block Factory Reset")

        model.snapshot.deviceCount = 1
        model.snapshot.mode = .dfu
        expect(model.canRestore == ToolPaths.hasConfigurator, "verified SE2 DFU should allow only Restore when Configurator exists")
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

        let factoryModel = RecoveryModel(autoSelectFirmware: false)
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
        factoryModel.crashCopyReviewRequired = true
        expect(!factoryModel.canCopyCrashReports, "a keep/privacy/target review lock must block another crash-copy attempt")
        expect(!factoryModel.canOpenFinderBackup, "a crash-copy review lock must freeze target-labelled support handoffs until manual review")
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
        factoryModel.operationRunning = false
        factoryModel.isScanning = true
        expect(!factoryModel.canFactoryReset, "scanning must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "scanning must block Normal device utilities")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "scanning must block Support Center target actions")
        factoryModel.isScanning = false
        factoryModel.isMonitoring = true
        expect(!factoryModel.canFactoryReset, "USB monitoring must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "USB monitoring must block Normal device utilities")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "USB monitoring must block Support Center target actions")
        factoryModel.isMonitoring = false
        factoryModel.isValidatingFirmware = true
        expect(!factoryModel.canFactoryReset, "firmware validation must block an otherwise eligible Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "firmware validation must block Normal device utilities")
        factoryModel.isValidatingFirmware = false
        factoryModel.isLoadingDeviceCenter = true
        expect(!factoryModel.canFactoryReset, "Device Center collection must block Factory Reset")
        expect(!factoryModel.canUseNormalDeviceUtilities, "Device Center collection must block Restart and Shut Down")
        factoryModel.isLoadingDeviceCenter = false
        factoryModel.destructiveWorkflowActive = true
        expect(!factoryModel.canFactoryReset, "a destructive workflow must block an otherwise eligible Factory Reset")
        factoryModel.destructiveWorkflowActive = false
        factoryModel.postResetReviewRequired = true
        expect(!factoryModel.canFactoryReset, "pending Hello-screen review must block another Factory Reset")
        expect(!factoryModel.canChooseIPSW, "pending Hello-screen review must freeze unrelated firmware controls")
        expect(factoryModel.primaryActionTitle == "I checked the iPhone — Scan", "pending post-reset review must expose only a manual Scan action")
        expect(!factoryModel.canUseNormalDeviceUtilities, "pending Hello-screen review must block Restart and Shut Down")
        expect(!factoryModel.canOpenFinderBackup && !factoryModel.canCopyCrashReports, "pending Hello-screen review must block Finder handoff and crash collection")
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

        if failures.isEmpty {
            print("MODEL SAFETY TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
