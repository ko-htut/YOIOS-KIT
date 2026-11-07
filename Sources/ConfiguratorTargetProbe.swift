import Foundation

struct ConfiguratorTargetInfo: Equatable {
    let ecid: String
    let udid: String?
    let deviceType: String?
    let isPaired: Bool?
    let activationState: String?
    let bootedState: String?
    let isSupervised: Bool?
    let passcodeProtected: Bool?
    let firmwareVersion: String?
    let buildVersion: String?
}

struct PairingValidation: Equatable {
    let isValid: Bool
    let detail: String
}

struct FactoryResetPin: Equatable {
    let ecid: String
    let udid: String
    let locationID: Int
    let model: SupportedDeviceModel?

    init(
        ecid: String,
        udid: String,
        locationID: Int,
        model: SupportedDeviceModel? = nil
    ) {
        self.ecid = ecid
        self.udid = udid
        self.locationID = locationID
        self.model = model
    }
}

enum FactoryResetSafety {
    static func validationIssue(
        detected: DeviceSnapshot,
        pairing: PairingValidation,
        info: ConfiguratorTargetInfo,
        pin: FactoryResetPin
    ) -> String? {
        guard DeviceDetector.matchesPinnedNormalTarget(
            detected,
            pinnedECID: pin.ecid,
            pinnedUDID: pin.udid,
            pinnedLocation: pin.locationID,
            pinnedModel: pin.model
        ) else {
            return "The same verified supported iPhone was not found at the original USB port."
        }
        guard pairing.isValid else {
            return "Pairing/Trust validation failed. Unlock the iPhone, tap Trust, enter its passcode, and scan again. \(pairing.detail)"
        }
        guard let pinnedModel = pin.model,
              DeviceDetector.normalizeECID(info.ecid) == DeviceDetector.normalizeECID(pin.ecid),
              info.udid?.caseInsensitiveCompare(pin.udid) == .orderedSame,
              info.deviceType?.caseInsensitiveCompare(pinnedModel.productType) == .orderedSame else {
            return "Apple Configurator returned a different device identity."
        }
        guard info.bootedState?.caseInsensitiveCompare("Booted") == .orderedSame else {
            return "Apple Configurator did not verify a booted Normal-iOS device."
        }
        guard info.isPaired == true else {
            return "Apple Configurator reports that the iPhone is not paired with this Mac. Unlock it and accept Trust."
        }
        guard info.activationState?.caseInsensitiveCompare("Activated") == .orderedSame else {
            return "The iPhone is not in an activated, fully booted state suitable for Factory Reset."
        }
        guard info.isSupervised == false else {
            return info.isSupervised == true
                ? "This iPhone is supervised. Factory Reset would remove supervision; contact its organization administrator instead."
                : "Apple Configurator could not verify whether this iPhone is supervised."
        }
        return nil
    }
}

enum ConfiguratorTargetProbe {
    static func inspect(ecid: String) -> Result<ConfiguratorTargetInfo, Error> {
        guard let canonical = DeviceDetector.canonicalECIDHex(ecid) else {
            return .failure(error(1, "The target ECID is invalid."))
        }
        let result = ProcessRunner.run(
            ToolPaths.cfgutil,
            AppleCommandBuilder.factoryResetPreflight(ecid: canonical),
            timeout: 20
        )
        guard result.exitCode == 0 else {
            let detail = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(error(2, detail.isEmpty ? "cfgutil target preflight failed." : detail))
        }
        return parse(result.stdout, expectedECID: canonical)
    }

    static func parse(_ output: String, expectedECID: String) -> Result<ConfiguratorTargetInfo, Error> {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["Type"] as? String)?.lowercased() == "commandoutput",
              (root["Command"] as? String)?.lowercased() == "get",
              let values = root["Output"] as? [String: Any] else {
            return .failure(error(3, "Configurator returned an invalid target-preflight response."))
        }

        let expected = DeviceDetector.normalizeECID(expectedECID)
        if let errors = values["Errors"] as? [String: Any],
           let targetError = errors.first(where: {
               DeviceDetector.normalizeECID($0.key) == expected
           })?.value {
            if let dictionary = targetError as? [String: Any], !dictionary.isEmpty {
                return .failure(error(4, "Configurator reported a target-preflight error: \(dictionary)"))
            }
            if !(targetError is [String: Any]) && !(targetError is NSNull) {
                return .failure(error(4, "Configurator reported a target-preflight error: \(targetError)"))
            }
        }
        guard let entry = values.first(where: { key, value in
            key != "Errors" && value is [String: Any] &&
            DeviceDetector.normalizeECID(key) == expected
        }),
        let record = entry.value as? [String: Any] else {
            return .failure(error(5, "Configurator did not return the exact requested ECID."))
        }

        let recordECID = record["ECID"] as? String ?? entry.key
        guard DeviceDetector.normalizeECID(recordECID) == expected,
              let canonical = DeviceDetector.canonicalECIDHex(recordECID) else {
            return .failure(error(6, "Configurator returned a different target ECID."))
        }

