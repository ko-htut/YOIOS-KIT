import Combine
import CoreFoundation
import CryptoKit
import Darwin
import Foundation

enum CompanionFailure: Error, Equatable {
    case payloadMissing
    case payloadInvalid
    case profileExpired
    case phoneNotProvisioned
    case unsupportedIOS
    case appleToolUnavailable
    case targetChanged
    case pairingRequired
    case developerModeRequired
    case malformedResponse
    case commandFailed
    case hostBusy
    case installationCancelled
    case installUncertain

    var detail: String {
        switch self {
        case .payloadMissing: return "Build a signed iPhone Companion and rebuild YIOS-KIT. The simulator app cannot be installed on an iPhone."
        case .payloadInvalid: return "The bundled iPhone app or its Apple development signature could not be verified. Rebuild the signed Companion."
        case .profileExpired: return "The Companion provisioning profile has expired. Re-sign the iPhone app and rebuild YIOS-KIT."
        case .phoneNotProvisioned: return "This iPhone is not included in the Companion provisioning profile. Register it with your signing team and rebuild the signed Companion."
        case .unsupportedIOS: return "This Companion requires a newer iOS version."
        case .appleToolUnavailable: return "Apple's verified device installer is unavailable. Complete the Xcode installation on this Mac."
        case .targetChanged: return "Connect one iPhone by USB and keep the same phone connected during installation."
        case .pairingRequired: return "Unlock the iPhone, approve Trust This Computer, then choose Install / Repair Companion."
        case .developerModeRequired: return "Enable Developer Mode on the iPhone, complete Apple's restart confirmation, then choose Install / Repair Companion."
        case .malformedResponse: return "Apple's installer returned an unsupported response. No automatic retry will be sent on this connection."
        case .commandFailed: return "The iPhone did not complete the requested check. Keep it unlocked and choose Install / Repair Companion."
        case .hostBusy: return "Finish the current iPhone operation before installing the Companion."
        case .installationCancelled: return "Automatic installation was switched off before dispatch."
        case .installUncertain: return "Installation was dispatched, but completion could not be verified. Check the iPhone before using Install / Repair Companion; YIOS-KIT will not retry automatically on this connection."
        }
    }
}

struct CompanionVersion: Equatable, Comparable {
    let marketing: String
    let build: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        let order = lhs.marketing.compare(rhs.marketing, options: .numeric)
        return order == .orderedAscending || (order == .orderedSame && lhs.build.compare(rhs.build, options: .numeric) == .orderedAscending)
    }

    var display: String { "\(marketing) (\(build))" }

    static func valid(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 48 && value.range(of: #"^[0-9]+(?:\.[0-9]+)*$"#, options: .regularExpression) != nil
    }
}

struct CompanionPayload {
    static let bundleIdentifier = "local.minthanhtut.YIOSKitCompanion"
    let url: URL
    let version: CompanionVersion
    let minimumIOS: String
}

enum CompanionNativeRequest {
    case devices
    case details(UUID)
    case apps(UUID)
    case install(UUID, URL)

    var arguments: [String] {
        let common = ["--timeout", isInstall ? "120" : "20", "--json-output", "-"]
        switch self {
        case .devices: return ["list", "devices"] + common
        case .details(let identifier): return ["device", "info", "details", "--device", identifier.uuidString] + common
        case .apps(let identifier):
            return ["device", "info", "apps", "--device", identifier.uuidString,
                    "--bundle-id", CompanionPayload.bundleIdentifier, "--include-default-apps"] + common
        case .install(let identifier, let url): return ["device", "install", "app", "--device", identifier.uuidString, url.path] + common
        }
    }

    var isInstall: Bool { if case .install = self { return true }; return false }
}

struct CompanionDependencies {
    var inspectPayload: () throws -> CompanionPayload
    var validatePayload: (CompanionPayload, MockLocationExactTarget) throws -> Void
    var verifyNativeTool: () throws -> Void
    var request: (CompanionNativeRequest) throws -> [String: Any]
    var detect: () -> DeviceSnapshot
    var validatePairing: (String) -> Bool

