import Foundation

@main
struct GenericDFURestoreTestMain {
    private static func classicFixture(
        productType: String = "iPhone13,1",
        hardwareModel: String = "d52gap",
        chipID: String = "0x8101",
        boardID: String = "0x0A"
    ) -> DeviceSnapshot {
        var snapshot = DeviceSnapshot(
            mode: .dfu,
            deviceCount: 1,
            usbPID: 0x1227,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: nil,
            productType: productType,
            hardwareModel: hardwareModel,
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: true,
            chipID: chipID,
            boardID: boardID
        )
        snapshot.recoveryIdentityQueryTargetVerified = true
        return snapshot
    }

    private static func kisFixture(productType: String = "iPhone15,4") -> DeviceSnapshot {
        var snapshot = DeviceSnapshot(
            mode: .unknown,
            deviceCount: 1,
            usbPID: 0x1881,
            locationID: 1_048_576,
            ecid: "0x1399A1401402E",
            udid: nil,
            productType: productType,
            hardwareModel: nil,
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: false
        )
        snapshot.configuratorDFURestoreVerified = true
        return snapshot
    }

    private static func configuratorInfo(
        ecid: String = "0x1399A1401402E",
        productType: String = "iPhone13,1",
        deviceClass: String = "iPhone",
        bootedState: String = "DFU",
        isRestorable: Bool = true,
        locationID: Int = 1_048_576
    ) -> ConfiguratorDFURestoreInfo {
        ConfiguratorDFURestoreInfo(
            ecid: ecid,
            productType: productType,
            deviceClass: deviceClass,
            bootedState: bootedState,
            isRestorable: isRestorable,
            locationID: locationID
        )
    }

    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        for productType in ["iPhone8,4", "iPhone9,3", "iPhone13,1", "iPhone18,3"] {
            let snapshot = classicFixture(productType: productType)
            guard let target = DFURestoreTarget(snapshot: snapshot) else {
                failures.append("complete classic DFU fixture \(productType) must produce a restore target")
                continue
            }
            expect(target.productType == productType, "target must retain ProductType \(productType)")
            expect(target.proof == .classicLibirecovery, "classic target must retain libirecovery proof")
            expect(target.usesAppleLatestOnly, "generic restore must use Apple latest only")
            expect(SupportedDeviceCatalog.model(productType: productType) == nil, "\(productType) must stay outside the reviewed catalog")
            expect(
                target.matches(snapshot: snapshot, configurator: configuratorInfo(productType: productType)),
                "exact Configurator agreement must validate \(productType)"
            )
        }

        let base = classicFixture()
        guard let target = DFURestoreTarget(snapshot: base) else {
            fputs("FAIL: base generic DFU target did not initialize\n", stderr)
            exit(1)
        }
        expect(target.ecid == "0x1399A1401402E", "target must canonicalize ECID")
        expect(target.hardwareModel == "d52gap", "target must normalize HardwareModel")
        expect(target.chipID == 0x8101 && target.boardID == 0x0A, "target must parse CPID and BDID")

