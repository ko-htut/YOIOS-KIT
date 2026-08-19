import Foundation

enum ToolKind: String, CaseIterable, Codable, Hashable {
    case homebrew = "brew"
    case cfgutil
    case ideviceID = "idevice_id"
    case ideviceInfo = "ideviceinfo"
    case idevicePair = "idevicepair"
    case ideviceEnterRecovery = "ideviceenterrecovery"
    case ideviceDiagnostics = "idevicediagnostics"
    case ideviceCrashReport = "idevicecrashreport"
    case irecovery

    static let libimobiledeviceTools: [ToolKind] = [
        .ideviceID,
        .ideviceInfo,
        .idevicePair,
        .ideviceEnterRecovery,
        .ideviceDiagnostics,
        .ideviceCrashReport
    ]

    static let bundledTools: [ToolKind] = libimobiledeviceTools + [.irecovery]

    var executableName: String { rawValue }

    var family: ToolFamily {
        switch self {
        case .homebrew: return .homebrew
        case .cfgutil: return .appleConfigurator
        case .irecovery: return .libirecovery
        case .ideviceID, .ideviceInfo, .idevicePair, .ideviceEnterRecovery,
             .ideviceDiagnostics, .ideviceCrashReport:
            return .libimobiledevice
        }
    }

    var canBeBundled: Bool {
        Self.bundledTools.contains(self)
    }
}

enum ToolFamily: String, Codable, Hashable {
    case homebrew
    case appleConfigurator
    case libimobiledevice
    case libirecovery
}

enum ToolSource: String, Codable, CaseIterable, Hashable {
    case bundled
    case homebrewAppleSilicon
    case homebrewIntel
    case appleConfigurator

    var title: String {
        switch self {
        case .bundled: return "Built in"
        case .homebrewAppleSilicon: return "Homebrew (/opt/homebrew)"
        case .homebrewIntel: return "Homebrew (/usr/local)"
        case .appleConfigurator: return "Apple Configurator"
        }
    }
}

struct ResolvedTool: Equatable, Hashable {
    let kind: ToolKind
    let executableURL: URL
    let source: ToolSource
    let advertisedVersion: String?

    var displayLocation: String {
        switch source {
        case .bundled: return "Inside YIOS-KIT"
        case .homebrewAppleSilicon: return "/opt/homebrew"
        case .homebrewIntel: return "/usr/local"
        case .appleConfigurator: return "/Applications/Apple Configurator.app"
        }
    }
}

enum ToolCapability: String, CaseIterable, Codable, Hashable {
    case normalIdentity
    case pairingValidation
    case recoveryModeVerification
    case normalToRecovery
    case normalPowerControl
    case crashReportCopy
    case appleReviveRestore
    case factoryReset

    var requiredTools: [ToolKind] {
        switch self {
        case .normalIdentity:
            return [.ideviceID, .ideviceInfo]
        case .pairingValidation:
            return [.idevicePair]
        case .recoveryModeVerification:
            return [.irecovery]
        case .normalToRecovery:
            return [.ideviceID, .ideviceInfo, .ideviceEnterRecovery]
        case .normalPowerControl:
            return [.idevicePair, .ideviceDiagnostics]
        case .crashReportCopy:
            return [.idevicePair, .ideviceCrashReport]
        case .appleReviveRestore:
            return [.irecovery, .cfgutil]
        case .factoryReset:
            return [.idevicePair, .cfgutil]
        }
    }
}

struct ToolCapabilityResolution: Equatable {
    let capability: ToolCapability
    let tools: [ToolKind: ResolvedTool]
    let unavailableTools: [ToolKind]

    var isAvailable: Bool {
        unavailableTools.isEmpty && tools.count == capability.requiredTools.count
    }
}

struct ToolchainRoots: Equatable {
    let appBundleURL: URL?
    let appleConfiguratorBundleURL: URL
    let appleSiliconHomebrewURL: URL
    let intelHomebrewURL: URL