    static var live: Self {
        Self(inspectPayload: { try CompanionBundleValidator.inspect() },
             validatePayload: { try CompanionBundleValidator.validate($0, for: $1) },
             verifyNativeTool: { try CompanionNativeClient.verifyTool() },
             request: { try CompanionNativeClient.request($0) },
             detect: { DeviceDetector.enriched() },
             validatePairing: { PairingProbe.validate(udid: $0).isValid })
    }
}

enum CompanionNativeParser {
    static func result(_ data: Data) throws -> [String: Any] {
        guard let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["error"] == nil,
              let info = envelope["info"] as? [String: Any], info["outcome"] as? String == "success",
              let result = envelope["result"] as? [String: Any] else { throw CompanionFailure.malformedResponse }
        return result
    }

    private static func hardware(_ record: [String: Any]) throws -> [[String: Any]] {
        if let value = record["properties"], !(value is [String: Any]) { throw CompanionFailure.malformedResponse }
        let properties = record["properties"] as? [String: Any] ?? [:]
        var values: [[String: Any]] = []
        for value in [properties["hardware"], record["hardwareProperties"]].compactMap({ $0 }) {
            guard let value = value as? [String: Any] else { throw CompanionFailure.malformedResponse }
            values.append(value)
        }
        guard !values.isEmpty else { throw CompanionFailure.malformedResponse }
        return values
    }

    static func selectDevice(_ result: [String: Any], target: MockLocationExactTarget) throws -> UUID {
        guard let devices = result["devices"] as? [[String: Any]] else { throw CompanionFailure.malformedResponse }
        let matches = devices.filter { record in
            guard let records = try? hardware(record) else { return false }
            return records.contains { ($0["udid"] as? String)?.caseInsensitiveCompare(target.udid) == .orderedSame }
        }
        guard matches.count == 1 else { throw CompanionFailure.targetChanged }
        return try attest(matches[0], target: target)
    }

    static func attest(_ record: [String: Any], target: MockLocationExactTarget) throws -> UUID {
        guard let identifierText = record["identifier"] as? String,
              let identifier = UUID(uuidString: identifierText),
              identifier.uuidString.caseInsensitiveCompare(identifierText) == .orderedSame,
              let expectedECID = UInt64(target.ecid.dropFirst(2), radix: 16) else { throw CompanionFailure.malformedResponse }
        for value in try hardware(record) {
            guard (value["udid"] as? String)?.caseInsensitiveCompare(target.udid) == .orderedSame,
                  value["productType"] as? String == target.productType,
                  let ecid = value["ecid"] as? NSNumber,
                  CFGetTypeID(ecid) != CFBooleanGetTypeID(),
                  String(cString: ecid.objCType) != "d", String(cString: ecid.objCType) != "f",
                  ecid.stringValue == String(expectedECID),
                  value["deviceType"] as? String == "iPhone", value["platform"] as? String == "iOS" else {
                throw CompanionFailure.targetChanged
            }
        }
        let properties = record["properties"] as? [String: Any] ?? [:]
        var connections: [([String: Any], String)] = []
        for (value, stateKey) in [(properties["connection"], "state"), (record["connectionProperties"], "tunnelState")] {
            if let value {
                guard let value = value as? [String: Any] else { throw CompanionFailure.malformedResponse }
                connections.append((value, stateKey))
            }
        }
        guard !connections.isEmpty else { throw CompanionFailure.malformedResponse }
        for (connection, key) in connections {
            guard connection["pairingState"] as? String == "paired" else { throw CompanionFailure.pairingRequired }
            guard connection[key] as? String == "connected", connection["transportType"] as? String == "wired" else {
                throw CompanionFailure.targetChanged
            }
        }
        var sawEnabled = false
        if let value = properties["state"] {
            guard let state = value as? [String: Any] else { throw CompanionFailure.malformedResponse }
            if let value = state["developerModeStatus"] {
                guard let mode = value as? [String: Any], mode["enabled"] is [String: Any] else {
                    throw CompanionFailure.developerModeRequired
                }
                sawEnabled = true
            }
        }
        if let value = record["deviceProperties"] {
            guard let state = value as? [String: Any] else { throw CompanionFailure.malformedResponse }
            if let value = state["developerModeStatus"] {
                guard value as? String == "enabled" else { throw CompanionFailure.developerModeRequired }
                sawEnabled = true
            }
        }
        guard sawEnabled else { throw CompanionFailure.developerModeRequired }
        return identifier
    }

