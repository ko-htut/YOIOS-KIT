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
          "0xE09812E82402E":{
            "deviceType":"iPhone12,8","serialNumber":"F17DK746PLJP",
            "batteryCurrentCapacity":45,"totalDiskCapacity":64000000000
          },
          "Errors":{"0xE09812E82402E":{"ICCID":{"Message":"property unavailable"}}}
        },"Type":"CommandOutput","Devices":["0xE09812E82402E"]}
        """
        let parsed = DeviceCenterParser.configuratorDetails(json, expectedECID: "0xe09812e82402e")
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
            ecid: "0xE09812E82402E",
            udid: nil,
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: nil,
            buildVersion: nil,
            activationState: nil,
            modeVerified: true,
            deviceName: nil,
            marketingName: "iPhone SE (2nd gen)",
            serialNumber: "F17DK746PLJP",
            chipID: "0x8030",
            boardID: "0x10",
            usbLinkSpeed: 480_000_000
        )
        let details = DeviceCenterCollector.baseline(for: snapshot, capturedAt: Date(timeIntervalSince1970: 1))
        expect(details.fact("mode")?.value == DeviceMode.recovery.title, "Recovery baseline must retain current mode")
        expect(details.fact("chipID")?.value == "0x8030", "Recovery CPID must be shown")
        expect(details.fact("serialNumber")?.value == "F17DK746PLJP", "Recovery serial must be shown when irecovery returns it")
        expect(details.fact("marketingName")?.value == "iPhone SE (2nd gen)", "Recovery NAME must be presented as a model name")
        expect(details.fact("deviceName") == nil, "Recovery NAME must never be presented as a user-assigned device name")
        expect(details.fact("batteryPercent") == nil, "Recovery baseline must not reuse a Normal-mode battery value")
        expect(details.fact("storageTotal") == nil, "Recovery baseline must not reuse Normal-mode storage")
        expect(details.notes.contains(where: { $0.contains("not reused") }), "Recovery baseline must explain stale-data protection")
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
        let ecid = "0x1C38A00A79802E"
        let decimal = String(UInt64("1C38A00A79802E", radix: 16)!)
        let udid = "00008030-001C38A00A79802E"
        let serial = "F17DK746PLJP"
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
            ecid: "0x1C38A00A79802E",
            udid: "00008030-001C38A00A79802E",
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
        expect(!report.contains("0x1C38A00A79802E"), "report must not expose full ECID")
        expect(!report.contains("00008030-001C38A00A79802E"), "report must not expose full UDID")
        expect(!report.contains("SECRET-SERIAL-1234"), "report must not expose full serial")
        expect(!report.contains("Private Owner's iPhone"), "report must not expose device name")
        expect(report.contains("Not verified by this app"), "report must preserve Find My limitation")
        expect(!report.contains("No issues found"), "report must not claim a 3uTools-style health verdict")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
