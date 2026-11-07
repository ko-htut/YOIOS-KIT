import Foundation

@main
struct DeviceCenterTestMain {
    private static var failures: [String] = []

    static func main() {
        testPlistParsing()
        testConfiguratorPartialResponse()
        testConfiguratorContractHardening()
        testValidationBounds()
        testRecoveryBaselineDoesNotInventNormalFacts()
        testRecoveryIdentityMatrix()
        testEvidenceFormattingAndAttribution()
        testOperationalRedaction()
        testRedactedReport()

        if failures.isEmpty {
            print("DEVICE CENTER TEST PASS")
            exit(0)
        }
        failures.forEach { fputs("FAIL: \($0)\n", stderr) }
        exit(1)
    }

    private static func testPlistParsing() {
        let source: [String: Any] = [
            "ProductType": "iPhone12,8",
            "BatteryCurrentCapacity": 89,
            "BatteryIsCharging": true
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: source, format: .xml, options: 0)
        let parsed = DeviceCenterParser.plistDictionary(data)
        expect(parsed["ProductType"] as? String == "iPhone12,8", "plist ProductType must round-trip")
        expect(DeviceCenterParser.int64(parsed["BatteryCurrentCapacity"]) == 89, "plist battery percent must parse")
        expect(DeviceCenterParser.bool(parsed["BatteryIsCharging"]) == true, "plist charging state must parse")
    }

    private static func testConfiguratorPartialResponse() {
        let json = """
        {"Command":"get","Output":{
          "0x123456789ABCDE":{
            "deviceType":"iPhone12,8","serialNumber":"SYNTHETIC0001",
            "batteryCurrentCapacity":45,"totalDiskCapacity":64000000000
          },
          "Errors":{"0x123456789ABCDE":{"ICCID":{"Message":"property unavailable"}}}
        },"Type":"CommandOutput","Devices":["0x123456789ABCDE"]}
        """
        let parsed = DeviceCenterParser.configuratorDetails(json, expectedECID: "0x123456789abcde")
        expect(parsed.values["deviceType"] as? String == "iPhone12,8", "partial cfgutil values must survive a property error")
        expect(DeviceCenterParser.int64(parsed.values["totalDiskCapacity"]) == 64_000_000_000, "cfgutil 64 GB capacity must parse")
        expect(parsed.propertyErrors.keys.contains("ICCID"), "cfgutil per-property error must be retained")

        let wrong = DeviceCenterParser.configuratorDetails(json, expectedECID: "0x111")
        expect(wrong.values.isEmpty, "a different ECID response must not be accepted")
    }

    private static func testValidationBounds() {
        expect(DeviceCenterParser.validBatteryPercent(0) == 0, "0% battery is valid")
        expect(DeviceCenterParser.validBatteryPercent(100) == 100, "100% battery is valid")
        expect(DeviceCenterParser.validBatteryPercent(101) == nil, "battery over 100% must be rejected")
        expect(DeviceCenterParser.validBatteryPercent(-1) == nil, "negative battery must be rejected")

        let coherent = DeviceCenterParser.coherentStorage(total: 64_000_000_000, available: 38_000_000_000)
        expect(coherent?.available == 38_000_000_000, "coherent storage must be retained")
        let incoherent = DeviceCenterParser.coherentStorage(total: 64_000_000_000, available: 70_000_000_000)
        expect(incoherent?.available == nil, "available storage larger than total must be rejected")
        expect(DeviceCenterParser.coherentStorage(total: 0, available: 0) == nil, "zero total storage must be rejected")
        expect(DeviceCenterParser.bool(NSNumber(value: 2)) == nil, "non-Boolean NSNumber sentinels must be rejected")
        expect(DeviceCenterParser.bool("2") == nil, "non-Boolean numeric strings must be rejected")
        expect(DeviceCenterParser.hexadecimal(NSNumber(value: 32_816)) == "0x8030", "decimal CPID must render as canonical hex")
        expect(DeviceCenterParser.hexadecimal(NSNumber(value: 16)) == "0x10", "decimal BDID must render as canonical hex")
    }