    static func installedVersion(_ result: [String: Any], identifier: UUID) throws -> CompanionVersion? {
        guard let device = result["deviceIdentifier"] as? String, UUID(uuidString: device) == identifier,
              result["matchingBundleIdentifier"] as? String == CompanionPayload.bundleIdentifier,
              let apps = result["apps"] as? [[String: Any]] else { throw CompanionFailure.malformedResponse }
        guard apps.count <= 1 else { throw CompanionFailure.malformedResponse }
        guard let app = apps.first else { return nil }
        guard app["bundleIdentifier"] as? String == CompanionPayload.bundleIdentifier else { throw CompanionFailure.malformedResponse }
        let build = app["bundleVersion"] as? String
        let marketing = (app["version"] as? String) ?? (app["marketingVersion"] as? String)
        guard let build, let marketing, CompanionVersion.valid(build), CompanionVersion.valid(marketing) else {
            throw CompanionFailure.malformedResponse
        }
        return CompanionVersion(marketing: marketing, build: build)
    }
}

struct CompanionPreparation {
    let payload: CompanionPayload
    let nativeIdentifier: UUID
    let installedVersion: CompanionVersion?
    var needsInstall: Bool { installedVersion.map { $0 < payload.version } ?? true }
}

struct CompanionInstaller {
    let dependencies: CompanionDependencies

    func prepare(target: MockLocationExactTarget) throws -> CompanionPreparation {
        let payload = try dependencies.inspectPayload()
        try dependencies.validatePayload(payload, target)
        try dependencies.verifyNativeTool()
        try attestUSB(target, payload: payload)
        let identifier = try CompanionNativeParser.selectDevice(dependencies.request(.devices), target: target)
        guard try CompanionNativeParser.attest(dependencies.request(.details(identifier)), target: target) == identifier else {
            throw CompanionFailure.targetChanged
        }
        let installed = try CompanionNativeParser.installedVersion(dependencies.request(.apps(identifier)), identifier: identifier)
        return CompanionPreparation(payload: payload, nativeIdentifier: identifier, installedVersion: installed)
    }

    func install(_ prepared: CompanionPreparation, target: MockLocationExactTarget, repairSameVersion: Bool = false, mayDispatch: () -> Bool = { true }) throws -> CompanionVersion {
        try dependencies.validatePayload(prepared.payload, target)
        try dependencies.verifyNativeTool()
        guard try CompanionNativeParser.attest(dependencies.request(.details(prepared.nativeIdentifier)), target: target) == prepared.nativeIdentifier else {
            throw CompanionFailure.targetChanged
        }
        if let current = try CompanionNativeParser.installedVersion(dependencies.request(.apps(prepared.nativeIdentifier)), identifier: prepared.nativeIdentifier),
           current > prepared.payload.version || (current == prepared.payload.version && !repairSameVersion) {
            return current
        }
        try attestUSB(target, payload: prepared.payload)
        guard mayDispatch() else { throw CompanionFailure.installationCancelled }
        do {
            _ = try dependencies.request(.install(prepared.nativeIdentifier, prepared.payload.url))
            guard let installed = try CompanionNativeParser.installedVersion(dependencies.request(.apps(prepared.nativeIdentifier)), identifier: prepared.nativeIdentifier),
                  installed >= prepared.payload.version else { throw CompanionFailure.installUncertain }
            return installed
        } catch {
            throw CompanionFailure.installUncertain
        }
    }

