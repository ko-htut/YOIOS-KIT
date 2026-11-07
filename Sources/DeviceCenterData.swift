import CryptoKit
import Foundation

enum DeviceFactGroup: String, CaseIterable, Codable {
    case connection = "Connection"
    case identity = "Identity"
    case software = "Software"
    case cellular = "Cellular & Network"
    case battery = "Battery & Power"
    case storage = "Storage"
    case security = "Activation & Management"
    case tooling = "Mac Tools"
    case limitations = "Not Verifiable Here"
}

enum DeviceFactStatus: String, Codable {
    case verified
    case reported
    case ready
    case warning
    case unavailable

    var title: String {
        switch self {
        case .verified: return "Verified"
        case .reported: return "Reported"
        case .ready: return "Ready"
        case .warning: return "Caution"
        case .unavailable: return "Unavailable"
        }
    }
}

enum DeviceFactSensitivity: String, Codable {
    case none
    case identifier
    case personal
}

struct DeviceFact: Identifiable, Equatable, Codable {
    let id: String
    let group: DeviceFactGroup
    let label: String
    let value: String
    let status: DeviceFactStatus
    let source: String
    let explanation: String
    let sensitivity: DeviceFactSensitivity

    func displayValue(revealSensitive: Bool) -> String {
        guard !revealSensitive else { return value }
        switch sensitivity {
        case .none:
            return value
        case .identifier:
            return DeviceCenterPrivacy.maskIdentifier(value)
        case .personal:
            return "Hidden — reveal to view"
        }
    }
}

struct DeviceCenterSnapshot: Equatable {
    let capturedAt: Date
    let mode: DeviceMode
    let targetECID: String?
    let targetUDID: String?
    let facts: [DeviceFact]
    let batteryPercent: Int?
    let isCharging: Bool?
    let totalStorageBytes: Int64?
    let availableStorageBytes: Int64?
    let notes: [String]

    static let empty = DeviceCenterSnapshot(
        capturedAt: Date(timeIntervalSince1970: 0),
        mode: .notDetected,
        targetECID: nil,
        targetUDID: nil,
        facts: [],
        batteryPercent: nil,
        isCharging: nil,
        totalStorageBytes: nil,
        availableStorageBytes: nil,
        notes: []
    )

    func facts(in group: DeviceFactGroup) -> [DeviceFact] {
        facts.filter { $0.group == group }
    }

    func fact(_ id: String) -> DeviceFact? {
        facts.first { $0.id == id }
    }

    var hasLiveNormalDetails: Bool {
        mode == .normal && facts.contains { $0.source.contains("ideviceinfo") || $0.source.contains("cfgutil") }
    }

    var pairingValidated: Bool {
        fact("pairing")?.value == "Validated"
    }
}

enum DeviceCenterPrivacy {
    static func maskIdentifier(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 6 else { return "••••••" }
        let suffixLength = min(6, max(4, trimmed.count / 4))
        return "••••••" + trimmed.suffix(suffixLength)
    }

    static func reportToken(ecid: String?, capturedAt: Date) -> String {
        let seed = (DeviceDetector.normalizeECID(ecid) ?? "no-ecid") + "|" + String(capturedAt.timeIntervalSince1970)
        let digest = SHA256.hash(data: Data(seed.utf8))
        return "device-" + digest.prefix(6).map { String(format: "%02x", $0) }.joined()
    }

    static func redactOperationalText(
        _ value: String,
        ecids: [String],
        udids: [String],
        facts: [DeviceFact],
        localPaths: [String]
    ) -> String {
        var output = value
        for ecid in Set(ecids) {
            guard let canonical = DeviceDetector.normalizeECID(ecid),
                  let numeric = UInt64(canonical, radix: 16) else { continue }
            let replacement = maskIdentifier(ecid)
            let aliases = [
                ecid,
                canonical,
                "0x" + canonical,
                "0X" + canonical.uppercased(),
                String(numeric, radix: 10)
            ].sorted { $0.count > $1.count }
            for alias in aliases where alias.count >= 6 {
                output = output.replacingOccurrences(of: alias, with: replacement, options: [.caseInsensitive])
            }
        }
        for udid in Set(udids) where udid.count >= 6 {
            output = output.replacingOccurrences(of: udid, with: maskIdentifier(udid), options: [.caseInsensitive])
        }
        for fact in facts where fact.sensitivity != .none && fact.value.count >= 4 {
            let replacement = fact.sensitivity == .personal
                ? "[personal value redacted]"
                : maskIdentifier(fact.value)
            output = output.replacingOccurrences(of: fact.value, with: replacement, options: [.caseInsensitive])
        }
        for path in Set(localPaths.filter { !$0.isEmpty }).sorted(by: { $0.count > $1.count }) {
            output = output.replacingOccurrences(of: path, with: "[local path redacted]")
        }
        return output
    }
}

