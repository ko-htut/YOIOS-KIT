import Darwin
import Foundation

@main
struct SelfTestMain {
    static func main() {
        var failures: [String] = []

        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        func fixture(pid: Int, ecid: UInt64, location: Int = 1_048_576, serial: String = "00008030-000511EA2E30C02E") -> String {
            """
            +-o iPhone@00100000  <class IOUSBHostDevice, id 0x100000000> {
              \"idVendor\" = 1452
              \"idProduct\" = \(pid)
              \"locationID\" = \(location)
              \"UsbAppleDeviceECID\" = \(ecid)
              \"kUSBProductString\" = \"iPhone\"
              \"kUSBSerialNumberString\" = \"\(serial)\"
            }
            """
        }

        let ecid: UInt64 = 1_427_072_378_519_598
        expect(DeviceDetector.parseIOReg("").mode == .notDetected, "empty USB tree must be notDetected")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x12A8, ecid: ecid)).mode == .usbUnavailable, "0x12A8 alone must not prove Normal iOS")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x1281, ecid: ecid)).mode == .recovery, "0x1281 must classify as Recovery")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x1227, ecid: ecid)).mode == .dfu, "0x1227 must classify as DFU")
        let provisionalKIS = DeviceDetector.parseIOReg(fixture(pid: 0x1881, ecid: ecid))
        expect(provisionalKIS.mode == .dfu, "0x1881 KIS/Debug USB must be classified as a provisional DFU transport")
        expect(!provisionalKIS.modeVerified, "0x1881 PID alone must never claim destructive-grade DFU verification")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x12AC, ecid: ecid)).mode == .restoreOS, "0x12AC must classify as RestoreOS")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x1299, ecid: ecid)).mode == .unknown, "unknown Apple mobile PID must stay unknown")
        expect(DeviceDetector.parseIOReg(fixture(pid: 0x1281, ecid: ecid) + fixture(pid: 0x1227, ecid: ecid + 1, location: 2_097_152)).mode == .multiple, "two iPhones must block as multiple")
        expect(DeviceDetector.normalizeECID("0x001230") == "1230", "ECID normalization must retain trailing zero")
        expect(DeviceDetector.normalizeECID("0000") == "0", "zero ECID normalization")
        expect(DeviceDetector.normalizeECID("344808900083758") == DeviceDetector.normalizeECID("0x1399A1401402E"), "decimal and hexadecimal ECID forms must compare equally")
        expect(DeviceDetector.canonicalECIDHex("0000ABC") == "0xABC", "Factory Reset ECID must canonicalize to explicit hex")

        let se2Model = SupportedDeviceCatalog.se2
        expect(SupportedDeviceCatalog.all.count == 14, "the supported-device catalog must contain exactly the bounded 14 ProductType variants")
        expect(Set(SupportedDeviceCatalog.all.map(\.productType)).count == 14, "supported ProductType values must be unique")
        expect(Set(SupportedDeviceCatalog.all.map { $0.hardwareModel.lowercased() }).count == 14, "supported HardwareModel values must be unique")
        for supported in SupportedDeviceCatalog.all {
            let resolved = SupportedDeviceCatalog.model(
                productType: supported.productType,
                hardwareModel: supported.hardwareModel,
                chipID: String(format: "0x%llX", supported.chipID),
                boardID: String(format: "0x%llX", supported.boardID)
            )
            expect(resolved == supported, "the exact identity tuple for \(supported.productType) must resolve to its catalog row")
        }
        expect(
            SupportedDeviceCatalog.model(
                productType: "iPhone12,1",
                hardwareModel: "d79ap",
                chipID: "0x8030",
                boardID: "0x10"
            ) == nil,
            "a cross-model ProductType/HardwareModel tuple must fail closed"
        )
        expect(SupportedDeviceCatalog.model(productType: "iPhone9,3") == nil, "iPhone 7 must remain below the supported boundary")
        expect(SupportedDeviceCatalog.model(productType: "iPhone13,1") == nil, "iPhone 12 mini must remain above the supported boundary")

        let revive = AppleCommandBuilder.revive(ecid: "0xABC")
        expect(revive == ["--ecid", "0xABC", "--format", "JSON", "--progress", "-v", "revive"], "revive argv changed unexpectedly")
        let firmwareURL = URL(fileURLWithPath: "/tmp/SE2 firmware.ipsw")
        let restore = AppleCommandBuilder.restore(ecid: "0xABC", ipsw: firmwareURL)
        expect(restore == ["--ecid", "0xABC", "--format", "JSON", "--progress", "-v", "restore", "-I", "/tmp/SE2 firmware.ipsw"], "restore argv must target one ECID and preserve path as one argv")
        expect(!restore.contains("--foreach"), "destructive argv must never use --foreach")
        let genericRestore = AppleCommandBuilder.restore(ecid: "0xABC", ipsw: nil)
        expect(genericRestore == ["--ecid", "0xABC", "--format", "JSON", "--progress", "-v", "restore"], "generic DFU restore must delegate to Apple's latest compatible iOS without a custom IPSW")
        expect(!genericRestore.contains("-I") && !genericRestore.contains("--foreach"), "generic DFU restore must not select custom firmware or every attached device")
        let dfuRestorePreflight = AppleCommandBuilder.dfuRestorePreflight(ecid: "0xABC")
        expect(dfuRestorePreflight.prefix(7) == ["--ecid", "0xABC", "--format", "JSON", "--timeout", "10", "get"], "generic DFU preflight must target exactly one ECID")
        expect(dfuRestorePreflight.contains("deviceClass") && dfuRestorePreflight.contains("bootedState") && dfuRestorePreflight.contains("isRestorable") && dfuRestorePreflight.contains("locationID"), "generic DFU preflight must request destructive-grade Configurator evidence")
        expect(!dfuRestorePreflight.contains("--foreach"), "generic DFU preflight must never target every attached device")
        let factoryReset = AppleCommandBuilder.factoryReset(ecid: "0xABC")
        expect(factoryReset == ["--ecid", "0xABC", "--format", "JSON", "--progress", "--timeout", "10", "-v", "erase"], "Factory Reset argv changed unexpectedly")
        expect(!factoryReset.contains("--foreach"), "Factory Reset must never target every device")
        expect(!factoryReset.contains("--esim"), "Factory Reset must preserve eSIM unless a separate opt-in is implemented")
        let factoryPreflight = AppleCommandBuilder.factoryResetPreflight(ecid: "0xABC")
        expect(factoryPreflight.prefix(7) == ["--ecid", "0xABC", "--format", "JSON", "--timeout", "10", "get"], "Factory Reset preflight must target the exact ECID")
        expect(factoryPreflight.contains("isPaired") && factoryPreflight.contains("isSupervised") && factoryPreflight.contains("bootedState"), "Factory Reset preflight must request Trust, supervision, and boot state")

        let successLine = "{\"Command\":\"restore\",\"Type\":\"CommandOutput\",\"Devices\":[\"0x1399A1401402E\"],\"Output\":{}}"
        expect(AppleOperationParser.parse(successLine, expectedECID: "0x1399A1401402E", expectedCommand: "restore")?.matchingSuccess == true, "matching cfgutil CommandOutput must be accepted")
        expect(AppleOperationParser.parse(successLine, expectedECID: "0x511EA2E30C02E", expectedCommand: "restore")?.matchingSuccess == false, "wrong-ECID CommandOutput must be rejected")
        expect(AppleOperationParser.parse(successLine, expectedECID: "0x1399A1401402E", expectedCommand: "revive")?.matchingSuccess == false, "wrong-command CommandOutput must be rejected")
        let eraseSuccess = "{\"Command\":\"erase\",\"Type\":\"CommandOutput\",\"Devices\":[\"0x1399A1401402E\"],\"Output\":{}}"
        expect(AppleOperationParser.parse(eraseSuccess, expectedECID: "0x1399A1401402E", expectedCommand: "erase")?.matchingSuccess == true, "matching Factory Reset success must be accepted")
        let eraseAliasSuccess = "{\"Command\":\"erase-content\",\"Type\":\"CommandOutput\",\"Devices\":[\"0x1399A1401402E\"],\"Output\":{}}"
        expect(AppleOperationParser.parse(eraseAliasSuccess, expectedECID: "0x1399A1401402E", expectedCommand: "erase")?.matchingSuccess == true, "cfgutil's documented erase-content alias may satisfy a launched erase operation")
        let eraseWithNestedError = "{\"Command\":\"erase\",\"Type\":\"CommandOutput\",\"Devices\":[\"0x1399A1401402E\"],\"Output\":{\"Errors\":{\"0x1399A1401402E\":{\"Message\":\"not erased\"}}}}"
        let parsedNestedEraseError = AppleOperationParser.parse(eraseWithNestedError, expectedECID: "0x1399A1401402E", expectedCommand: "erase")
        expect(parsedNestedEraseError?.matchingSuccess == false && parsedNestedEraseError?.errorMessage != nil, "a non-empty nested cfgutil error must fail closed even inside CommandOutput")
        expect(AppleOperationParser.parse(eraseSuccess, expectedECID: "0x511EA2E30C02E", expectedCommand: "erase")?.matchingSuccess == false, "wrong-target Factory Reset success must be rejected")
        expect(AppleOperationParser.parse(eraseSuccess, expectedECID: "0x1399A1401402E", expectedCommand: "restore")?.matchingSuccess == false, "Factory Reset output must not satisfy Restore")
        let errorLine = "{\"Type\":\"Error\",\"Domain\":\"com.apple.MobileDevice\",\"Code\":4013,\"FailureReason\":\"Disconnected\"}"
        expect(AppleOperationParser.parse(errorLine, expectedECID: nil, expectedCommand: nil)?.errorMessage?.contains("4013") == true, "cfgutil error code must be preserved")
        let findMyError = "{\"Type\":\"Error\",\"Domain\":\"ConfigurationUtilityKit.error\",\"Code\":123,\"Message\":\"The operation failed\",\"FailureReason\":\"Sign out of Find My iPhone\",\"Detail\":\"Disable Find My and retry manually\",\"AffectedDevices\":[\"0x1399A1401402E\"]}"
        let parsedFindMyError = AppleOperationParser.parse(findMyError, expectedECID: "0x1399A1401402E", expectedCommand: "erase")?.errorMessage
        expect(parsedFindMyError?.contains("The operation failed") == true && parsedFindMyError?.contains("Find My") == true && parsedFindMyError?.contains("retry manually") == true, "Factory Reset must preserve high-level and detailed cfgutil failure fields")
        let progressLine = "{\"Type\":\"Progress\",\"PercentComplete\":42,\"Status\":\"Writing filesystem\"}"
        expect(AppleOperationParser.parse(progressLine, expectedECID: nil, expectedCommand: nil)?.progress == 0.42, "percent progress must normalize to 0...1")

        let pinnedRecovery = DeviceSnapshot(mode: .recovery, deviceCount: 1, usbPID: 0x1281, locationID: 1_048_576, ecid: "0x1399A1401402E")
        expect(DeviceDetector.matchesPinnedTransition(pinnedRecovery, pinnedECID: "0x1399A1401402E", pinnedLocation: 1_048_576), "matching pinned Recovery transition must pass")
        var missingECID = pinnedRecovery
        missingECID.ecid = nil
        expect(!DeviceDetector.matchesPinnedTransition(missingECID, pinnedECID: "0x1399A1401402E", pinnedLocation: 1_048_576), "missing-ECID transition must be rejected")
        var wrongLocation = pinnedRecovery
        wrongLocation.locationID = 2_097_152
        expect(!DeviceDetector.matchesPinnedTransition(wrongLocation, pinnedECID: "0x1399A1401402E", pinnedLocation: 1_048_576), "wrong USB location must be rejected")
        var restoreOSCandidate = pinnedRecovery
        restoreOSCandidate.mode = .restoreOS
        expect(!DeviceDetector.matchesPinnedTransition(restoreOSCandidate, pinnedECID: "0x1399A1401402E", pinnedLocation: 1_048_576), "RestoreOS must not satisfy the Recovery/DFU watcher")

        let pinnedNormal = DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: "00008030-0001399A1401402E",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            modeVerified: true
        )
        expect(DeviceDetector.matchesPinnedNormalTarget(pinnedNormal, pinnedECID: "0x1399A1401402E", pinnedUDID: "00008030-0001399A1401402E", pinnedLocation: 1_048_576, pinnedModel: se2Model), "exact verified Normal target must satisfy Factory Reset pin")
        var conflictingSE2Identity = pinnedNormal
        conflictingSE2Identity.hardwareModel = "n104ap"
        expect(!conflictingSE2Identity.isSE2, "conflicting ProductType and HardwareModel must fail SE2 identity closed")
        expect(!DeviceDetector.matchesPinnedNormalTarget(conflictingSE2Identity, pinnedECID: "0x1399A1401402E", pinnedUDID: "00008030-0001399A1401402E", pinnedLocation: 1_048_576, pinnedModel: se2Model), "conflicting supported-device identifiers must block exact-target writes")
        var swappedUDID = pinnedNormal
        swappedUDID.udid = "00008030-000511EA2E30C02E"
        expect(!DeviceDetector.matchesPinnedNormalTarget(swappedUDID, pinnedECID: "0x1399A1401402E", pinnedUDID: "00008030-0001399A1401402E", pinnedLocation: 1_048_576, pinnedModel: se2Model), "changed UDID must reject Factory Reset")
        var swappedLocation = pinnedNormal
        swappedLocation.locationID = 2_097_152
        expect(!DeviceDetector.matchesPinnedNormalTarget(swappedLocation, pinnedECID: "0x1399A1401402E", pinnedUDID: "00008030-0001399A1401402E", pinnedLocation: 1_048_576, pinnedModel: se2Model), "changed USB location must reject Factory Reset")
        var unverifiedNormal = pinnedNormal
        unverifiedNormal.modeVerified = false
        expect(!DeviceDetector.matchesPinnedNormalTarget(unverifiedNormal, pinnedECID: "0x1399A1401402E", pinnedUDID: "00008030-0001399A1401402E", pinnedLocation: 1_048_576, pinnedModel: se2Model), "unverified Normal USB must reject Factory Reset")

        let completeRecoveryQuery = DeviceDetector.parseRecoveryIdentityQuery("""
        ECID: 0x1399A1401402E
        PRODUCT: iPhone12,8
        MODEL: d79ap
        CPID: 0x8030
        BDID: 0x10
        NAME: iPhone SE (2nd generation)
        """)
        expect(completeRecoveryQuery.exactModel(for: "0x1399A1401402E") == se2Model, "targeted irecovery identity must require and match the requested ECID plus the complete model tuple")
        let missingRecoveryECID = DeviceDetector.parseRecoveryIdentityQuery("PRODUCT: iPhone12,8\nMODEL: d79ap\nCPID: 0x8030\nBDID: 0x10")
        expect(missingRecoveryECID.exactModel(for: "0x1399A1401402E") == nil, "irecovery identity without a returned ECID must fail closed")
        let mismatchedRecoveryECID = DeviceDetector.parseRecoveryIdentityQuery("ECID: 0x511EA2E30C02E\nPRODUCT: iPhone12,8\nMODEL: d79ap\nCPID: 0x8030\nBDID: 0x10")
        expect(mismatchedRecoveryECID.exactModel(for: "0x1399A1401402E") == nil, "irecovery identity returned for a different ECID must fail closed")
        let unsupportedRecoveryIdentity = DeviceDetector.parseRecoveryIdentityQuery("ECID: 0x1399A1401402E\nPRODUCT: iPhone13,1\nMODEL: d52gap\nCPID: 0x8101\nBDID: 0x0A")
        expect(unsupportedRecoveryIdentity.matches(requestedECID: "0x1399A1401402E"), "same-target unsupported ProductType evidence may be retained for model-aware guidance")
        expect(unsupportedRecoveryIdentity.exactModel(for: "0x1399A1401402E") == nil, "unsupported ProductType evidence must never satisfy the destructive catalog")

        var postReset = pinnedNormal
        postReset.mode = .usbUnavailable
        postReset.modeVerified = false
        postReset.udid = nil
        expect(DeviceDetector.matchesPostFactoryResetCandidate(postReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "same-ECID pinned model on raw Normal USB must satisfy post-reset target check")
        var postResetWithoutProduct = postReset
        postResetWithoutProduct.productType = nil
        expect(!DeviceDetector.matchesPostFactoryResetCandidate(postResetWithoutProduct, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "same ECID without fresh exact ProductType evidence must not satisfy the post-reset model check")
        var resetTracker = PostFactoryResetTracker()
        expect(!resetTracker.observe(pinnedNormal, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "unchanged pre-reset Normal state must not prove Factory Reset completion")
        expect(!resetTracker.observe(DeviceSnapshot(mode: .notDetected), pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "target disappearance records a transition but is not a completed return")
        expect(resetTracker.observe(postReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "same target and model must return after an observed transition before post-reset verification passes")
        var differentSupportedModelAfterReset = postReset
        differentSupportedModelAfterReset.productType = "iPhone12,1"
        differentSupportedModelAfterReset.hardwareModel = "n104ap"
        expect(!DeviceDetector.matchesPostFactoryResetCandidate(differentSupportedModelAfterReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "a different supported model must fail the pinned post-reset target check")
        var recoveryAfterReset = postReset
        recoveryAfterReset.mode = .recovery
        recoveryAfterReset.usbPID = 0x1281
        expect(!DeviceDetector.matchesPostFactoryResetCandidate(recoveryAfterReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "Recovery mode must fail post-reset Normal return check")
        var multipleAfterReset = postReset
        multipleAfterReset.mode = .multiple
        multipleAfterReset.deviceCount = 2
        expect(!DeviceDetector.matchesPostFactoryResetCandidate(multipleAfterReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "multiple devices must fail post-reset target check")
        postReset.ecid = "0x511EA2E30C02E"
        expect(!DeviceDetector.matchesPostFactoryResetCandidate(postReset, pinnedECID: "0x1399A1401402E", pinnedModel: se2Model), "wrong ECID must reject post-reset target check")

        let preflightJSON = "{\"Command\":\"get\",\"Output\":{\"0x1399A1401402E\":{\"isPaired\":true,\"bootedState\":\"Booted\",\"ECID\":\"0x1399A1401402E\",\"UDID\":\"00008030-0001399A1401402E\",\"activationState\":\"Activated\",\"deviceType\":\"iPhone12,8\",\"isSupervised\":false,\"passcodeProtected\":true,\"firmwareVersion\":\"17.7\",\"buildVersion\":\"21H16\"},\"Errors\":{\"0x1399A1401402E\":{}}},\"Type\":\"CommandOutput\",\"Devices\":[\"0x1399A1401402E\"]}"
        if case .success(let info) = ConfiguratorTargetProbe.parse(preflightJSON, expectedECID: "0x1399A1401402E") {
            expect(info.isPaired == true && info.isSupervised == false && info.deviceType == "iPhone12,8", "Configurator preflight fields must parse")
        } else {
            failures.append("valid Configurator target preflight must parse")
        }
        if case .success = ConfiguratorTargetProbe.parse(preflightJSON, expectedECID: "0x511EA2E30C02E") {
            failures.append("Configurator target preflight must reject a different ECID")
        }
        let preflightWithError = preflightJSON.replacingOccurrences(
            of: "\"Errors\":{\"0x1399A1401402E\":{}}",
            with: "\"Errors\":{\"0x1399A1401402E\":{\"message\":\"not paired\"}}"
        )
        if case .success = ConfiguratorTargetProbe.parse(preflightWithError, expectedECID: "0x1399A1401402E") {
            failures.append("Configurator target preflight must reject a non-empty target error")
        }

        let factoryPin = FactoryResetPin(
            ecid: "0x1399A1401402E",
            udid: "00008030-0001399A1401402E",
            locationID: 1_048_576,
            model: se2Model
        )
        let validPairing = PairingValidation(isValid: true, detail: "SUCCESS")
        let validFactoryInfo = ConfiguratorTargetInfo(
            ecid: factoryPin.ecid,
            udid: factoryPin.udid,
            deviceType: "iPhone12,8",
            isPaired: true,
            activationState: "Activated",
            bootedState: "Booted",
            isSupervised: false,
            passcodeProtected: true,
            firmwareVersion: "17.7",
            buildVersion: "21H16"
        )
        expect(FactoryResetSafety.validationIssue(detected: pinnedNormal, pairing: validPairing, info: validFactoryInfo, pin: factoryPin) == nil, "fully matched Factory Reset preflight must pass")
        let invalidPairing = PairingValidation(isValid: false, detail: "not paired")
        expect(FactoryResetSafety.validationIssue(detected: pinnedNormal, pairing: invalidPairing, info: validFactoryInfo, pin: factoryPin)?.contains("Trust") == true, "pairing failure must block Factory Reset")
        let supervisedInfo = ConfiguratorTargetInfo(
            ecid: factoryPin.ecid,
            udid: factoryPin.udid,
            deviceType: "iPhone12,8",
            isPaired: true,
            activationState: "Activated",
            bootedState: "Booted",
            isSupervised: true,
            passcodeProtected: true,
            firmwareVersion: "17.7",
            buildVersion: "21H16"
        )
        expect(FactoryResetSafety.validationIssue(detected: pinnedNormal, pairing: validPairing, info: supervisedInfo, pin: factoryPin)?.contains("supervised") == true, "supervised device must block Factory Reset")
        let wrongFactoryInfo = ConfiguratorTargetInfo(
            ecid: "0x511EA2E30C02E",
            udid: factoryPin.udid,
            deviceType: "iPhone12,8",
            isPaired: true,
            activationState: "Activated",
            bootedState: "Booted",
            isSupervised: false,
            passcodeProtected: true,
            firmwareVersion: "17.7",
            buildVersion: "21H16"
        )
        expect(FactoryResetSafety.validationIssue(detected: pinnedNormal, pairing: validPairing, info: wrongFactoryInfo, pin: factoryPin)?.contains("different device") == true, "Configurator identity mismatch must block Factory Reset")

        let timeoutStart = Date()
        let timedOut = ProcessRunner.run("/bin/sleep", ["2"], timeout: 0.05)
        expect(timedOut.timedOut && timedOut.exitCode == -2, "timed-out child must be terminated and reported as -2")
        expect(Date().timeIntervalSince(timeoutStart) < 1.5, "timed-out child must not hang pipe collection")

        let streamFinished = DispatchSemaphore(value: 0)
        let streamLock = NSLock()
        var streamedLines: [String] = []
        _ = ProcessRunner.stream("/usr/bin/printf", ["final-line-without-newline"], onLine: { line in
            streamLock.lock()
            streamedLines.append(line)
            streamLock.unlock()
        }, onExit: { code, _ in
            expect(code == 0, "streaming child must exit zero")
            streamFinished.signal()
        })
        expect(streamFinished.wait(timeout: .now() + 2) == .success, "streaming child callback timed out")
        streamLock.lock()
        let capturedLines = streamedLines
        streamLock.unlock()
        expect(capturedLines == ["final-line-without-newline"], "streamer must flush a final line without newline")

        if CommandLine.arguments.count > 1 {
            let url = URL(fileURLWithPath: CommandLine.arguments[1])
            switch IPSWValidator.inspect(url) {
            case .success(let info):
                expect(info.isCompatible(with: se2Model), "selected IPSW must contain the exact iPhone12,8/d79ap model")
                expect(info.productVersion != "Unknown", "IPSW must expose ProductVersion")
                expect(info.buildVersion != "Unknown", "IPSW must expose ProductBuildVersion")
                print("IPSW: \(info.title), target-compatible=\(info.isCompatible(with: se2Model))")
            case .failure(let error):
                failures.append("IPSW validation failed: \(error.localizedDescription)")
            }
        }

        if failures.isEmpty {
            print("SELF-TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