    private func attestUSB(_ target: MockLocationExactTarget, payload: CompanionPayload) throws {
        let snapshot = dependencies.detect()
        guard target.matches(snapshot) else { throw CompanionFailure.targetChanged }
        try CompanionBundleValidator.checkIOS(snapshot, payload: payload)
        guard dependencies.validatePairing(target.udid) else { throw CompanionFailure.pairingRequired }
    }
}

private final class CompanionDispatchPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var permitted = true
    func cancel() { lock.lock(); permitted = false; lock.unlock() }
    func allowsDispatch() -> Bool { lock.lock(); defer { lock.unlock() }; return permitted }
}

@MainActor
final class CompanionController: ObservableObject {
    struct HostCallbacks {
        let currentSnapshot: () -> DeviceSnapshot
        let canInstall: () -> Bool
        let requestFreshEvidence: (@escaping (MockLocationFreshEvidence) -> Void) -> Void
    }

    @Published private(set) var autoInstallEnabled: Bool
    @Published private(set) var isBusy = false
    @Published private(set) var statusText = "Companion setup"
    @Published private(set) var detailText = "A signed iPhone Companion is required for automatic installation."
    @Published private(set) var lastError: String?
    @Published private(set) var installedVersion: String?
    @Published private(set) var payloadAvailable = false
    @Published private(set) var payloadVersion: String?
    private let defaults: UserDefaults
    private let dependencies: CompanionDependencies
    private let workQueue = DispatchQueue(label: "local.minthanhtut.YIOSKitCompanion.installer", qos: .userInitiated)
    private var host: HostCallbacks?
    private var attemptedConnections: Set<String> = []
    private var operationID: UUID?
    private var automaticOperation = false
    private var dispatchPermit = CompanionDispatchPermit()
    private var availabilityID = UUID()
    static let preferenceKey = "companion.autoInstallOnUSBConnection"

    init(defaults: UserDefaults = .standard, dependencies: CompanionDependencies = .live) {
        self.defaults = defaults
        self.dependencies = dependencies
        autoInstallEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    }

    func configureHost(_ host: HostCallbacks) { self.host = host }

    func setAutoInstallEnabled(_ enabled: Bool) {
        autoInstallEnabled = enabled
        defaults.set(enabled, forKey: Self.preferenceKey)
        if !enabled && automaticOperation { dispatchPermit.cancel() }
        if enabled, let snapshot = host?.currentSnapshot() { observeConnection(snapshot) }
    }