enum DeviceCenterReportBuilder {
    static func redactedText(for snapshot: DeviceCenterSnapshot) -> String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "YIOS-KIT Device Center — redacted support report",
            "Captured: \(formatter.string(from: snapshot.capturedAt))",
            "Target token: \(DeviceCenterPrivacy.reportToken(ecid: snapshot.targetECID, capturedAt: snapshot.capturedAt))",
            "Mode: \(snapshot.mode.title)",
            "",
            "This report omits or masks linkable identifiers and does not include app lists, crash contents, syslog, screenshots, backups, account data, or Mac paths."
        ]

        for group in DeviceFactGroup.allCases {
            let records = snapshot.facts(in: group)
            guard !records.isEmpty else { continue }
            lines.append("")
            lines.append("[\(group.rawValue)]")
            for fact in records {
                let value: String
                switch fact.sensitivity {
                case .none: value = fact.value
                case .identifier: value = DeviceCenterPrivacy.maskIdentifier(fact.value)
                case .personal: value = "[redacted]"
                }
                lines.append("\(fact.label): \(value) | \(fact.status.title) | Source: \(fact.source)")
            }
        }

        if !snapshot.notes.isEmpty {
            lines.append("")
            lines.append("[Collection notes]")
            snapshot.notes.forEach { lines.append("- \($0)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func redactedSummary(for snapshot: DeviceCenterSnapshot) -> String {
        let product = snapshot.fact("productType")?.value ?? "Unknown iPhone"
        let version = snapshot.fact("productVersion")?.value ?? "iOS unavailable"
        let build = snapshot.fact("buildVersion")?.value
        let os = build.map { "\(version) (\($0))" } ?? version
        let ecid = DeviceCenterPrivacy.maskIdentifier(snapshot.targetECID ?? "Unavailable")
        return "\(product) • \(os) • \(snapshot.mode.title) • ECID \(ecid)"
    }
}

private struct DeviceFactAccumulator {
    private var order: [String] = []
    private var records: [String: DeviceFact] = [:]

    init(_ initial: [DeviceFact] = []) {
        initial.forEach { upsert($0) }
    }

    mutating func upsert(_ fact: DeviceFact) {
        if records[fact.id] == nil { order.append(fact.id) }
        records[fact.id] = fact
    }

    var facts: [DeviceFact] { order.compactMap { records[$0] } }
}

struct ConfiguratorDetails {
    let values: [String: Any]
    let propertyErrors: [String: String]
}

enum DeviceCenterParser {
    static func plistDictionary(_ data: Data) -> [String: Any] {
        guard !data.isEmpty,
              let value = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dictionary = value as? [String: Any] else { return [:] }
        return dictionary
    }

    static func configuratorDetails(_ text: String, expectedECID: String) -> ConfiguratorDetails {
        guard let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (root["Type"] as? String)?.caseInsensitiveCompare("CommandOutput") == .orderedSame,
              (root["Command"] as? String)?.caseInsensitiveCompare("get") == .orderedSame,
              let output = root["Output"] as? [String: Any] else {
            return ConfiguratorDetails(values: [:], propertyErrors: [:])
        }

        let expected = DeviceDetector.normalizeECID(expectedECID)
        guard let devices = root["Devices"] as? [String],
              devices.contains(where: { DeviceDetector.normalizeECID($0) == expected }) else {
            return ConfiguratorDetails(values: [:], propertyErrors: [:])
        }
        var values: [String: Any] = [:]
        for (key, raw) in output where key != "Errors" {
            guard DeviceDetector.normalizeECID(key) == expected,
                  let dictionary = raw as? [String: Any] else { continue }
            values = dictionary
            break
        }
        if let returnedECID = values["ECID"],
           DeviceDetector.normalizeECID(DeviceCenterParser.string(returnedECID)) != expected {
            values = [:]
        }

        var parsedErrors: [String: String] = [:]
        if let allErrors = output["Errors"] as? [String: Any] {
            for (key, raw) in allErrors where DeviceDetector.normalizeECID(key) == expected {
                guard let dictionary = raw as? [String: Any] else { continue }
                for (property, detail) in dictionary {
                    parsedErrors[property] = String(describing: detail)
                }
            }
        }
        return ConfiguratorDetails(values: values, propertyErrors: parsedErrors)
    }

    static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let value = value as? NSNumber {
            if String(cString: value.objCType) == "c" {
                return value.boolValue ? "Yes" : "No"
            }
            return value.stringValue
        }
        return nil
    }

    static func bool(_ value: Any?) -> Bool? {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber {
            guard value.intValue == 0 || value.intValue == 1 else { return nil }
            return value.boolValue
        }
        if let value = value as? String {
            switch value.lowercased() {
            case "yes", "true", "1": return true
            case "no", "false", "0": return false
            default: return nil
            }
        }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? NSNumber { return value.int64Value }
        if let value = value as? String { return Int64(value) }
        return nil
    }

    static func hexadecimal(_ value: Any?) -> String? {
        if let value = value as? NSNumber {
            return String(format: "0x%llX", value.uint64Value)
        }
        guard let text = string(value) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            guard let number = UInt64(trimmed.dropFirst(2), radix: 16) else { return nil }
            return String(format: "0x%llX", number)
        }
        if let decimal = UInt64(trimmed, radix: 10) {
            return String(format: "0x%llX", decimal)
        }
        if let hexadecimal = UInt64(trimmed, radix: 16) {
            return String(format: "0x%llX", hexadecimal)
        }
        return nil
    }

    static func validBatteryPercent(_ value: Int64?) -> Int? {
        guard let value, (0...100).contains(value) else { return nil }
        return Int(value)
    }

    static func coherentStorage(total: Int64?, available: Int64?) -> (total: Int64, available: Int64?)? {
        guard let total, total > 0 else { return nil }
        guard let available else { return (total, nil) }
        guard available >= 0, available <= total else { return (total, nil) }
        return (total, available)
    }
}

