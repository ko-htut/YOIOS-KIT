import Foundation

private final class FakeToolchainFileSystem: ToolchainFileSystem {
    private var canonicalPaths: [String: String] = [:]
    private var regularFiles: Set<String> = []
    private var executableFiles: Set<String> = []
    private var fileData: [String: Data] = [:]

    func redirect(_ path: String, to canonicalPath: String) {
        canonicalPaths[normalize(path)] = normalize(canonicalPath)
    }

    func addRegularFile(_ path: String, data: Data = Data()) {
        let path = normalize(path)
        regularFiles.insert(path)
        fileData[path] = data
    }

    func addExecutable(_ path: String) {
        let path = normalize(path)
        regularFiles.insert(path)
        executableFiles.insert(path)
    }

    func canonicalURL(for url: URL) -> URL {
        let path = normalize(url.path)
        return URL(fileURLWithPath: canonicalPaths[path] ?? path)
    }

    func isRegularFile(at url: URL) -> Bool {
        regularFiles.contains(normalize(url.path))
    }

    func isExecutableFile(at url: URL) -> Bool {
        executableFiles.contains(normalize(url.path))
    }

    func data(at url: URL) throws -> Data {
        let path = normalize(url.path)
        guard let data = fileData[path] else {
            throw NSError(domain: "FakeToolchainFileSystem", code: 1)
        }
        return data
    }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}

@main
struct ToolchainTestMain {
    private static var failures: [String] = []