    func refreshAvailability() {
        guard !isBusy else { return }
        let generation = UUID()
        availabilityID = generation
        let inspect = dependencies.inspectPayload
        workQueue.async { [weak self] in
            let result = Result { try inspect() }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.availabilityID == generation, !self.isBusy else { return }
                switch result {
                case .success(let payload):
                    self.payloadAvailable = true
                    self.payloadVersion = payload.version.display
                    self.statusText = "Companion ready"
                    self.detailText = "Connect one trusted, unlocked iPhone by USB to install or update the Companion."
                    if let snapshot = self.host?.currentSnapshot() { self.observeConnection(snapshot) }
                case .failure(let error):
                    self.payloadAvailable = false
                    self.payloadVersion = nil
                    self.statusText = "Signed Companion needed"
                    self.detailText = (error as? CompanionFailure ?? .payloadInvalid).detail
                }
            }
        }
    }

    func observeConnection(_ snapshot: DeviceSnapshot) {
        guard autoInstallEnabled, payloadAvailable, !isBusy, let host, host.canInstall(),
              let target = try? MockLocationExactTarget(snapshot: snapshot),
              !attemptedConnections.contains(target.pin.fingerprint) else { return }
        begin(target, automatic: true)
    }

    // Only the USB watcher may call this after independently confirming two
    // successful, empty USB scans. An enrichment failure is not a disconnect.
    func confirmedUSBDisconnected() {
        attemptedConnections.removeAll()
    }

    func installNow() {
        guard !isBusy, let host else { return }
        guard host.canInstall() else { fail(.hostBusy); return }
        guard let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()) else {
            fail(.targetChanged); return
        }
        begin(target, automatic: false)
    }

    private func begin(_ target: MockLocationExactTarget, automatic: Bool) {
        guard !isBusy, let host, host.canInstall() else { return }
        attemptedConnections.insert(target.pin.fingerprint)
        let identifier = UUID()
        operationID = identifier
        automaticOperation = automatic
        dispatchPermit = CompanionDispatchPermit()
        availabilityID = UUID()
        isBusy = true
        lastError = nil
        installedVersion = nil
        statusText = "Checking Companion installation…"
        detailText = "Keep this iPhone connected and unlocked while signing, Trust, and the installed version are checked."
        host.requestFreshEvidence { [weak self] evidence in
            guard let self, self.operationID == identifier else { return }
            guard !self.automaticOperation || self.autoInstallEnabled else { self.finishCancelledAutomatic(); return }
            guard let host = self.host, host.canInstall() else { self.finish(.failure(.hostBusy)); return }
            guard target.matches(evidence.snapshot) else { self.finish(.failure(.targetChanged)); return }
            guard evidence.pairingAndTrustVerified else { self.finish(.failure(.pairingRequired)); return }
            let installer = CompanionInstaller(dependencies: self.dependencies)
            self.workQueue.async { [weak self] in
                let result = Result { try installer.prepare(target: target) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operationID == identifier else { return }
                    switch result {
                    case .failure(let error): self.finish(.failure(error as? CompanionFailure ?? .commandFailed))
                    case .success(let prepared): self.prepared(prepared, target: target, identifier: identifier)
                    }
                }
            }
        }
    }

    private func prepared(_ prepared: CompanionPreparation, target: MockLocationExactTarget, identifier: UUID) {
        payloadAvailable = true
        payloadVersion = prepared.payload.version.display
        guard !automaticOperation || autoInstallEnabled else { finishCancelledAutomatic(); return }
        let manualRepair = !automaticOperation && prepared.installedVersion == prepared.payload.version
        guard prepared.needsInstall || manualRepair else {
            finish(.success((prepared.installedVersion ?? prepared.payload.version, false))); return
        }
        guard let host, host.canInstall() else { finish(.failure(.hostBusy)); return }
        host.requestFreshEvidence { [weak self] evidence in
            guard let self, self.operationID == identifier else { return }
            guard !self.automaticOperation || self.autoInstallEnabled else { self.finishCancelledAutomatic(); return }
            guard let host = self.host, host.canInstall() else { self.finish(.failure(.hostBusy)); return }
            guard target.matches(evidence.snapshot) else { self.finish(.failure(.targetChanged)); return }
            guard evidence.pairingAndTrustVerified else { self.finish(.failure(.pairingRequired)); return }
            self.statusText = "Installing YIOS-KIT Companion…"
            self.detailText = "Apple is installing the signed Companion on this verified iPhone. Keep the USB cable connected."
            let installer = CompanionInstaller(dependencies: self.dependencies)
            let permit = self.dispatchPermit
            self.workQueue.async { [weak self] in
                let result = Result { try installer.install(prepared, target: target, repairSameVersion: manualRepair, mayDispatch: { permit.allowsDispatch() }) }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.operationID == identifier else { return }
                    switch result {
                    case .success(let version): self.finish(.success((version, true)))
                    case .failure(let error):
                        if error as? CompanionFailure == .installationCancelled { self.finishCancelledAutomatic() }
                        else { self.finish(.failure(error as? CompanionFailure ?? .commandFailed)) }
                    }
                }
            }
        }
    }

    private func finish(_ result: Result<(CompanionVersion, Bool), CompanionFailure>) {
        operationID = nil
        automaticOperation = false
        isBusy = false
        switch result {
        case .success(let (version, installed)):
            installedVersion = version.display
            statusText = installed ? "Companion installed" : "Companion is up to date"
            detailText = "YIOS-KIT Companion \(version.display) is installed. Open it on the iPhone; it does not change the phone's system location."
            lastError = nil
        case .failure(let error): fail(error)
        }
    }

    private func finishCancelledAutomatic() {
        operationID = nil
        automaticOperation = false
        isBusy = false
        statusText = "Automatic installation paused"
        detailText = "Automatic installation was switched off before dispatch. Use Install / Repair Companion for an explicit installation."
    }

    private func fail(_ error: CompanionFailure) {
        statusText = error == .payloadMissing || error == .payloadInvalid || error == .profileExpired ? "Signed Companion needed" : "Companion needs attention"
        detailText = error.detail
        lastError = error.detail
        if error == .payloadMissing || error == .payloadInvalid || error == .profileExpired { payloadAvailable = false }
    }
}