        var invalid = base
        invalid.deviceCount = 2
        expect(DFURestoreTarget(snapshot: invalid) == nil, "multiple devices must be rejected")
        invalid = base
        invalid.mode = .recovery
        expect(DFURestoreTarget(snapshot: invalid) == nil, "Recovery must not satisfy generic DFU restore")
        invalid = base
        invalid.modeVerified = false
        expect(DFURestoreTarget(snapshot: invalid) == nil, "unverified classic DFU must be rejected")
        invalid = base
        invalid.usbPID = 0x1281
        expect(DFURestoreTarget(snapshot: invalid) == nil, "non-DFU PID must be rejected")
        invalid = base
        invalid.ecid = nil
        expect(DFURestoreTarget(snapshot: invalid) == nil, "missing ECID must be rejected")
        invalid = base
        invalid.ecid = "0"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "zero ECID must be rejected")
        invalid = base
        invalid.locationID = nil
        expect(DFURestoreTarget(snapshot: invalid) == nil, "missing location must be rejected")
        invalid = base
        invalid.productType = "iPad13,1"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "non-iPhone ProductType must be rejected")
        invalid = base
        invalid.productType = "iPhone13,01"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "malformed ProductType must be rejected")
        invalid = base
        invalid.hardwareModel = "   "
        expect(DFURestoreTarget(snapshot: invalid) == nil, "blank HardwareModel must be rejected")
        invalid = base
        invalid.chipID = nil
        expect(DFURestoreTarget(snapshot: invalid) == nil, "missing CPID must be rejected")
        invalid = base
        invalid.chipID = "0"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "zero CPID must be rejected")
        invalid = base
        invalid.chipID = "not-a-number"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "malformed CPID must be rejected")
        invalid = base
        invalid.boardID = nil
        expect(DFURestoreTarget(snapshot: invalid) == nil, "missing BDID must be rejected")
        invalid = base
        invalid.boardID = "0"
        expect(DFURestoreTarget(snapshot: invalid) == nil, "zero BDID must be rejected")
        invalid = base
        invalid.recoveryIdentityQueryTargetVerified = false
        expect(DFURestoreTarget(snapshot: invalid) == nil, "missing exact query attestation must be rejected")
        invalid = base
        invalid.identityConflict = true
        expect(DFURestoreTarget(snapshot: invalid) == nil, "identity conflict must be rejected")

        var changed = base
        changed.hardwareModel = "differentap"
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed HardwareModel must fail")
        changed = base
        changed.chipID = "0x8015"
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed CPID must fail")
        changed = base
        changed.boardID = "0x02"
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed BDID must fail")
        changed = base
        changed.ecid = "0x511EA2E30C02E"
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed snapshot ECID must fail")
        changed = base
        changed.locationID = 2_097_152
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed snapshot location must fail")
        changed = base
        changed.productType = "iPhone12,8"
        expect(!target.matches(snapshot: changed, configurator: configuratorInfo()), "changed snapshot ProductType must fail")

        expect(!target.matches(snapshot: base, configurator: configuratorInfo(ecid: "0x511EA2E30C02E")), "wrong Configurator ECID must fail")
        expect(!target.matches(snapshot: base, configurator: configuratorInfo(productType: "iPhone12,8")), "wrong Configurator ProductType must fail")
        expect(!target.matches(snapshot: base, configurator: configuratorInfo(deviceClass: "iPad")), "wrong Configurator class must fail")
        expect(!target.matches(snapshot: base, configurator: configuratorInfo(bootedState: "Booted")), "ordinary boot state must fail")
        expect(!target.matches(snapshot: base, configurator: configuratorInfo(isRestorable: false)), "non-restorable result must fail")
        expect(!target.matches(snapshot: base, configurator: configuratorInfo(locationID: 2_097_152)), "wrong Configurator location must fail")

        let kis = kisFixture()
        guard let kisTarget = DFURestoreTarget(snapshot: kis) else {
            fputs("FAIL: Configurator-verified KIS target did not initialize\n", stderr)
            exit(1)
        }
        expect(kisTarget.proof == .appleConfiguratorKIS, "KIS must not claim classic DFU proof")
        expect(kisTarget.hardwareModel == nil && kisTarget.chipID == nil && kisTarget.boardID == nil, "KIS must not invent hardware fields")
        expect(
            kisTarget.matches(
                snapshot: kis,
                configurator: configuratorInfo(productType: "iPhone15,4", bootedState: "DFU (Port)")
            ),
            "exact Apple Configurator KIS target must pass"
        )
        invalid = kis
        invalid.configuratorDFURestoreVerified = false
        expect(DFURestoreTarget(snapshot: invalid) == nil, "raw KIS PID must fail without Configurator proof")
        invalid = kis
        invalid.mode = .recovery
        expect(DFURestoreTarget(snapshot: invalid) == nil, "Recovery must not masquerade as KIS")
        invalid = kis
        invalid.usbPID = 0x1227
        invalid.mode = .dfu
        invalid.modeVerified = true
        expect(DFURestoreTarget(snapshot: invalid) == nil, "KIS-only proof must not satisfy classic DFU")

        let validJSON = """
        {"Command":"get","Output":{"0x1399A1401402E":{"ECID":"0x1399A1401402E","deviceType":"iPhone13,1","deviceClass":"iPhone","bootedState":"DFU","isRestorable":true,"locationID":1048576},"Errors":{"0x1399A1401402E":{}}},"Type":"CommandOutput"}
        """
        if case .success(let info) = ConfiguratorDFURestoreProbe.parse(validJSON, expectedECID: target.ecid) {
            expect(info.isExactRestorableDFU(for: target), "valid exact Configurator get response must verify target")
        } else {
            failures.append("valid Configurator DFU get response must parse")
        }
        if case .success = ConfiguratorDFURestoreProbe.parse(validJSON, expectedECID: "0x511EA2E30C02E") {
            failures.append("Configurator parser must reject a different requested ECID")
        }
        for fragment in [
            "\"ECID\":\"0x1399A1401402E\",",
            "\"deviceType\":\"iPhone13,1\",",
            "\"deviceClass\":\"iPhone\",",
            "\"bootedState\":\"DFU\",",
            "\"isRestorable\":true,",
            ",\"locationID\":1048576"
        ] {
            let missingFieldJSON = validJSON.replacingOccurrences(of: fragment, with: "")
            if case .success = ConfiguratorDFURestoreProbe.parse(missingFieldJSON, expectedECID: target.ecid) {
                failures.append("Configurator parser must reject response missing \(fragment)")
            }
        }
        let nonRestorableJSON = validJSON.replacingOccurrences(of: "\"isRestorable\":true", with: "\"isRestorable\":false")
        if case .success(let info) = ConfiguratorDFURestoreProbe.parse(nonRestorableJSON, expectedECID: target.ecid) {
            expect(!info.isExactRestorableDFU(for: target), "parsed non-restorable evidence must not verify target")
        } else {
            failures.append("explicit false isRestorable should parse as evidence and fail policy")
        }
        for (original, replacement, reason) in [
            ("\"deviceClass\":\"iPhone\"", "\"deviceClass\":\"iPad\"", "wrong device class"),
            ("\"bootedState\":\"DFU\"", "\"bootedState\":\"Booted\"", "wrong boot state"),
            ("\"locationID\":1048576", "\"locationID\":2097152", "wrong USB location")
        ] {
            let mismatchJSON = validJSON.replacingOccurrences(of: original, with: replacement)
            if case .success(let info) = ConfiguratorDFURestoreProbe.parse(mismatchJSON, expectedECID: target.ecid) {
                expect(!info.isExactRestorableDFU(for: target), "parsed \(reason) must not verify target")
            } else {
                failures.append("Configurator should parse complete evidence with \(reason) so policy can reject it")
            }
        }

        let genericPostBoot = RestorePostBootPin(
            ecid: target.ecid,
            productType: target.productType,
            displayName: "iPhone 12 mini"
        )!
        var normalReturn = base
        normalReturn.mode = .normal
        normalReturn.usbPID = 0x12A8
        normalReturn.modeVerified = true
        normalReturn.recoveryIdentityQueryTargetVerified = false
        expect(genericPostBoot.matches(normalReturn), "same generic iPhone may verify Normal return")
        var wrongReturn = normalReturn
        wrongReturn.ecid = "0x511EA2E30C02E"
        expect(!genericPostBoot.matches(wrongReturn), "wrong post-boot ECID must fail")
        wrongReturn = normalReturn
        wrongReturn.productType = "iPhone12,8"
        expect(!genericPostBoot.matches(wrongReturn), "wrong post-boot ProductType must fail")
        wrongReturn = normalReturn
        wrongReturn.productType = nil
        expect(!genericPostBoot.matches(wrongReturn), "missing post-boot ProductType must fail")
        wrongReturn = normalReturn
        wrongReturn.identityConflict = true
        expect(!genericPostBoot.matches(wrongReturn), "post-boot identity conflict must fail")
        wrongReturn = normalReturn
        wrongReturn.modeVerified = false
        expect(!genericPostBoot.matches(wrongReturn), "unverified Normal return must fail")
        wrongReturn = normalReturn
        wrongReturn.mode = .recovery
        expect(!genericPostBoot.matches(wrongReturn), "Recovery must not satisfy Normal return")

        let reviewed = SupportedDeviceCatalog.se2
        let reviewedPin = RestorePostBootPin(
            ecid: target.ecid,
            productType: reviewed.productType,
            displayName: reviewed.marketingName,
            reviewedModel: reviewed
        )!
        var reviewedReturn = normalReturn
        reviewedReturn.productType = reviewed.productType
        reviewedReturn.hardwareModel = reviewed.hardwareModel
        reviewedReturn.chipID = String(format: "0x%llX", reviewed.chipID)
        reviewedReturn.boardID = String(format: "0x%llX", reviewed.boardID)
        expect(reviewedPin.matches(reviewedReturn), "reviewed post-boot pin must retain catalog agreement")

        guard let confirmation = DestructiveRestoreConfirmationPolicy(ecid: target.ecid) else {
            fputs("FAIL: valid destructive confirmation policy did not initialize\n", stderr)
            exit(1)
        }
        expect(confirmation.phrase == "ERASE 01402E", "phrase must bind final six ECID digits")
        expect(confirmation.accepts(typedText: confirmation.phrase, dataLossAcknowledged: true), "exact phrase plus acknowledgement must pass")
        expect(!confirmation.accepts(typedText: "ERASE", dataLossAcknowledged: true), "generic ERASE must fail")
        expect(!confirmation.accepts(typedText: "erase 01402e", dataLossAcknowledged: true), "phrase must be case-sensitive")
        expect(!confirmation.accepts(typedText: confirmation.phrase, dataLossAcknowledged: false), "missing acknowledgement must fail")
        expect(DestructiveRestoreConfirmationPolicy(ecid: "0") == nil, "zero ECID must not create confirmation policy")

        if failures.isEmpty {
            print("GENERIC DFU RESTORE TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