    static func main() {
        testManifestAndVersionParsing()
        testBundleFirstResolution()
        testInstalledFallbackOrderAndCanonicalContainment()
        testBundleEscapeAndNonExecutableRejection()
        testCfgutilIsExternalOnly()
        testCoherentCapabilityResolution()
        testDependencyDoctorSnapshot()
        testSanitizedEnvironment()

        if failures.isEmpty {
            print("TOOLCHAIN TEST PASS")
            exit(0)
        }
        for failure in failures {
            fputs("FAIL: \(failure)\n", stderr)
        }
        exit(1)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures.append(message) }
    }

    private static func roots(app: String? = "/Applications/YIOS-KIT.app") -> ToolchainRoots {
        ToolchainRoots(
            appBundleURL: app.map { URL(fileURLWithPath: $0, isDirectory: true) },
            appleConfiguratorBundleURL: URL(fileURLWithPath: "/Applications/Apple Configurator.app", isDirectory: true),
            appleSiliconHomebrewURL: URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
            intelHomebrewURL: URL(fileURLWithPath: "/usr/local", isDirectory: true)
        )
    }

    private static func manifestData(kinds: [ToolKind] = ToolKind.bundledTools) -> Data {
        let tools = Dictionary(uniqueKeysWithValues: kinds.map { kind in
            let version = kind == .irecovery ? "1.3.1" : "1.4.0"
            return (
                kind.rawValue,
                [
                    "Version": version,
                    "Suite": kind.family.rawValue,
                    "LicenseIdentifiers": ["LGPL-2.1"]
                ] as [String: Any]
            )
        })
        return try! PropertyListSerialization.data(
            fromPropertyList: ["SchemaVersion": 1, "Tools": tools],
            format: .xml,
            options: 0
        )
    }

    private static func addManifest(_ fileSystem: FakeToolchainFileSystem, kinds: [ToolKind] = ToolKind.bundledTools) {
        fileSystem.addRegularFile(
            "/Applications/YIOS-KIT.app/Contents/Resources/ToolchainManifest.plist",
            data: manifestData(kinds: kinds)
        )
    }

    private static func addBundled(_ kinds: [ToolKind], to fileSystem: FakeToolchainFileSystem) {
        for kind in kinds {
            fileSystem.addExecutable("/Applications/YIOS-KIT.app/Contents/Helpers/YIOSTools/\(kind.executableName)")
        }
    }

    private static func addHomebrew(
        _ kinds: [ToolKind],
        prefix: String,
        to fileSystem: FakeToolchainFileSystem
    ) {
        for kind in kinds {
            let link = "\(prefix)/bin/\(kind.executableName)"
            let target = "\(prefix)/Cellar/test/1.0/bin/\(kind.executableName)"
            fileSystem.redirect(link, to: target)
            fileSystem.addExecutable(target)
        }
    }

    private static func addConfigurator(to fileSystem: FakeToolchainFileSystem, version: String = "2.20") {
        fileSystem.addExecutable("/Applications/Apple Configurator.app/Contents/MacOS/cfgutil")
        let info = try! PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version],
            format: .xml,
            options: 0
        )
        fileSystem.addRegularFile("/Applications/Apple Configurator.app/Contents/Info.plist", data: info)
    }

    private static func testManifestAndVersionParsing() {
        do {
            let manifest = try ToolchainManifest.parse(manifestData())
            expect(manifest.schemaVersion == 1, "manifest schema must parse")
            expect(manifest.entry(for: .ideviceInfo)?.version == "1.4.0", "manifest tool version must parse")
            expect(manifest.entry(for: .irecovery)?.suite == ToolFamily.libirecovery.rawValue, "manifest suite must parse")
        } catch {
            failures.append("valid manifest failed to parse: \(error)")
        }

        let invalid = try! PropertyListSerialization.data(
            fromPropertyList: ["SchemaVersion": 2, "Tools": [:]],
            format: .xml,
            options: 0
        )
        do {
            _ = try ToolchainManifest.parse(invalid)
            failures.append("unsupported manifest schema must fail")
        } catch { }

        expect(
            ToolVersionParser.parse(kind: .ideviceID, output: "idevice_id 1.4.0\n") == "1.4.0",
            "libimobiledevice version output must parse"
        )
        expect(
            ToolVersionParser.parse(kind: .irecovery, output: "irecovery 1.3.1 (readline)") == "1.3.1",
            "libirecovery version output must parse"
        )
        expect(
            ToolVersionParser.parse(kind: .homebrew, output: "Homebrew 6.0.18") == "6.0.18",
            "Homebrew version output must parse"
        )
        expect(
            ToolVersionParser.parse(kind: .cfgutil, output: "anything") == nil,
            "cfgutil version must not be inferred from command output"
        )
    }

    private static func testBundleFirstResolution() {
        let fileSystem = FakeToolchainFileSystem()
        addManifest(fileSystem)
        addBundled(ToolKind.bundledTools, to: fileSystem)
        addHomebrew(ToolKind.bundledTools, prefix: "/opt/homebrew", to: fileSystem)
        let resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)

        let info = resolver.resolve(.ideviceInfo)
        expect(info?.source == .bundled, "bundled helper must win over installed fallback")
        expect(info?.advertisedVersion == "1.4.0", "bundled version must come from the manifest")
        expect(info?.executableURL.path.contains("/Contents/Helpers/YIOSTools/ideviceinfo") == true, "bundle helper path must be canonical")
    }

    private static func testInstalledFallbackOrderAndCanonicalContainment() {
        let fileSystem = FakeToolchainFileSystem()
        addHomebrew(ToolKind.libimobiledeviceTools, prefix: "/opt/homebrew", to: fileSystem)
        addHomebrew(ToolKind.libimobiledeviceTools, prefix: "/usr/local", to: fileSystem)
        let resolver = ToolchainResolver(roots: roots(app: nil), fileSystem: fileSystem)
        expect(resolver.resolve(.ideviceInfo)?.source == .homebrewAppleSilicon, "/opt fallback must precede /usr/local")

        let escape = FakeToolchainFileSystem()
        escape.redirect("/opt/homebrew/bin/ideviceinfo", to: "/private/tmp/ideviceinfo")
        escape.addExecutable("/private/tmp/ideviceinfo")
        let escapedResolver = ToolchainResolver(roots: roots(app: nil), fileSystem: escape)
        expect(escapedResolver.resolve(.ideviceInfo) == nil, "Homebrew symlink escaping its trusted prefix must be rejected")
    }

    private static func testBundleEscapeAndNonExecutableRejection() {
        let fileSystem = FakeToolchainFileSystem()
        addManifest(fileSystem, kinds: [.ideviceInfo, .irecovery])
        fileSystem.redirect(
            "/Applications/YIOS-KIT.app/Contents/Helpers/YIOSTools/ideviceinfo",
            to: "/private/tmp/ideviceinfo"
        )
        fileSystem.addExecutable("/private/tmp/ideviceinfo")
        fileSystem.addRegularFile("/Applications/YIOS-KIT.app/Contents/Helpers/YIOSTools/irecovery")
        let resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)
        expect(resolver.resolve(.ideviceInfo) == nil, "bundle symlink escaping the app must be rejected")
        expect(resolver.resolve(.irecovery) == nil, "non-executable bundle file must be rejected")
    }

    private static func testCfgutilIsExternalOnly() {
        let fileSystem = FakeToolchainFileSystem()
        addManifest(fileSystem)
        fileSystem.addExecutable("/Applications/YIOS-KIT.app/Contents/Helpers/YIOSTools/cfgutil")
        addConfigurator(to: fileSystem)
        let resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)
        let cfgutil = resolver.resolve(.cfgutil)
        expect(cfgutil?.source == .appleConfigurator, "cfgutil must resolve only from Apple Configurator")
        expect(cfgutil?.advertisedVersion == "2.20", "Configurator version must come from its Info.plist")
        expect(resolver.resolve(.cfgutil, from: .bundled) == nil, "bundled cfgutil must always be rejected")
    }

    private static func testCoherentCapabilityResolution() {
        let fileSystem = FakeToolchainFileSystem()
        addManifest(fileSystem, kinds: [.idevicePair, .ideviceCrashReport])
        addBundled([.idevicePair], to: fileSystem)
        addHomebrew([.ideviceCrashReport], prefix: "/opt/homebrew", to: fileSystem)
        var resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)
        expect(
            !resolver.resolve(.crashReportCopy).isAvailable,
            "one action must not mix incomplete libimobiledevice sources"
        )
        expect(
            resolver.resolve(.idevicePair) == nil && resolver.resolve(.ideviceCrashReport) == nil,
            "runtime tool paths must fail closed instead of mixing a partial bundle and fallback"
        )

        addHomebrew(ToolKind.libimobiledeviceTools, prefix: "/opt/homebrew", to: fileSystem)
        resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)
        let capability = resolver.resolve(.crashReportCopy)
        expect(capability.isAvailable, "coherent installed pair/crashreport tools should satisfy capability")
        expect(
            Set(capability.tools.values.map(\.source)) == [.homebrewAppleSilicon],
            "capability tools must be pinned to one libimobiledevice source"
        )
    }

    private static func testDependencyDoctorSnapshot() {
        let fileSystem = FakeToolchainFileSystem()
        addManifest(fileSystem)
        addBundled(ToolKind.bundledTools, to: fileSystem)
        addConfigurator(to: fileSystem)
        addHomebrew([.homebrew], prefix: "/opt/homebrew", to: fileSystem)
        let resolver = ToolchainResolver(roots: roots(), fileSystem: fileSystem)
        let snapshot = DependencyDoctor.inspect(
            resolver: resolver,
            versionOutputs: [.homebrew: "Homebrew 6.0.18"],
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        expect(snapshot.component(.libimobiledevice)?.health == .ready, "complete built-in libimobiledevice suite must be ready")
        expect(snapshot.component(.libimobiledevice)?.version == "1.4.0", "doctor must report bundled suite version")
        expect(snapshot.component(.libirecovery)?.version == "1.3.1", "doctor must report bundled irecovery version")
        expect(snapshot.component(.appleConfigurator)?.version == "2.20", "doctor must report Configurator bundle version")
        expect(snapshot.component(.homebrew)?.version == "6.0.18", "doctor must report observed Homebrew version")
        expect(snapshot.capability(.normalIdentity)?.isAvailable == true, "Normal identity capability must be ready")
        expect(snapshot.capability(.appleReviveRestore)?.isAvailable == true, "Apple restore capability must require cfgutil and irecovery")

        let partialFileSystem = FakeToolchainFileSystem()
        addManifest(partialFileSystem, kinds: [.ideviceID])
        addBundled([.ideviceID], to: partialFileSystem)
        let partial = DependencyDoctor.inspect(
            resolver: ToolchainResolver(roots: roots(), fileSystem: partialFileSystem)
        )
        expect(partial.component(.libimobiledevice)?.health == .missing, "an incomplete atomic suite must be unavailable")
        expect(partial.capability(.normalIdentity)?.isAvailable == false, "missing ideviceinfo must block Normal identity capability")
        expect(partial.component(.appleConfigurator)?.health == .missing, "missing Configurator must be explicit")
    }

    private static func testSanitizedEnvironment() {
        let environment = ToolchainExecutionEnvironment.sanitized(inheriting: [
            "HOME": "/Users/test",
            "TMPDIR": "/private/tmp/test",
            "PATH": "/untrusted/bin",
            "DYLD_LIBRARY_PATH": "/private/tmp/evil",
            "DYLD_INSERT_LIBRARIES": "/private/tmp/inject.dylib"
        ])
        expect(environment["HOME"] == "/Users/test", "sanitization must preserve pairing/user context")
        expect(environment["TMPDIR"] == "/private/tmp/test", "sanitization must preserve temporary-directory context")
        expect(environment["DYLD_LIBRARY_PATH"] == nil, "DYLD_LIBRARY_PATH must be removed")
        expect(environment["DYLD_INSERT_LIBRARIES"] == nil, "DYLD_INSERT_LIBRARIES must be removed")
        expect(environment["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin", "PATH must be deterministic")
        expect(environment["LC_ALL"] == "C" && environment["LANG"] == "C", "tool output locale must be deterministic")
    }
}
