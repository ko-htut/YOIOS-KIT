import Combine
import CryptoKit
import Darwin
import Foundation

// MARK: - Coordinate input

enum MockLocationCoordinateError: LocalizedError, Equatable {
    case latitudeMissing
    case longitudeMissing
    case latitudeInvalid
    case longitudeInvalid
    case latitudeOutOfRange
    case longitudeOutOfRange

    var errorDescription: String? {
        switch self {
        case .latitudeMissing:
            return "Enter a latitude."
        case .longitudeMissing:
            return "Enter a longitude."
        case .latitudeInvalid:
            return "Latitude must be a finite decimal number using a period as the decimal separator."
        case .longitudeInvalid:
            return "Longitude must be a finite decimal number using a period as the decimal separator."
        case .latitudeOutOfRange:
            return "Latitude must be between -90 and 90."
        case .longitudeOutOfRange:
            return "Longitude must be between -180 and 180."
        }
    }
}

struct MockLocationCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite else { throw MockLocationCoordinateError.latitudeInvalid }
        guard longitude.isFinite else { throw MockLocationCoordinateError.longitudeInvalid }
        guard (-90.0...90.0).contains(latitude) else {
            throw MockLocationCoordinateError.latitudeOutOfRange
        }
        guard (-180.0...180.0).contains(longitude) else {
            throw MockLocationCoordinateError.longitudeOutOfRange
        }
        self.latitude = latitude
        self.longitude = longitude
    }

    static func parse(latitude latitudeText: String, longitude longitudeText: String) throws -> Self {
        let latitude = latitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        let longitude = longitudeText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !latitude.isEmpty else { throw MockLocationCoordinateError.latitudeMissing }
        guard !longitude.isEmpty else { throw MockLocationCoordinateError.longitudeMissing }
        guard isPlainDecimal(latitude), let parsedLatitude = Double(latitude), parsedLatitude.isFinite else {
            throw MockLocationCoordinateError.latitudeInvalid
        }
        guard isPlainDecimal(longitude), let parsedLongitude = Double(longitude), parsedLongitude.isFinite else {
            throw MockLocationCoordinateError.longitudeInvalid
        }
        return try Self(latitude: parsedLatitude, longitude: parsedLongitude)
    }

    var latitudeArgument: String { Self.commandArgument(latitude) }
    var longitudeArgument: String { Self.commandArgument(longitude) }

    private static func isPlainDecimal(_ value: String) -> Bool {
        guard value.utf8.count <= 32,
              let expression = try? NSRegularExpression(
                pattern: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)$"#
              ) else { return false }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.firstMatch(in: value, range: range)?.range == range
    }

    private static func commandArgument(_ value: Double) -> String {
        var result = String(format: "%.8f", locale: Locale(identifier: "en_US_POSIX"), value)
        while result.contains("."), result.last == "0" { result.removeLast() }
        if result.last == "." { result.removeLast() }
        return result == "-0" ? "0" : result
    }
}

// MARK: - Exact target identity

enum MockLocationTargetError: LocalizedError, Equatable {
    case noDevice
    case multipleDevices
    case normalModeRequired
    case unverifiedMode
    case unsupportedDevice
    case conflictingIdentity
    case missingECID
    case missingUDID
    case missingUSBLocation
    case missingProductType

    var errorDescription: String? {
        switch self {
        case .noDevice:
            return "Connect one iPhone by USB, then scan again."
        case .multipleDevices:
            return "Disconnect extra Apple devices. Mock Location requires exactly one target."
        case .normalModeRequired:
            return "Mock Location is available only while the iPhone is running verified Normal iOS."
        case .unverifiedMode:
            return "The current USB mode has not been protocol-verified. Scan again before continuing."
        case .unsupportedDevice:
            return "Mock Location requires a valid, verified iPhone product type."
        case .conflictingIdentity:
            return "The device identity sources disagree. Reconnect the iPhone and scan again."
        case .missingECID:
            return "A verified ECID is required to pin the exact target."
        case .missingUDID:
            return "A verified UDID is required to pin the exact target."
        case .missingUSBLocation:
            return "A stable USB location is required to pin the exact target."
        case .missingProductType:
            return "A verified product type is required to pin the exact target."
        }
    }
}

struct MockLocationTargetPin: Codable, Equatable, Hashable {
    static let fingerprintLength = 64

    let fingerprint: String

    init(fingerprint: String) throws {
        let normalized = fingerprint.lowercased()
        guard normalized.count == Self.fingerprintLength,
              normalized.allSatisfy({ $0.isNumber || ("a"..."f").contains(String($0)) }) else {
            throw MockLocationJournalError.invalidTargetFingerprint
        }
        self.fingerprint = normalized
    }

    fileprivate init(uncheckedFingerprint: String) {
        fingerprint = uncheckedFingerprint
    }

    var displayToken: String {
        "ML-" + fingerprint.prefix(10).uppercased()
    }
}

struct MockLocationExactTarget: Equatable {
    let ecid: String
    let udid: String
    let locationID: Int
    let productType: String
    let pin: MockLocationTargetPin
    let stablePin: MockLocationTargetPin

    init(snapshot: DeviceSnapshot) throws {
        guard snapshot.deviceCount > 0 else { throw MockLocationTargetError.noDevice }
        guard snapshot.deviceCount == 1, snapshot.mode != .multiple else {
            throw MockLocationTargetError.multipleDevices
        }
        guard snapshot.mode == .normal else { throw MockLocationTargetError.normalModeRequired }
        guard snapshot.modeVerified else { throw MockLocationTargetError.unverifiedMode }
        guard !snapshot.identityConflict else { throw MockLocationTargetError.conflictingIdentity }
        guard let ecid = DeviceDetector.canonicalECIDHex(snapshot.ecid), ecid != "0x0" else {
            throw MockLocationTargetError.missingECID
        }
        guard let rawUDID = Self.validatedUDID(snapshot.udid) else {
            throw MockLocationTargetError.missingUDID
        }
        guard let locationID = snapshot.locationID, locationID >= 0 else {
            throw MockLocationTargetError.missingUSBLocation
        }
        guard let rawProductType = snapshot.productType,
              !rawProductType.isEmpty else { throw MockLocationTargetError.missingProductType }
        guard let productType = Self.validatedProductType(rawProductType) else {
            throw MockLocationTargetError.unsupportedDevice
        }

        self.ecid = ecid
        self.udid = rawUDID
        self.locationID = locationID
        self.productType = productType
        self.pin = Self.makePin(
            ecid: ecid,
            udid: rawUDID,
            locationID: locationID,
            productType: productType
        )
        self.stablePin = Self.makeStablePin(
            ecid: ecid,
            udid: rawUDID,
            productType: productType
        )
    }

    func matches(_ snapshot: DeviceSnapshot) -> Bool {
        guard let observed = try? MockLocationExactTarget(snapshot: snapshot) else { return false }
        return observed.pin == pin &&
            observed.ecid.caseInsensitiveCompare(ecid) == .orderedSame &&
            observed.udid.caseInsensitiveCompare(udid) == .orderedSame &&
            observed.locationID == locationID &&
            observed.productType == productType
    }

    static func pin(for snapshot: DeviceSnapshot) -> MockLocationTargetPin? {
        try? MockLocationExactTarget(snapshot: snapshot).pin
    }

    static func stablePin(for snapshot: DeviceSnapshot) -> MockLocationTargetPin? {
        guard snapshot.deviceCount == 1,
              !snapshot.identityConflict,
              let ecid = DeviceDetector.canonicalECIDHex(snapshot.ecid), ecid != "0x0",
              let rawUDID = validatedUDID(snapshot.udid),
              let productType = validatedProductType(snapshot.productType) else { return nil }
        return makeStablePin(ecid: ecid, udid: rawUDID, productType: productType)
    }