enum DeviceCenterCollector {
    static let configuratorProperties = [
        "name", "deviceClass", "deviceType", "ECID", "UDID", "serialNumber",
        "firmwareVersion", "humanReadableProductVersion", "buildVersion",
        "supplementalBuildVersion", "bootedState", "locationID",
        "hasTelephonyCapability", "IMEI", "IMEI2", "batteryCurrentCapacity",
        "ICCID", "ICCID2", "phoneNumber", "phoneNumber2",
        "batteryIsCharging", "totalDiskCapacity", "totalSpaceAvailable",
        "freeDiskSpace", "appDiskUsage", "audioDiskUsage", "booksDiskUsage",
        "documentsDiskUsage", "logsDiskUsage", "otherDiskUsage", "photosDiskUsage",
        "videoDiskUsage", "activationState", "isPaired", "pairingAllowed",
        "passcodeProtected", "isSupervised", "acceptsSupervision",
        "backupWillBeEncrypted", "cloudBackupsAreEnabled"
    ]

    static func baseline(for device: DeviceSnapshot, capturedAt: Date = Date()) -> DeviceCenterSnapshot {
        var facts = DeviceFactAccumulator()
        addBaselineFacts(device, to: &facts)
        addLimitationFacts(to: &facts)
        return DeviceCenterSnapshot(
            capturedAt: capturedAt,
            mode: device.mode,
            targetECID: device.ecid,
            targetUDID: device.udid,
            facts: facts.facts,
            batteryPercent: nil,
            isCharging: nil,
            totalStorageBytes: nil,
            availableStorageBytes: nil,
            notes: baselineNotes(for: device)
        )
    }

    static func postMutationDeviceEvidence(for device: DeviceSnapshot) -> DeviceSnapshot {
        var currentEvidence = device
        currentEvidence.udid = nil
        currentEvidence.deviceName = nil
        currentEvidence.serialNumber = nil
        currentEvidence.productVersion = nil
        currentEvidence.buildVersion = nil
        currentEvidence.activationState = nil
        return currentEvidence
    }

    static func postMutationBaseline(for device: DeviceSnapshot, capturedAt: Date = Date()) -> DeviceCenterSnapshot {
        let currentEvidence = postMutationDeviceEvidence(for: device)
        let base = baseline(for: currentEvidence, capturedAt: capturedAt)
        return DeviceCenterSnapshot(
            capturedAt: base.capturedAt,
            mode: base.mode,
            targetECID: base.targetECID,
            targetUDID: nil,
            facts: base.facts,
            batteryPercent: nil,
            isCharging: nil,
            totalStorageBytes: nil,
            availableStorageBytes: nil,
            notes: base.notes + ["All pre-operation Normal-iOS private fields were discarded. A fresh trusted Scan is required before they can be shown again."]
        )
    }

