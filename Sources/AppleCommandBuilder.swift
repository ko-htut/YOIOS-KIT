import Foundation

enum AppleCommandBuilder {
    static let factoryResetProperties = [
        "ECID",
        "UDID",
        "deviceType",
        "isPaired",
        "activationState",
        "bootedState",
        "isSupervised",
        "passcodeProtected",
        "firmwareVersion",
        "buildVersion"
    ]

    static func revive(ecid: String) -> [String] {
        ["--ecid", ecid, "--format", "JSON", "--progress", "-v", "revive"]
    }

    static func restore(ecid: String, ipsw: URL?) -> [String] {
        var arguments = ["--ecid", ecid, "--format", "JSON", "--progress", "-v", "restore"]
        if let ipsw {
            arguments += ["-I", ipsw.path]
        }
        return arguments
    }

    static func factoryResetPreflight(ecid: String) -> [String] {
        ["--ecid", ecid, "--format", "JSON", "--timeout", "10", "get"] + factoryResetProperties
    }

    static func factoryReset(ecid: String) -> [String] {
        // Intentionally omit --esim: Factory Reset keeps cellular eSIMs by default.
        ["--ecid", ecid, "--format", "JSON", "--progress", "--timeout", "10", "-v", "erase"]
    }
}
