import CryptoKit
import Foundation

enum DeviceMode: String, Codable {
    case notDetected
    case normal
    case recovery
    case dfu
    case restoreOS
    case usbUnavailable
    case unknown
    case multiple

    var title: String {
        switch self {
        case .notDetected: return "Not detected"
        case .normal: return "Normal iOS"
        case .recovery: return "Recovery Mode"
        case .dfu: return "DFU Mode"
        case .restoreOS: return "RestoreOS (stuck intermediate)"
        case .usbUnavailable: return "USB detected; iOS communication unavailable"
        case .unknown: return "Unknown Apple USB mode"
        case .multiple: return "Multiple iPhones detected"
        }
    }
}

struct DeviceSnapshot: Equatable {
    var mode: DeviceMode = .notDetected
    var deviceCount: Int = 0
    var usbPID: Int?
    var locationID: Int?
    var ecid: String?
    var udid: String?
    var productType: String?
    var hardwareModel: String?
    var productVersion: String?
    var buildVersion: String?
    var activationState: String?
    var modeVerified: Bool = false
    var deviceName: String?
    var marketingName: String?
    var serialNumber: String?
    var chipID: String?
    var boardID: String?
    var usbLinkSpeed: Int?
    var usbPowerSinkAllocation: Int?
    var usbPowerSinkCapability: Int?

    var isSE2: Bool {
        let productMatch = productType.map { $0 == "iPhone12,8" }
        let hardwareMatch = hardwareModel.map { $0.lowercased() == "d79ap" }
        if let productMatch, let hardwareMatch {
            return productMatch && hardwareMatch
        }
        return productMatch ?? hardwareMatch ?? false
    }

    var pidHex: String {
        guard let usbPID else { return "—" }
        return String(format: "0x%04X", usbPID)
    }

    var displayECID: String { ecid ?? "—" }
    var displayUDID: String { udid ?? "—" }
}

struct PostFactoryResetTracker {
    private(set) var observedTargetTransition = false

    mutating func observe(_ detected: DeviceSnapshot, pinnedECID: String) -> Bool {
        let sameTarget = DeviceDetector.normalizeECID(detected.ecid) ==
            DeviceDetector.normalizeECID(pinnedECID)
        let targetStillOnNormalUSB = sameTarget &&
            detected.deviceCount == 1 &&
            (detected.usbPID == 0x12A8 || detected.usbPID == 0x12A9) &&
            (detected.mode == .normal || detected.mode == .usbUnavailable)

        if !targetStillOnNormalUSB {
            observedTargetTransition = true
            return false
        }
        return observedTargetTransition &&
            DeviceDetector.matchesPostFactoryResetCandidate(detected, pinnedECID: pinnedECID)
    }
}

enum ToolPaths {
    static let cfgutil = "/Applications/Apple Configurator.app/Contents/MacOS/cfgutil"
    static let ioreg = "/usr/sbin/ioreg"
    static let unzip = "/usr/bin/unzip"
    static let ps = "/bin/ps"
    static let caffeinate = "/usr/bin/caffeinate"

    static func firstExisting(_ paths: [String]) -> String? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var ideviceID: String? {
        firstExisting(["/opt/homebrew/bin/idevice_id", "/usr/local/bin/idevice_id"])
    }

    static var ideviceInfo: String? {
        firstExisting(["/opt/homebrew/bin/ideviceinfo", "/usr/local/bin/ideviceinfo"])
    }

    static var enterRecovery: String? {
        firstExisting(["/opt/homebrew/bin/ideviceenterrecovery", "/usr/local/bin/ideviceenterrecovery"])
    }

    static var idevicePair: String? {
        firstExisting(["/opt/homebrew/bin/idevicepair", "/usr/local/bin/idevicepair"])
    }

    static var ideviceDiagnostics: String? {
        firstExisting(["/opt/homebrew/bin/idevicediagnostics", "/usr/local/bin/idevicediagnostics"])
    }

    static var ideviceCrashReport: String? {
        firstExisting(["/opt/homebrew/bin/idevicecrashreport", "/usr/local/bin/idevicecrashreport"])
    }

    static var irecovery: String? {
        firstExisting(["/opt/homebrew/bin/irecovery", "/usr/local/bin/irecovery"])
    }

    static var hasConfigurator: Bool {
        FileManager.default.isExecutableFile(atPath: cfgutil)
    }
}

enum DeviceDetector {
    private static func integer(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }

