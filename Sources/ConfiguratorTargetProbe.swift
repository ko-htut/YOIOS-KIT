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
            pinnedLocation: pin.locationID
        ) else {
            return "The same verified Normal-mode SE2 was not found at the original USB port."
        }
        guard pairing.isValid else {
            return "Pairing/Trust validation failed. Unlock the iPhone, tap Trust, enter its passcode, and scan again. \(pairing.detail)"
        }
        guard DeviceDetector.normalizeECID(info.ecid) == DeviceDetector.normalizeECID(pin.ecid),
              info.udid?.caseInsensitiveCompare(pin.udid) == .orderedSame,
              info.deviceType == "iPhone12,8" else {
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