    fileprivate static func validatedProductType(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 32,
              let expression = try? NSRegularExpression(pattern: #"^iPhone[1-9][0-9]*,(0|[1-9][0-9]*)$"#) else {
            return nil
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard expression.firstMatch(in: value, range: range)?.range == range else { return nil }
        let components = value.dropFirst("iPhone".count).split(separator: ",")
        guard components.count == 2,
              Int64(components[0]) != nil,
              Int64(components[1]) != nil else { return nil }
        return value
    }

    private static func validatedUDID(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              let expression = try? NSRegularExpression(pattern: #"^[A-Za-z0-9-]{8,64}$"#) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard expression.firstMatch(in: value, range: range)?.range == range else { return nil }
        return value
    }

    private static func makePin(
        ecid: String,
        udid: String,
        locationID: Int,
        productType: String
    ) -> MockLocationTargetPin {
        let material = [
            "local.minthanhtut.YIOS-KIT.mock-location.target.v1",
            ecid.lowercased(),
            udid.lowercased(),
            String(locationID),
            productType
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MockLocationTargetPin(uncheckedFingerprint: digest)
    }

    private static func makeStablePin(
        ecid: String,
        udid: String,
        productType: String
    ) -> MockLocationTargetPin {
        let material = [
            "local.minthanhtut.YIOS-KIT.mock-location.stable-target.v1",
            ecid.lowercased(),
            udid.lowercased(),
            productType
        ].joined(separator: "\u{001F}")
        let digest = SHA256.hash(data: Data(material.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
        return MockLocationTargetPin(uncheckedFingerprint: digest)
    }
}

// MARK: - Readiness and simulation knowledge

enum MockLocationHostBlockReason: String, Equatable {
    case anotherOperation
    case destructiveWorkflow
    case postResetReview
    case crashCopyReview
    case usbScan
    case usbMonitoring
    case firmwareValidation
    case deviceDetailCollection

    var userDescription: String {
        switch self {
        case .anotherOperation: return "Wait for the current device operation to finish."
        case .destructiveWorkflow: return "Finish or cancel the armed destructive workflow first."
        case .postResetReview: return "Complete the pending factory-reset review first."
        case .crashCopyReview: return "Complete the pending crash-copy review first."
        case .usbScan: return "Wait for the current USB scan to finish."
        case .usbMonitoring: return "Stop the Recovery/DFU watcher first."
        case .firmwareValidation: return "Wait for firmware validation to finish."
        case .deviceDetailCollection: return "Wait for Device Center collection to finish."
        }
    }
}

struct MockLocationHostGate: Equatable {
    var blockReason: MockLocationHostBlockReason?

    static let idle = Self(blockReason: nil)
    var permitsLocationWork: Bool { blockReason == nil }
}

enum MockLocationReadinessIssue: String, Equatable {
    case helperUnavailable
    case hostBusy
    case targetNotEligible
    case targetChanged
    case pairingRequired
    case developerModeRequired
    case unlockRequired
    case developerModeRevealFailed
    case developerDiskImageRequired
    case tunnelUnavailable
    case developerServiceUnavailable
    case permissionDenied
    case probeTimedOut
    case backendProtocolError
    case backendFailure

    var userDescription: String {
        switch self {
        case .helperUnavailable:
            return "The signed, app-private Mock Location backend is not bundled in this build."
        case .hostBusy:
            return "Another device workflow is active."
        case .targetNotEligible:
            return "One verified iPhone in Normal iOS is required."
        case .targetChanged:
            return "The exact ECID, UDID, or USB location changed during preflight."
        case .pairingRequired:
            return "Unlock the iPhone, tap Trust if asked, and run the check again."
        case .developerModeRequired:
            return "Developer Mode must be enabled explicitly on the iPhone before location simulation can start."
        case .unlockRequired:
            return "Unlock the iPhone, keep it connected, and request the Developer Mode Settings option again."
        case .developerModeRevealFailed:
            return "The iPhone did not accept the non-reboot request to make the Developer Mode option available in Settings."
        case .developerDiskImageRequired:
            return "Developer services are not prepared for this iOS build. Mount the matching Developer Disk Image explicitly, then check again."
        case .tunnelUnavailable:
            return "The iOS 17+ developer tunnel could not be established over the selected connection."
        case .developerServiceUnavailable:
            return "The private developer location service is unavailable for this device session."
        case .permissionDenied:
            return "macOS denied the app-private backend access needed for this check."
        case .probeTimedOut:
            return "The read-only readiness check timed out. No location request was sent."
        case .backendProtocolError:
            return "The bundled backend returned an invalid or unsupported response."
        case .backendFailure:
            return "The bundled backend could not complete the readiness check."
        }
    }
}

enum MockLocationReadinessState: Equatable {
    case notChecked
    case checking
    case ready(pin: MockLocationTargetPin, checkedAt: Date, backendVersion: String?)
    case blocked(MockLocationReadinessIssue, detail: String?)
    case failed(MockLocationReadinessIssue)

    func isReady(for pin: MockLocationTargetPin) -> Bool {
        guard case .ready(let readyPin, _, _) = self else { return false }
        return readyPin == pin
    }
}

enum MockLocationUncertaintyReason: String, Codable, Equatable {
    case recoveredAfterInterruption
    case journalUnreadable
    case targetChanged
    case backendExited
    case backendProtocolError
    case clearNotObserved
    case journalWriteFailed

    var userDescription: String {
        switch self {
        case .recoveredAfterInterruption:
            return "The previous session ended before a reset could be recorded. Simulation state cannot be queried."
        case .journalUnreadable:
            return "The crash-safety journal is unreadable, so the previous simulation state cannot be determined."
        case .targetChanged:
            return "The pinned iPhone disconnected or changed while location simulation might be active."
        case .backendExited:
            return "The live backend ended without recording a reset request."
        case .backendProtocolError:
            return "The backend response became invalid after a location request may have been sent."
        case .clearNotObserved:
            return "A reset was requested, but the backend did not report that it sent the clear command."
        case .journalWriteFailed:
            return "The safety journal could not record the current state."
        }
    }
}

enum MockLocationSimulationKnowledge: Equatable {
    case notRequested
    case preparing(pin: MockLocationTargetPin)
    case assumedActive(pin: MockLocationTargetPin, requestedAt: Date)
    case assumedPersistent(pin: MockLocationTargetPin, requestedAt: Date)
    case clearing(pin: MockLocationTargetPin)
    case resetRequestSent(pin: MockLocationTargetPin, requestedAt: Date)
    case uncertain(pin: MockLocationTargetPin?, reason: MockLocationUncertaintyReason)

    var pin: MockLocationTargetPin? {
        switch self {
        case .notRequested: return nil
        case .preparing(let pin), .clearing(let pin): return pin
        case .assumedActive(let pin, _), .assumedPersistent(let pin, _),
             .resetRequestSent(let pin, _): return pin
        case .uncertain(let pin, _): return pin
        }
    }
}

enum MockLocationSetMode: String, Codable, Equatable {
    case liveSession
    case persistentUntilClearOrReboot
}

enum MockLocationTransport: String, Codable, CaseIterable, Identifiable {
    case usb
    case wifi

    var id: String { rawValue }
    var displayName: String { self == .usb ? "USB" : "Wi-Fi" }
}

// MARK: - Crash-safe journal

enum MockLocationJournalError: LocalizedError, Equatable {
    case invalidTargetFingerprint
    case unsupportedSchema
    case invalidRecord
    case recordTooLarge
    case notRegularFile
    case cannotCreateDirectory
    case cannotWrite
    case cannotRead

    var errorDescription: String? {
        "The Mock Location crash-safety journal could not be validated."
    }
}

struct MockLocationJournalRecord: Codable, Equatable {
    enum State: String, Codable {
        case pendingSet
        case setAcknowledged
        case assumedActive
        case assumedPersistent
        case pendingClear
        case uncertain
    }

    static let schemaVersion = 3

    let schema: Int
    let state: State
    let targetFingerprint: String
    let stableTargetFingerprint: String?
    let setMode: MockLocationSetMode
    let transport: MockLocationTransport
    let requestDispatched: Bool
    let createdAt: Date
    let updatedAt: Date

    init(
        state: State,
        pin: MockLocationTargetPin,
        stablePin: MockLocationTargetPin? = nil,
        setMode: MockLocationSetMode = .liveSession,
        transport: MockLocationTransport = .usb,
        requestDispatched: Bool,
        createdAt: Date,
        updatedAt: Date
    ) {
        schema = Self.schemaVersion
        self.state = state
        targetFingerprint = pin.fingerprint
        stableTargetFingerprint = stablePin?.fingerprint
        self.setMode = setMode
        self.transport = transport
        self.requestDispatched = requestDispatched
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var pin: MockLocationTargetPin? {
        try? MockLocationTargetPin(fingerprint: targetFingerprint)
    }

    var stablePin: MockLocationTargetPin? {
        guard let stableTargetFingerprint else { return nil }
        return try? MockLocationTargetPin(fingerprint: stableTargetFingerprint)
    }

    func validated() throws -> Self {
        guard (1...Self.schemaVersion).contains(schema) else {
            throw MockLocationJournalError.unsupportedSchema
        }
        _ = try MockLocationTargetPin(fingerprint: targetFingerprint)
        guard (schema >= 3 || transport == .usb),
              (transport != .wifi || setMode == .liveSession) else {
            throw MockLocationJournalError.invalidRecord
        }
        if schema == 1 {
            guard stableTargetFingerprint == nil,
                  setMode == .liveSession else {
                throw MockLocationJournalError.invalidRecord
            }
            switch state {
            case .pendingSet, .assumedActive, .pendingClear, .uncertain:
                break
            case .setAcknowledged, .assumedPersistent:
                throw MockLocationJournalError.invalidRecord
            }
        } else {
            guard let stableTargetFingerprint else { throw MockLocationJournalError.invalidRecord }
            _ = try MockLocationTargetPin(fingerprint: stableTargetFingerprint)
        }
        guard createdAt.timeIntervalSince1970 > 0,
              updatedAt.timeIntervalSince1970 > 0,
              updatedAt >= createdAt else { throw MockLocationJournalError.invalidRecord }
        switch state {
        case .pendingSet:
            guard !requestDispatched else { throw MockLocationJournalError.invalidRecord }
        case .pendingClear:
            break
        case .setAcknowledged, .assumedActive, .assumedPersistent, .uncertain:
            guard requestDispatched else { throw MockLocationJournalError.invalidRecord }
        }
        if state == .assumedPersistent || state == .setAcknowledged {
            guard setMode == .persistentUntilClearOrReboot,
                  stableTargetFingerprint != nil else {
                throw MockLocationJournalError.invalidRecord
            }
        } else if state == .assumedActive {
            guard setMode == .liveSession else {
                throw MockLocationJournalError.invalidRecord
            }
        }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schema
        case state
        case targetFingerprint
        case stableTargetFingerprint
        case setMode
        case transport
        case requestDispatched
        case createdAt
        case updatedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schema = try container.decode(Int.self, forKey: .schema)
        state = try container.decode(State.self, forKey: .state)
        targetFingerprint = try container.decode(String.self, forKey: .targetFingerprint)
        stableTargetFingerprint = try container.decodeIfPresent(
            String.self,
            forKey: .stableTargetFingerprint
        )
        setMode = try container.decodeIfPresent(MockLocationSetMode.self, forKey: .setMode)
            ?? .liveSession
        transport = try container.decodeIfPresent(MockLocationTransport.self, forKey: .transport)
            ?? .usb
        requestDispatched = try container.decode(Bool.self, forKey: .requestDispatched)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    }
}

struct MockLocationJournalClient {
    let load: () throws -> MockLocationJournalRecord?
    let write: (MockLocationJournalRecord) throws -> Void
    let remove: () throws -> Void
}

private final class MockLocationInMemoryJournal: @unchecked Sendable {
    private let lock = NSLock()
    private var record: MockLocationJournalRecord?

    init(record: MockLocationJournalRecord?) {
        self.record = record
    }

    var client: MockLocationJournalClient {
        MockLocationJournalClient(
            load: {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.record
            },
            write: { record in
                _ = try record.validated()
                self.lock.lock()
                self.record = record
                self.lock.unlock()
            },
            remove: {
                self.lock.lock()
                self.record = nil
                self.lock.unlock()
            }
        )
    }
}

struct MockLocationJournalStore {
    static let maximumRecordBytes = 65_536

    let fileURL: URL
    let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func applicationSupport(fileManager: FileManager = .default) throws -> Self {
        guard let root = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw MockLocationJournalError.cannotCreateDirectory
        }
        return Self(
            fileURL: root
                .appendingPathComponent("YIOS-KIT", isDirectory: true)
                .appendingPathComponent("MockLocation", isDirectory: true)
                .appendingPathComponent("state.json", isDirectory: false),
            fileManager: fileManager
        )
    }

    var client: MockLocationJournalClient {
        MockLocationJournalClient(
            load: { try load() },
            write: { try write($0) },
            remove: { try remove() }
        )
    }

    func load() throws -> MockLocationJournalRecord? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        } catch {
            throw MockLocationJournalError.cannotRead
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MockLocationJournalError.notRegularFile
        }
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0, byteCount <= Self.maximumRecordBytes else {
            throw MockLocationJournalError.recordTooLarge
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [])
        } catch {
            throw MockLocationJournalError.cannotRead
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(MockLocationJournalRecord.self, from: data).validated()
        } catch let error as MockLocationJournalError {
            throw error
        } catch {
            throw MockLocationJournalError.invalidRecord
        }
    }

    func write(_ record: MockLocationJournalRecord) throws {
        _ = try record.validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw MockLocationJournalError.cannotWrite
        }
        guard data.count <= Self.maximumRecordBytes else {
            throw MockLocationJournalError.recordTooLarge
        }

        let directory = fileURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o700))],
                ofItemAtPath: directory.path
            )
        } catch {
            throw MockLocationJournalError.cannotCreateDirectory
        }

        let temporaryURL = directory.appendingPathComponent(".state-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: data,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else { throw MockLocationJournalError.cannotWrite }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.synchronize()
            try handle.close()
            guard Darwin.rename(temporaryURL.path, fileURL.path) == 0 else {
                throw MockLocationJournalError.cannotWrite
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o600))],
                ofItemAtPath: fileURL.path
            )
            Self.synchronizeDirectory(directory)
        } catch let error as MockLocationJournalError {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw MockLocationJournalError.cannotWrite
        }
    }

    func remove() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        do {
            try fileManager.removeItem(at: fileURL)
            Self.synchronizeDirectory(fileURL.deletingLastPathComponent())
        } catch {
            throw MockLocationJournalError.cannotWrite
        }
    }

    private static func synchronizeDirectory(_ directory: URL) {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { return }
        _ = Darwin.fsync(descriptor)
        _ = Darwin.close(descriptor)
    }
}

// MARK: - Bundled backend resolution and command contract

enum MockLocationBackendResolutionError: LocalizedError, Equatable {
    case missing
    case unsafePath
    case notExecutable
    case unsafePermissions

    var errorDescription: String? {
        switch self {
        case .missing: return "The app-private Mock Location backend is missing from this build."
        case .unsafePath: return "The bundled backend path could not be verified."
        case .notExecutable: return "The bundled Mock Location backend is not executable."
        case .unsafePermissions: return "The bundled Mock Location backend has unsafe write permissions."
        }
    }
}

struct MockLocationBackendDescriptor: Equatable {
    let executableURL: URL
}

enum MockLocationBackendResolver {
    static let relativeExecutablePath = "Contents/Helpers/YIOSLocation/yios-location-backend"

    static func resolve(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) -> Result<MockLocationBackendDescriptor, MockLocationBackendResolutionError> {
        let candidate = bundleURL.appendingPathComponent(relativeExecutablePath, isDirectory: false)
        guard fileManager.fileExists(atPath: candidate.path) else { return .failure(.missing) }

        let resolvedBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedCandidate.hasPrefix(resolvedBundle + "/") else { return .failure(.unsafePath) }

        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(atPath: candidate.path)
        } catch {
            return .failure(.missing)
        }
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            return .failure(.unsafePath)
        }
        guard fileManager.isExecutableFile(atPath: candidate.path) else {
            return .failure(.notExecutable)
        }
        let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
        guard permissions & 0o022 == 0 else { return .failure(.unsafePermissions) }
        return .success(MockLocationBackendDescriptor(executableURL: candidate))
    }
}

enum MockLocationBackendOperation: String, Equatable {
    case probe
    case set
    case setPersistent = "set-persistent"
    case clear
    case revealDeveloperMode = "reveal-developer-mode"
    case enableWiFi = "enable-wifi"
}

struct MockLocationBackendCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
    let initialRequest: Data
    let operation: MockLocationBackendOperation
}

enum MockLocationCommandBuilder {
    static func probe(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget,
        transport: MockLocationTransport = .usb
    ) -> MockLocationBackendCommand {
        command(backend: backend, operation: .probe, target: target, coordinate: nil, transport: transport)
    }

    static func set(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget,
        coordinate: MockLocationCoordinate,
        transport: MockLocationTransport = .usb
    ) -> MockLocationBackendCommand {
        command(backend: backend, operation: .set, target: target, coordinate: coordinate, transport: transport)
    }

    static func setPersistent(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget,
        coordinate: MockLocationCoordinate
    ) -> MockLocationBackendCommand {
        command(
            backend: backend,
            operation: .setPersistent,
            target: target,
            coordinate: coordinate
        )
    }