        return .success(ConfiguratorTargetInfo(
            ecid: canonical,
            udid: record["UDID"] as? String,
            deviceType: record["deviceType"] as? String,
            isPaired: record["isPaired"] as? Bool,
            activationState: record["activationState"] as? String,
            bootedState: record["bootedState"] as? String,
            isSupervised: record["isSupervised"] as? Bool,
            passcodeProtected: record["passcodeProtected"] as? Bool,
            firmwareVersion: record["firmwareVersion"] as? String,
            buildVersion: record["buildVersion"] as? String
        ))
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "local.minthanhtut.SE2RecoveryAssistant.ConfiguratorTargetProbe",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum ConfiguratorDFURestoreProbe {
    static func inspect(ecid: String) -> Result<ConfiguratorDFURestoreInfo, Error> {
        guard let canonical = DeviceDetector.canonicalECIDHex(ecid) else {
            return .failure(error(1, "The DFU restore target ECID is invalid."))
        }
        let result = ProcessRunner.run(
            ToolPaths.cfgutil,
            AppleCommandBuilder.dfuRestorePreflight(ecid: canonical),
            timeout: 20
        )
        guard result.exitCode == 0 else {
            let detail = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(error(2, detail.isEmpty ? "Configurator DFU preflight failed." : detail))
        }
        return parse(result.stdout, expectedECID: canonical)
    }

    static func parse(
        _ output: String,
        expectedECID: String
    ) -> Result<ConfiguratorDFURestoreInfo, Error> {
        guard let data = output.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["Type"] as? String)?.lowercased() == "commandoutput",
              (root["Command"] as? String)?.lowercased() == "get",
              let values = root["Output"] as? [String: Any] else {
            return .failure(error(3, "Configurator returned an invalid DFU-preflight response."))
        }

        let expected = DeviceDetector.normalizeECID(expectedECID)
        if let errors = values["Errors"] as? [String: Any],
           let targetError = errors.first(where: {
               DeviceDetector.normalizeECID($0.key) == expected
           })?.value,
           !isEmptyError(targetError) {
            return .failure(error(4, "Configurator reported a DFU-preflight error."))
        }
        guard let entry = values.first(where: { key, value in
            key != "Errors" && value is [String: Any] &&
                DeviceDetector.normalizeECID(key) == expected
        }), let record = entry.value as? [String: Any] else {
            return .failure(error(5, "Configurator did not return the exact requested DFU ECID."))
        }
        guard let info = parseRecord(
            record,
            keyedECID: entry.key,
            expectedECID: expectedECID
        ) else {
            return .failure(error(6, "Configurator did not return a complete restorable DFU identity."))
        }
        return .success(info)
    }

    static func parseRecord(
        _ record: [String: Any],
        keyedECID: String,
        expectedECID: String
    ) -> ConfiguratorDFURestoreInfo? {
        guard let recordECID = record["ECID"] as? String,
              DeviceDetector.normalizeECID(keyedECID) == DeviceDetector.normalizeECID(expectedECID),
              DeviceDetector.normalizeECID(recordECID) == DeviceDetector.normalizeECID(expectedECID),
              let canonical = DeviceDetector.canonicalECIDHex(recordECID),
              let productType = record["deviceType"] as? String,
              IPhoneButtonFamily.classify(productType: productType) != nil,
              let deviceClass = record["deviceClass"] as? String,
              !deviceClass.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let bootedState = record["bootedState"] as? String,
              !bootedState.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let isRestorable = boolean(record["isRestorable"]),
              let locationID = locationIdentifier(record["locationID"]) else {
            return nil
        }
        return ConfiguratorDFURestoreInfo(
            ecid: canonical,
            productType: productType,
            deviceClass: deviceClass,
            bootedState: bootedState,
            isRestorable: isRestorable,
            locationID: locationID
        )
    }

    private static func boolean(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        return nil
    }

    private static func locationIdentifier(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.hasPrefix("0x") {
            return Int(trimmed.dropFirst(2), radix: 16)
        }
        return Int(trimmed, radix: 10)
    }

    private static func isEmptyError(_ value: Any) -> Bool {
        if value is NSNull { return true }
        if let dictionary = value as? [String: Any] { return dictionary.isEmpty }
        return false
    }

    private static func error(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "local.minthanhtut.SE2RecoveryAssistant.ConfiguratorDFURestoreProbe",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

enum PairingProbe {
    static func validate(udid: String) -> PairingValidation {
        guard let tool = ToolPaths.idevicePair else {
            return PairingValidation(
                isValid: false,
                detail: "idevicepair is not installed. Install or update libimobiledevice."
            )
        }
        let result = ProcessRunner.run(tool, ["-u", udid, "validate"], timeout: 15)
        let detail = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let success = result.exitCode == 0 && detail.localizedCaseInsensitiveContains("SUCCESS")
        return PairingValidation(
            isValid: success,
            detail: detail.isEmpty ? "Pairing validation exited with code \(result.exitCode)." : detail
        )
    }
}