    init(
        appBundleURL: URL?,
        appleConfiguratorBundleURL: URL = URL(fileURLWithPath: "/Applications/Apple Configurator.app", isDirectory: true),
        appleSiliconHomebrewURL: URL = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true),
        intelHomebrewURL: URL = URL(fileURLWithPath: "/usr/local", isDirectory: true)
    ) {
        self.appBundleURL = appBundleURL
        self.appleConfiguratorBundleURL = appleConfiguratorBundleURL
        self.appleSiliconHomebrewURL = appleSiliconHomebrewURL
        self.intelHomebrewURL = intelHomebrewURL
    }

    static func live(bundle: Bundle = .main) -> ToolchainRoots {
        let bundleURL = bundle.bundleURL
        return ToolchainRoots(
            appBundleURL: bundleURL.pathExtension.caseInsensitiveCompare("app") == .orderedSame
                ? bundleURL
                : nil
        )
    }
}

enum ToolchainRuntime {
    // One immutable resolver is used for the lifetime of the process so an
    // action cannot silently switch from the bundled suite to a host fallback
    // between its preflight and execution.
    static let resolver = ToolchainResolver()
}

protocol ToolchainFileSystem {
    func canonicalURL(for url: URL) -> URL
    func isRegularFile(at url: URL) -> Bool
    func isExecutableFile(at url: URL) -> Bool
    func data(at url: URL) throws -> Data
}

struct LocalToolchainFileSystem: ToolchainFileSystem {
    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func canonicalURL(for url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    func isRegularFile(at url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
    }

    func isExecutableFile(at url: URL) -> Bool {
        fileManager.isExecutableFile(atPath: url.path)
    }

    func data(at url: URL) throws -> Data {
        try Data(contentsOf: url, options: [.mappedIfSafe])
    }
}

struct ToolchainManifest: Equatable {
    struct Entry: Equatable {
        let kind: ToolKind
        let version: String
        let suite: String
        let licenseIdentifiers: [String]
    }

    enum ParseError: Error, Equatable, LocalizedError {
        case invalidPropertyList
        case unsupportedSchema
        case missingTools
        case invalidEntry(String)

        var errorDescription: String? {
            switch self {
            case .invalidPropertyList: return "The bundled tool manifest is not a property-list dictionary."
            case .unsupportedSchema: return "The bundled tool manifest schema is unsupported."
            case .missingTools: return "The bundled tool manifest contains no supported tools."
            case .invalidEntry(let name): return "The bundled tool manifest entry for \(name) is invalid."
            }
        }
    }

    let schemaVersion: Int
    let entries: [ToolKind: Entry]

    func entry(for kind: ToolKind) -> Entry? {
        entries[kind]
    }