    static func collect(_ device: DeviceSnapshot, capturedAt: Date = Date()) -> DeviceCenterSnapshot {
        let baseline = baseline(for: device, capturedAt: capturedAt)
        var facts = DeviceFactAccumulator(baseline.facts)
        var notes = baseline.notes
        var batteryPercent: Int?
        var charging: Bool?
        var totalStorage: Int64?
        var availableStorage: Int64?

        guard device.deviceCount == 1,
              device.mode == .normal,
              device.modeVerified,
              let udid = device.udid,
              let ecid = DeviceDetector.canonicalECIDHex(device.ecid) else {
            notes.append("Detailed lockdownd data is available only for one verified Normal-iOS target. Current-mode identity and USB evidence remain current.")
            return DeviceCenterSnapshot(
                capturedAt: capturedAt,
                mode: device.mode,
                targetECID: device.ecid,
                targetUDID: device.udid,
                facts: facts.facts,
                batteryPercent: nil,
                isCharging: nil,
                totalStorageBytes: nil,
                availableStorageBytes: nil,
                notes: notes
            )
        }

        let pairing = PairingProbe.validate(udid: udid)
        facts.upsert(fact(
            "pairing", .security, "Pairing / Trust",
            pairing.isValid ? "Validated" : "Not available",
            pairing.isValid ? .verified : .warning,
            "idevicepair validate",
            pairing.isValid ? "The existing pairing record was validated for this exact UDID." : "Unlock the iPhone, tap Trust, and enter its passcode. No automatic pairing was attempted."
        ))

        var base: [String: Any] = [:]
        var battery: [String: Any] = [:]
        var disk: [String: Any] = [:]
        if let infoTool = ToolPaths.ideviceInfo {
            let baseArguments = pairing.isValid ? ["-u", udid, "-x"] : ["-u", udid, "-s", "-x"]
            let baseResult = ProcessRunner.run(infoTool, baseArguments, timeout: 12)
            if baseResult.exitCode == 0 {
                base = DeviceCenterParser.plistDictionary(baseResult.stdoutData)
            } else {
                notes.append(pairing.isValid
                    ? "The trusted ideviceinfo identity query did not return data."
                    : "Only the non-pairing identity probe was attempted because Trust was not validated.")
            }
            if pairing.isValid {
                let batteryResult = ProcessRunner.run(
                    infoTool,
                    ["-u", udid, "-q", "com.apple.mobile.battery", "-x"],
                    timeout: 10
                )
                if batteryResult.exitCode == 0 {
                    battery = DeviceCenterParser.plistDictionary(batteryResult.stdoutData)
                }
                let diskResult = ProcessRunner.run(
                    infoTool,
                    ["-u", udid, "-q", "com.apple.disk_usage", "-x"],
                    timeout: 10
                )
                if diskResult.exitCode == 0 {
                    disk = DeviceCenterParser.plistDictionary(diskResult.stdoutData)
                }
            }
        } else {
            notes.append("libimobiledevice is not installed, so trusted identity, battery, and storage domains were not queried.")
        }

        guard pairing.isValid else {
            notes.append("Trust was not validated. No Configurator, battery, storage, cellular, or other private detail query was run.")
            return DeviceCenterSnapshot(
                capturedAt: capturedAt,
                mode: device.mode,
                targetECID: device.ecid,
                targetUDID: device.udid,
                facts: facts.facts,
                batteryPercent: nil,
                isCharging: nil,
                totalStorageBytes: nil,
                availableStorageBytes: nil,
                notes: notes
            )
        }

        var cfg = ConfiguratorDetails(values: [:], propertyErrors: [:])
        if ToolPaths.hasConfigurator {
            let result = ProcessRunner.run(
                ToolPaths.cfgutil,
                ["--ecid", ecid, "--format", "JSON", "--timeout", "10", "get"] + configuratorProperties,
                timeout: 25
            )
            // cfgutil can return useful values together with per-property errors
            // and a non-zero exit code. Parse the exact ECID record regardless.
            cfg = DeviceCenterParser.configuratorDetails(result.stdout, expectedECID: ecid)
            if cfg.values.isEmpty {
                notes.append("Apple Configurator did not return detailed properties for the exact ECID.")
            }
        }

        addNormalIdentityFacts(base: base, cfg: cfg.values, to: &facts)
        addNormalSoftwareFacts(base: base, cfg: cfg.values, to: &facts)
        addCellularAndNetworkFacts(base: base, cfg: cfg.values, to: &facts)
        addSecurityFacts(base: base, cfg: cfg.values, to: &facts)

        let percent = firstInt64([cfg.values["batteryCurrentCapacity"], battery["BatteryCurrentCapacity"]])
        if let validPercent = DeviceCenterParser.validBatteryPercent(percent) {
            batteryPercent = validPercent
            facts.upsert(fact(
                "batteryPercent", .battery, "Current charge", "\(validPercent)%", .reported,
                cfg.values["batteryCurrentCapacity"] != nil ? "Apple Configurator / cfgutil" : "lockdownd / com.apple.mobile.battery",
                "A current device-reported charge level; this is not Battery Health."
            ))
        }
        charging = firstBool([cfg.values["batteryIsCharging"], battery["BatteryIsCharging"]])
        if let charging {
            facts.upsert(fact(
                "batteryCharging", .battery, "Charging", charging ? "Yes" : "No", .reported,
                cfg.values["batteryIsCharging"] != nil ? "Apple Configurator / cfgutil" : "lockdownd / com.apple.mobile.battery",
                "Current charging state reported by the device."
            ))
        }
        addOptionalBool("externalPower", label: "External power connected", value: battery["ExternalConnected"], group: .battery, source: "lockdownd / com.apple.mobile.battery", to: &facts)
        addOptionalBool("fullyCharged", label: "Fully charged", value: battery["FullyCharged"], group: .battery, source: "lockdownd / com.apple.mobile.battery", to: &facts)

        totalStorage = firstInt64([
            cfg.values["totalDiskCapacity"], disk["TotalDiskCapacity"],
            disk["TotalDataCapacity"]
        ])
        availableStorage = firstInt64([
            cfg.values["freeDiskSpace"], cfg.values["totalSpaceAvailable"],
            disk["AmountDataAvailable"], disk["AmountDataRestoreAvailable"]
        ])
        let reportedAvailableStorage = availableStorage
        if let validated = DeviceCenterParser.coherentStorage(total: totalStorage, available: availableStorage) {
            totalStorage = validated.total
            availableStorage = validated.available
            facts.upsert(fact(
                "storageTotal", .storage, "Total capacity", formatBytes(validated.total), .reported,
                cfg.values["totalDiskCapacity"] != nil ? "Apple Configurator / cfgutil" : "lockdownd / com.apple.disk_usage",
                "Approximate device-reported capacity."
            ))
            if let availableStorage = validated.available {
                facts.upsert(fact(
                    "storageAvailable", .storage, "Available", formatBytes(availableStorage), .reported,
                    cfg.values["freeDiskSpace"] != nil || cfg.values["totalSpaceAvailable"] != nil
                        ? "Apple Configurator / cfgutil" : "lockdownd / com.apple.disk_usage",
                    "Approximate free or available space reported by the device."
                ))
                facts.upsert(fact(
                    "storageUsed", .storage, "Used", formatBytes(validated.total - availableStorage), .reported,
                    "Calculated from reported total and available bytes",
                    "Approximate value; iCloud and purgeable storage can make categories differ."
                ))
            } else if reportedAvailableStorage != nil {
                notes.append("An incoherent available-storage value was rejected instead of being displayed.")
                availableStorage = nil
            }
        } else {
            totalStorage = nil
            availableStorage = nil
        }
        addStorageCategories(cfg.values, to: &facts)

        if !cfg.propertyErrors.isEmpty {
            let missing = cfg.propertyErrors.keys.sorted().joined(separator: ", ")
            notes.append("Configurator did not expose these optional properties: \(missing). Missing values do not prove the feature or SIM is absent.")
        }

        return DeviceCenterSnapshot(
            capturedAt: capturedAt,
            mode: device.mode,
            targetECID: device.ecid,
            targetUDID: device.udid,
            facts: facts.facts,
            batteryPercent: batteryPercent,
            isCharging: charging,
            totalStorageBytes: totalStorage,
            availableStorageBytes: availableStorage,
            notes: notes
        )
    }

