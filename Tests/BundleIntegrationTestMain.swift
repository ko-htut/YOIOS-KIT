import Foundation

@main
struct BundleIntegrationTestMain {
    private static var failures: [String] = []

    static func main() {
        guard CommandLine.arguments.count == 2 else {
            fputs("Usage: bundle-integration-test <app-bundle>\n", stderr)
            exit(64)
        }

        let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let canonicalAppURL = appURL.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
        let helperRoot = canonicalAppURL
            .appendingPathComponent("Contents/Helpers/YIOSTools", isDirectory: true)
            .path
        let resolver = ToolchainResolver(
            roots: ToolchainRoots(
                appBundleURL: appURL,
                appleConfiguratorBundleURL: URL(fileURLWithPath: "/Applications/Apple Configurator.app", isDirectory: true),
                appleSiliconHomebrewURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
                intelHomebrewURL: URL(fileURLWithPath: "/usr/local", isDirectory: true)
            )
        )

        guard case .valid(let manifest) = resolver.manifestState else {
            fputs("FAIL: packaged toolchain manifest is missing or invalid\n", stderr)
            exit(1)
        }

        for kind in ToolKind.bundledTools {
            let tool = resolver.resolve(kind)
            expect(tool?.source == .bundled, "\(kind.rawValue) must resolve from the app bundle")
            expect(
                tool?.executableURL.path.hasPrefix(helperRoot.hasSuffix("/") ? helperRoot : helperRoot + "/") == true,
                "\(kind.rawValue) must stay inside the app"
            )
            expect(tool?.advertisedVersion == manifest.entry(for: kind)?.version, "\(kind.rawValue) version must match the signed manifest")
        }

        for capability in [
            ToolCapability.normalIdentity,
            .pairingValidation,
            .recoveryModeVerification,
            .normalToRecovery,
            .normalPowerControl,
            .crashReportCopy
        ] {
            let resolution = resolver.resolve(capability)
            expect(resolution.isAvailable, "\(capability.rawValue) must be available from built-in tools")
            expect(
                resolution.tools.values
                    .filter { $0.kind.family == .libimobiledevice || $0.kind.family == .libirecovery }
                    .allSatisfy { $0.source == .bundled },
                "\(capability.rawValue) must not use a Homebrew fallback"
            )
        }

        expect(resolver.resolve(.cfgutil, from: .bundled) == nil, "cfgutil must never resolve from the app bundle")

        if failures.isEmpty {
            print("APP BUNDLE TOOLCHAIN INTEGRATION PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }
}