    static func clear(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget,
        transport: MockLocationTransport = .usb
    ) -> MockLocationBackendCommand {
        command(backend: backend, operation: .clear, target: target, coordinate: nil, transport: transport)
    }

    static func enableWiFi(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget
    ) -> MockLocationBackendCommand {
        command(backend: backend, operation: .enableWiFi, target: target, coordinate: nil)
    }

    static func revealDeveloperMode(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget
    ) -> MockLocationBackendCommand {
        command(
            backend: backend,
            operation: .revealDeveloperMode,
            target: target,
            coordinate: nil
        )
    }

    private static func command(
        backend: MockLocationBackendDescriptor,
        operation: MockLocationBackendOperation,
        target: MockLocationExactTarget,
        coordinate: MockLocationCoordinate?,
        transport: MockLocationTransport = .usb
    ) -> MockLocationBackendCommand {
        var request: [String: Any] = [
            "udid": target.udid,
            "expectedProductType": target.productType
        ]
        if operation == .revealDeveloperMode || operation == .enableWiFi || transport == .wifi {
            request["expectedECID"] = target.ecid
        }
        if transport == .wifi { request["transport"] = transport.rawValue }
        if let coordinate {
            request["latitude"] = coordinate.latitude
            request["longitude"] = coordinate.longitude
        }
        var requestData = (try? JSONSerialization.data(
            withJSONObject: request,
            options: [.sortedKeys]
        )) ?? Data()
        requestData.append(0x0A)
        return MockLocationBackendCommand(
            executableURL: backend.executableURL,
            arguments: [operation.rawValue],
            initialRequest: requestData,
            operation: operation
        )
    }
}

// MARK: - Structured backend protocol

enum MockLocationBackendErrorCode: String, Equatable {
    case invalidRequest = "invalid_request"
    case targetNotFound = "target_not_found"
    case targetMismatch = "target_mismatch"
    case pairingRequired = "pairing_required"
    case developerModeRequired = "developer_mode_required"
    case unlockRequired = "unlock_required"
    case developerModeRevealFailed = "developer_mode_reveal_failed"
    case developerDiskImageRequired = "developer_disk_image_required"
    case tunnelUnavailable = "tunnel_unavailable"
    case developerServiceUnavailable = "developer_service_unavailable"
    case permissionDenied = "permission_denied"
    case timeout
    case connectionLost = "connection_lost"
    case internalFailure = "internal_failure"

    var readinessIssue: MockLocationReadinessIssue {
        switch self {
        case .targetNotFound, .targetMismatch: return .targetChanged
        case .pairingRequired: return .pairingRequired
        case .developerModeRequired: return .developerModeRequired
        case .unlockRequired: return .unlockRequired
        case .developerModeRevealFailed: return .developerModeRevealFailed
        case .developerDiskImageRequired: return .developerDiskImageRequired
        case .tunnelUnavailable, .connectionLost: return .tunnelUnavailable
        case .developerServiceUnavailable: return .developerServiceUnavailable
        case .permissionDenied: return .permissionDenied
        case .timeout: return .probeTimedOut
        case .invalidRequest: return .backendProtocolError
        case .internalFailure: return .backendFailure
        }
    }
}

enum MockLocationBackendEventKind: Equatable {
    case hello
    case attested
    case ready
    case requestDispatched
    case active
    case clearSent
    case developerModeOptionRequested
    case developerModeAlreadyEnabled
    case wifiEnabled
    case error
}

struct MockLocationBackendEvent: Equatable {
    let kind: MockLocationBackendEventKind
    let protocolVersion: Int?
    let backendVersion: String?
    let productType: String?
    let errorCode: MockLocationBackendErrorCode?
    var setMode: MockLocationSetMode? = nil
}

enum MockLocationBackendProtocolError: Error, Equatable {
    case invalidUTF8
    case invalidJSON
    case invalidEvent
    case unsupportedProtocol
    case unknownErrorCode
    case lineTooLong
    case outputTooLarge
}

enum MockLocationBackendEventParser {
    static let supportedProtocolVersion = 1

    static func parse(line: String) -> Result<MockLocationBackendEvent, MockLocationBackendProtocolError> {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dictionary = object as? [String: Any] else {
            return .failure(.invalidJSON)
        }
        guard let rawEvent = dictionary["event"] as? String else {
            return .failure(.invalidEvent)
        }
        let normalizedEvent = rawEvent
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }

        let protocolVersion = integer(
            dictionary["protocol"] ?? dictionary["protocol_version"] ?? dictionary["protocolVersion"]
        )
        let backendVersion = safeVersion(
            dictionary["backend_version"] as? String ?? dictionary["backendVersion"] as? String
        )
        let productType = safeProductType(
            dictionary["product_type"] as? String ?? dictionary["productType"] as? String
        )
        let setMode: MockLocationSetMode?
        if let rawPersistence = dictionary["persistence"] as? String {
            guard rawPersistence == "experimental" else {
                return .failure(.invalidEvent)
            }
            setMode = .persistentUntilClearOrReboot
        } else {
            setMode = nil
        }