    private static func string(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func normalizeECID(_ value: String?) -> String? {
        guard var value else { return nil }
        value = value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitlyHex = value.hasPrefix("0x") || value.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdef")) != nil
        value = value.replacingOccurrences(of: "0x", with: "")
        while value.count > 1, value.first == "0" {
            value.removeFirst()
        }
        // ioreg can expose ECID as a 15–20 digit decimal value while
        // libirecovery/cfgutil commonly use hexadecimal. Canonicalize the
        // unambiguous long-decimal form to lower-case hex for comparison.
        if !explicitlyHex,
           value.count >= 15,
           value.allSatisfy({ $0.isNumber }),
           let decimal = UInt64(value, radix: 10) {
            return String(decimal, radix: 16)
        }
        return value.isEmpty ? "0" : value
    }

    static func canonicalECIDHex(_ value: String?) -> String? {
        guard let normalized = normalizeECID(value),
              let number = UInt64(normalized, radix: 16) else { return nil }
        return String(format: "0x%llX", number)
    }

    private static func ecidHex(_ value: Any?) -> String? {
        if let number = value as? NSNumber {
            return String(format: "0x%llX", number.uint64Value)
        }
        guard let text = value as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            guard let parsed = UInt64(trimmed.dropFirst(2), radix: 16) else { return nil }
            return String(format: "0x%llX", parsed)
        }
        if trimmed.rangeOfCharacter(from: CharacterSet(charactersIn: "abcdefABCDEF")) != nil,
           let parsed = UInt64(trimmed, radix: 16) {
            return String(format: "0x%llX", parsed)
        }
        if let parsed = UInt64(trimmed, radix: 10) {
            return String(format: "0x%llX", parsed)
        }
        return nil
    }

    static func parseIOReg(_ output: String) -> DeviceSnapshot {
        let blocks = output.components(separatedBy: "+-o ")
        var devices: [DeviceSnapshot] = []

        for block in blocks where block.contains("\"idVendor\" = 1452") {
            let pid = integer(in: block, pattern: "\\\"idProduct\\\"\\s*=\\s*([0-9]+)")
            let ecidDecimal = string(in: block, pattern: "\\\"UsbAppleDeviceECID\\\"\\s*=\\s*([0-9]+)")
            let serial = string(in: block, pattern: "\\\"(?:kUSBSerialNumberString|USB Serial Number)\\\"\\s*=\\s*\\\"([^\\\"]+)\\\"")
            let serialECID = serial.flatMap {
                string(in: $0, pattern: "(?i)ECID[:=]\\s*(?:0x)?([0-9a-f]+)")
            }
            let location = integer(in: block, pattern: "\\\"locationID\\\"\\s*=\\s*([0-9]+)")
            let linkSpeed = integer(in: block, pattern: "\\\"UsbLinkSpeed\\\"\\s*=\\s*([0-9]+)")
            let powerAllocation = integer(in: block, pattern: "\\\"UsbPowerSinkAllocation\\\"\\s*=\\s*([0-9]+)")
            let powerCapability = integer(in: block, pattern: "\\\"UsbPowerSinkCapability\\\"\\s*=\\s*([0-9]+)")
            let product = string(in: block, pattern: "\\\"kUSBProductString\\\"\\s*=\\s*\\\"([^\\\"]+)\\\"") ?? ""
            let knownPID = [0x1227, 0x1280, 0x1281, 0x1282, 0x1283, 0x12A8, 0x12A9, 0x12AC].contains(pid ?? -1)
            let looksLikeIPhone = product.localizedCaseInsensitiveContains("iPhone") ||
                product.localizedCaseInsensitiveContains("Recovery") || ecidDecimal != nil || knownPID
            guard looksLikeIPhone else { continue }

            let mode: DeviceMode
            switch pid {
            case 0x1227: mode = .dfu
            case 0x1280, 0x1281, 0x1282, 0x1283: mode = .recovery
            case 0x12AC: mode = .restoreOS
            case 0x12A8, 0x12A9: mode = .usbUnavailable
            default: mode = .unknown
            }

            var ecidHex: String?
            if let ecidDecimal, let decimal = UInt64(ecidDecimal) {
                ecidHex = String(format: "0x%llX", decimal)
            } else if let serialECID, let hexadecimal = UInt64(serialECID, radix: 16) {
                ecidHex = String(format: "0x%llX", hexadecimal)
            }
            var snapshot = DeviceSnapshot(
                mode: mode,
                deviceCount: 1,
                usbPID: pid,
                locationID: location,
                ecid: ecidHex,
                udid: nil,
                productType: nil,
                hardwareModel: nil,
                productVersion: nil,
                buildVersion: nil,
                activationState: nil
            )
            snapshot.usbLinkSpeed = linkSpeed
            snapshot.usbPowerSinkAllocation = powerAllocation
            snapshot.usbPowerSinkCapability = powerCapability
            if mode == .normal, let serial, serial.count >= 20 {
                snapshot.udid = serial
            }
            devices.append(snapshot)
        }

        if devices.isEmpty { return DeviceSnapshot(mode: .notDetected) }
        if devices.count > 1 {
            return DeviceSnapshot(mode: .multiple, deviceCount: devices.count)
        }
        return devices[0]
    }

