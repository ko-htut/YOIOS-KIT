import Foundation

struct AppleOperationEvent: Equatable {
    var progress: Double?
    var step: String?
    var errorMessage: String?
    var matchingSuccess = false
}

enum AppleOperationParser {
    private static func hasNonEmptyErrorValue(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let text = value as? String { return !text.isEmpty }
        if let dictionary = value as? [String: Any] {
            return dictionary.values.contains { hasNonEmptyErrorValue($0) }
        }
        if let array = value as? [Any] {
            return array.contains { hasNonEmptyErrorValue($0) }
        }
        return true
    }

    static func parse(
        _ rawLine: String,
        expectedECID: String?,
        expectedCommand: String?
    ) -> AppleOperationEvent? {
        guard let data = rawLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        var event = AppleOperationEvent()
        let type = (json["Type"] as? String ?? "").lowercased()
        let output = json["Output"] as? [String: Any]
        let hasEmbeddedError = hasNonEmptyErrorValue(json["Error"]) ||
            hasNonEmptyErrorValue(json["Errors"]) ||
            hasNonEmptyErrorValue(output?["Error"]) ||
            hasNonEmptyErrorValue(output?["Errors"])

        for key in ["Progress", "PercentComplete", "Percent"] {
            guard let number = json[key] as? NSNumber else { continue }
            let rawValue = number.doubleValue
            guard rawValue >= 0 else { continue }
            let normalized = rawValue > 1 && rawValue <= 100 ? rawValue / 100 : rawValue
            event.progress = min(max(normalized, 0), 1)
            break
        }

        if type == "step" || type == "stepcomplete" || type == "progress" {
            event.step = (json["Step"] as? String) ??
                (json["Status"] as? String) ??
                (json["Message"] as? String) ??
                (json["Detail"] as? String)
        }

        if type.contains("error") || hasEmbeddedError {
            let domain = json["Domain"] as? String ?? "Apple recovery"
            let code = json["Code"].map { String(describing: $0) } ?? "unknown"
            var parts: [String] = []
            for key in ["Message", "FailureReason", "Detail"] {
                guard let value = json[key] as? String,
                      !value.isEmpty,
                      !parts.contains(where: { $0.caseInsensitiveCompare(value) == .orderedSame }) else { continue }
                parts.append(value)
            }
            let message = parts.isEmpty ? "Unknown error" : parts.joined(separator: " | ")
            event.errorMessage = "\(domain) code \(code): \(message)"
        }

        if type == "commandoutput",
           let expectedECID,
           let expectedCommand {
            let command = (json["Command"] as? String ?? "").lowercased()
            var devices = json["Devices"] as? [String] ?? []
            devices += json["AffectedDevices"] as? [String] ?? []
            if let output {
                devices += Array(output.keys)
            }
            let expected = DeviceDetector.normalizeECID(expectedECID)
            let containsExpected = devices.contains {
                DeviceDetector.normalizeECID($0) == expected
            }
            let expectedCommand = expectedCommand.lowercased()
            let commandMatches = command == expectedCommand ||
                (expectedCommand == "erase" && command == "erase-content")
            event.matchingSuccess = containsExpected && commandMatches && !hasEmbeddedError
        }

        return event
    }
}