    private static func addBaselineFacts(_ device: DeviceSnapshot, to facts: inout DeviceFactAccumulator) {
        let protocolStatus: DeviceFactStatus = device.modeVerified ? .verified : (device.deviceCount == 0 ? .unavailable : .warning)
        facts.upsert(fact("mode", .connection, "Current mode", device.mode.title, protocolStatus, "IORegistry + mode classifier", "The current USB/iOS state, not a visual guess."))
        let protocolSource: String
        switch device.mode {
        case .normal where device.modeVerified:
            protocolSource = "lockdownd + IORegistry"
        case .recovery where device.modeVerified, .dfu where device.modeVerified:
            protocolSource = "libirecovery + IORegistry"
        case .restoreOS:
            protocolSource = "IORegistry (RestoreOS USB identity)"
        default:
            protocolSource = "IORegistry"
        }
        facts.upsert(fact(
            "protocol", .connection, "Protocol evidence",
            device.deviceCount == 0 ? "No device" : (device.modeVerified ? "Verified" : "USB evidence only"),
            protocolStatus,
            protocolSource,
            "Write actions require protocol verification, not only a USB product ID."
        ))
        if let value = device.productType { facts.upsert(fact("productType", .identity, "Product type", value, device.supportedDeviceModel != nil ? .verified : .reported, "Apple device service", "Apple hardware product identifier.")) }
        if let value = device.hardwareModel { facts.upsert(fact("hardwareModel", .identity, "Hardware model", value, .reported, "Apple device service", "Board configuration identifier; not proof of original parts.")) }
        if let value = device.deviceName { facts.upsert(fact("deviceName", .identity, "Device name", value, .reported, "Apple device service", "User-assigned device name.", .personal)) }
        if let value = device.marketingName { facts.upsert(fact("marketingName", .identity, "Model name", value, .reported, "libirecovery", "Hardware marketing name returned in Recovery/DFU; not a user-assigned device name.")) }
        if let value = device.serialNumber { facts.upsert(fact("serialNumber", .identity, "Serial number", value, .reported, device.mode == .recovery || device.mode == .dfu ? "libirecovery" : "lockdownd", "Linkable hardware identifier.", .identifier)) }
        if let value = device.chipID { facts.upsert(fact("chipID", .identity, "Chip ID (CPID)", value, .reported, device.mode == .recovery || device.mode == .dfu ? "libirecovery" : "lockdownd", "SoC identity fact; not a health verdict.")) }
        if let value = device.boardID { facts.upsert(fact("boardID", .identity, "Board ID (BDID)", value, .reported, device.mode == .recovery || device.mode == .dfu ? "libirecovery" : "lockdownd", "Board configuration identity fact; not a motherboard test.")) }
        if let value = device.productVersion { facts.upsert(fact("productVersion", .software, "iOS version", value, .reported, "lockdownd", "Version reported by the device.")) }
        if let value = device.buildVersion { facts.upsert(fact("buildVersion", .software, "Build", value, .reported, "lockdownd", "Apple build identifier.")) }
        if let value = device.activationState { facts.upsert(fact("activationState", .security, "Activation state", value, .reported, "Apple device service", "Device-reported activation state; this does not reveal Find My or Activation Lock.")) }
        if let value = device.ecid { facts.upsert(fact("ecid", .identity, "ECID", value, .verified, "IORegistry / Apple device service", "Exact hardware target identifier used by safety checks.", .identifier)) }
        if let value = device.udid { facts.upsert(fact("udid", .identity, "UDID", value, .reported, "lockdownd / Apple device service", "Linkable device identifier.", .identifier)) }
        if let pid = device.usbPID { facts.upsert(fact("usbPID", .connection, "USB product ID", String(format: "0x%04X", pid), .reported, "IORegistry", "USB enumeration evidence for the current mode.")) }
        if let location = device.locationID { facts.upsert(fact("usbLocation", .connection, "USB location", String(format: "0x%08X", location), .reported, "IORegistry", "Mac USB-port location used to detect a target swap.")) }
        if let speed = device.usbLinkSpeed, speed > 0 { facts.upsert(fact("usbLink", .connection, "USB link", formatLinkSpeed(speed), .reported, "IORegistry", "Negotiated USB link speed, not transfer throughput.")) }
        if let allocation = device.usbPowerSinkAllocation { facts.upsert(fact("usbPowerAllocation", .connection, "USB power allocation (raw)", String(allocation), .reported, "IORegistry", "Raw capability/allocation value; not measured charging current or watts.")) }

        let supportedModel = device.supportedDeviceModel
        let productMatches = supportedModel?.productType.caseInsensitiveCompare(device.productType ?? "") == .orderedSame
        let hardwareMatches = supportedModel?.hardwareModel.caseInsensitiveCompare(device.hardwareModel ?? "") == .orderedSame
        let identityValue: String
        let identitySource: String
        if let supportedModel, productMatches && hardwareMatches {
            let tuple = device.mode == .recovery || device.mode == .dfu
                ? " • CPID/BDID \(device.recoveryIdentityQueryVerified ? "verified" : "not fully verified")"
                : ""
            identityValue = "\(supportedModel.productType) + \(supportedModel.hardwareModel) agree\(tuple)"
            identitySource = device.mode == .recovery || device.mode == .dfu
                ? "Targeted libirecovery identity query"
                : "Product type + hardware model"
        } else if let supportedModel, productMatches {
            identityValue = "\(supportedModel.productType) reported; hardware model not confirmed"
            identitySource = "Apple product identifier"
        } else if let supportedModel, hardwareMatches {
            identityValue = "\(supportedModel.hardwareModel) reported; product type not confirmed"
            identitySource = "Apple hardware-model identifier"
        } else if device.identityConflict {
            identityValue = "Conflicting identity evidence — writes blocked"
            identitySource = "Cross-source identity check"
        } else {
            identityValue = "Not confirmed"
            identitySource = "Available identity evidence"
        }
        facts.upsert(fact(
            "supportedIdentity", .connection, "Supported recovery identity",
            identityValue,
            device.hasVerifiedSupportedDeviceIdentity ? .verified : (supportedModel != nil ? .reported : .warning),
            identitySource,
            "Identity verification does not test individual components. Conflicting identifiers fail closed."
        ))
        let doctor = DependencyDoctor.inspect(resolver: ToolchainRuntime.resolver)
        if let configurator = doctor.component(.appleConfigurator) {
            let value = configurator.health == .ready
                ? ["Ready", configurator.version.map { "v\($0)" }].compactMap { $0 }.joined(separator: " • ")
                : "Not installed — advanced Apple operations unavailable"
            facts.upsert(fact(
                "configuratorReady", .tooling, "Apple Configurator", value,
                configurator.health == .ready ? .ready : .warning,
                configurator.sourceSummary,
                "Optional for inspection; required for Apple Revive, Restore, and Factory Reset."
            ))
        }
        if let mobile = doctor.component(.libimobiledevice) {
            let value = [mobile.health == .ready ? "Ready" : "Incomplete", mobile.sourceSummary, mobile.version.map { "v\($0)" }]
                .compactMap { $0 }
                .joined(separator: " • ")
            facts.upsert(fact(
                "mobileToolsReady", .tooling, "libimobiledevice tools", value,
                mobile.health == .ready ? .ready : .warning,
                "Dependency Doctor",
                "Built-in tools are preferred; Homebrew is only an optional fallback."
            ))
        }
        if let recovery = doctor.component(.libirecovery) {
            let value = [recovery.health == .ready ? "Ready" : "Missing", recovery.sourceSummary, recovery.version.map { "v\($0)" }]
                .compactMap { $0 }
                .joined(separator: " • ")
            facts.upsert(fact(
                "recoveryToolReady", .tooling, "libirecovery", value,
                recovery.health == .ready ? .ready : .warning,
                "Dependency Doctor",
                "Provides protocol verification for Recovery and DFU modes."
            ))
        }
    }