    static func usbOnly() -> DeviceSnapshot {
        let result = ProcessRunner.run(
            ToolPaths.ioreg,
            ["-p", "IOUSB", "-r", "-c", "IOUSBHostDevice", "-l", "-w", "0"],
            timeout: 5
        )
        guard result.exitCode == 0 else { return DeviceSnapshot(mode: .notDetected) }
        return parseIOReg(result.stdout)
    }

    static func stableUSB() -> DeviceSnapshot {
        let first = usbOnly()
        Thread.sleep(forTimeInterval: 0.35)
        let second = usbOnly()
        guard first.mode == second.mode,
              normalizeECID(first.ecid) == normalizeECID(second.ecid),
              first.usbPID == second.usbPID else {
            return DeviceSnapshot(mode: .unknown, deviceCount: max(first.deviceCount, second.deviceCount))
        }
        return second
    }

    static func matchesPinnedTransition(
        _ detected: DeviceSnapshot,
        pinnedECID: String,
        pinnedLocation: Int?
    ) -> Bool {
        guard detected.mode == .recovery || detected.mode == .dfu,
              let detectedECID = detected.ecid,
              normalizeECID(detectedECID) == normalizeECID(pinnedECID) else {
            return false
        }
        if let pinnedLocation {
            return detected.locationID == pinnedLocation
        }
        return true
    }

    static func matchesPinnedNormalTarget(
        _ detected: DeviceSnapshot,
        pinnedECID: String,
        pinnedUDID: String,
        pinnedLocation: Int
    ) -> Bool {
        detected.deviceCount == 1 &&
        detected.mode == .normal &&
        detected.modeVerified &&
        detected.isSE2 &&
        normalizeECID(detected.ecid) == normalizeECID(pinnedECID) &&
        detected.udid?.caseInsensitiveCompare(pinnedUDID) == .orderedSame &&
        detected.locationID == pinnedLocation
    }

    static func matchesPostFactoryResetCandidate(
        _ detected: DeviceSnapshot,
        pinnedECID: String
    ) -> Bool {
        detected.deviceCount == 1 &&
        (detected.usbPID == 0x12A8 || detected.usbPID == 0x12A9) &&
        (detected.mode == .normal || detected.mode == .usbUnavailable) &&
        detected.isSE2 &&
        normalizeECID(detected.ecid) == normalizeECID(pinnedECID)
    }