// Apple tool and bundle checks are deliberately separate from the controller so
// offline tests can exercise every dispatch decision without touching a phone.
enum CompanionNativeClient {
    static let tool = "/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/Resources/bin/devicectl"

    static func verifyTool() throws {
        var current = URL(fileURLWithPath: tool)
        var first = true
        while true {
            var metadata = stat()
            guard lstat(current.path, &metadata) == 0, metadata.st_uid == 0, metadata.st_mode & 0o022 == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(first ? S_IFREG : S_IFDIR) else {
                throw CompanionFailure.appleToolUnavailable
            }
            if first, metadata.st_mode & 0o111 == 0 { throw CompanionFailure.appleToolUnavailable }
            if current.path == "/" { break }
            current.deleteLastPathComponent()
            first = false
        }
        guard let stream = FileHandle(forReadingAtPath: tool) else { throw CompanionFailure.appleToolUnavailable }
        defer { try? stream.close() }
        let magic = [UInt8](try stream.read(upToCount: 4) ?? Data())
        guard [[0xcf, 0xfa, 0xed, 0xfe], [0xfe, 0xed, 0xfa, 0xcf], [0xca, 0xfe, 0xba, 0xbe], [0xbe, 0xba, 0xfe, 0xca], [0xca, 0xfe, 0xba, 0xbf], [0xbf, 0xba, 0xfe, 0xca]].contains(magic) else {
            throw CompanionFailure.appleToolUnavailable
        }
        let result = CompanionBoundedProcess.run("/usr/bin/codesign", ["--verify", "--strict", "-R", "=anchor apple", tool], timeout: 15)
        guard result.success else { throw CompanionFailure.appleToolUnavailable }
    }

    static func request(_ request: CompanionNativeRequest) throws -> [String: Any] {
        let result = CompanionBoundedProcess.run(tool, request.arguments, timeout: request.isInstall ? 135 : 30)
        guard result.success else { throw CompanionFailure.commandFailed }
        return try CompanionNativeParser.result(result.stdout)
    }
}

enum CompanionBundleValidator {
    static func inspect(bundle: Bundle = .main) throws -> CompanionPayload {
        guard let resources = bundle.resourceURL else { throw CompanionFailure.payloadMissing }
        return try inspect(at: resources.appendingPathComponent("Companion/YIOS-KIT Companion.app"))
    }