    private static func testConfiguratorContractHardening() {
        let good = """
        {"Command":"get","Output":{"0xABC":{"ECID":"0xABC","deviceType":"iPhone12,8"},"Errors":{"0xABC":{}}},"Type":"CommandOutput","Devices":["0xABC"]}
        """
        expect(!DeviceCenterParser.configuratorDetails(good, expectedECID: "0xABC").values.isEmpty, "valid exact-target cfgutil response must parse")
        expect(
            DeviceCenterParser.configuratorDetails(good.replacingOccurrences(of: "CommandOutput", with: "Error"), expectedECID: "0xABC").values.isEmpty,
            "non-CommandOutput cfgutil response must be rejected"
        )
        expect(
            DeviceCenterParser.configuratorDetails(good.replacingOccurrences(of: "\"get\"", with: "\"list\""), expectedECID: "0xABC").values.isEmpty,
            "wrong cfgutil command must be rejected"
        )
        expect(
            DeviceCenterParser.configuratorDetails(good.replacingOccurrences(of: "[\"0xABC\"]", with: "[\"0xDEF\"]"), expectedECID: "0xABC").values.isEmpty,
            "cfgutil Devices must contain the expected ECID"
        )
        expect(
            DeviceCenterParser.configuratorDetails(good.replacingOccurrences(of: "\"ECID\":\"0xABC\"", with: "\"ECID\":\"0xDEF\""), expectedECID: "0xABC").values.isEmpty,
            "internal cfgutil ECID mismatch must be rejected"
        )
    }

    private static func testRecoveryBaselineDoesNotInventNormalFacts() {
        let snapshot = DeviceSnapshot(
            mode: .recovery,
            deviceCount: 1,
            usbPID: 0x1281,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: nil,
            productType: "iPhone11,4",
            hardwareModel: "d331ap",
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: true,
            deviceName: nil,
            marketingName: "iPhone XS Max (China)",
            serialNumber: "SYNTHETIC0001",
            chipID: "0x8020",
            boardID: "0x0A",
            usbLinkSpeed: 480_000_000,
            recoveryIdentityQueryVerified: true
        )
        let details = DeviceCenterCollector.baseline(for: snapshot, capturedAt: Date(timeIntervalSince1970: 1))
        expect(details.fact("mode")?.value == DeviceMode.recovery.title, "Recovery baseline must retain current mode")
        expect(details.fact("chipID")?.value == "0x8020", "Recovery CPID must be shown")
        expect(details.fact("boardID")?.value == "0x0A", "Recovery BDID must be shown")
        expect(details.fact("serialNumber")?.value == "SYNTHETIC0001", "Recovery serial must be shown when irecovery returns it")
        expect(details.fact("marketingName")?.value == "iPhone XS Max (China)", "Recovery NAME must be presented as a model name")
        expect(details.fact("supportedIdentity")?.status == .verified, "complete targeted Recovery identity evidence must be verified")
        expect(details.fact("supportedIdentity")?.value.contains("CPID/BDID verified") == true, "Recovery identity summary must disclose the complete queried tuple")
        expect(details.fact("supportedIdentity")?.source == "Targeted libirecovery identity query", "Recovery identity must retain targeted-query attribution")
        expect(details.fact("deviceName") == nil, "Recovery NAME must never be presented as a user-assigned device name")
        expect(details.fact("batteryPercent") == nil, "Recovery baseline must not reuse a Normal-mode battery value")
        expect(details.fact("storageTotal") == nil, "Recovery baseline must not reuse Normal-mode storage")
        expect(details.notes.contains(where: { $0.contains("not reused") }), "Recovery baseline must explain stale-data protection")
    }

    private static func testRecoveryIdentityMatrix() {
        expect(SupportedDeviceCatalog.all.count == 14, "the bounded iPhone 8-through-SE2 catalog must retain every regional ProductType identity")

        for supportedModel in SupportedDeviceCatalog.all {
            for mode in [DeviceMode.recovery, .dfu] {
                let snapshot = DeviceSnapshot(
                    mode: mode,
                    deviceCount: 1,
                    usbPID: mode == .recovery ? 0x1281 : 0x1227,
                    locationID: 1_048_576,
                    ecid: "0x123456789ABCDE",
                    productType: supportedModel.productType,
                    hardwareModel: supportedModel.hardwareModel,
                    modeVerified: true,
                    chipID: String(format: "0x%X", supportedModel.chipID),
                    boardID: String(format: "0x%X", supportedModel.boardID),
                    recoveryIdentityQueryVerified: true
                )
                expect(snapshot.supportedDeviceModel == supportedModel, "\(mode.title) must resolve exact identity \(supportedModel.identitySummary)")
                expect(snapshot.hasVerifiedSupportedDeviceIdentity, "\(mode.title) must accept the complete targeted tuple for \(supportedModel.identitySummary)")
                let details = DeviceCenterCollector.baseline(for: snapshot)
                expect(details.fact("supportedIdentity")?.status == .verified, "\(mode.title) evidence must mark \(supportedModel.productType) verified")
                expect(details.fact("supportedIdentity")?.source == "Targeted libirecovery identity query", "\(mode.title) evidence must preserve libirecovery attribution")
            }
        }

        let model = SupportedDeviceCatalog.all[0]
        let incomplete = DeviceSnapshot(
            mode: .recovery,
            deviceCount: 1,
            usbPID: 0x1281,
            ecid: "0x123456789ABCDE",
            productType: model.productType,
            hardwareModel: model.hardwareModel,
            modeVerified: true,
            chipID: String(format: "0x%X", model.chipID),
            boardID: nil,
            recoveryIdentityQueryVerified: true
        )
        expect(!incomplete.hasVerifiedSupportedDeviceIdentity, "Recovery must fail closed when targeted BDID evidence is absent")

        var unverifiedQuery = incomplete
        unverifiedQuery.boardID = String(format: "0x%X", model.boardID)
        unverifiedQuery.recoveryIdentityQueryVerified = false
        expect(!unverifiedQuery.hasVerifiedSupportedDeviceIdentity, "Recovery must fail closed when the full tuple was not returned by one targeted query")

        var conflicting = unverifiedQuery
        conflicting.recoveryIdentityQueryVerified = true
        conflicting.boardID = "0xFFFF"
        expect(conflicting.supportedDeviceModel == nil && !conflicting.hasVerifiedSupportedDeviceIdentity, "Recovery must reject a ProductType/HardwareModel/CPID/BDID mismatch")
    }