    static func enriched() -> DeviceSnapshot {
        var snapshot = stableUSB()
        guard snapshot.deviceCount == 1 else { return snapshot }

        // A successful lockdownd query is the strongest proof of Normal iOS.
        // idevice_id alone is intentionally insufficient because RestoreOS can
        // expose a UDID over usbmux while rejecting lockdownd.
        if snapshot.mode == .usbUnavailable,
           let idPath = ToolPaths.ideviceID,
           let infoPath = ToolPaths.ideviceInfo {
            let ids = ProcessRunner.run(idPath, ["-l"], timeout: 6)
            if ids.exitCode == 0 {
                for candidate in ids.stdout.components(separatedBy: .newlines) where !candidate.isEmpty {
                    let info = ProcessRunner.run(infoPath, ["-s", "-u", candidate, "-x"], timeout: 8)
                    guard info.exitCode == 0,
                          let plist = try? PropertyListSerialization.propertyList(from: info.stdoutData, options: [], format: nil),
                          let values = plist as? [String: Any],
                          let productType = values["ProductType"] as? String else { continue }
                    snapshot.mode = .normal
                    snapshot.udid = candidate
                    snapshot.productType = productType
                    snapshot.hardwareModel = values["HardwareModel"] as? String
                    snapshot.productVersion = values["ProductVersion"] as? String
                    snapshot.buildVersion = values["BuildVersion"] as? String
                    snapshot.activationState = values["ActivationState"] as? String
                    snapshot.deviceName = values["DeviceName"] as? String
                    snapshot.serialNumber = values["SerialNumber"] as? String
                    if let chipID = values["ChipID"] as? NSNumber {
                        snapshot.chipID = String(format: "0x%X", chipID.uint64Value)
                    }
                    if let boardID = values["BoardId"] as? NSNumber {
                        snapshot.boardID = String(format: "0x%X", boardID.uint64Value)
                    }
                    snapshot.ecid = ecidHex(values["UniqueChipID"]) ?? snapshot.ecid
                    snapshot.modeVerified = true
                    break
                }
            }
        }

        if ToolPaths.hasConfigurator {
            let listed = ProcessRunner.run(ToolPaths.cfgutil, ["--format", "JSON", "list"], timeout: 10)
            if listed.exitCode == 0,
               let data = listed.stdout.data(using: .utf8),
               let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let output = root["Output"] as? [String: Any] {
                let iPhones = output.filter { _, rawValue in
                    guard let value = rawValue as? [String: Any],
                          let type = value["deviceType"] as? String else { return false }
                    return type.hasPrefix("iPhone")
                }
                if iPhones.count > 1 {
                    return DeviceSnapshot(mode: .multiple, deviceCount: iPhones.count)
                }
                let targetNormalized = normalizeECID(snapshot.ecid)
                for (key, rawValue) in iPhones {
                    let keyMatches = targetNormalized == nil || normalizeECID(key) == targetNormalized
                    guard keyMatches,
                          let value = rawValue as? [String: Any] else { continue }
                    snapshot.ecid = ecidHex(value["ECID"]) ?? ecidHex(key) ?? snapshot.ecid
                    snapshot.productType = value["deviceType"] as? String
                    snapshot.udid = value["UDID"] as? String ?? snapshot.udid
                }
            }
        }

        if snapshot.mode == .normal, snapshot.productType == nil,
           let udid = snapshot.udid, let infoPath = ToolPaths.ideviceInfo {
            let info = ProcessRunner.run(infoPath, ["-u", udid], timeout: 8)
            if info.exitCode == 0 {
                for line in info.stdout.components(separatedBy: .newlines) {
                    let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                    guard pair.count == 2 else { continue }
                    let key = pair[0]
                    let value = pair[1].trimmingCharacters(in: .whitespaces)
                    switch key {
                    case "ProductType": snapshot.productType = value
                    case "HardwareModel": snapshot.hardwareModel = value
                    case "ProductVersion": snapshot.productVersion = value
                    case "BuildVersion": snapshot.buildVersion = value
                    case "ActivationState": snapshot.activationState = value
                    case "DeviceName": snapshot.deviceName = value
                    case "SerialNumber": snapshot.serialNumber = value
                    case "ChipID": snapshot.chipID = value
                    case "BoardId": snapshot.boardID = value
                    default: break
                    }
                }
            }
        }

        if (snapshot.mode == .recovery || snapshot.mode == .dfu),
           let irecovery = ToolPaths.irecovery {
            let targetArguments = snapshot.ecid.map { ["-i", $0] } ?? []
            let modeResult = ProcessRunner.run(irecovery, targetArguments + ["-m"], timeout: 8)
            let modeText = (modeResult.stdout + modeResult.stderr).trimmingCharacters(in: .whitespacesAndNewlines)
            if modeResult.exitCode == 0, modeText == "Recovery Mode" {
                snapshot.mode = .recovery
                snapshot.modeVerified = true
            }
            if modeResult.exitCode == 0, modeText == "DFU Mode" {
                snapshot.mode = .dfu
                snapshot.modeVerified = true
            }
            let query = ProcessRunner.run(irecovery, targetArguments + ["-q"], timeout: 8)
            let combined = query.stdout + "\n" + query.stderr
            for line in combined.components(separatedBy: .newlines) {
                let pair = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                let value = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)
                switch key {
                case "ECID": snapshot.ecid = ecidHex(value) ?? snapshot.ecid
                case "PRODUCT": snapshot.productType = value
                case "MODEL": snapshot.hardwareModel = value
                case "CPID": snapshot.chipID = value
                case "BDID": snapshot.boardID = value
                case "SRNM": snapshot.serialNumber = value
                case "NAME": snapshot.marketingName = value
                default: break
                }
            }
        }
        return snapshot
    }
}

struct IPSWInfo: Equatable {
    let url: URL
    let productVersion: String
    let buildVersion: String
    let compatibleWithSE2: Bool
    let fileSize: UInt64
    let modificationDate: Date
    let sampledSHA256: String

    var title: String { "iOS \(productVersion) (\(buildVersion))" }
}