        switch normalizedEvent {
        case "hello", "version":
            guard protocolVersion == supportedProtocolVersion else {
                return .failure(.unsupportedProtocol)
            }
            return .success(MockLocationBackendEvent(
                kind: .hello,
                protocolVersion: protocolVersion,
                backendVersion: backendVersion,
                productType: nil,
                errorCode: nil
            ))
        case "attested", "accepted":
            guard productType != nil else { return .failure(.invalidEvent) }
            return .success(MockLocationBackendEvent(
                kind: .attested,
                protocolVersion: nil,
                backendVersion: nil,
                productType: productType,
                errorCode: nil
            ))
        case "ready", "readiness":
            if normalizedEvent == "readiness",
               let rawState = dictionary["state"] as? String ?? dictionary["readiness"] as? String,
               rawState.lowercased() != "ready" {
                return .failure(.invalidEvent)
            }
            return .success(MockLocationBackendEvent(
                kind: .ready,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "phase":
            guard let rawPhase = dictionary["phase"] as? String else {
                return .failure(.invalidEvent)
            }
            let phase = rawPhase.lowercased().filter { $0.isLetter || $0.isNumber }
            switch phase {
            case "attested", "accepted":
                guard productType != nil else { return .failure(.invalidEvent) }
                return .success(MockLocationBackendEvent(
                    kind: .attested,
                    protocolVersion: nil,
                    backendVersion: nil,
                    productType: productType,
                    errorCode: nil
                ))
            case "ready":
                return .success(MockLocationBackendEvent(
                    kind: .ready,
                    protocolVersion: nil,
                    backendVersion: nil,
                    productType: nil,
                    errorCode: nil
                ))
            case "active":
                return .success(MockLocationBackendEvent(
                    kind: .active,
                    protocolVersion: nil,
                    backendVersion: nil,
                    productType: nil,
                    errorCode: nil,
                    setMode: setMode
                ))
            default:
                return .failure(.invalidEvent)
            }
        case "requestdispatched":
            return .success(MockLocationBackendEvent(
                kind: .requestDispatched,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "active":
            return .success(MockLocationBackendEvent(
                kind: .active,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil,
                setMode: setMode
            ))
        case "clearsent", "resetrequestsent":
            return .success(MockLocationBackendEvent(
                kind: .clearSent,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "developermodeoptionrequested":
            guard dictionary["status"] as? String == "settingsOptionExpected" else {
                return .failure(.invalidEvent)
            }
            return .success(MockLocationBackendEvent(
                kind: .developerModeOptionRequested,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "developermodealreadyenabled":
            guard dictionary["status"] as? String == "alreadyEnabled" else {
                return .failure(.invalidEvent)
            }
            return .success(MockLocationBackendEvent(
                kind: .developerModeAlreadyEnabled,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "wifienabled":
            guard dictionary["status"] as? String == "ok" else {
                return .failure(.invalidEvent)
            }
            return .success(MockLocationBackendEvent(
                kind: .wifiEnabled,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: nil
            ))
        case "error":
            guard let rawCode = dictionary["code"] as? String,
                  let code = MockLocationBackendErrorCode(rawValue: rawCode) else {
                return .failure(.unknownErrorCode)
            }
            return .success(MockLocationBackendEvent(
                kind: .error,
                protocolVersion: nil,
                backendVersion: nil,
                productType: nil,
                errorCode: code
            ))
        default:
            return .failure(.invalidEvent)
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func safeVersion(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 80,
              trimmed.unicodeScalars.allSatisfy({ scalar in
                scalar.value >= 0x20 && scalar.value <= 0x7E
              }) else { return nil }
        return trimmed
    }

    private static func safeProductType(_ value: String?) -> String? {
        MockLocationExactTarget.validatedProductType(value)
    }
}

struct MockLocationJSONLineAccumulator {
    static let maximumLineBytes = 16_384
    static let maximumOutputBytes = 65_536

    private(set) var pending = Data()
    private(set) var totalBytes = 0
    private(set) var terminalError: MockLocationBackendProtocolError?

    mutating func append(_ data: Data) -> [Result<MockLocationBackendEvent, MockLocationBackendProtocolError>] {
        guard terminalError == nil else { return [] }
        totalBytes += data.count
        guard totalBytes <= Self.maximumOutputBytes else {
            terminalError = .outputTooLarge
            pending.removeAll(keepingCapacity: false)
            return [.failure(.outputTooLarge)]
        }
        pending.append(data)
        var results: [Result<MockLocationBackendEvent, MockLocationBackendProtocolError>] = []
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending.prefix(upTo: newline)
            pending.removeSubrange(...newline)
            results.append(parseLine(Data(lineData)))
            if terminalError != nil { break }
        }
        if pending.count > Self.maximumLineBytes, terminalError == nil {
            terminalError = .lineTooLong
            pending.removeAll(keepingCapacity: false)
            results.append(.failure(.lineTooLong))
        }
        return results
    }

    mutating func finish() -> [Result<MockLocationBackendEvent, MockLocationBackendProtocolError>] {
        guard terminalError == nil, !pending.isEmpty else { return [] }
        let line = pending
        pending.removeAll(keepingCapacity: false)
        return [parseLine(line)]
    }

    private mutating func parseLine(_ rawData: Data) -> Result<MockLocationBackendEvent, MockLocationBackendProtocolError> {
        var data = rawData
        if data.last == 0x0D { data.removeLast() }
        guard !data.isEmpty else {
            terminalError = .invalidEvent
            return .failure(.invalidEvent)
        }
        guard data.count <= Self.maximumLineBytes else {
            terminalError = .lineTooLong
            return .failure(.lineTooLong)
        }
        guard let line = String(data: data, encoding: .utf8) else {
            terminalError = .invalidUTF8
            return .failure(.invalidUTF8)
        }
        let result = MockLocationBackendEventParser.parse(line: line)
        if case .failure(let error) = result { terminalError = error }
        return result
    }
}

// MARK: - Long-running backend process

enum MockLocationProcessStartError: Error, Equatable {
    case busy
    case launchFailed
    case initialRequestFailed
}

struct MockLocationProcessCompletion: Equatable {
    let exitStatus: Int32
    let timedOut: Bool
    let stderrObserved: Bool
    let protocolError: MockLocationBackendProtocolError?

    var completedCleanly: Bool {
        exitStatus == 0 && !timedOut && !stderrObserved && protocolError == nil
    }
}

@MainActor
final class MockLocationProcessCoordinator {
    typealias EventHandler = (UUID, MockLocationBackendEvent) -> Void
    typealias CompletionHandler = (UUID, MockLocationProcessCompletion) -> Void

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _stderrObserved = false
        private var _protocolError: MockLocationBackendProtocolError?
        private var _timedOut = false

        func observeStderr(_ data: Data) {
            guard data.contains(where: { byte in
                byte != 0x0A && byte != 0x0D && byte != 0x09 && byte != 0x20
            }) else { return }
            lock.lock()
            _stderrObserved = true
            lock.unlock()
        }

        func observeProtocolError(_ error: MockLocationBackendProtocolError) {
            lock.lock()
            if _protocolError == nil { _protocolError = error }
            lock.unlock()
        }

        func markTimedOut() {
            lock.lock()
            _timedOut = true
            lock.unlock()
        }

        func result(exitStatus: Int32) -> MockLocationProcessCompletion {
            lock.lock()
            defer { lock.unlock() }
            return MockLocationProcessCompletion(
                exitStatus: exitStatus,
                timedOut: _timedOut,
                stderrObserved: _stderrObserved,
                protocolError: _protocolError
            )
        }
    }

    private final class Session {
        let id: UUID
        let operation: MockLocationBackendOperation
        let process: Process
        let capture: Capture
        var standardInput: FileHandle?
        var deadline: DispatchSourceTimer?

        init(
            id: UUID,
            operation: MockLocationBackendOperation,
            process: Process,
            capture: Capture,
            standardInput: FileHandle?
        ) {
            self.id = id
            self.operation = operation
            self.process = process
            self.capture = capture
            self.standardInput = standardInput
        }
    }

    private let readQueue = DispatchQueue(
        label: "local.minthanhtut.YIOS-KIT.mock-location.read",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private var activeSession: Session?

    var hasActiveProcess: Bool { activeSession != nil }
    var activeOperation: MockLocationBackendOperation? { activeSession?.operation }

    @discardableResult
    func start(
        _ command: MockLocationBackendCommand,
        handshakeTimeout: TimeInterval = 180,
        onEvent: @escaping EventHandler,
        completion: @escaping CompletionHandler
    ) -> Result<UUID, MockLocationProcessStartError> {
        guard activeSession == nil else { return .failure(.busy) }

        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let inputPipe = Pipe()
        let capture = Capture()
        let identifier = UUID()

        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.environment = [
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "TMPDIR": NSTemporaryDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "LC_ALL": "C",
            "LANG": "C",
            "PYTHONUNBUFFERED": "1"
        ]
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = inputPipe

        let readGroup = DispatchGroup()
        process.terminationHandler = { _ in }
        do {
            try process.run()
        } catch {
            return .failure(.launchFailed)
        }
        do {
            try inputPipe.fileHandleForWriting.write(contentsOf: command.initialRequest)
            if command.operation != .set {
                try inputPipe.fileHandleForWriting.close()
            }
        } catch {
            Self.stopProcess(process)
            try? inputPipe.fileHandleForWriting.close()
            return .failure(.initialRequestFailed)
        }

        let session = Session(
            id: identifier,
            operation: command.operation,
            process: process,
            capture: capture,
            standardInput: command.operation == .set ? inputPipe.fileHandleForWriting : nil
        )
        activeSession = session

        readGroup.enter()
        readQueue.async { [weak self, weak process] in
            defer { readGroup.leave() }
            guard let self, let process else { return }
            var accumulator = MockLocationJSONLineAccumulator()
            while true {
                // `read(upToCount:)` may wait for the requested byte count or EOF on
                // a pipe. A successful Set process intentionally stays alive after
                // its `active` acknowledgement, so waiting for EOF would deadlock the
                // state machine and hide every acknowledgement until Clear/timeout.
                // `availableData` blocks only until some bytes (or EOF) are available,
                // which preserves line streaming for the long-lived backend session.
                let chunk = stdoutPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                self.deliver(
                    accumulator.append(chunk),
                    sessionID: identifier,
                    capture: capture,
                    onEvent: onEvent
                )
            }
            self.deliver(
                accumulator.finish(),
                sessionID: identifier,
                capture: capture,
                onEvent: onEvent
            )
            process.waitUntilExit()
        }

        readGroup.enter()
        readQueue.async {
            defer { readGroup.leave() }
            while true {
                let chunk = stderrPipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                capture.observeStderr(chunk)
            }
        }

        readGroup.notify(queue: .main) { [weak self, weak process] in
            guard let self, let process else { return }
            let result = capture.result(exitStatus: process.terminationStatus)
            if self.activeSession?.id == identifier {
                self.activeSession?.deadline?.cancel()
                self.activeSession?.standardInput.map { try? $0.close() }
                self.activeSession = nil
            }
            completion(identifier, result)
        }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, handshakeTimeout))
        timer.setEventHandler { [weak self, weak process, weak capture] in
            guard let self, let process, let capture,
                  self.activeSession?.id == identifier else { return }
            capture.markTimedOut()
            Self.stopProcess(process)
            self.activeSession?.deadline?.cancel()
        }
        session.deadline = timer
        timer.resume()

        return .success(identifier)
    }

    func sendClear(to sessionID: UUID) -> Bool {
        guard let session = activeSession,
              session.id == sessionID,
              session.operation == .set,
              let input = session.standardInput else { return false }
        do {
            try input.write(contentsOf: Data("{\"command\":\"clear\"}\n".utf8))
            try input.close()
            session.standardInput = nil
            return true
        } catch {
            return false
        }
    }

    func beginClearDeadline(for sessionID: UUID, timeout: TimeInterval = 45) {
        guard let session = activeSession, session.id == sessionID else { return }
        session.deadline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, timeout))
        timer.setEventHandler { [weak self, weak process = session.process, weak capture = session.capture] in
            guard let self, let process, let capture,
                  self.activeSession?.id == sessionID else { return }
            capture.markTimedOut()
            Self.stopProcess(process)
            self.activeSession?.deadline?.cancel()
        }
        session.deadline = timer
        timer.resume()
    }

    func beginPersistentTeardownDeadline(for sessionID: UUID, timeout: TimeInterval = 45) {
        guard let session = activeSession,
              session.id == sessionID,
              session.operation == .setPersistent else { return }
        session.deadline?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + max(1, timeout))
        timer.setEventHandler { [weak self, weak process = session.process, weak capture = session.capture] in
            guard let self, let process, let capture,
                  self.activeSession?.id == sessionID else { return }
            capture.markTimedOut()
            Self.stopProcess(process)
            self.activeSession?.deadline?.cancel()
        }
        session.deadline = timer
        timer.resume()
    }

    func acknowledgeActive(for sessionID: UUID) {
        guard let session = activeSession,
              session.id == sessionID,
              session.operation == .set else { return }
        session.deadline?.cancel()
        session.deadline = nil
    }

    private nonisolated static func stopProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let identifier = process.processIdentifier
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2) {
            guard process.isRunning else { return }
            _ = Darwin.kill(identifier, SIGKILL)
        }
    }

    private nonisolated func deliver(
        _ results: [Result<MockLocationBackendEvent, MockLocationBackendProtocolError>],
        sessionID: UUID,
        capture: Capture,
        onEvent: @escaping EventHandler
    ) {
        for result in results {
            switch result {
            case .success(let event):
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.activeSession?.id == sessionID else { return }
                    onEvent(sessionID, event)
                }
            case .failure(let error):
                capture.observeProtocolError(error)
            }
        }
    }
}

// MARK: - Feature controller

private enum MockLocationPreflightFailure: Error {
    case timedOut
    case targetChanged
    case pairingRequired
    case hostBusy(MockLocationHostBlockReason)
    case unavailable
}

struct MockLocationFreshEvidence {
    let snapshot: DeviceSnapshot
    let pairingAndTrustVerified: Bool
}

enum MockLocationSafetyRecordMatch: Equatable {
    case none
    case connectedUnavailable
    case exactConnection
    case sameStableIPhoneNewConnection
    case differentStableIPhone
}

struct MockLocationForgetRecordContext: Equatable {
    let recordedTargetToken: String
    let connectedTargetToken: String
}

@MainActor
final class MockLocationController: ObservableObject {
    private enum ClearTargetMatch {
        case exact
        case reconnected(originalConnectionPin: MockLocationTargetPin)
        case unpinned
    }

    struct HostCallbacks {
        let currentSnapshot: () -> DeviceSnapshot
        let hostGate: () -> MockLocationHostGate
        let requestFreshEvidence: (@escaping (MockLocationFreshEvidence) -> Void) -> Void
        let confirmForgetUnavailableRecord: (MockLocationForgetRecordContext) -> Bool
        let confirmDeveloperModeOptionRequest: (MockLocationExactTarget) -> Bool
        let confirmSet: (
            MockLocationExactTarget,
            MockLocationCoordinate,
            MockLocationSetMode
        ) -> Bool
        let confirmUnpinnedClear: (MockLocationExactTarget) -> Bool
        let confirmReconnectedClear: (
            MockLocationExactTarget,
            MockLocationTargetPin
        ) -> Bool
        var confirmEnableWiFi: (MockLocationExactTarget) -> Bool = { _ in false }
    }

    private struct ActiveRun {
        let id: UUID
        let operation: MockLocationBackendOperation
        let target: MockLocationExactTarget
        let createdAt: Date
        var transport: MockLocationTransport = .usb
        var sawHello = false
        var backendVersion: String?
        var attested = false
        var ready = false
        var requestDispatched = false
        var activeAcknowledged = false
        var clearRequested = false
        var clearRequestDispatched = false
        var clearSent = false
        var developerModeOptionRequested = false
        var developerModeAlreadyEnabled = false
        var wifiEnabled = false
        var protocolOrderInvalid = false
        var backendError: MockLocationBackendErrorCode?
    }

    @Published private(set) var readiness: MockLocationReadinessState = .notChecked
    @Published private(set) var simulationKnowledge: MockLocationSimulationKnowledge = .notRequested
    @Published private(set) var statusText = "Mock Location has not been checked"
    @Published private(set) var detailText = "Check the exact USB target, pairing, Developer Mode, developer services, and tunnel before sending a location request."
    @Published private(set) var lastError: String?
    @Published private(set) var isBusy = false
    @Published private(set) var blocksDeviceMutation = false
    @Published private(set) var isAssumedActive = false
    @Published private(set) var reviewRequired = false
    @Published private(set) var selectedTransport: MockLocationTransport = .usb

    private let resolveBackend: () -> Result<MockLocationBackendDescriptor, MockLocationBackendResolutionError>
    private let journal: MockLocationJournalClient
    private let processCoordinator: MockLocationProcessCoordinator
    private let now: () -> Date
    private let persistentTeardownTimeout: TimeInterval
    private var host: HostCallbacks?
    private var journalRecord: MockLocationJournalRecord?
    private var activeRun: ActiveRun?
    private var preflightID: UUID?
    private var readinessTransport: MockLocationTransport = .usb

    init(
        resolveBackend: @escaping () -> Result<MockLocationBackendDescriptor, MockLocationBackendResolutionError>,
        journal: MockLocationJournalClient,
        processCoordinator: MockLocationProcessCoordinator? = nil,
        persistentTeardownTimeout: TimeInterval = 45,
        now: @escaping () -> Date = Date.init
    ) {
        self.resolveBackend = resolveBackend
        self.journal = journal
        self.processCoordinator = processCoordinator ?? MockLocationProcessCoordinator()
        self.persistentTeardownTimeout = max(1, persistentTeardownTimeout)
        self.now = now

        do {
            if let record = try journal.load() {
                journalRecord = record
                selectedTransport = record.transport
                if record.state == .assumedPersistent,
                   record.setMode == .persistentUntilClearOrReboot,
                   let pin = record.pin {
                    simulationKnowledge = .assumedPersistent(
                        pin: pin,
                        requestedAt: record.updatedAt
                    )
                    statusText = "Persistent location may still be active"
                    detailText = "A previous experimental Set completed cleanly without Clear. Reconnect the same stable iPhone and send Return to Real Location. Rebooting is expected to restore phone-side GPS, but the app safety record still requires this explicit reset."
                } else {
                    simulationKnowledge = .uncertain(
                        pin: record.pin,
                        reason: .recoveredAfterInterruption
                    )
                    statusText = "Simulation state needs review"
                    detailText = "The previous session ended without a recorded reset. Reconnect the same target and choose Return to Real Location."
                }
            }
        } catch {
            simulationKnowledge = .uncertain(pin: nil, reason: .journalUnreadable)
            statusText = "Simulation state needs review"
            detailText = MockLocationUncertaintyReason.journalUnreadable.userDescription
        }
        publishDerivedState()
    }

    convenience init(
        bundleURL: URL = Bundle.main.bundleURL,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init
    ) {
        let journalClient: MockLocationJournalClient
        do {
            journalClient = try MockLocationJournalStore
                .applicationSupport(fileManager: fileManager)
                .client
        } catch {
            journalClient = MockLocationJournalClient(
                load: { throw MockLocationJournalError.cannotCreateDirectory },
                write: { _ in throw MockLocationJournalError.cannotCreateDirectory },
                remove: { throw MockLocationJournalError.cannotCreateDirectory }
            )
        }
        self.init(
            resolveBackend: {
                MockLocationBackendResolver.resolve(bundleURL: bundleURL, fileManager: fileManager)
            },
            journal: journalClient,
            now: now
        )
    }

    static func offlineFixture(
        recoveredRecord: MockLocationJournalRecord? = nil
    ) -> MockLocationController {
        let memoryJournal = MockLocationInMemoryJournal(record: recoveredRecord)
        return MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: memoryJournal.client,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
    }

    func configureHost(_ callbacks: HostCallbacks) {
        host = callbacks
        refreshLocalState()
    }

    var connectedTargetToken: String? {
        if let run = liveWiFiRun { return run.target.pin.displayToken }
        guard let snapshot = host?.currentSnapshot() else { return nil }
        return MockLocationExactTarget.pin(for: snapshot)?.displayToken
    }

    var recordedTargetToken: String? {
        journalRecord?.pin?.displayToken ?? simulationKnowledge.pin?.displayToken
    }

    var safetyRecordMatch: MockLocationSafetyRecordMatch {
        guard journalRecord != nil else { return .none }
        guard let snapshot = host?.currentSnapshot(),
              let target = try? MockLocationExactTarget(snapshot: snapshot) else {
            return .connectedUnavailable
        }
        return safetyRecordMatch(for: target)
    }

    var shouldOfferForgetUnavailableRecord: Bool {
        safetyRecordMatch == .differentStableIPhone
    }

    var canForgetUnavailableRecord: Bool {
        guard shouldOfferForgetUnavailableRecord,
              !isBusy,
              activeRun == nil,
              !processCoordinator.hasActiveProcess,
              let host,
              host.hostGate().permitsLocationWork else { return false }
        return true
    }

    var canCheckReadiness: Bool {
        guard !isBusy, !isAssumedActive, !reviewRequired,
              let host, host.hostGate().permitsLocationWork,
              (try? MockLocationExactTarget(snapshot: host.currentSnapshot())) != nil,
              case .success = resolveBackend() else { return false }
        return true
    }

    var canSelectTransport: Bool {
        !isBusy && !isAssumedActive && !reviewRequired &&
        activeRun == nil && !processCoordinator.hasActiveProcess
    }

    func selectTransport(_ transport: MockLocationTransport) {
        guard canSelectTransport, transport != selectedTransport else { return }
        selectedTransport = transport
        readiness = .notChecked
        lastError = nil
        statusText = "Check \(transport.displayName) readiness"
        detailText = transport == .wifi
            ? "Connect and Trust the iPhone over USB first. Enable Wi-Fi, then check the separate Wi-Fi developer connection before setting a location."
            : "Connect the iPhone over USB and check the developer session before setting a location."
        refreshLocalState()
    }

    var canEnableWiFi: Bool {
        selectedTransport == .wifi && canCheckReadiness &&
        activeRun == nil && !processCoordinator.hasActiveProcess
    }

    // This is the same authenticated Network channel that accepted Set. USB
    // discovery is deliberately irrelevant here; Clear must never retarget a
    // newly attached phone or require the cable it is designed to replace.
    private var liveWiFiRun: ActiveRun? {
        guard let run = activeRun,
              run.operation == .set, run.transport == .wifi,
              run.attested, run.ready, run.activeAcknowledged,
              !run.clearRequested, !run.clearSent, !run.protocolOrderInvalid,
              run.backendError == nil,
              processCoordinator.activeOperation == .set else { return nil }
        return run
    }

    var isWiFiSessionActive: Bool { liveWiFiRun != nil }
    var liveWiFiProductType: String? { liveWiFiRun?.target.productType }

    var shouldOfferDeveloperModeOptionRequest: Bool {
        guard let host,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()) else {
            return false
        }
        if hasLocationSafetyRecord {
            return targetMatchesLocationSafetyRecord(target)
        }
        if case .failed(.developerModeRequired) = readiness { return true }
        return false
    }

    var canRequestDeveloperModeOption: Bool {
        guard !isBusy,
              let host,
              host.hostGate().permitsLocationWork,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              case .success = resolveBackend(),
              !processCoordinator.hasActiveProcess else { return false }

        if hasLocationSafetyRecord {
            return targetMatchesLocationSafetyRecord(target)
        }
        guard !isAssumedActive, !reviewRequired else { return false }
        if case .failed(.developerModeRequired) = readiness { return true }
        return false
    }

    var canSetLocation: Bool {
        guard !isBusy, !isAssumedActive, !reviewRequired,
              let host, host.hostGate().permitsLocationWork,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              readinessTransport == selectedTransport,
              readiness.isReady(for: target.pin) else { return false }
        switch simulationKnowledge {
        case .notRequested, .resetRequestSent:
            return true
        case .preparing, .assumedActive, .assumedPersistent, .clearing, .uncertain:
            return false
        }
    }

    var isAssumedPersistent: Bool {
        if case .assumedPersistent = simulationKnowledge { return true }
        return false
    }

    var canReturnToRealLocation: Bool {
        guard !isBusy, let host, host.hostGate().permitsLocationWork else { return false }
        if liveWiFiRun != nil { return true }
        guard
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              let match = clearTargetMatch(for: target) else { return false }
        switch simulationKnowledge {
        case .preparing, .clearing:
            return false
        case .assumedActive, .assumedPersistent, .notRequested, .resetRequestSent, .uncertain:
            break
        }
        if processCoordinator.hasActiveProcess {
            guard case .exact = match, let run = activeRun,
                  run.operation == .set, run.target.pin == target.pin,
                  run.backendError == nil, !run.protocolOrderInvalid,
                  processCoordinator.activeOperation == .set else { return false }
            return true
        }
        switch match {
        case .exact, .reconnected, .unpinned:
            if case .success = resolveBackend() { return true }
            return false
        }
    }

    func refreshLocalState() {
        guard let host else { return }
        let snapshot = host.currentSnapshot()

        if liveWiFiRun != nil {
            // USB removal or another USB device cannot change the target of an
            // established Network session. Its backend watches tunnel closure.
            return
        }

        if isAssumedPersistent {
            if let expectedStablePin = journalRecord?.stablePin,
               snapshot.deviceCount == 1,
               let observedStablePin = MockLocationExactTarget.stablePin(for: snapshot) {
                if observedStablePin != expectedStablePin {
                    readiness = .blocked(.targetChanged, detail: nil)
                    statusText = "A different iPhone is connected"
                    detailText = "The saved safety record belongs to another stable iPhone identity. USB-port changes alone are allowed; this ECID, UDID, and product fingerprint does not match. Reconnect the recorded phone to Clear, or explicitly forget the local record if that iPhone is permanently unavailable."
                    lastError = "The connected iPhone does not match the stable identity in the saved Mock Location safety record."
                } else if case .blocked(.targetChanged, _) = readiness {
                    readiness = .notChecked
                    statusText = "Persistent location is assumed active"
                    detailText = "The original stable iPhone is connected. Use Return to Real Location; a changed USB connection requires two fresh Trust checks and explicit confirmation."
                    lastError = nil
                }
            }
        } else if (isAssumedActive || reviewRequired),
                  let expectedPin = simulationKnowledge.pin,
                  MockLocationExactTarget.pin(for: snapshot) != expectedPin {
            transitionToUncertain(pin: expectedPin, reason: .targetChanged)
        }

        if case .ready(let readyPin, _, _) = readiness,
           MockLocationExactTarget.pin(for: snapshot) != readyPin {
            readiness = .notChecked
        }

        guard !isBusy else { return }
        if let reason = host.hostGate().blockReason {
            if !isAssumedActive && !reviewRequired {
                readiness = .blocked(.hostBusy, detail: reason.userDescription)
            }
            return
        }
        do {
            _ = try MockLocationExactTarget(snapshot: snapshot)
        } catch let error as MockLocationTargetError {
            if !isAssumedActive && !reviewRequired {
                readiness = .blocked(.targetNotEligible, detail: error.errorDescription)
            }
            return
        } catch {
            if !isAssumedActive && !reviewRequired {
                readiness = .blocked(.targetNotEligible, detail: nil)
            }
            return
        }
        if case .failure = resolveBackend(), !isAssumedActive && !reviewRequired {
            readiness = .blocked(.helperUnavailable, detail: nil)
        } else if case .blocked = readiness,
                  !isAssumedActive,
                  !reviewRequired {
            readiness = .notChecked
        }
    }

    func checkReadiness() {
        lastError = nil
        guard let host else {
            failReadiness(.backendFailure)
            return
        }
        guard !isBusy, !isAssumedActive, !reviewRequired else { return }
        guard host.hostGate().permitsLocationWork else {
            readiness = .blocked(.hostBusy, detail: host.hostGate().blockReason?.userDescription)
            return
        }
        let target: MockLocationExactTarget
        do {
            target = try MockLocationExactTarget(snapshot: host.currentSnapshot())
        } catch let error as MockLocationTargetError {
            readiness = .blocked(.targetNotEligible, detail: error.errorDescription)
            lastError = error.errorDescription
            return
        } catch {
            readiness = .blocked(.targetNotEligible, detail: nil)
            return
        }
        guard case .success(let backend) = resolveBackend() else {
            failReadiness(.helperUnavailable)
            return
        }

        isBusy = true
        readiness = .checking
        statusText = "Checking Mock Location readiness…"
        detailText = "This probe opens developer services for the exact target but does not send a location request."
        publishDerivedState()

        requestPreflight(expected: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let freshTarget):
                self.startProbe(backend: backend, target: freshTarget)
            case .failure(let failure):
                self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: false)
            }
        }
    }

    func requestDeveloperModeOption() {
        lastError = nil
        guard canRequestDeveloperModeOption,
              let host,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              case .success(let backend) = resolveBackend() else { return }

        isBusy = true
        statusText = "Verifying the exact iPhone…"
        detailText = "No Developer Mode request is sent until identity, USB location, pairing, and Trust are freshly verified."
        publishDerivedState()

        requestPreflight(expected: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let freshTarget):
                guard let host = self.host,
                      host.confirmDeveloperModeOptionRequest(freshTarget) else {
                    self.isBusy = false
                    self.statusText = "Developer Mode Settings request was cancelled"
                    self.detailText = "No Settings-option request was sent. Developer Mode was not enabled and the iPhone was not restarted."
                    self.publishDerivedState()
                    return
                }
                self.statusText = "Rechecking the confirmed iPhone…"
                self.detailText = "A second exact-target and Trust check is required after confirmation."
                self.requestPreflight(expected: freshTarget) { [weak self] secondResult in
                    guard let self else { return }
                    switch secondResult {
                    case .success(let confirmedTarget):
                        self.startDeveloperModeOptionRequest(
                            backend: backend,
                            target: confirmedTarget
                        )
                    case .failure(let failure):
                        self.finishDeveloperModePreflightFailure(failure)
                    }
                }
            case .failure(let failure):
                self.finishDeveloperModePreflightFailure(failure)
            }
        }
    }

    func enableWiFiConnection() {
        guard canEnableWiFi, let host,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              case .success(let backend) = resolveBackend() else { return }
        lastError = nil
        isBusy = true
        readiness = .notChecked
        statusText = "Verifying USB Trust for Wi-Fi setup…"
        detailText = "The exact USB iPhone is verified before enabling Apple's Wi-Fi connection setting."
        publishDerivedState()
        requestPreflight(expected: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let freshTarget):
                guard host.confirmEnableWiFi(freshTarget) else {
                    self.isBusy = false
                    self.statusText = "Wi-Fi setup was cancelled"
                    self.detailText = "No Wi-Fi setting request was sent."
                    self.publishDerivedState()
                    return
                }
                self.requestPreflight(expected: freshTarget) { [weak self] confirmed in
                    guard let self else { return }
                    switch confirmed {
                    case .success(let confirmedTarget):
                        self.startWiFiSetup(backend: backend, target: confirmedTarget)
                    case .failure(let failure):
                        self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: false)
                    }
                }
            case .failure(let failure):
                self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: false)
            }
        }
    }

    func setLocation(
        _ coordinate: MockLocationCoordinate,
        mode: MockLocationSetMode = .liveSession
    ) {
        lastError = nil
        guard let host, !isBusy, !isAssumedActive, !reviewRequired,
              (selectedTransport != .wifi || mode == .liveSession),
              host.hostGate().permitsLocationWork,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              readinessTransport == selectedTransport,
              readiness.isReady(for: target.pin),
              case .success(let backend) = resolveBackend() else { return }

        isBusy = true
        setSimulation(.preparing(pin: target.pin))
        statusText = "Rechecking the exact target…"
        detailText = "No location request is sent until ECID, UDID, USB location, and product type match the ready target."

        requestPreflight(expected: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let freshTarget):
                guard let host = self.host,
                      host.confirmSet(freshTarget, coordinate, mode) else {
                    self.isBusy = false
                    self.setSimulation(.notRequested)
                    self.statusText = "Mock Location was cancelled"
                    self.detailText = "No location request was sent."
                    return
                }
                self.statusText = "Rechecking the confirmed target…"
                self.detailText = "A second exact-target and Trust check is required after confirmation."
                self.requestPreflight(expected: freshTarget) { [weak self] secondResult in
                    guard let self else { return }
                    switch secondResult {
                    case .success(let confirmedTarget):
                        self.startSet(
                            backend: backend,
                            target: confirmedTarget,
                            coordinate: coordinate,
                            mode: mode
                        )
                    case .failure(let failure):
                        self.setSimulation(.notRequested)
                        self.finishPreflightFailure(
                            failure,
                            mutatingRequestMayHaveStarted: false
                        )
                    }
                }
            case .failure(let failure):
                self.setSimulation(.notRequested)
                self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: false)
            }
        }
    }

    @discardableResult
    func forgetUnavailableIPhoneRecord() -> Bool {
        guard canForgetUnavailableRecord,
              let host,
              let record = journalRecord,
              let recordedPin = record.pin,
              let targetBeforeConfirmation = try? MockLocationExactTarget(
                  snapshot: host.currentSnapshot()
              ),
              safetyRecordMatch(for: targetBeforeConfirmation) == .differentStableIPhone else {
            return false
        }

        let context = MockLocationForgetRecordContext(
            recordedTargetToken: recordedPin.displayToken,
            connectedTargetToken: targetBeforeConfirmation.pin.displayToken
        )
        let previousStatus = statusText
        let previousDetail = detailText
        let previousError = lastError

        isBusy = true
        statusText = "Waiting for local-record confirmation…"
        detailText = "No iPhone command will be sent. The saved record is retained unless the local deletion completes successfully."
        publishDerivedState()

        guard host.confirmForgetUnavailableRecord(context) else {
            isBusy = false
            statusText = previousStatus
            detailText = previousDetail
            lastError = previousError
            publishDerivedState()
            return false
        }

        guard host.hostGate().permitsLocationWork,
              activeRun == nil,
              !processCoordinator.hasActiveProcess,
              let targetAfterConfirmation = try? MockLocationExactTarget(
                  snapshot: host.currentSnapshot()
              ),
              targetAfterConfirmation.pin == targetBeforeConfirmation.pin,
              targetAfterConfirmation.stablePin == targetBeforeConfirmation.stablePin,
              safetyRecordMatch(for: targetAfterConfirmation) == .differentStableIPhone else {
            isBusy = false
            statusText = "Local safety record was not forgotten"
            detailText = "The connected target or app workflow changed while confirmation was open. The saved record and every safety lock remain active."
            lastError = "The local record was not deleted because its confirmation context changed."
            publishDerivedState()
            return false
        }

        do {
            guard try journal.load() == record else {
                throw MockLocationJournalError.invalidRecord
            }
            try journal.remove()
            guard try journal.load() == nil else {
                throw MockLocationJournalError.cannotWrite
            }
        } catch {
            isBusy = false
            statusText = "Local safety record could not be deleted"
            detailText = "No device command was sent. The saved record and safety lock remain active."
            lastError = "YIOS-KIT could not delete its local Mock Location safety record."
            publishDerivedState()
            return false
        }

        journalRecord = nil
        readiness = .notChecked
        simulationKnowledge = .notRequested
        isBusy = false
        statusText = "Unavailable iPhone record forgotten locally"
        detailText = "No command was sent. The unavailable iPhone's location state is still unknown and may remain simulated. Operations on this Mac are unlocked for a fresh check of the connected iPhone."
        lastError = nil
        publishDerivedState()
        return true
    }

    func returnToRealLocation() {
        lastError = nil
        if canReturnToRealLocation, let run = liveWiFiRun {
            isBusy = true
            setSimulation(.clearing(pin: run.target.pin))
            beginClear(target: run.target)
            return
        }
        guard canReturnToRealLocation,
              let host,
              let target = try? MockLocationExactTarget(snapshot: host.currentSnapshot()),
              let match = clearTargetMatch(for: target) else { return }

        isBusy = true
        publishDerivedState()
        let previousKnowledge = simulationKnowledge
        let safetyPin = journalRecord?.pin ?? simulationKnowledge.pin ?? target.pin
        statusText = "Verifying the exact target before reset…"
        detailText = "Pairing, Trust, stable identity, and the current USB session are checked before any confirmation or reset request."

        requestPreflight(expected: target) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let freshTarget):
                guard let freshMatch = self.clearTargetMatch(for: freshTarget),
                      self.clearMatchesOriginalIntent(freshMatch, original: match) else {
                    self.isBusy = false
                    self.setSimulation(previousKnowledge)
                    self.readiness = .blocked(.targetChanged, detail: nil)
                    self.lastError = MockLocationReadinessIssue.targetChanged.userDescription
                    self.statusText = "Reset was not sent"
                    self.detailText = "The target changed during the first verification. The safety lock remains active."
                    return
                }

                if case .unpinned = freshMatch,
                   !host.confirmUnpinnedClear(freshTarget) {
                    self.isBusy = false
                    self.setSimulation(previousKnowledge)
                    self.statusText = "Reset review remains active"
                    self.detailText = "No reset request was sent. The unreadable journal still prevents the app from identifying the previous target."
                    return
                }
                if case .reconnected(let originalConnectionPin) = freshMatch,
                   !host.confirmReconnectedClear(freshTarget, originalConnectionPin) {
                    self.isBusy = false
                    self.setSimulation(previousKnowledge)
                    self.statusText = "Persistent-location review remains active"
                    self.detailText = "No reset request was sent. The same stable iPhone was not confirmed for its new USB connection."
                    return
                }

                self.statusText = "Rechecking the confirmed target…"
                self.detailText = "A second exact-target and Trust check is required immediately before the reset request."
                self.requestPreflight(expected: freshTarget) { [weak self] secondResult in
                    guard let self else { return }
                    switch secondResult {
                    case .success(let confirmedTarget):
                        guard let confirmedMatch = self.clearTargetMatch(for: confirmedTarget),
                              self.clearMatchesOriginalIntent(confirmedMatch, original: freshMatch) else {
                            self.isBusy = false
                            self.setSimulation(previousKnowledge)
                            self.readiness = .blocked(.targetChanged, detail: nil)
                            self.lastError = MockLocationReadinessIssue.targetChanged.userDescription
                            self.statusText = "Reset was not sent"
                            self.detailText = "The target changed after confirmation. The safety lock remains active."
                            return
                        }
                        self.setSimulation(.clearing(pin: safetyPin))
                        self.beginClear(target: confirmedTarget)
                    case .failure(let failure):
                        self.setSimulation(previousKnowledge)
                        self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: true)
                    }
                }
            case .failure(let failure):
                self.setSimulation(previousKnowledge)
                self.finishPreflightFailure(failure, mutatingRequestMayHaveStarted: true)
            }
        }
    }

    private func clearMatchesOriginalIntent(
        _ candidate: ClearTargetMatch,
        original: ClearTargetMatch
    ) -> Bool {
        switch (candidate, original) {
        case (.exact, .exact), (.unpinned, .unpinned):
            return true
        case let (.reconnected(candidatePin), .reconnected(originalPin)):
            return candidatePin == originalPin
        default:
            return false
        }
    }

    private func clearTargetMatch(for target: MockLocationExactTarget) -> ClearTargetMatch? {
        if let pin = simulationKnowledge.pin, pin == target.pin { return .exact }
        if (journalRecord?.setMode == .persistentUntilClearOrReboot || journalRecord?.transport == .wifi),
           journalRecord?.stablePin == target.stablePin,
           let originalConnectionPin = journalRecord?.pin {
            return .reconnected(originalConnectionPin: originalConnectionPin)
        }
        if case .uncertain(pin: nil, reason: _) = simulationKnowledge,
           case .success = resolveBackend() {
            return .unpinned
        }
        if simulationKnowledge == .notRequested,
           readiness.isReady(for: target.pin) { return .exact }
        if case .resetRequestSent = simulationKnowledge,
           readiness.isReady(for: target.pin) { return .exact }
        return nil
    }

    private func safetyRecordMatch(
        for target: MockLocationExactTarget
    ) -> MockLocationSafetyRecordMatch {
        guard let record = journalRecord,
              let recordedPin = record.pin else { return .none }
        if recordedPin == target.pin { return .exactConnection }
        guard let recordedStablePin = record.stablePin else {
            return .connectedUnavailable
        }
        if recordedStablePin == target.stablePin {
            return .sameStableIPhoneNewConnection
        }
        return .differentStableIPhone
    }

    private var hasLocationSafetyRecord: Bool {
        journalRecord != nil || isAssumedActive || reviewRequired
    }

    private func targetMatchesLocationSafetyRecord(_ target: MockLocationExactTarget) -> Bool {
        guard let record = journalRecord else { return false }
        if record.pin == target.pin { return true }
        return record.stablePin == target.stablePin
    }

    private func requestPreflight(
        expected target: MockLocationExactTarget,
        completion: @escaping (Result<MockLocationExactTarget, MockLocationPreflightFailure>) -> Void
    ) {
        guard let host else {
            completion(.failure(.unavailable))
            return
        }
        let identifier = UUID()
        preflightID = identifier
        host.requestFreshEvidence { [weak self] evidence in
            DispatchQueue.main.async {
                guard let self, self.preflightID == identifier else { return }
                self.preflightID = nil
                guard let currentHost = self.host else {
                    completion(.failure(.unavailable))
                    return
                }
                if let block = currentHost.hostGate().blockReason {
                    completion(.failure(.hostBusy(block)))
                    return
                }
                guard evidence.pairingAndTrustVerified else {
                    completion(.failure(.pairingRequired))
                    return
                }
                guard target.matches(evidence.snapshot),
                      let freshTarget = try? MockLocationExactTarget(snapshot: evidence.snapshot) else {
                    completion(.failure(.targetChanged))
                    return
                }
                completion(.success(freshTarget))
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.preflightID == identifier else { return }
            self.preflightID = nil
            completion(.failure(.timedOut))
        }
    }

    private func startProbe(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget
    ) {
        let transport = selectedTransport
        let command = MockLocationCommandBuilder.probe(backend: backend, target: target, transport: transport)
        let createdAt = now()
        let result = processCoordinator.start(
            command,
            handshakeTimeout: 150,
            onEvent: { [weak self] identifier, event in
                self?.handleBackendEvent(identifier: identifier, event: event)
            },
            completion: { [weak self] identifier, completion in
                self?.handleProcessCompletion(identifier: identifier, completion: completion)
            }
        )
        switch result {
        case .success(let identifier):
            activeRun = ActiveRun(
                id: identifier,
                operation: .probe,
                target: target,
                createdAt: createdAt,
                transport: transport
            )
        case .failure:
            failReadiness(.backendFailure)
            isBusy = false
            publishDerivedState()
        }
    }

    private func startWiFiSetup(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget
    ) {
        statusText = "Enabling the iPhone's Wi-Fi connection…"
        detailText = "One exact-target USB request enables Apple's Wi-Fi connection setting. A separate Network probe must still pass."
        let result = processCoordinator.start(
            MockLocationCommandBuilder.enableWiFi(backend: backend, target: target),
            handshakeTimeout: 120,
            onEvent: { [weak self] identifier, event in
                self?.handleBackendEvent(identifier: identifier, event: event)
            },
            completion: { [weak self] identifier, completion in
                self?.handleProcessCompletion(identifier: identifier, completion: completion)
            }
        )
        switch result {
        case .success(let identifier):
            activeRun = ActiveRun(id: identifier, operation: .enableWiFi, target: target, createdAt: now())
        case .failure:
            isBusy = false
            statusText = "Wi-Fi setup could not start"
            detailText = "The bundled backend could not be launched. Connect the same iPhone over USB and try again."
            lastError = MockLocationReadinessIssue.backendFailure.userDescription
            publishDerivedState()
        }
    }

    private func startDeveloperModeOptionRequest(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget
    ) {
        statusText = "Requesting the Developer Mode Settings option…"
        detailText = "The app-private backend is sending one non-reboot Apple request to the twice-verified iPhone. It does not enable Developer Mode."
        let command = MockLocationCommandBuilder.revealDeveloperMode(
            backend: backend,
            target: target
        )
        let result = processCoordinator.start(
            command,
            handshakeTimeout: 90,
            onEvent: { [weak self] identifier, event in
                self?.handleBackendEvent(identifier: identifier, event: event)
            },
            completion: { [weak self] identifier, completion in
                self?.handleProcessCompletion(identifier: identifier, completion: completion)
            }
        )
        switch result {
        case .success(let identifier):
            activeRun = ActiveRun(
                id: identifier,
                operation: .revealDeveloperMode,
                target: target,
                createdAt: now()
            )
        case .failure:
            isBusy = false
            readiness = .failed(.backendFailure)
            statusText = "Developer Mode Settings request was not started"
            detailText = "The app-private backend could not be launched. No Settings-option request was sent."
            lastError = MockLocationReadinessIssue.backendFailure.userDescription
            publishDerivedState()
        }
    }

    private func startSet(
        backend: MockLocationBackendDescriptor,
        target: MockLocationExactTarget,
        coordinate: MockLocationCoordinate,
        mode: MockLocationSetMode
    ) {
        let createdAt = now()
        let transport = selectedTransport
        let pending = MockLocationJournalRecord(
            state: .pendingSet,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: mode,
            transport: transport,
            requestDispatched: false,
            createdAt: createdAt,
            updatedAt: createdAt
        )
        do {
            try journal.write(pending)
            journalRecord = pending
        } catch {
            isBusy = false
            setSimulation(.notRequested)
            lastError = "The safety journal could not be written, so no location request was sent."
            statusText = "Mock Location was not started"
            detailText = "Fix local Application Support permissions, then check readiness again."
            return
        }

        statusText = mode == .persistentUntilClearOrReboot
            ? "Starting experimental persistent location…"
            : "Starting Mock Location…"
        detailText = "The backend is attesting the iOS developer session for the pinned target."
        let command: MockLocationBackendCommand
        switch mode {
        case .liveSession:
            command = MockLocationCommandBuilder.set(
                backend: backend,
                target: target,
                coordinate: coordinate,
                transport: transport
            )
        case .persistentUntilClearOrReboot:
            command = MockLocationCommandBuilder.setPersistent(
                backend: backend,
                target: target,
                coordinate: coordinate
            )
        }
        let result = processCoordinator.start(
            command,
            handshakeTimeout: 180,
            onEvent: { [weak self] identifier, event in
                self?.handleBackendEvent(identifier: identifier, event: event)
            },
            completion: { [weak self] identifier, completion in
                self?.handleProcessCompletion(identifier: identifier, completion: completion)
            }
        )
        switch result {
        case .success(let identifier):
            activeRun = ActiveRun(
                id: identifier,
                operation: command.operation,
                target: target,
                createdAt: createdAt,
                transport: transport
            )
        case .failure(let failure):
            isBusy = false
            if failure == .initialRequestFailed {
                transitionToUncertain(pin: target.pin, reason: .backendExited)
                lastError = "The backend launched but the private request channel failed. A location request cannot be ruled out; reset the same target."
            } else {
                try? journal.remove()
                journalRecord = nil
                setSimulation(.notRequested)
                lastError = "The app-private backend could not be launched. No location request was sent."
                statusText = "Mock Location was not started"
                detailText = "Check the bundled backend, then run the readiness check again."
            }
        }
    }

    private func beginClear(target: MockLocationExactTarget) {
        let createdAt = journalRecord?.createdAt ?? now()
        let pending = MockLocationJournalRecord(
            state: .pendingClear,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: journalRecord?.setMode ?? .liveSession,
            transport: journalRecord?.transport ?? .usb,
            requestDispatched: false,
            createdAt: createdAt,
            updatedAt: now()
        )
        do {
            try journal.write(pending)
            journalRecord = pending
        } catch {
            isBusy = false
            setSimulation(.uncertain(pin: target.pin, reason: .journalWriteFailed))
            lastError = "The reset was not sent because the safety journal could not record the attempt."
            return
        }

        if var run = activeRun,
           run.operation == .set,
           run.target.pin == target.pin,
           processCoordinator.activeOperation == .set {
            run.clearRequested = true
            activeRun = run
            statusText = "Sending reset request…"
            detailText = "The app is asking the same live developer session to stop location simulation."
            processCoordinator.beginClearDeadline(for: run.id)
            guard processCoordinator.sendClear(to: run.id) else {
                isBusy = false
                transitionToUncertain(pin: target.pin, reason: .clearNotObserved)
                lastError = "The live backend did not accept the reset command. Try Return to Real Location again after reconnecting the same target."
                return
            }
            return
        }

        guard !processCoordinator.hasActiveProcess,
              case .success(let backend) = resolveBackend() else {
            isBusy = false
            transitionToUncertain(pin: target.pin, reason: .clearNotObserved)
            lastError = "The reset backend is unavailable. Reconnect the same target and try again."
            return
        }

        statusText = "Sending reset request…"
        detailText = "A new exact-target developer session is being opened only to send the clear command."
        let command = MockLocationCommandBuilder.clear(backend: backend, target: target)
        let result = processCoordinator.start(
            command,
            handshakeTimeout: 180,
            onEvent: { [weak self] identifier, event in
                self?.handleBackendEvent(identifier: identifier, event: event)
            },
            completion: { [weak self] identifier, completion in
                self?.handleProcessCompletion(identifier: identifier, completion: completion)
            }
        )
        switch result {
        case .success(let identifier):
            var run = ActiveRun(
                id: identifier,
                operation: .clear,
                target: target,
                createdAt: createdAt
            )
            run.clearRequested = true
            activeRun = run
        case .failure:
            isBusy = false
            transitionToUncertain(pin: target.pin, reason: .clearNotObserved)
            lastError = "The reset backend could not be launched. Reconnect the same target and try again."
        }
    }

    private func handleBackendEvent(identifier: UUID, event: MockLocationBackendEvent) {
        guard var run = activeRun, run.id == identifier else { return }
        switch event.kind {
        case .hello:
            guard !run.sawHello else { run.protocolOrderInvalid = true; break }
            if run.transport == .wifi || run.operation == .enableWiFi {
                let components = (event.backendVersion ?? "").split(separator: ".", omittingEmptySubsequences: false)
                let version = components.compactMap { component -> Int? in
                    guard !component.isEmpty, component.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
                    return Int(component)
                }
                guard components.count == 3, version.count == 3,
                      version.lexicographicallyPrecedes([1, 3, 0]) == false else {
                    run.protocolOrderInvalid = true
                    break
                }
            }
            run.sawHello = true
            run.backendVersion = event.backendVersion
        case .attested:
            guard run.sawHello, !run.attested,
                  event.productType == run.target.productType else {
                run.protocolOrderInvalid = true
                break
            }
            run.attested = true
        case .ready:
            guard run.operation != .revealDeveloperMode, run.operation != .enableWiFi,
                  run.attested, !run.ready else {
                run.protocolOrderInvalid = true
                break
            }
            run.ready = true
        case .requestDispatched:
            guard run.attested else {
                run.protocolOrderInvalid = true
                break
            }
            if run.operation == .enableWiFi {
                guard !run.ready, !run.requestDispatched, !run.wifiEnabled else {
                    run.protocolOrderInvalid = true
                    break
                }
                run.requestDispatched = true
            } else if run.operation == .revealDeveloperMode {
                guard !run.ready,
                      !run.requestDispatched,
                      !run.developerModeOptionRequested,
                      !run.developerModeAlreadyEnabled else {
                    run.protocolOrderInvalid = true
                    break
                }
                run.requestDispatched = true
                statusText = "Developer Mode Settings request dispatched…"
                detailText = "Waiting for the backend's non-reboot option-expected acknowledgement. Developer Mode has not been enabled."
            } else if run.clearRequested {
                guard run.ready else {
                    run.protocolOrderInvalid = true
                    break
                }
                guard !run.clearRequestDispatched else {
                    run.protocolOrderInvalid = true
                    break
                }
                run.clearRequestDispatched = true
                let pendingClear = MockLocationJournalRecord(
                    state: .pendingClear,
                    pin: run.target.pin,
                    stablePin: run.target.stablePin,
                    setMode: journalRecord?.setMode ?? .liveSession,
                    transport: journalRecord?.transport ?? run.transport,
                    requestDispatched: true,
                    createdAt: run.createdAt,
                    updatedAt: now()
                )
                do {
                    try journal.write(pendingClear)
                    journalRecord = pendingClear
                    statusText = "Reset request dispatched…"
                    detailText = "Waiting for the backend to report that it sent the clear command."
                } catch {
                    isBusy = false
                    setSimulation(.uncertain(pin: run.target.pin, reason: .journalWriteFailed))
                    lastError = "The reset request may have been dispatched, but its safety state could not be recorded."
                }
            } else if (run.operation == .set || run.operation == .setPersistent) &&
                        !run.requestDispatched {
                guard run.ready else {
                    run.protocolOrderInvalid = true
                    break
                }
                run.requestDispatched = true
                let dispatched = MockLocationJournalRecord(
                    state: .uncertain,
                    pin: run.target.pin,
                    stablePin: run.target.stablePin,
                    setMode: run.operation == .setPersistent
                        ? .persistentUntilClearOrReboot
                        : .liveSession,
                    transport: run.transport,
                    requestDispatched: true,
                    createdAt: run.createdAt,
                    updatedAt: now()
                )
                do {
                    try journal.write(dispatched)
                    journalRecord = dispatched
                    statusText = "Location request dispatched…"
                    detailText = "Waiting for the backend's active acknowledgement. Device mutations remain blocked."
                } catch {
                    isBusy = false
                    setSimulation(.uncertain(pin: run.target.pin, reason: .journalWriteFailed))
                    lastError = "The location request may be active, but its crash-safety state could not be recorded. Choose Return to Real Location now."
                }
            } else {
                run.protocolOrderInvalid = true
            }
        case .active:
            guard (run.operation == .set || run.operation == .setPersistent),
                  run.attested,
                  run.ready,
                  run.requestDispatched,
                  !run.clearRequested,
                  !run.activeAcknowledged,
                  !run.protocolOrderInvalid,
                  run.backendError == nil,
                  (run.operation == .setPersistent
                    ? event.setMode == .persistentUntilClearOrReboot
                    : event.setMode == nil) else {
                run.protocolOrderInvalid = true
                break
            }
            run.activeAcknowledged = true
            let setMode: MockLocationSetMode = run.operation == .setPersistent
                ? .persistentUntilClearOrReboot
                : .liveSession
            let active = MockLocationJournalRecord(
                state: run.operation == .setPersistent ? .setAcknowledged : .assumedActive,
                pin: run.target.pin,
                stablePin: run.target.stablePin,
                setMode: setMode,
                transport: run.transport,
                requestDispatched: true,
                createdAt: run.createdAt,
                updatedAt: now()
            )
            do {
                try journal.write(active)
                journalRecord = active
                if run.operation == .set {
                    processCoordinator.acknowledgeActive(for: identifier)
                    isBusy = false
                    setSimulation(.assumedActive(pin: run.target.pin, requestedAt: now()))
                    statusText = run.transport == .wifi
                        ? "Wi-Fi Mock Location session is active"
                        : "USB Mock Location session is active — keep the cable connected"
                    detailText = run.transport == .wifi
                        ? "The exact iPhone acknowledged Set over Wi-Fi. You may unplug USB now. Keep YIOS-KIT and this Mac awake on the same network. iOS provides no getter to verify the coordinate."
                        : "The backend acknowledged Set over USB. Unplugging ends this live session. To use a live session without the cable, send Return to Real Location first, then choose Wi-Fi and check its connection. iOS provides no getter to verify the coordinate."
                } else {
                    processCoordinator.beginPersistentTeardownDeadline(
                        for: identifier,
                        timeout: persistentTeardownTimeout
                    )
                    statusText = "Persistent Set returned — closing developer session…"
                    detailText = "The app will claim only assumed persistence after the backend exits cleanly without sending Clear."
                }
            } catch {
                isBusy = false
                setSimulation(.uncertain(pin: run.target.pin, reason: .journalWriteFailed))
                lastError = "The location request may be active, but its crash-safety state could not be recorded. Choose Return to Real Location now."
            }
        case .clearSent:
            guard (run.operation == .clear || run.operation == .set),
                  run.attested,
                  run.ready,
                  run.clearRequested,
                  run.clearRequestDispatched,
                  !run.protocolOrderInvalid,
                  run.backendError == nil else {
                run.protocolOrderInvalid = true
                break
            }
            run.clearSent = true
            do {
                try journal.remove()
                journalRecord = nil
                setSimulation(.resetRequestSent(pin: run.target.pin, requestedAt: now()))
                statusText = "Reset request sent — real GPS expected"
                detailText = "The clear command was sent to the pinned iPhone. The developer service does not provide a getter, so this is not a location confirmation."
                lastError = nil
            } catch {
                setSimulation(.uncertain(pin: run.target.pin, reason: .journalWriteFailed))
                lastError = "The reset request was sent, but the local safety journal could not be cleared. Review is still required."
            }
        case .developerModeOptionRequested:
            guard run.operation == .revealDeveloperMode,
                  run.attested,
                  !run.ready,
                  run.requestDispatched,
                  !run.developerModeOptionRequested,
                  !run.developerModeAlreadyEnabled,
                  run.backendError == nil else {
                run.protocolOrderInvalid = true
                break
            }
            run.developerModeOptionRequested = true
            statusText = "Settings option is expected"
            detailText = "The exact-target backend accepted the non-reboot request. Waiting for a clean exit before reporting completion."
        case .developerModeAlreadyEnabled:
            guard run.operation == .revealDeveloperMode,
                  run.attested,
                  !run.ready,
                  !run.requestDispatched,
                  !run.developerModeOptionRequested,
                  !run.developerModeAlreadyEnabled,
                  run.backendError == nil else {
                run.protocolOrderInvalid = true
                break
            }
            run.developerModeAlreadyEnabled = true
            statusText = "Developer Mode was already enabled"
            detailText = "Waiting for a clean backend exit before returning to the readiness check."
        case .wifiEnabled:
            guard run.operation == .enableWiFi,
                  run.attested, run.requestDispatched, !run.ready,
                  !run.wifiEnabled, !run.protocolOrderInvalid,
                  run.backendError == nil else {
                run.protocolOrderInvalid = true
                break
            }
            run.wifiEnabled = true
        case .error:
            run.backendError = event.errorCode
            if event.errorCode == .connectionLost, run.requestDispatched,
               run.operation == .set, !run.clearSent {
                isBusy = false
                transitionToUncertain(pin: run.target.pin, reason: .backendExited)
                statusText = "Mock Location connection was lost"
                detailText = "The developer tunnel closed. Reconnect the same iPhone over USB and send Return to Real Location before starting another session."
                lastError = "The live connection ended; the phone's current simulated location cannot be confirmed."
                processCoordinator.beginClearDeadline(for: identifier)
            }
        }
        activeRun = run
    }

    private func handleProcessCompletion(
        identifier: UUID,
        completion: MockLocationProcessCompletion
    ) {
        guard let run = activeRun, run.id == identifier else { return }
        activeRun = nil
        isBusy = false

        switch run.operation {
        case .probe:
            if completion.completedCleanly,
               run.sawHello, run.attested, run.ready,
               !run.protocolOrderInvalid, run.backendError == nil {
                readiness = .ready(
                    pin: run.target.pin,
                    checkedAt: now(),
                    backendVersion: run.backendVersion
                )
                readinessTransport = run.transport
                statusText = "\(run.transport.displayName) Mock Location is ready"
                detailText = "The exact target, developer service, and \(run.transport.displayName) tunnel passed the read-only probe. Keep USB connected until Set is acknowledged. No simulated coordinate has been sent."
                lastError = nil
            } else {
                let issue = processIssue(run: run, completion: completion)
                failReadiness(issue)
                if run.transport == .wifi,
                   (run.backendError == .targetNotFound || issue == .tunnelUnavailable || issue == .probeTimedOut) {
                    statusText = "The iPhone's Wi-Fi connection is not ready"
                    detailText = "Keep USB attached, unlock and Trust the iPhone, enable Wi-Fi Connection, and put both devices on the same network. Allow local-network access if macOS asks. Apple's Network discovery must find this exact iPhone before Set can start."
                    lastError = "No exact-target Wi-Fi developer connection was established."
                }
            }
        case .enableWiFi:
            readiness = .notChecked
            if completion.completedCleanly, run.sawHello, run.attested,
               run.requestDispatched, run.wifiEnabled, !run.ready,
               !run.protocolOrderInvalid, run.backendError == nil {
                statusText = "Wi-Fi connection setting is enabled"
                detailText = "Keep USB attached and choose Check Readiness. The iPhone and Mac must share a network; enabling the setting alone does not prove a Network connection is available."
                lastError = nil
            } else {
                statusText = "Wi-Fi setup was not confirmed"
                detailText = "Reconnect and unlock the same iPhone over USB, verify Trust, then try again. No location request was sent."
                lastError = processIssue(run: run, completion: completion).userDescription
            }
        case .revealDeveloperMode:
            let optionExpected = run.requestDispatched &&
                run.developerModeOptionRequested &&
                !run.developerModeAlreadyEnabled
            let alreadyEnabled = !run.requestDispatched &&
                !run.developerModeOptionRequested &&
                run.developerModeAlreadyEnabled
            if completion.completedCleanly,
               run.sawHello,
               run.attested,
               !run.ready,
               optionExpected != alreadyEnabled,
               !run.protocolOrderInvalid,
               run.backendError == nil {
                readiness = .notChecked
                if alreadyEnabled {
                    statusText = "Developer Mode was already enabled"
                    detailText = "Run Check Readiness to verify the developer service, matching DDI, and USB tunnel for this exact iPhone."
                } else {
                    statusText = "Developer Mode Settings option is expected"
                    detailText = "The exact-target request was accepted and the backend exited cleanly. Reopen Settings > Privacy & Security on the iPhone. YIOS-KIT cannot read back whether the option is visibly rendered, and it did not enable Developer Mode or restart the phone."
                }
                lastError = nil
            } else {
                let issue = processIssue(run: run, completion: completion)
                readiness = .failed(issue)
                statusText = run.requestDispatched
                    ? "Developer Mode request outcome needs review"
                    : "Developer Mode Settings request failed"
                detailText = run.requestDispatched
                    ? "A request may have reached the exact iPhone, but a clean option-expected completion was not proven. Reopen Privacy & Security and do not assume Developer Mode is enabled."
                    : issue.userDescription
                lastError = issue.userDescription
            }
        case .set:
            if run.clearSent {
                // The clear event already established the only honest success claim.
                break
            }
            transitionToUncertain(
                pin: run.target.pin,
                reason: run.protocolOrderInvalid || completion.protocolError != nil
                    ? .backendProtocolError
                    : .backendExited
            )
            lastError = run.requestDispatched
                ? "The live backend ended before a reset request was recorded. Reconnect the same target and choose Return to Real Location."
                : "The backend ended after launch; a location request cannot be ruled out. Review and reset the same target."
            if run.backendError == .connectionLost {
                statusText = "Mock Location connection was lost"
                detailText = "Reconnect the same iPhone over USB and choose Return to Real Location. The phone's current location is unknown; starting another simulation remains blocked."
            }
        case .setPersistent:
            if completion.completedCleanly,
               run.sawHello, run.attested, run.ready,
               run.requestDispatched, run.activeAcknowledged,
               !run.protocolOrderInvalid, run.backendError == nil,
               journalRecord?.state == .setAcknowledged,
               journalRecord?.setMode == .persistentUntilClearOrReboot {
                let persistent = MockLocationJournalRecord(
                    state: .assumedPersistent,
                    pin: run.target.pin,
                    stablePin: run.target.stablePin,
                    setMode: .persistentUntilClearOrReboot,
                    requestDispatched: true,
                    createdAt: run.createdAt,
                    updatedAt: now()
                )
                do {
                    try journal.write(persistent)
                    journalRecord = persistent
                    setSimulation(.assumedPersistent(pin: run.target.pin, requestedAt: now()))
                    statusText = "Persistent location is assumed active"
                    detailText = "The Set call returned and the backend deliberately closed its developer session without Clear. Persistence is experimental and has no read-back getter. Use Return to Real Location; rebooting is expected to restore phone-side GPS but does not clear the app safety record."
                    lastError = nil
                } catch {
                    transitionToUncertain(pin: run.target.pin, reason: .journalWriteFailed)
                    lastError = "The Set call returned, but the durable persistent-state journal could not be recorded. Reset the same target now."
                }
            } else {
                transitionToUncertain(
                    pin: run.target.pin,
                    reason: run.protocolOrderInvalid || completion.protocolError != nil
                        ? .backendProtocolError
                        : .backendExited
                )
                lastError = "The experimental Set may have been sent, but clean developer-session teardown was not proven. Reconnect the same target and choose Return to Real Location."
            }
        case .clear:
            if !run.clearSent {
                transitionToUncertain(pin: run.target.pin, reason: .clearNotObserved)
                lastError = "The backend ended without reporting that it sent the reset request. Reconnect the same target and try again."
            }
        }
        publishDerivedState()
    }

    private func processIssue(
        run: ActiveRun,
        completion: MockLocationProcessCompletion
    ) -> MockLocationReadinessIssue {
        if let backendError = run.backendError { return backendError.readinessIssue }
        if completion.timedOut { return .probeTimedOut }
        if run.protocolOrderInvalid || completion.protocolError != nil { return .backendProtocolError }
        return .backendFailure
    }

    private func finishPreflightFailure(
        _ failure: MockLocationPreflightFailure,
        mutatingRequestMayHaveStarted: Bool
    ) {
        isBusy = false
        switch failure {
        case .timedOut:
            lastError = mutatingRequestMayHaveStarted
                ? "The exact-target reset preflight timed out. No reset was recorded."
                : "The exact-target preflight timed out. No location request was sent."
            if !mutatingRequestMayHaveStarted { readiness = .failed(.probeTimedOut) }
        case .targetChanged:
            readiness = .blocked(.targetChanged, detail: nil)
            lastError = MockLocationReadinessIssue.targetChanged.userDescription
        case .pairingRequired:
            readiness = .failed(.pairingRequired)
            lastError = MockLocationReadinessIssue.pairingRequired.userDescription
        case .hostBusy(let reason):
            readiness = .blocked(.hostBusy, detail: reason.userDescription)
            lastError = reason.userDescription
        case .unavailable:
            readiness = .failed(.backendFailure)
            lastError = "The app host became unavailable during preflight."
        }
        if !mutatingRequestMayHaveStarted {
            statusText = "Mock Location preflight stopped"
            detailText = "No location request was sent."
        } else {
            statusText = "Reset was not sent — review required"
            detailText = "The exact-target reset preflight did not complete. Simulation may still be active; reconnect the pinned iPhone and try Return to Real Location again."
        }
        publishDerivedState()
    }

    private func finishDeveloperModePreflightFailure(
        _ failure: MockLocationPreflightFailure
    ) {
        isBusy = false
        switch failure {
        case .timedOut:
            readiness = .failed(.probeTimedOut)
            lastError = "The exact-target verification timed out. No Developer Mode Settings request was sent."
        case .targetChanged:
            readiness = .blocked(.targetChanged, detail: nil)
            lastError = MockLocationReadinessIssue.targetChanged.userDescription
        case .pairingRequired:
            readiness = .failed(.pairingRequired)
            lastError = MockLocationReadinessIssue.pairingRequired.userDescription
        case .hostBusy(let reason):
            readiness = .blocked(.hostBusy, detail: reason.userDescription)
            lastError = reason.userDescription
        case .unavailable:
            readiness = .failed(.backendFailure)
            lastError = "The app host became unavailable during exact-target verification."
        }
        statusText = "Developer Mode Settings request stopped"
        detailText = "No Settings-option request was sent. Developer Mode was not enabled and the iPhone was not restarted."
        publishDerivedState()
    }

    private func failReadiness(_ issue: MockLocationReadinessIssue) {
        readiness = .failed(issue)
        isBusy = false
        statusText = "Mock Location is not ready"
        detailText = issue.userDescription
        lastError = issue.userDescription
        publishDerivedState()
    }

    private func transitionToUncertain(
        pin: MockLocationTargetPin,
        reason: MockLocationUncertaintyReason
    ) {
        let createdAt = journalRecord?.createdAt ?? now()
        let currentStablePin: MockLocationTargetPin? = {
            guard let snapshot = host?.currentSnapshot(),
                  MockLocationExactTarget.pin(for: snapshot) == pin else { return nil }
            return MockLocationExactTarget.stablePin(for: snapshot)
        }()
        if let stablePin = journalRecord?.stablePin ?? currentStablePin {
            let uncertain = MockLocationJournalRecord(
                state: .uncertain,
                pin: pin,
                stablePin: stablePin,
                setMode: journalRecord?.setMode ?? .liveSession,
                transport: journalRecord?.transport ?? .usb,
                requestDispatched: true,
                createdAt: createdAt,
                updatedAt: now()
            )
            if (try? journal.write(uncertain)) != nil {
                journalRecord = uncertain
            }
        }
        setSimulation(.uncertain(pin: pin, reason: reason))
        statusText = "Simulation state is uncertain — review required"
        detailText = reason.userDescription + " Reconnect the pinned target and choose Return to Real Location."
    }

    private func setSimulation(_ state: MockLocationSimulationKnowledge) {
        simulationKnowledge = state
        publishDerivedState()
    }

    private func publishDerivedState() {
        switch simulationKnowledge {
        case .assumedActive, .assumedPersistent:
            isAssumedActive = true
            reviewRequired = false
        case .uncertain:
            isAssumedActive = false
            reviewRequired = true
        case .notRequested, .preparing, .clearing, .resetRequestSent:
            isAssumedActive = false
            reviewRequired = false
        }
        blocksDeviceMutation = isBusy || isAssumedActive || reviewRequired
    }
}