    private static func testEvidenceFormattingAndAttribution() {
        let unverifiedRecovery = DeviceSnapshot(
            mode: .recovery,
            deviceCount: 1,
            usbPID: 0x1281,
            locationID: 1_048_576,
            ecid: "0xABC",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            modeVerified: false
        )
        let baseline = DeviceCenterCollector.baseline(for: unverifiedRecovery)
        expect(baseline.fact("protocol")?.source == "IORegistry", "unverified Recovery must not claim libirecovery verification")

        let pairingFact = DeviceFact(
            id: "pairing",
            group: .security,
            label: "Pairing / Trust",
            value: "Validated",
            status: .verified,
            source: "idevicepair validate",
            explanation: "fixture",
            sensitivity: .none
        )
        let paired = DeviceCenterSnapshot(
            capturedAt: Date(), mode: .normal, targetECID: "0xABC", targetUDID: "UDID",
            facts: [pairingFact], batteryPercent: nil, isCharging: nil,
            totalStorageBytes: nil, availableStorageBytes: nil, notes: []
        )
        expect(paired.pairingValidated, "pairingValidated must require the explicit validated evidence record")
    }

    private static func testOperationalRedaction() {
        let ecid = "0x123456789ABCDE"
        let decimal = String(UInt64("123456789ABCDE", radix: 16)!)
        let udid = "00008030-00123456789ABCDE"
        let serial = "SYNTHETIC0001"
        let name = "Private Owner's iPhone"
        let facts = [
            DeviceFact(id: "serial", group: .identity, label: "Serial", value: serial, status: .reported, source: "fixture", explanation: "fixture", sensitivity: .identifier),
            DeviceFact(id: "name", group: .identity, label: "Name", value: name, status: .reported, source: "fixture", explanation: "fixture", sensitivity: .personal)
        ]
        let raw = "error target \(ecid) decimal \(decimal) udid \(udid) serial \(serial) name \(name) at /Users/private/firmware.ipsw"
        let redacted = DeviceCenterPrivacy.redactOperationalText(
            raw,
            ecids: [ecid],
            udids: [udid],
            facts: facts,
            localPaths: ["/Users/private"]
        )
        for secret in [ecid, decimal, udid, serial, name, "/Users/private"] {
            expect(!redacted.localizedCaseInsensitiveContains(secret), "operational text must redact \(secret)")
        }
    }

    private static func testRedactedReport() {
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
            modeVerified: true,
            deviceName: "Private Owner's iPhone",
            serialNumber: "SECRET-SERIAL-1234"
        )
        let details = DeviceCenterCollector.baseline(for: snapshot, capturedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let report = DeviceCenterReportBuilder.redactedText(for: details)
        expect(!report.contains("0x123456789ABCDE"), "report must not expose full ECID")
        expect(!report.contains("00008030-00123456789ABCDE"), "report must not expose full UDID")
        expect(!report.contains("SECRET-SERIAL-1234"), "report must not expose full serial")
        expect(!report.contains("Private Owner's iPhone"), "report must not expose device name")
        expect(report.contains("Not verified by this app"), "report must preserve Find My limitation")
        expect(!report.contains("No issues found"), "report must not claim a 3uTools-style health verdict")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