    static func parse(_ data: Data) throws -> ToolchainManifest {
        let object: Any
        do {
            object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        } catch {
            throw ParseError.invalidPropertyList
        }

        guard let root = object as? [String: Any] else {
            throw ParseError.invalidPropertyList
        }
        let schemaValue = root["SchemaVersion"] ?? root["schemaVersion"]
        guard let schemaVersion = (schemaValue as? NSNumber)?.intValue,
              schemaVersion == 1 else { throw ParseError.unsupportedSchema }

        let rawTools = root["Tools"] ?? root["tools"]
        guard let toolDictionary = rawTools as? [String: Any] else {
            throw ParseError.missingTools
        }

        var entries: [ToolKind: Entry] = [:]
        for name in toolDictionary.keys.sorted() {
            guard let kind = ToolKind(rawValue: name), kind.canBeBundled else {
                continue
            }
            guard let rawEntry = toolDictionary[name] as? [String: Any] else {
                throw ParseError.invalidEntry(name)
            }
            let rawVersion = rawEntry["Version"] ?? rawEntry["version"]
            guard let version = cleanString(rawVersion) else {
                throw ParseError.invalidEntry(name)
            }
            let rawSuite = rawEntry["Suite"] ?? rawEntry["suite"]
            let suite = cleanString(rawSuite) ?? kind.family.rawValue
            let rawLicenses = rawEntry["LicenseIdentifiers"] ?? rawEntry["licenseIdentifiers"]
            let licenses = (rawLicenses as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            entries[kind] = Entry(
                kind: kind,
                version: version,
                suite: suite,
                licenseIdentifiers: licenses
            )
        }

        guard !entries.isEmpty else { throw ParseError.missingTools }
        return ToolchainManifest(schemaVersion: schemaVersion, entries: entries)
    }

    private static func cleanString(_ value: Any?) -> String? {
        guard let text = value as? String else { return nil }
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

enum ToolchainManifestState: Equatable {
    case unavailable
    case invalid(String)
    case valid(ToolchainManifest)
}

final class ToolchainResolver {
    let roots: ToolchainRoots
    let manifestState: ToolchainManifestState

    private let fileSystem: ToolchainFileSystem

    init(
        roots: ToolchainRoots = .live(),
        fileSystem: ToolchainFileSystem = LocalToolchainFileSystem()
    ) {
        self.roots = roots
        self.fileSystem = fileSystem
        self.manifestState = Self.loadManifest(roots: roots, fileSystem: fileSystem)
    }

    func resolve(_ kind: ToolKind) -> ResolvedTool? {
        switch kind {
        case .cfgutil:
            // cfgutil is Apple-owned and must never be accepted from this app's
            // bundle or a Homebrew prefix.
            return resolve(kind, from: .appleConfigurator)
        case .homebrew:
            return resolve(kind, from: .homebrewAppleSilicon)
                ?? resolve(kind, from: .homebrewIntel)
        case .ideviceID, .ideviceInfo, .idevicePair, .ideviceEnterRecovery,
             .ideviceDiagnostics, .ideviceCrashReport:
            // Treat the libimobiledevice helper suite as one atomic runtime.
            // A damaged/partial bundle must never be completed with helpers
            // from another prefix during a device workflow.
            return resolveCoherent(ToolKind.libimobiledeviceTools)[kind]
        case .irecovery:
            return resolve(kind, from: .bundled)
                ?? resolve(kind, from: .homebrewAppleSilicon)
                ?? resolve(kind, from: .homebrewIntel)
        }
    }

    func resolve(_ capability: ToolCapability) -> ToolCapabilityResolution {
        var resolved: [ToolKind: ResolvedTool] = [:]
        var unavailable: [ToolKind] = []

        let mobileRequirements = capability.requiredTools.filter { $0.family == .libimobiledevice }
        if !mobileRequirements.isEmpty {
            let coherentSuite = resolveCoherent(ToolKind.libimobiledeviceTools)
            let requiredSet = Dictionary(uniqueKeysWithValues: mobileRequirements.compactMap { kind in
                coherentSuite[kind].map { (kind, $0) }
            })
            if requiredSet.count == mobileRequirements.count {
                resolved.merge(requiredSet) { current, _ in current }
            } else {
                unavailable.append(contentsOf: mobileRequirements)
            }
        }

        for kind in capability.requiredTools where kind.family != .libimobiledevice {
            if let tool = resolve(kind) {
                resolved[kind] = tool
            } else {
                unavailable.append(kind)
            }
        }

        return ToolCapabilityResolution(
            capability: capability,
            tools: resolved,
            unavailableTools: unavailable.sorted { $0.rawValue < $1.rawValue }
        )
    }

    func resolve(_ kind: ToolKind, from source: ToolSource) -> ResolvedTool? {
        guard sourceIsAllowed(source, for: kind),
              let locations = candidateLocations(for: kind, source: source),
              let canonical = validatedExecutable(locations.candidate, inside: locations.root) else {
            return nil
        }

        let advertisedVersion: String?
        switch source {
        case .bundled:
            guard case .valid(let manifest) = manifestState,
                  let entry = manifest.entry(for: kind) else { return nil }
            advertisedVersion = entry.version
        case .appleConfigurator:
            advertisedVersion = configuratorVersion()
        case .homebrewAppleSilicon, .homebrewIntel:
            advertisedVersion = nil
        }

        return ResolvedTool(
            kind: kind,
            executableURL: canonical,
            source: source,
            advertisedVersion: advertisedVersion
        )
    }

    private func resolveCoherent(_ kinds: [ToolKind]) -> [ToolKind: ResolvedTool] {
        for source in [ToolSource.bundled, .homebrewAppleSilicon, .homebrewIntel] {
            let matches = kinds.compactMap { kind -> (ToolKind, ResolvedTool)? in
                resolve(kind, from: source).map { (kind, $0) }
            }
            if matches.count == kinds.count {
                return Dictionary(uniqueKeysWithValues: matches)
            }
        }
        return [:]
    }

    private func sourceIsAllowed(_ source: ToolSource, for kind: ToolKind) -> Bool {
        switch kind {
        case .cfgutil:
            return source == .appleConfigurator
        case .homebrew:
            return source == .homebrewAppleSilicon || source == .homebrewIntel
        default:
            if source == .appleConfigurator { return false }
            if source == .bundled { return kind.canBeBundled }
            return true
        }
    }

    private func candidateLocations(
        for kind: ToolKind,
        source: ToolSource
    ) -> (candidate: URL, root: URL)? {
        switch source {
        case .bundled:
            guard let appBundleURL = roots.appBundleURL else { return nil }
            return (
                appBundleURL
                    .appendingPathComponent("Contents/Helpers/YIOSTools", isDirectory: true)
                    .appendingPathComponent(kind.executableName, isDirectory: false),
                appBundleURL
            )
        case .homebrewAppleSilicon:
            return (
                roots.appleSiliconHomebrewURL
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(kind.executableName, isDirectory: false),
                roots.appleSiliconHomebrewURL
            )
        case .homebrewIntel:
            return (
                roots.intelHomebrewURL
                    .appendingPathComponent("bin", isDirectory: true)
                    .appendingPathComponent(kind.executableName, isDirectory: false),
                roots.intelHomebrewURL
            )
        case .appleConfigurator:
            let bundle = roots.appleConfiguratorBundleURL
            return (
                bundle
                    .appendingPathComponent("Contents/MacOS", isDirectory: true)
                    .appendingPathComponent("cfgutil", isDirectory: false),
                bundle
            )
        }
    }

    private func validatedExecutable(_ candidate: URL, inside root: URL) -> URL? {
        guard candidate.isFileURL, root.isFileURL,
              candidate.path.hasPrefix("/"), root.path.hasPrefix("/") else { return nil }
        let canonicalRoot = fileSystem.canonicalURL(for: root)
        let canonicalCandidate = fileSystem.canonicalURL(for: candidate)
        guard Self.isDescendant(canonicalCandidate, of: canonicalRoot),
              fileSystem.isRegularFile(at: canonicalCandidate),
              fileSystem.isExecutableFile(at: canonicalCandidate) else { return nil }
        return canonicalCandidate
    }

    private func configuratorVersion() -> String? {
        let infoURL = roots.appleConfiguratorBundleURL
            .appendingPathComponent("Contents/Info.plist", isDirectory: false)
        let canonicalRoot = fileSystem.canonicalURL(for: roots.appleConfiguratorBundleURL)
        let canonicalInfo = fileSystem.canonicalURL(for: infoURL)
        guard Self.isDescendant(canonicalInfo, of: canonicalRoot),
              fileSystem.isRegularFile(at: canonicalInfo),
              let data = try? fileSystem.data(at: canonicalInfo) else { return nil }
        return ToolVersionParser.parseInfoPlist(data)
    }

    private static func loadManifest(
        roots: ToolchainRoots,
        fileSystem: ToolchainFileSystem
    ) -> ToolchainManifestState {
        guard let appBundleURL = roots.appBundleURL else { return .unavailable }
        let manifestURL = appBundleURL
            .appendingPathComponent("Contents/Resources", isDirectory: true)
            .appendingPathComponent("ToolchainManifest.plist", isDirectory: false)
        let canonicalRoot = fileSystem.canonicalURL(for: appBundleURL)
        let canonicalManifest = fileSystem.canonicalURL(for: manifestURL)
        guard isDescendant(canonicalManifest, of: canonicalRoot),
              fileSystem.isRegularFile(at: canonicalManifest) else { return .unavailable }
        do {
            let data = try fileSystem.data(at: canonicalManifest)
            return .valid(try ToolchainManifest.parse(data))
        } catch {
            return .invalid((error as? LocalizedError)?.errorDescription ?? "The bundled tool manifest could not be read.")
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let candidatePath = candidate.standardizedFileURL.path
        guard candidatePath != rootPath else { return false }
        return candidatePath.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}

enum ToolVersionParser {
    static func parse(kind: ToolKind, output: String) -> String? {
        let cleaned = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        let pattern: String
        switch kind {
        case .homebrew:
            pattern = #"(?i)\bHomebrew\s+([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)"#
        case .cfgutil:
            return nil
        default:
            pattern = #"(?i)\b(?:idevice[_a-z]*|irecovery)\s+([0-9]+(?:\.[0-9]+){1,3}(?:[-+][0-9A-Za-z.-]+)?)"#
        }
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: cleaned,
                range: NSRange(cleaned.startIndex..., in: cleaned)
              ),
              let range = Range(match.range(at: 1), in: cleaned) else { return nil }
        return String(cleaned[range])
    }

    static func parseInfoPlist(_ data: Data) -> String? {
        guard let object = try? PropertyListSerialization.propertyList(
            from: data,
            options: [],
            format: nil
        ), let dictionary = object as? [String: Any] else { return nil }
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            if let value = dictionary[key] as? String {
                let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }
}

enum ToolchainExecutionEnvironment {
    static func sanitized(
        inheriting base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var result = base.filter { key, _ in
            !key.uppercased().hasPrefix("DYLD_")
        }
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        result["LANG"] = "C"
        result["LC_ALL"] = "C"
        return result
    }
}

enum DependencyComponent: String, CaseIterable, Codable, Hashable {
    case homebrew
    case appleConfigurator
    case libimobiledevice
    case libirecovery

    var title: String {
        switch self {
        case .homebrew: return "Homebrew"
        case .appleConfigurator: return "Apple Configurator"
        case .libimobiledevice: return "libimobiledevice"
        case .libirecovery: return "libirecovery"
        }
    }
}

enum DependencyRequirement: String, Codable, Hashable {
    case coreInspection
    case advancedAppleOperations
    case optionalFallback
}

enum DependencyHealth: String, Codable, Hashable {
    case ready
    case degraded
    case missing
    case notRequired
}

struct DependencyComponentStatus: Equatable {
    let component: DependencyComponent
    let requirement: DependencyRequirement
    let health: DependencyHealth
    let version: String?
    let sourceSummary: String
    let availableTools: [ToolKind]
    let missingTools: [ToolKind]
    let detail: String
}

struct DependencyToolStatus: Equatable {
    let kind: ToolKind
    let isAvailable: Bool
    let source: ToolSource?
    let version: String?
    let displayLocation: String?
}

struct DependencyDoctorSnapshot: Equatable {
    let capturedAt: Date
    let components: [DependencyComponentStatus]
    let tools: [DependencyToolStatus]
    let capabilities: [ToolCapabilityResolution]
    let manifestState: ToolchainManifestState

    func component(_ component: DependencyComponent) -> DependencyComponentStatus? {
        components.first { $0.component == component }
    }

    func capability(_ capability: ToolCapability) -> ToolCapabilityResolution? {
        capabilities.first { $0.capability == capability }
    }
}

enum DependencyDoctor {
    static func inspect(
        resolver: ToolchainResolver,
        versionOutputs: [ToolKind: String] = [:],
        capturedAt: Date = Date()
    ) -> DependencyDoctorSnapshot {
        var resolved: [ToolKind: ResolvedTool] = [:]
        let toolStatuses = ToolKind.allCases.map { kind -> DependencyToolStatus in
            let tool = resolver.resolve(kind)
            if let tool { resolved[kind] = tool }
            let observedVersion = versionOutputs[kind].flatMap {
                ToolVersionParser.parse(kind: kind, output: $0)
            }
            return DependencyToolStatus(
                kind: kind,
                isAvailable: tool != nil,
                source: tool?.source,
                version: tool?.advertisedVersion ?? observedVersion,
                displayLocation: tool?.displayLocation
            )
        }

        let mobileStatus = componentStatus(
            component: .libimobiledevice,
            requirement: .coreInspection,
            kinds: ToolKind.libimobiledeviceTools,
            resolved: resolved,
            versionOutputs: versionOutputs,
            completeDetail: "Built-in or installed tools are ready for Normal-iOS identity and supported utilities.",
            missingDetail: "Normal-iOS detail and related utilities are limited until the listed tools are available."
        )
        let recoveryStatus = componentStatus(
            component: .libirecovery,
            requirement: .coreInspection,
            kinds: [.irecovery],
            resolved: resolved,
            versionOutputs: versionOutputs,
            completeDetail: "Recovery and DFU protocol verification is available.",
            missingDetail: "Recovery and DFU USB evidence cannot be protocol-verified without irecovery."
        )

        let cfgutil = resolved[.cfgutil]
        let configuratorStatus = DependencyComponentStatus(
            component: .appleConfigurator,
            requirement: .advancedAppleOperations,
            health: cfgutil == nil ? .missing : .ready,
            version: cfgutil?.advertisedVersion,
            sourceSummary: cfgutil?.source.title ?? "Not installed",
            availableTools: cfgutil == nil ? [] : [.cfgutil],
            missingTools: cfgutil == nil ? [.cfgutil] : [],
            detail: cfgutil == nil
                ? "Inspection remains available, but Apple Revive, Restore, and Factory Reset are unavailable."
                : "Official Apple Revive, Restore, and Factory Reset tooling is available."
        )

        let brew = resolved[.homebrew]
        let allMobileBuiltIn = ToolKind.bundledTools.allSatisfy {
            resolved[$0]?.source == .bundled
        }
        let brewVersion = brew?.advertisedVersion ?? versionOutputs[.homebrew].flatMap {
            ToolVersionParser.parse(kind: .homebrew, output: $0)
        }
        let homebrewHealth: DependencyHealth = brew != nil
            ? .ready
            : (allMobileBuiltIn ? .notRequired : .missing)
        let homebrewStatus = DependencyComponentStatus(
            component: .homebrew,
            requirement: .optionalFallback,
            health: homebrewHealth,
            version: brewVersion,
            sourceSummary: brew?.source.title ?? (allMobileBuiltIn ? "Not needed" : "Not installed"),
            availableTools: brew == nil ? [] : [.homebrew],
            missingTools: brew == nil && !allMobileBuiltIn ? [.homebrew] : [],
            detail: allMobileBuiltIn
                ? "YIOS-KIT can use its built-in mobile-device tools; Homebrew is only an optional fallback."
                : "Homebrew can supply an installed fallback when built-in mobile-device tools are unavailable."
        )

        return DependencyDoctorSnapshot(
            capturedAt: capturedAt,
            components: [homebrewStatus, configuratorStatus, mobileStatus, recoveryStatus],
            tools: toolStatuses,
            capabilities: ToolCapability.allCases.map { resolver.resolve($0) },
            manifestState: resolver.manifestState
        )
    }

    private static func componentStatus(
        component: DependencyComponent,
        requirement: DependencyRequirement,
        kinds: [ToolKind],
        resolved: [ToolKind: ResolvedTool],
        versionOutputs: [ToolKind: String],
        completeDetail: String,
        missingDetail: String
    ) -> DependencyComponentStatus {
        let available = kinds.filter { resolved[$0] != nil }
        let missing = kinds.filter { resolved[$0] == nil }
        let health: DependencyHealth
        if available.isEmpty {
            health = .missing
        } else if missing.isEmpty {
            health = .ready
        } else {
            health = .degraded
        }

        let sources = Set(available.compactMap { resolved[$0]?.source.title }).sorted()
        let versions = Set(available.compactMap { kind -> String? in
            if let advertised = resolved[kind]?.advertisedVersion { return advertised }
            return versionOutputs[kind].flatMap { ToolVersionParser.parse(kind: kind, output: $0) }
        }).sorted()

        return DependencyComponentStatus(
            component: component,
            requirement: requirement,
            health: health,
            version: versions.count == 1 ? versions[0] : (versions.isEmpty ? nil : "Mixed"),
            sourceSummary: sources.count == 1 ? sources[0] : (sources.isEmpty ? "Unavailable" : "Mixed sources"),
            availableTools: available,
            missingTools: missing,
            detail: missing.isEmpty ? completeDetail : missingDetail
        )
    }
}