    private static func addNormalIdentityFacts(base: [String: Any], cfg: [String: Any], to facts: inout DeviceFactAccumulator) {
        addString("deviceName", label: "Device name", values: [cfg["name"], base["DeviceName"]], group: .identity, source: source(cfg["name"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "User-assigned device name.", sensitivity: .personal, to: &facts)
        addString("serialNumber", label: "Serial number", values: [cfg["serialNumber"], base["SerialNumber"]], group: .identity, source: source(cfg["serialNumber"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Linkable hardware identifier.", sensitivity: .identifier, to: &facts)
        addString("modelNumber", label: "Model number", values: [base["ModelNumber"]], group: .identity, source: "lockdownd / ideviceinfo", explanation: "Device-reported model number.", to: &facts)
        addString("regionInfo", label: "Region info", values: [base["RegionInfo"]], group: .identity, source: "lockdownd / ideviceinfo", explanation: "Device-reported sales-region code.", to: &facts)
        addString("cpuArchitecture", label: "CPU architecture", values: [base["CPUArchitecture"]], group: .identity, source: "lockdownd / ideviceinfo", explanation: "Runtime architecture reported by iOS.", to: &facts)
        addHexString("chipID", label: "Chip ID (CPID)", value: base["ChipID"], group: .identity, source: "lockdownd / ideviceinfo", explanation: "SoC identity fact; not a health verdict.", to: &facts)
        addHexString("boardID", label: "Board ID (BDID)", value: base["BoardId"], group: .identity, source: "lockdownd / ideviceinfo", explanation: "Board configuration identity fact; not a motherboard test.", to: &facts)
        addString("deviceColorCode", label: "Device color code", values: [base["DeviceColor"]], group: .identity, source: "lockdownd / ideviceinfo", explanation: "Raw Apple color code; the app does not guess a marketing color name.", to: &facts)
    }

    private static func addNormalSoftwareFacts(base: [String: Any], cfg: [String: Any], to facts: inout DeviceFactAccumulator) {
        let cfgProductVersion = DeviceCenterParser.string(cfg["firmwareVersion"])
            ?? DeviceCenterParser.string(cfg["humanReadableProductVersion"])
        addString("productVersion", label: "iOS version", values: [cfgProductVersion, base["ProductVersion"]], group: .software, source: cfgProductVersion == nil ? "lockdownd / ideviceinfo" : "Apple Configurator / cfgutil", explanation: "Installed iOS version reported by the device.", to: &facts)
        addString("buildVersion", label: "Build", values: [cfg["buildVersion"], base["BuildVersion"]], group: .software, source: source(cfg["buildVersion"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Installed Apple build identifier.", to: &facts)
        addString("supplementalBuild", label: "Supplemental build", values: [cfg["supplementalBuildVersion"]], group: .software, source: "Apple Configurator / cfgutil", explanation: "Optional supplemental build identifier.", to: &facts)
        addString("basebandVersion", label: "Baseband version", values: [base["BasebandVersion"]], group: .software, source: "lockdownd / ideviceinfo", explanation: "Modem firmware version; not a baseband-health test.", to: &facts)
        addString("bootedState", label: "Boot state", values: [cfg["bootedState"]], group: .software, source: "Apple Configurator / cfgutil", explanation: "Configurator-reported operating state.", to: &facts)
    }

    private static func addCellularAndNetworkFacts(base: [String: Any], cfg: [String: Any], to facts: inout DeviceFactAccumulator) {
        addOptionalBool("telephony", label: "Telephony capable", value: cfg["hasTelephonyCapability"] ?? base["TelephonyCapability"], group: .cellular, source: cfg["hasTelephonyCapability"] != nil ? "Apple Configurator / cfgutil" : "lockdownd / ideviceinfo", to: &facts)
        addString("imei1", label: "IMEI 1", values: [cfg["IMEI"], base["InternationalMobileEquipmentIdentity"]], group: .cellular, source: source(cfg["IMEI"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Linkable cellular identifier.", sensitivity: .identifier, to: &facts)
        addString("imei2", label: "IMEI 2", values: [cfg["IMEI2"], base["InternationalMobileEquipmentIdentity2"]], group: .cellular, source: source(cfg["IMEI2"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Linkable secondary cellular identifier when exposed.", sensitivity: .identifier, to: &facts)
        addString("meid", label: "MEID", values: [base["MobileEquipmentIdentifier"]], group: .cellular, source: "lockdownd / ideviceinfo", explanation: "Linkable cellular identifier when exposed.", sensitivity: .identifier, to: &facts)
        addString("iccid1", label: "ICCID 1", values: [cfg["ICCID"], base["IntegratedCircuitCardIdentity"]], group: .cellular, source: source(cfg["ICCID"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Sensitive SIM identifier. Missing does not mean no SIM.", sensitivity: .identifier, to: &facts)
        addString("iccid2", label: "ICCID 2", values: [cfg["ICCID2"]], group: .cellular, source: "Apple Configurator / cfgutil", explanation: "Sensitive secondary SIM identifier. Missing does not mean no eSIM.", sensitivity: .identifier, to: &facts)
        addString("phoneNumber", label: "Phone number", values: [cfg["phoneNumber"], base["PhoneNumber"]], group: .cellular, source: source(cfg["phoneNumber"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Personal number when the device exposes it.", sensitivity: .personal, to: &facts)
        addString("wifiAddress", label: "Wi-Fi address", values: [base["WiFiAddress"]], group: .cellular, source: "lockdownd / ideviceinfo", explanation: "Linkable network hardware address.", sensitivity: .identifier, to: &facts)
        addString("bluetoothAddress", label: "Bluetooth address", values: [base["BluetoothAddress"]], group: .cellular, source: "lockdownd / ideviceinfo", explanation: "Linkable network hardware address.", sensitivity: .identifier, to: &facts)
    }

    private static func addSecurityFacts(base: [String: Any], cfg: [String: Any], to facts: inout DeviceFactAccumulator) {
        addString("activationState", label: "Activation state", values: [cfg["activationState"], base["ActivationState"]], group: .security, source: source(cfg["activationState"], cfgName: "Apple Configurator / cfgutil", fallback: "lockdownd / ideviceinfo"), explanation: "Device-reported activation only; not Find My or Activation Lock status.", to: &facts)
        addOptionalBool("paired", label: "Paired with this Mac", value: cfg["isPaired"], group: .security, source: "Apple Configurator / cfgutil", to: &facts)
        addOptionalBool("passcodeProtected", label: "Passcode protection reported", value: cfg["passcodeProtected"] ?? base["PasswordProtected"], group: .security, source: cfg["passcodeProtected"] != nil ? "Apple Configurator / cfgutil" : "lockdownd / ideviceinfo", to: &facts)
        addOptionalBool("supervised", label: "Supervised", value: cfg["isSupervised"], group: .security, source: "Apple Configurator / cfgutil", to: &facts)
        addOptionalBool("backupEncrypted", label: "Computer backup encryption", value: cfg["backupWillBeEncrypted"], group: .security, source: "Apple Configurator / cfgutil", to: &facts)
        addOptionalBool("cloudBackup", label: "Cloud backups reported", value: cfg["cloudBackupsAreEnabled"], group: .security, source: "Apple Configurator / cfgutil", to: &facts)
    }

    private static func addLimitationFacts(to facts: inout DeviceFactAccumulator) {
        facts.upsert(fact("findMy", .limitations, "Find My / Activation Lock", "Not verified by this app", .warning, "App limitation", "ActivationState does not prove Find My or Activation Lock is off."))
        facts.upsert(fact("warranty", .limitations, "Warranty / AppleCare", "Unknown — check with Apple", .unavailable, "App limitation", "The app does not send the serial number to a third-party lookup or infer coverage from manufacturing data."))
        facts.upsert(fact("partsHistory", .limitations, "Parts & service history", "Check Settings > General > About", .unavailable, "On-device Apple interface", "Availability varies by model and iOS. This Mac app does not infer original parts or repair history."))
        facts.upsert(fact("componentHealth", .limitations, "Motherboard, display, cameras, Face ID/Touch ID", "Not hardware-tested", .unavailable, "App limitation", "USB communication cannot prove that these components are healthy or original."))
        facts.upsert(fact("batteryHealth", .limitations, "Battery Health / cycle count", "Not available from the supported read-only fields", .unavailable, "App limitation", "Current charge may be shown when reported; the app does not invent Maximum Capacity or a health score."))
        facts.upsert(fact("jailbreak", .limitations, "Jailbreak status", "Not assessed", .unavailable, "App policy", "No exploit, jailbreak, or bypass tool is used."))
    }

    private static func addStorageCategories(_ values: [String: Any], to facts: inout DeviceFactAccumulator) {
        let categories: [(String, String, String)] = [
            ("storageApps", "Apps", "appDiskUsage"),
            ("storagePhotos", "Photos", "photosDiskUsage"),
            ("storageVideo", "Video", "videoDiskUsage"),
            ("storageAudio", "Audio", "audioDiskUsage"),
            ("storageBooks", "Books", "booksDiskUsage"),
            ("storageDocuments", "Documents", "documentsDiskUsage"),
            ("storageLogs", "Logs", "logsDiskUsage"),
            ("storageOther", "Other", "otherDiskUsage")
        ]
        for (id, label, key) in categories {
            guard let bytes = DeviceCenterParser.int64(values[key]), bytes >= 0 else { continue }
            facts.upsert(fact(id, .storage, label, formatBytes(bytes), .reported, "Apple Configurator / cfgutil", "Approximate category reported by iOS; categories may not sum exactly to used storage."))
        }
    }

    private static func addString(
        _ id: String,
        label: String,
        values: [Any?],
        group: DeviceFactGroup,
        source: String,
        explanation: String,
        sensitivity: DeviceFactSensitivity = .none,
        to facts: inout DeviceFactAccumulator
    ) {
        guard let value = values.compactMap(DeviceCenterParser.string).first else { return }
        if sensitivity != .none {
            let placeholder = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["n/a", "na", "none", "null", "(null)", "unknown"].contains(placeholder) { return }
        }
        facts.upsert(fact(id, group, label, value, .reported, source, explanation, sensitivity))
    }

    private static func addHexString(
        _ id: String,
        label: String,
        value: Any?,
        group: DeviceFactGroup,
        source: String,
        explanation: String,
        to facts: inout DeviceFactAccumulator
    ) {
        guard let value = DeviceCenterParser.hexadecimal(value) else { return }
        facts.upsert(fact(id, group, label, value, .reported, source, explanation))
    }

    private static func addOptionalBool(
        _ id: String,
        label: String,
        value: Any?,
        group: DeviceFactGroup,
        source: String,
        to facts: inout DeviceFactAccumulator
    ) {
        guard let value = DeviceCenterParser.bool(value) else { return }
        facts.upsert(fact(id, group, label, value ? "Yes" : "No", .reported, source, "A device-reported state, not an inferred health or ownership claim."))
    }

    private static func firstInt64(_ values: [Any?]) -> Int64? {
        values.compactMap(DeviceCenterParser.int64).first
    }

    private static func firstBool(_ values: [Any?]) -> Bool? {
        values.compactMap(DeviceCenterParser.bool).first
    }

    private static func source(_ preferred: Any?, cfgName: String, fallback: String) -> String {
        preferred == nil ? fallback : cfgName
    }

    private static func fact(
        _ id: String,
        _ group: DeviceFactGroup,
        _ label: String,
        _ value: String,
        _ status: DeviceFactStatus,
        _ source: String,
        _ explanation: String,
        _ sensitivity: DeviceFactSensitivity = .none
    ) -> DeviceFact {
        DeviceFact(
            id: id,
            group: group,
            label: label,
            value: value,
            status: status,
            source: source,
            explanation: explanation,
            sensitivity: sensitivity
        )
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: bytes)
    }

    private static func formatLinkSpeed(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000_000 {
            return String(format: "%.1f Gb/s", Double(bitsPerSecond) / 1_000_000_000)
        }
        return "\(bitsPerSecond / 1_000_000) Mb/s"
    }

    private static func baselineNotes(for device: DeviceSnapshot) -> [String] {
        switch device.mode {
        case .normal:
            return device.modeVerified ? [] : ["Normal iOS communication was not verified; only USB evidence is current."]
        case .recovery, .dfu:
            return ["Normal-iOS private details are intentionally not reused in \(device.mode.title). Recovery identity comes from current USB/libirecovery evidence."]
        case .restoreOS:
            return ["RestoreOS is an intermediate restore environment. Normal-iOS battery, storage, SIM, and account details are unavailable."]
        case .notDetected:
            return ["No connected iPhone was detected."]
        case .multiple:
            return ["Multiple devices are present; no single target detail set is collected."]
        case .usbUnavailable, .unknown:
            return ["Only current USB evidence is available; detailed iOS communication is unavailable."]
        }
    }
}