    static func inspect(at url: URL) throws -> CompanionPayload {
        guard FileManager.default.fileExists(atPath: url.path) else { throw CompanionFailure.payloadMissing }
        try validateTree(url)
        let info = try propertyList(url.appendingPathComponent("Info.plist"))
        guard info["CFBundleIdentifier"] as? String == CompanionPayload.bundleIdentifier,
              info["CFBundlePackageType"] as? String == "APPL",
              (info["CFBundleSupportedPlatforms"] as? [String]) == ["iPhoneOS"],
              let marketing = info["CFBundleShortVersionString"] as? String,
              let build = info["CFBundleVersion"] as? String,
              let minimumIOS = info["MinimumOSVersion"] as? String,
              CompanionVersion.valid(marketing), CompanionVersion.valid(build), CompanionVersion.valid(minimumIOS),
              let executable = info["CFBundleExecutable"] as? String,
              !executable.isEmpty, !executable.contains("/"), !executable.contains("\\"), !executable.contains("\0"),
              FileManager.default.isExecutableFile(atPath: url.appendingPathComponent(executable).path) else {
            throw CompanionFailure.payloadInvalid
        }
        try verifySignature(url)
        let profile = try validatedProfile(url: url, now: Date())
        try validateSigningIdentity(url: url, profile: profile)
        return CompanionPayload(url: url, version: CompanionVersion(marketing: marketing, build: build), minimumIOS: minimumIOS)
    }

    static func validate(_ payload: CompanionPayload, for target: MockLocationExactTarget, now: Date = Date()) throws {
        let current = try inspect(at: payload.url)
        guard current.version == payload.version, current.minimumIOS == payload.minimumIOS else { throw CompanionFailure.payloadInvalid }
        let profile = try validatedProfile(url: payload.url, now: now)
        guard let devices = profile["ProvisionedDevices"] as? [String],
              devices.contains(where: { $0.caseInsensitiveCompare(target.udid) == .orderedSame }),
              profile["ProvisionsAllDevices"] as? Bool != true else { throw CompanionFailure.phoneNotProvisioned }
    }

    private static func validatedProfile(url: URL, now: Date) throws -> [String: Any] {
        let result = CompanionBoundedProcess.run("/usr/bin/security", ["cms", "-D", "-i", url.appendingPathComponent("embedded.mobileprovision").path], timeout: 15)
        guard result.success,
              let profile = try? PropertyListSerialization.propertyList(from: result.stdout, format: nil) as? [String: Any],
              profile["Entitlements"] is [String: Any],
              let expiration = expiration(profile) else { throw CompanionFailure.payloadInvalid }
        guard expiration > now.addingTimeInterval(60) else { throw CompanionFailure.profileExpired }
        return profile
    }