enum IPSWValidator {
    static func inspect(_ url: URL) -> Result<IPSWInfo, Error> {
        do {
            let before = try fileIdentity(url)
            let manifest = try inspectManifest(url)
            let archive = ProcessRunner.run(ToolPaths.unzip, ["-tqq", url.path], timeout: 600)
            guard archive.exitCode == 0 else {
                throw validationError(
                    12,
                    "The IPSW archive integrity test failed. The file may be partial or corrupt."
                )
            }
            let after = try fileIdentity(url)
            guard before.size == after.size, before.modificationDate == after.modificationDate else {
                throw validationError(13, "The IPSW changed while it was being validated.")
            }
            let fingerprint = try sampledFingerprint(url, fileSize: after.size)
            return .success(IPSWInfo(
                url: url,
                productVersion: manifest.productVersion,
                buildVersion: manifest.buildVersion,
                compatibleWithSE2: manifest.compatible,
                fileSize: after.size,
                modificationDate: after.modificationDate,
                sampledSHA256: fingerprint
            ))
        } catch {
            return .failure(error)
        }
    }

    static func revalidatePinned(_ info: IPSWInfo) -> Result<Void, Error> {
        do {
            let identity = try fileIdentity(info.url)
            guard identity.size == info.fileSize,
                  identity.modificationDate == info.modificationDate else {
                throw validationError(14, "The selected IPSW was modified or replaced after confirmation.")
            }
            let fingerprint = try sampledFingerprint(info.url, fileSize: identity.size)
            guard fingerprint == info.sampledSHA256 else {
                throw validationError(15, "The selected IPSW fingerprint changed after validation.")
            }
            let manifest = try inspectManifest(info.url)
            guard manifest.compatible,
                  manifest.productVersion == info.productVersion,
                  manifest.buildVersion == info.buildVersion else {
                throw validationError(16, "The selected IPSW BuildManifest no longer matches the confirmed firmware.")
            }
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    private static func inspectManifest(_ url: URL) throws -> (
        productVersion: String,
        buildVersion: String,
        compatible: Bool
    ) {
        let result = ProcessRunner.run(ToolPaths.unzip, ["-p", url.path, "BuildManifest.plist"], timeout: 20)
        guard result.exitCode == 0, !result.stdoutData.isEmpty else {
            throw validationError(10, "BuildManifest.plist could not be read from this IPSW.")
        }
        let plist = try PropertyListSerialization.propertyList(from: result.stdoutData, options: [], format: nil)
        guard let dict = plist as? [String: Any] else {
            throw validationError(11, "The IPSW BuildManifest is invalid.")
        }
        let productVersion = dict["ProductVersion"] as? String ?? "Unknown"
        let buildVersion = dict["ProductBuildVersion"] as? String ?? "Unknown"
        let supported = dict["SupportedProductTypes"] as? [String] ?? []
        var compatible = supported.contains("iPhone12,8")
        if !compatible, let identities = dict["BuildIdentities"] as? [[String: Any]] {
            compatible = identities.contains { identity in
                guard let info = identity["Info"] as? [String: Any],
                      let deviceClass = info["DeviceClass"] as? String else { return false }
                return deviceClass.lowercased() == "d79ap"
            }
        }
        return (productVersion, buildVersion, compatible)
    }

    private static func fileIdentity(_ url: URL) throws -> (size: UInt64, modificationDate: Date) {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes[.size] as? NSNumber,
              let modificationDate = attributes[.modificationDate] as? Date else {
            throw validationError(17, "The IPSW file identity could not be read.")
        }
        return (size.uint64Value, modificationDate)
    }

    private static func sampledFingerprint(_ url: URL, fileSize: UInt64) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let sampleSize: UInt64 = 1_048_576
        let middle = fileSize > sampleSize ? (fileSize / 2) - min(fileSize / 2, sampleSize / 2) : 0
        let end = fileSize > sampleSize ? fileSize - sampleSize : 0
        let offsets = Array(Set([UInt64(0), middle, end])).sorted()
        var hasher = SHA256()
        hasher.update(data: Data("size:\(fileSize)".utf8))
        for offset in offsets {
            try handle.seek(toOffset: offset)
            let count = Int(min(sampleSize, fileSize - offset))
            let data = try handle.read(upToCount: count) ?? Data()
            hasher.update(data: Data("offset:\(offset);count:\(data.count)".utf8))
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func validationError(_ code: Int, _ message: String) -> NSError {
        NSError(
            domain: "SE2RecoveryAssistant",
            code: code,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