    private static func validateSigningIdentity(url: URL, profile: [String: Any]) throws {
        guard let entitlements = profile["Entitlements"] as? [String: Any],
              let allowedCertificates = profile["DeveloperCertificates"] as? [Data], !allowedCertificates.isEmpty else { throw CompanionFailure.payloadInvalid }
        let entitlementResult = CompanionBoundedProcess.run("/usr/bin/codesign", ["-d", "--entitlements", ":-", url.path], timeout: 15)
        guard entitlementResult.success,
              let signed = try? PropertyListSerialization.propertyList(from: entitlementResult.stdout, format: nil) as? [String: Any],
              let profileApp = entitlements["application-identifier"] as? String,
              let signedApp = signed["application-identifier"] as? String,
              let team = signed["com.apple.developer.team-identifier"] as? String,
              (profile["TeamIdentifier"] as? [String])?.contains(team) == true,
              signedApp == team + "." + CompanionPayload.bundleIdentifier,
              profileApp == signedApp || profileApp == team + ".*" else { throw CompanionFailure.payloadInvalid }
        let privateDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("yios-companion-signature-" + UUID().uuidString, isDirectory: true)
        do { try FileManager.default.createDirectory(at: privateDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { throw CompanionFailure.payloadInvalid }
        defer { try? FileManager.default.removeItem(at: privateDirectory) }
        let prefix = privateDirectory.appendingPathComponent("certificate-").path
        let certificateResult = CompanionBoundedProcess.run("/usr/bin/codesign", ["-d", "--extract-certificates=" + prefix, url.path], timeout: 15)
        guard certificateResult.success,
              let leaf = try? Data(contentsOf: URL(fileURLWithPath: prefix + "0")), !leaf.isEmpty, leaf.count < 131_072,
              allowedCertificates.contains(leaf) else { throw CompanionFailure.payloadInvalid }
    }

    static func checkIOS(_ snapshot: DeviceSnapshot, payload: CompanionPayload) throws {
        guard let version = snapshot.productVersion, CompanionVersion.valid(version),
              version.compare(payload.minimumIOS, options: .numeric) != .orderedAscending else { throw CompanionFailure.unsupportedIOS }
    }

    private static func expiration(_ profile: [String: Any]) -> Date? {
        if let date = profile["ExpirationDate"] as? Date { return date }
        guard let created = profile["CreationDate"] as? Date, let ttl = profile["TimeToLive"] as? NSNumber,
              CFGetTypeID(ttl) != CFBooleanGetTypeID(), ttl.doubleValue > 0, ttl.doubleValue <= 3660 else { return nil }
        return created.addingTimeInterval(ttl.doubleValue * 86_400)
    }

    private static func verifySignature(_ url: URL) throws {
        let result = CompanionBoundedProcess.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=anchor apple generic", url.path], timeout: 20)
        guard result.success else { throw CompanionFailure.payloadInvalid }
    }

    private static func propertyList(_ url: URL) throws -> [String: Any] {
        guard let data = try? Data(contentsOf: url), data.count < 1_048_576,
              let value = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw CompanionFailure.payloadInvalid
        }
        return value
    }

    private static func validateTree(_ url: URL) throws {
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else { throw CompanionFailure.payloadInvalid }
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        var enumerationFailed = false
        guard let iterator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys), options: [], errorHandler: { _, _ in enumerationFailed = true; return false }) else { throw CompanionFailure.payloadInvalid }
        var count = 0
        for case let entry as URL in iterator {
            count += 1
            let values = try entry.resourceValues(forKeys: keys)
            guard count < 20_000, values.isSymbolicLink != true,
                  values.isRegularFile == true || values.isDirectory == true else { throw CompanionFailure.payloadInvalid }
        }
        guard !enumerationFailed else { throw CompanionFailure.payloadInvalid }
    }
}

struct CompanionProcessResult {
    let success: Bool
    let stdout: Data
}

enum CompanionBoundedProcess {
    private final class Capture: @unchecked Sendable {
        let lock = NSLock()
        var bytes = 0
        var output = Data()
        var overflow = false
        func add(_ data: Data, stdout: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            bytes += data.count
            if bytes > 2 * 1024 * 1024 { overflow = true; return false }
            if stdout { output.append(data) }
            return true
        }
    }

    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> CompanionProcessResult {
        let process = Process()
        let outputPipe = Pipe(), errorPipe = Pipe()
        let capture = Capture()
        let exited = DispatchSemaphore(value: 0)
        let reads = DispatchGroup()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C", "TMPDIR": NSTemporaryDirectory()]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return CompanionProcessResult(success: false, stdout: Data()) }
        for (pipe, stdout) in [(outputPipe, true), (errorPipe, false)] {
            reads.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { reads.leave() }
                while true {
                    let data = pipe.fileHandleForReading.availableData
                    if data.isEmpty { return }
                    if !capture.add(data, stdout: stdout) {
                        if process.isRunning { process.terminate() }
                        return
                    }
                }
            }
        }
        let completed = exited.wait(timeout: .now() + timeout) == .success
        if !completed, process.isRunning {
            process.terminate()
            if exited.wait(timeout: .now() + 1) == .timedOut, process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + 2)
            }
        }
        if reads.wait(timeout: .now() + 2) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = reads.wait(timeout: .now() + 2)
        }
        capture.lock.lock(); defer { capture.lock.unlock() }
        return CompanionProcessResult(success: completed && !process.isRunning && process.terminationStatus == 0 && !capture.overflow, stdout: capture.output)
    }
}
