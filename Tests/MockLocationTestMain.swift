import Foundation

@main
@MainActor
struct MockLocationTestMain {
    private final class Counter {
        var value = 0
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    static func main() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        testCoordinates(expect: expect)
        testExactTarget(expect: expect)
        testJournal(expect: expect)
        testBackendCommand(expect: expect)
        testBackendProtocol(expect: expect)
        testBundledResolver(expect: expect)
        testOfflineController(expect: expect)
        testDeveloperModeOptionLifecycle(expect: expect)
        testDeveloperModeStablePinRecoveryGate(expect: expect)
        testForgetUnavailableRecord(expect: expect)
        testControllerLifecycle(expect: expect)
        testPersistentFailureLifecycle(expect: expect)
        testPersistentClearGuards(expect: expect)
        testOutOfOrderActiveKeepsDeadline(expect: expect)

        if failures.isEmpty {
            print("MOCK LOCATION TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }

    private static func testCoordinates(expect: (Bool, String) -> Void) {
        let origin = try? MockLocationCoordinate.parse(latitude: "0", longitude: "-0")
        expect(origin?.latitudeArgument == "0", "zero latitude must remain a valid command argument")
        expect(origin?.longitudeArgument == "0", "negative zero must be canonicalized")

        let boundary = try? MockLocationCoordinate.parse(latitude: "+90.0", longitude: "-180.000")
        expect(boundary?.latitude == 90, "latitude +90 boundary must be valid")
        expect(boundary?.longitude == -180, "longitude -180 boundary must be valid")

        let leadingPoint = try? MockLocationCoordinate.parse(latitude: ".5", longitude: "-.25")
        expect(leadingPoint?.latitude == 0.5 && leadingPoint?.longitude == -0.25, "plain leading-point decimals must parse")

        expectCoordinateFailure("", "1", .latitudeMissing, expect: expect)
        expectCoordinateFailure("1", "", .longitudeMissing, expect: expect)
        expectCoordinateFailure("NaN", "1", .latitudeInvalid, expect: expect)
        expectCoordinateFailure("1e2", "1", .latitudeInvalid, expect: expect)
        expectCoordinateFailure("1,5", "1", .latitudeInvalid, expect: expect)
        expectCoordinateFailure("90.0001", "1", .latitudeOutOfRange, expect: expect)
        expectCoordinateFailure("1", "180.0001", .longitudeOutOfRange, expect: expect)
        expectCoordinateFailure(String(repeating: "1", count: 33), "1", .latitudeInvalid, expect: expect)
    }

    private static func expectCoordinateFailure(
        _ latitude: String,
        _ longitude: String,
        _ expected: MockLocationCoordinateError,
        expect: (Bool, String) -> Void
    ) {
        do {
            _ = try MockLocationCoordinate.parse(latitude: latitude, longitude: longitude)
            expect(false, "coordinate \(latitude),\(longitude) should be rejected")
        } catch let error as MockLocationCoordinateError {
            expect(error == expected, "coordinate rejection should be \(expected), got \(error)")
        } catch {
            expect(false, "coordinate rejection returned an unexpected error type")
        }
    }

    private static func targetFixture() -> DeviceSnapshot {
        DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: "00008030-00123456789ABCDE",
            productType: "iPhone12,8",
            hardwareModel: "d79ap",
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true
        )
    }

    private static func testExactTarget(expect: (Bool, String) -> Void) {
        let snapshot = targetFixture()
        guard let target = try? MockLocationExactTarget(snapshot: snapshot) else {
            expect(false, "verified Normal-iOS SE2 fixture must produce an exact target")
            return
        }
        expect(target.matches(snapshot), "exact target must match the unchanged verified snapshot")
        expect(target.pin.fingerprint.count == 64, "target pin must be a SHA-256 fingerprint")
        expect(!target.pin.displayToken.contains("89ABCDE"), "display token must not expose the synthetic ECID suffix")
        expect(!target.pin.displayToken.contains("56789ABCDE"), "display token must not expose the synthetic UDID suffix")

        var changed = snapshot
        changed.locationID = 2_097_152
        expect(!target.matches(changed), "USB location change must invalidate the exact target")
        changed = snapshot
        changed.udid = "00008030-00FFFFFFFFFFFFFF"
        expect(!target.matches(changed), "UDID change must invalidate the exact target")
        changed = snapshot
        changed.ecid = "0xABCDEF"
        expect(!target.matches(changed), "ECID change must invalidate the exact target")
        changed = snapshot
        changed.mode = .recovery
        expect(!target.matches(changed), "Recovery Mode must invalidate the Normal-iOS target")
        changed = snapshot
        changed.deviceCount = 2
        expect(!target.matches(changed), "multiple devices must invalidate the exact target")
    }

    private static func testJournal(expect: (Bool, String) -> Void) {
        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()) else { return }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-MockLocation-Test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("state.json")
        let store = MockLocationJournalStore(fileURL: url)
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let pending = MockLocationJournalRecord(
            state: .pendingSet,
            pin: target.pin,
            stablePin: target.stablePin,
            requestDispatched: false,
            createdAt: created,
            updatedAt: created
        )
        do {
            try store.write(pending)
            expect(try store.load() == pending, "journal must round-trip a validated pending-set record")
            let text = String(data: try Data(contentsOf: url), encoding: .utf8) ?? ""
            expect(!text.contains(target.udid), "journal must never contain a raw UDID")
            expect(!text.localizedCaseInsensitiveContains(target.ecid), "journal must never contain a raw ECID")
            expect(!text.contains(String(target.locationID)), "journal must never contain a raw USB location")
            expect(!text.contains("16.8409") && !text.contains("96.1735"), "journal must never contain coordinates")
            let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            expect(permissions?.intValue == 0o600, "journal file permissions must be 0600")

            let pendingClear = MockLocationJournalRecord(
                state: .pendingClear,
                pin: target.pin,
                stablePin: target.stablePin,
                requestDispatched: false,
                createdAt: created,
                updatedAt: created.addingTimeInterval(1)
            )
            try store.write(pendingClear)
            expect(try store.load() == pendingClear, "write-ahead pending-clear state must be valid before dispatch")
            try store.remove()
            expect(try store.load() == nil, "journal removal must be durable and idempotent")

            let persistent = MockLocationJournalRecord(
                state: .assumedPersistent,
                pin: target.pin,
                stablePin: target.stablePin,
                setMode: .persistentUntilClearOrReboot,
                requestDispatched: true,
                createdAt: created,
                updatedAt: created.addingTimeInterval(2)
            )
            try store.write(persistent)
            expect(try store.load() == persistent, "schema-v2 persistent journal must round-trip with separate stable and connection pins")

            var legacyObject = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(pending)
            ) as? [String: Any] ?? [:]
            legacyObject["schema"] = 1
            legacyObject.removeValue(forKey: "stableTargetFingerprint")
            legacyObject.removeValue(forKey: "setMode")
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
            let legacy = try JSONDecoder().decode(MockLocationJournalRecord.self, from: legacyData)
            expect(try legacy.validated().schema == 1, "schema-v1 journals must remain decodable for conservative recovery")
            expect(legacy.stablePin == nil, "schema-v1 journals must not invent a stable identity pin")

            var forgedLegacyObject = legacyObject
            forgedLegacyObject["state"] = "assumedPersistent"
            forgedLegacyObject["setMode"] = "persistentUntilClearOrReboot"
            forgedLegacyObject["stableTargetFingerprint"] = target.stablePin.fingerprint
            let forgedLegacy = try JSONDecoder().decode(
                MockLocationJournalRecord.self,
                from: JSONSerialization.data(withJSONObject: forgedLegacyObject)
            )
            do {
                _ = try forgedLegacy.validated()
                expect(false, "schema-v1 journal must reject persistent states and schema-v2 identity fields")
            } catch {
                expect(true, "forged schema-v1 persistent journal must fail closed")
            }

            let wrongModeActive = MockLocationJournalRecord(
                state: .assumedActive,
                pin: target.pin,
                stablePin: target.stablePin,
                setMode: .persistentUntilClearOrReboot,
                requestDispatched: true,
                createdAt: created,
                updatedAt: created.addingTimeInterval(3)
            )
            do {
                _ = try wrongModeActive.validated()
                expect(false, "schema-v2 assumedActive must reject persistent mode")
            } catch {
                expect(true, "schema-v2 state/mode mismatch must fail closed")
            }
        } catch {
            expect(false, "journal fixture failed: \(error)")
        }
    }

    private static func testBackendCommand(expect: (Bool, String) -> Void) {
        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()),
              let coordinate = try? MockLocationCoordinate(latitude: 16.8409, longitude: 96.1735) else { return }
        let backend = MockLocationBackendDescriptor(executableURL: URL(fileURLWithPath: "/Fixture.app/Contents/Helpers/YIOSLocation/yios-location-backend"))
        let command = MockLocationCommandBuilder.set(
            backend: backend,
            target: target,
            coordinate: coordinate
        )
        expect(command.arguments == ["set"], "backend argv must contain only the allowlisted operation")
        expect(!command.arguments.joined().contains(target.udid), "raw target identifiers must not appear in process argv")
        let requestData = command.initialRequest.dropLast()
        let object = try? JSONSerialization.jsonObject(with: Data(requestData)) as? [String: Any]
        expect(object?["udid"] as? String == target.udid, "stdin request must carry the exact UDID")
        expect(object?["expectedProductType"] as? String == "iPhone12,8", "stdin request must carry the expected product")
        expect(object?["latitude"] as? Double == 16.8409, "stdin request must carry latitude as a JSON number")
        expect(object?["longitude"] as? Double == 96.1735, "stdin request must carry longitude as a JSON number")

        let persistent = MockLocationCommandBuilder.setPersistent(
            backend: backend,
            target: target,
            coordinate: coordinate
        )
        expect(persistent.arguments == ["set-persistent"], "persistent backend argv must use only the explicit allowlisted operation")
        expect(persistent.initialRequest == command.initialRequest, "live and persistent Set must carry the same exact-target stdin request")

        let developerMode = MockLocationCommandBuilder.revealDeveloperMode(
            backend: backend,
            target: target
        )
        expect(developerMode.arguments == ["reveal-developer-mode"], "Developer Mode argv must contain only the reviewed non-reboot backend operation")
        expect(developerMode.operation == .revealDeveloperMode, "Developer Mode command must retain its distinct operation type")
        let developerModeData = developerMode.initialRequest.dropLast()
        let developerModeObject = try? JSONSerialization.jsonObject(
            with: Data(developerModeData)
        ) as? [String: Any]
        expect(developerModeObject?["udid"] as? String == target.udid, "Developer Mode request must carry the exact UDID over private stdin")
        expect(developerModeObject?["expectedProductType"] as? String == target.productType, "Developer Mode request must pin ProductType")
        expect(developerModeObject?["expectedECID"] as? String == target.ecid, "Developer Mode request must pin canonical ECID")
        expect(developerModeObject?.count == 3, "Developer Mode request must not contain coordinates or unreviewed fields")
    }

    private static func testBackendProtocol(expect: (Bool, String) -> Void) {
        var decoder = MockLocationJSONLineAccumulator()
        let first = Data(#"{"event":"version","protocol":1,"backendVersion":"pymobiledevice3 10.9.0"}"#.utf8)
        expect(decoder.append(first).isEmpty, "partial JSON line must remain buffered")
        let versionResults = decoder.append(Data("\n".utf8))
        if case .success(let event)? = versionResults.first {
            expect(event.kind == .hello && event.protocolVersion == 1, "version event must normalize to hello")
        } else {
            expect(false, "version event should parse")
        }

        let accepted = MockLocationBackendEventParser.parse(
            line: #"{"event":"accepted","productType":"iPhone12,8"}"#
        )
        if case .success(let event) = accepted {
            expect(event.kind == .attested, "accepted target event must normalize to attested")
        } else {
            expect(false, "accepted target event should parse")
        }

        let phase = MockLocationBackendEventParser.parse(
            line: #"{"event":"phase","phase":"active"}"#
        )
        if case .success(let event) = phase {
            expect(event.kind == .active, "active phase must normalize to active acknowledgement")
        } else {
            expect(false, "active phase should parse")
        }

        let persistentActive = MockLocationBackendEventParser.parse(
            line: #"{"event":"active","persistence":"experimental"}"#
        )
        if case .success(let event) = persistentActive {
            expect(event.kind == .active, "persistent active event must remain an active acknowledgement")
            expect(event.setMode == .persistentUntilClearOrReboot, "persistent marker must be parsed explicitly")
        } else {
            expect(false, "persistent active event should parse")
        }

        if case .failure(.invalidEvent) = MockLocationBackendEventParser.parse(
            line: #"{"event":"active","persistence":"guaranteed"}"#
        ) {
            expect(true, "unknown persistence claims must fail closed")
        } else {
            expect(false, "unknown persistence marker must violate the protocol")
        }

        let clear = MockLocationBackendEventParser.parse(line: #"{"event":"resetRequestSent"}"#)
        if case .success(let event) = clear {
            expect(event.kind == .clearSent, "resetRequestSent must normalize to clearSent")
        } else {
            expect(false, "resetRequestSent should parse")
        }

        let optionExpected = MockLocationBackendEventParser.parse(
            line: #"{"event":"developerModeOptionRequested","status":"settingsOptionExpected"}"#
        )
        if case .success(let event) = optionExpected {
            expect(event.kind == .developerModeOptionRequested, "option-expected acknowledgement must parse without claiming visibility")
        } else {
            expect(false, "valid option-expected acknowledgement should parse")
        }
        let alreadyEnabled = MockLocationBackendEventParser.parse(
            line: #"{"event":"developerModeAlreadyEnabled","status":"alreadyEnabled"}"#
        )
        if case .success(let event) = alreadyEnabled {
            expect(event.kind == .developerModeAlreadyEnabled, "already-enabled terminal event must parse distinctly")
        } else {
            expect(false, "valid already-enabled event should parse")
        }
        if case .failure(.invalidEvent) = MockLocationBackendEventParser.parse(
            line: #"{"event":"developerModeOptionRequested","status":"revealed"}"#
        ) {
            expect(true, "unsupported visible/revealed claim must fail closed")
        } else {
            expect(false, "Developer Mode option event must require settingsOptionExpected")
        }

        if case .failure(.unknownErrorCode) = MockLocationBackendEventParser.parse(
            line: #"{"event":"error","code":"raw_private_error"}"#
        ) {
            expect(true, "unknown backend errors must be rejected instead of displayed")
        } else {
            expect(false, "unknown backend error code must violate the protocol")
        }

        var oversized = MockLocationJSONLineAccumulator()
        let results = oversized.append(Data(repeating: 0x41, count: MockLocationJSONLineAccumulator.maximumLineBytes + 1))
        if case .failure(.lineTooLong)? = results.first {
            expect(true, "oversized backend lines must be bounded")
        } else {
            expect(false, "oversized backend line must fail closed")
        }
    }

    private static func testBundledResolver(expect: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-Backend-Resolver-\(UUID().uuidString).app", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent(MockLocationBackendResolver.relativeExecutablePath)
        do {
            try FileManager.default.createDirectory(
                at: executable.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            expect(FileManager.default.createFile(atPath: executable.path, contents: Data("fixture".utf8)), "resolver fixture executable must be created")
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            if case .success(let descriptor) = MockLocationBackendResolver.resolve(bundleURL: root) {
                expect(descriptor.executableURL == executable, "resolver must select only the app-private helper path")
            } else {
                expect(false, "safe app-private executable must resolve")
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o775], ofItemAtPath: executable.path)
            expect(
                MockLocationBackendResolver.resolve(bundleURL: root) == .failure(.unsafePermissions),
                "group-writable helper must be rejected"
            )
        } catch {
            expect(false, "resolver fixture failed: \(error)")
        }
    }

    private static func testOfflineController(expect: (Bool, String) -> Void) {
        let clean = MockLocationController.offlineFixture()
        expect(!clean.isBusy, "offline fixture must start idle")
        expect(!clean.blocksDeviceMutation, "clean offline fixture must not arm a device-mutation lock")

        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()) else { return }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let recovered = MockLocationJournalRecord(
            state: .assumedActive,
            pin: target.pin,
            stablePin: target.stablePin,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let uncertain = MockLocationController.offlineFixture(recoveredRecord: recovered)
        expect(uncertain.reviewRequired, "recovered active journal must become uncertain, never assumed confirmed")
        expect(uncertain.blocksDeviceMutation, "uncertain recovered state must block all other device mutations")
        expect(!uncertain.isAssumedActive, "a relaunched session must not claim that simulation is still active")

        let persistentRecord = MockLocationJournalRecord(
            state: .assumedPersistent,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: .persistentUntilClearOrReboot,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let recoveredPersistent = MockLocationController.offlineFixture(recoveredRecord: persistentRecord)
        expect(recoveredPersistent.isAssumedPersistent, "clean persistent journal must recover as assumed persistent")
        expect(recoveredPersistent.blocksDeviceMutation, "recovered persistent state must keep all other device mutations blocked")
        expect(!recoveredPersistent.reviewRequired, "clean persistent recovery must remain distinct from interrupted uncertainty")

        let unreadable = MockLocationController(
            resolveBackend: {
                .success(MockLocationBackendDescriptor(executableURL: URL(fileURLWithPath: "/fixture/mock-backend")))
            },
            journal: MockLocationJournalClient(
                load: { throw MockLocationJournalError.cannotRead },
                write: { _ in },
                remove: { }
            )
        )
        let snapshot = targetFixture()
        unreadable.configureHost(.init(
            currentSnapshot: { snapshot },
            hostGate: { .idle },
            requestFreshEvidence: { completion in
                completion(MockLocationFreshEvidence(snapshot: snapshot, pairingAndTrustVerified: true))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(unreadable.reviewRequired, "unreadable journal must remain a conservative review state")
        expect(unreadable.canReturnToRealLocation, "unreadable journal review must still offer an explicitly confirmed exact-target clear path")
        unreadable.returnToRealLocation()
        waitUntil(timeout: 1) { !unreadable.isBusy }
        expect(!unreadable.isBusy, "cancelling the unreadable-journal recovery confirmation must remain idle")
        expect(unreadable.reviewRequired, "cancelling recovery must preserve the conservative review lock")
    }

    private static func testDeveloperModeOptionLifecycle(expect: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-DeveloperMode-Option-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let cleanExecutable = root.appendingPathComponent("clean-backend")
        let uncleanExecutable = root.appendingPathComponent("unclean-backend")
        let cleanScript = #"""
#!/bin/zsh
IFS= read -r initial_request
/usr/bin/printf '%s\n' '{"event":"hello","protocol":1,"backend_version":"fixture-1"}'
/usr/bin/printf '%s\n' '{"event":"attested","product_type":"iPhone12,8"}'
case "$1" in
  probe)
    /usr/bin/printf '%s\n' '{"event":"error","code":"developer_mode_required"}'
    exit 4
    ;;
  reveal-developer-mode)
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"developerModeOptionRequested","status":"settingsOptionExpected"}'
    exit 0
    ;;
esac
exit 2
"""#
        let uncleanScript = cleanScript.replacingOccurrences(
            of: "    exit 0\n    ;;",
            with: "    exit 5\n    ;;"
        )
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(cleanScript.utf8).write(to: cleanExecutable)
            try Data(uncleanScript.utf8).write(to: uncleanExecutable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: cleanExecutable.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uncleanExecutable.path)
        } catch {
            expect(false, "Developer Mode fake backend could not be created: \(error)")
            return
        }

        func makeController(
            executable: URL,
            preflightCount: Counter,
            confirmationCount: Counter,
            journalWriteCount: Counter
        ) -> MockLocationController {
            let snapshot = targetFixture()
            let controller = MockLocationController(
                resolveBackend: { .success(MockLocationBackendDescriptor(executableURL: executable)) },
                journal: MockLocationJournalClient(
                    load: { nil },
                    write: { _ in journalWriteCount.value += 1 },
                    remove: { journalWriteCount.value += 1 }
                )
            )
            controller.configureHost(.init(
                currentSnapshot: { snapshot },
                hostGate: { .idle },
                requestFreshEvidence: { completion in
                    preflightCount.value += 1
                    completion(MockLocationFreshEvidence(snapshot: snapshot, pairingAndTrustVerified: true))
                },
                confirmForgetUnavailableRecord: { _ in false },
                confirmDeveloperModeOptionRequest: { _ in
                    confirmationCount.value += 1
                    return true
                },
                confirmSet: { _, _, _ in false },
                confirmUnpinnedClear: { _ in false },
                confirmReconnectedClear: { _, _ in false }
            ))
            return controller
        }

        let cleanPreflights = Counter()
        let cleanConfirmations = Counter()
        let cleanJournalWrites = Counter()
        let clean = makeController(
            executable: cleanExecutable,
            preflightCount: cleanPreflights,
            confirmationCount: cleanConfirmations,
            journalWriteCount: cleanJournalWrites
        )
        clean.checkReadiness()
        waitUntil(timeout: 3) {
            if case .failed(.developerModeRequired) = clean.readiness { return true }
            return false
        }
        expect(clean.canRequestDeveloperModeOption, "a verified Developer Mode prerequisite failure must offer the guarded Settings request")
        clean.requestDeveloperModeOption()
        expect(clean.blocksDeviceMutation, "Developer Mode exact-target preflight/process must hold the global mutation lock")
        waitUntil(timeout: 3) { !clean.isBusy }
        expect(cleanPreflights.value == 3, "Developer Mode flow must use one readiness preflight plus two fresh post-action target/Trust checks")
        expect(cleanConfirmations.value == 1, "Developer Mode Settings request must require one explicit confirmation")
        expect(cleanJournalWrites.value == 0, "Developer Mode Settings request must not create, remove, or rewrite the location safety journal")
        expect(clean.readiness == .notChecked, "clean option-expected completion must require a new readiness check")
        expect(clean.simulationKnowledge == .notRequested, "Developer Mode Settings request must not alter location simulation knowledge")
        expect(clean.statusText.contains("expected"), "success must claim only that the Settings option is expected")

        let uncleanPreflights = Counter()
        let uncleanConfirmations = Counter()
        let uncleanJournalWrites = Counter()
        let unclean = makeController(
            executable: uncleanExecutable,
            preflightCount: uncleanPreflights,
            confirmationCount: uncleanConfirmations,
            journalWriteCount: uncleanJournalWrites
        )
        unclean.checkReadiness()
        waitUntil(timeout: 3) {
            if case .failed(.developerModeRequired) = unclean.readiness { return true }
            return false
        }
        unclean.requestDeveloperModeOption()
        waitUntil(timeout: 3) { !unclean.isBusy }
        expect(unclean.readiness == .failed(.backendFailure), "valid terminal events with a nonzero exit must not become success")
        expect(unclean.statusText.contains("review"), "a dispatched request without clean exit must require outcome review")
        expect(uncleanJournalWrites.value == 0, "unclean Developer Mode completion must still preserve the location journal")
    }

    private static func testDeveloperModeStablePinRecoveryGate(expect: (Bool, String) -> Void) {
        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()) else { return }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let persistent = MockLocationJournalRecord(
            state: .assumedPersistent,
            pin: target.pin,
            stablePin: target.stablePin,
            setMode: .persistentUntilClearOrReboot,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var connected = targetFixture()
        connected.locationID = 2_097_152
        let descriptor = MockLocationBackendDescriptor(executableURL: URL(fileURLWithPath: "/fixture/mock-backend"))
        var record: MockLocationJournalRecord? = persistent
        let controller = MockLocationController(
            resolveBackend: { .success(descriptor) },
            journal: MockLocationJournalClient(
                load: { record },
                write: { record = try $0.validated() },
                remove: { record = nil }
            )
        )
        controller.configureHost(.init(
            currentSnapshot: { connected },
            hostGate: { .idle },
            requestFreshEvidence: { completion in
                completion(MockLocationFreshEvidence(snapshot: connected, pairingAndTrustVerified: true))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(controller.shouldOfferDeveloperModeOptionRequest, "persistent recovery must show the non-reboot option request for the same stable iPhone")
        expect(controller.canRequestDeveloperModeOption, "same stable pin on a changed USB path must avoid a Developer Mode/Clear recovery deadlock")

        connected.ecid = "0xABCDEF12345678"
        connected.udid = "00008030-00ABCDEF12345678"
        controller.refreshLocalState()
        expect(!controller.canRequestDeveloperModeOption, "an active location journal must never authorize the Settings request for a different iPhone")
    }

    private static func testForgetUnavailableRecord(expect: (Bool, String) -> Void) {
        guard let recordedTarget = try? MockLocationExactTarget(snapshot: targetFixture()) else {
            expect(false, "forget-record fixture must create the recorded exact target")
            return
        }
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let persistentRecord = MockLocationJournalRecord(
            state: .assumedPersistent,
            pin: recordedTarget.pin,
            stablePin: recordedTarget.stablePin,
            setMode: .persistentUntilClearOrReboot,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        var differentSnapshot = targetFixture()
        differentSnapshot.ecid = "0xABCDEF12345678"
        differentSnapshot.udid = "00008030-00ABCDEF12345678"
        guard let differentTarget = try? MockLocationExactTarget(snapshot: differentSnapshot) else {
            expect(false, "forget-record fixture must create a different exact target")
            return
        }

        let stored = Box<MockLocationJournalRecord?>(persistentRecord)
        let snapshot = Box(differentSnapshot)
        let confirmationContext = Box<MockLocationForgetRecordContext?>(nil)
        let confirmationCount = Counter()
        let removeCount = Counter()
        let freshEvidenceCount = Counter()
        let backendResolutionCount = Counter()
        let controller = MockLocationController(
            resolveBackend: {
                backendResolutionCount.value += 1
                return .failure(.missing)
            },
            journal: MockLocationJournalClient(
                load: { stored.value },
                write: { stored.value = try $0.validated() },
                remove: {
                    removeCount.value += 1
                    stored.value = nil
                }
            )
        )
        controller.configureHost(.init(
            currentSnapshot: { snapshot.value },
            hostGate: { .idle },
            requestFreshEvidence: { _ in freshEvidenceCount.value += 1 },
            confirmForgetUnavailableRecord: { context in
                confirmationCount.value += 1
                confirmationContext.value = context
                return true
            },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        let backendResolutionBaseline = backendResolutionCount.value

        expect(controller.safetyRecordMatch == .differentStableIPhone, "a different stable iPhone must be classified separately from a USB reconnect")
        expect(controller.shouldOfferForgetUnavailableRecord, "a valid unavailable-phone record must expose the explicit local forget path")
        expect(controller.canForgetUnavailableRecord, "an idle different-phone fixture must enable local record forgetting")
        expect(controller.connectedTargetToken == differentTarget.pin.displayToken, "the connected token must identify the current phone")
        expect(controller.recordedTargetToken == recordedTarget.pin.displayToken, "the recorded token must remain separately labelled")
        expect(controller.connectedTargetToken != controller.recordedTargetToken, "current and recorded tokens must never collapse in a mismatch")
        expect(!controller.shouldOfferDeveloperModeOptionRequest, "a stale record must hide the Developer Mode request for a different phone")

        expect(controller.forgetUnavailableIPhoneRecord(), "confirmed local record deletion must succeed")
        expect(confirmationCount.value == 1 && removeCount.value == 1, "forget must confirm once and delete once")
        expect(
            confirmationContext.value == MockLocationForgetRecordContext(
                recordedTargetToken: recordedTarget.pin.displayToken,
                connectedTargetToken: differentTarget.pin.displayToken
            ),
            "confirmation must contain only the two masked target tokens"
        )
        expect(stored.value == nil, "successful forget must remove the saved journal")
        expect(controller.simulationKnowledge == .notRequested, "successful forget must reset local simulation knowledge")
        expect(controller.readiness == .notChecked, "successful forget must discard stale readiness")
        expect(!controller.isAssumedActive && !controller.reviewRequired && !controller.blocksDeviceMutation, "successful forget must synchronously release every location interlock")
        expect(controller.recordedTargetToken == nil, "successful forget must stop retaining the old target token")
        expect(controller.connectedTargetToken == differentTarget.pin.displayToken, "successful forget must retain the current target token")
        expect(
            freshEvidenceCount.value == 0 && backendResolutionCount.value == backendResolutionBaseline,
            "local forget must not probe Trust, resolve a backend, or contact a device"
        )
        expect(controller.detailText.contains("No command was sent"), "success copy must disclose that no reset command was sent")
        expect(controller.detailText.contains("still unknown"), "success copy must keep the unavailable phone's location state honest")

        let cancelledRecord = Box<MockLocationJournalRecord?>(persistentRecord)
        let cancelRemoveCount = Counter()
        let cancelled = MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: MockLocationJournalClient(
                load: { cancelledRecord.value },
                write: { cancelledRecord.value = try $0.validated() },
                remove: {
                    cancelRemoveCount.value += 1
                    cancelledRecord.value = nil
                }
            )
        )
        cancelled.configureHost(.init(
            currentSnapshot: { differentSnapshot },
            hostGate: { .idle },
            requestFreshEvidence: { _ in },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(!cancelled.forgetUnavailableIPhoneRecord(), "Cancel must refuse local record deletion")
        expect(cancelRemoveCount.value == 0 && cancelledRecord.value == persistentRecord, "Cancel must preserve the exact journal")
        expect(cancelled.isAssumedPersistent && cancelled.blocksDeviceMutation, "Cancel must preserve the persistent safety lock")

        let failedRecord = Box<MockLocationJournalRecord?>(persistentRecord)
        let failedRemoveCount = Counter()
        let removalFailure = MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: MockLocationJournalClient(
                load: { failedRecord.value },
                write: { failedRecord.value = try $0.validated() },
                remove: {
                    failedRemoveCount.value += 1
                    throw MockLocationJournalError.cannotWrite
                }
            )
        )
        removalFailure.configureHost(.init(
            currentSnapshot: { differentSnapshot },
            hostGate: { .idle },
            requestFreshEvidence: { _ in },
            confirmForgetUnavailableRecord: { _ in true },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(!removalFailure.forgetUnavailableIPhoneRecord(), "journal removal failure must fail closed")
        expect(failedRemoveCount.value == 1 && failedRecord.value == persistentRecord, "removal failure must preserve the journal")
        expect(removalFailure.isAssumedPersistent && removalFailure.blocksDeviceMutation, "removal failure must preserve the global lock")
        expect(removalFailure.lastError != nil, "removal failure must expose a bounded local error")

        var reconnectedSnapshot = targetFixture()
        reconnectedSnapshot.locationID = 2_097_152
        let sameRecord = Box<MockLocationJournalRecord?>(persistentRecord)
        let sameConfirmationCount = Counter()
        let sameStable = MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: MockLocationJournalClient(
                load: { sameRecord.value },
                write: { sameRecord.value = try $0.validated() },
                remove: { sameRecord.value = nil }
            )
        )
        sameStable.configureHost(.init(
            currentSnapshot: { reconnectedSnapshot },
            hostGate: { .idle },
            requestFreshEvidence: { _ in },
            confirmForgetUnavailableRecord: { _ in
                sameConfirmationCount.value += 1
                return true
            },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(sameStable.safetyRecordMatch == .sameStableIPhoneNewConnection, "USB-only change must preserve the same stable identity")
        expect(!sameStable.canForgetUnavailableRecord, "same stable iPhone on a new USB path must use guarded Clear, not Forget")
        expect(!sameStable.forgetUnavailableIPhoneRecord() && sameConfirmationCount.value == 0, "same-phone direct Forget calls must be no-ops")
        expect(sameRecord.value == persistentRecord && sameStable.blocksDeviceMutation, "same-phone Forget denial must preserve the journal and lock")

        let raceRecord = Box<MockLocationJournalRecord?>(persistentRecord)
        let raceSnapshot = Box(differentSnapshot)
        let raceRemoveCount = Counter()
        let identityRace = MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: MockLocationJournalClient(
                load: { raceRecord.value },
                write: { raceRecord.value = try $0.validated() },
                remove: {
                    raceRemoveCount.value += 1
                    raceRecord.value = nil
                }
            )
        )
        identityRace.configureHost(.init(
            currentSnapshot: { raceSnapshot.value },
            hostGate: { .idle },
            requestFreshEvidence: { _ in },
            confirmForgetUnavailableRecord: { _ in
                raceSnapshot.value = targetFixture()
                return true
            },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(!identityRace.forgetUnavailableIPhoneRecord(), "confirmation-time target change must abort local deletion")
        expect(raceRemoveCount.value == 0 && raceRecord.value == persistentRecord, "identity race must preserve the exact journal")
        expect(identityRace.blocksDeviceMutation, "identity race must retain the safety lock")

        let noRecord = Box<MockLocationJournalRecord?>(nil)
        let noRecordConfirmationCount = Counter()
        let noRecordRemoveCount = Counter()
        let noRecordFreshEvidenceCount = Counter()
        let cleanController = MockLocationController(
            resolveBackend: { .failure(.missing) },
            journal: MockLocationJournalClient(
                load: { noRecord.value },
                write: { noRecord.value = try $0.validated() },
                remove: {
                    noRecordRemoveCount.value += 1
                    noRecord.value = nil
                }
            )
        )
        cleanController.configureHost(.init(
            currentSnapshot: { differentSnapshot },
            hostGate: { .idle },
            requestFreshEvidence: { _ in noRecordFreshEvidenceCount.value += 1 },
            confirmForgetUnavailableRecord: { _ in
                noRecordConfirmationCount.value += 1
                return true
            },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in false },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        expect(cleanController.safetyRecordMatch == .none, "a controller without a journal must report no safety-record match")
        expect(!cleanController.shouldOfferForgetUnavailableRecord && !cleanController.canForgetUnavailableRecord, "a controller without a journal must never offer Forget")
        expect(!cleanController.forgetUnavailableIPhoneRecord(), "a direct Forget call without a journal must be a no-op")
        expect(
            noRecordConfirmationCount.value == 0 &&
                noRecordRemoveCount.value == 0 &&
                noRecordFreshEvidenceCount.value == 0,
            "a no-journal Forget call must not confirm, remove, or contact a device"
        )
        expect(cleanController.simulationKnowledge == .notRequested && !cleanController.blocksDeviceMutation, "a clean controller must remain unlocked after a no-op Forget call")
    }

    private static func testControllerLifecycle(expect: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-MockLocation-Lifecycle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("mock-backend")
        let script = #"""
#!/bin/zsh
IFS= read -r initial_request
/usr/bin/printf '%s\n' '{"event":"hello","protocol":1,"backend_version":"fixture-1"}'
/usr/bin/printf '%s\n' '{"event":"attested","product_type":"iPhone12,8"}'
/usr/bin/printf '%s\n' '{"event":"ready"}'
case "$1" in
  probe)
    exit 0
    ;;
  set)
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"active"}'
    IFS= read -r clear_request
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"clearSent"}'
    exit 0
    ;;
  set-persistent)
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"active","persistence":"experimental"}'
    exit 0
    ;;
  clear)
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"clearSent"}'
    exit 0
    ;;
esac
exit 2
"""#
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            expect(false, "lifecycle fixture backend could not be created: \(error)")
            return
        }

        let descriptor = MockLocationBackendDescriptor(executableURL: executable)
        var journalRecord: MockLocationJournalRecord?
        var journalHistory: [MockLocationJournalRecord] = []
        let journal = MockLocationJournalClient(
            load: { journalRecord },
            write: {
                let validated = try $0.validated()
                journalRecord = validated
                journalHistory.append(validated)
            },
            remove: { journalRecord = nil }
        )
        let controller = MockLocationController(
            resolveBackend: { .success(descriptor) },
            journal: journal,
            now: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        var snapshot = targetFixture()
        var preflightCount = 0
        var confirmationCount = 0
        var persistentConfirmationCount = 0
        var reconnectedClearConfirmationCount = 0
        controller.configureHost(.init(
            currentSnapshot: { snapshot },
            hostGate: { .idle },
            requestFreshEvidence: { completion in
                preflightCount += 1
                completion(MockLocationFreshEvidence(snapshot: snapshot, pairingAndTrustVerified: true))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, mode in
                confirmationCount += 1
                if mode == .persistentUntilClearOrReboot {
                    persistentConfirmationCount += 1
                }
                return true
            },
            confirmUnpinnedClear: { _ in true },
            confirmReconnectedClear: { _, _ in
                reconnectedClearConfirmationCount += 1
                return true
            }
        ))

        controller.checkReadiness()
        waitUntil(timeout: 3) {
            if case .ready = controller.readiness { return true }
            return false
        }
        expect(controller.canSetLocation, "valid hello→attested→ready probe must enable Set")

        if let coordinate = try? MockLocationCoordinate(latitude: 16.8409, longitude: 96.1735) {
            controller.setLocation(coordinate)
        } else {
            expect(false, "lifecycle coordinate fixture must be valid")
            return
        }
        waitUntil(timeout: 3) { controller.isAssumedActive }
        expect(
            controller.isAssumedActive,
            "valid set stream must reach assumed-active only after active acknowledgement (status: \(controller.statusText); detail: \(controller.detailText); error: \(controller.lastError ?? "none"))"
        )
        expect(controller.blocksDeviceMutation, "assumed-active state must hold the global mutation lock")
        expect(journalRecord?.state == .assumedActive, "active acknowledgement must be crash-journaled")
        expect(preflightCount == 3, "readiness plus Set must perform one probe preflight and two target/Trust preflights")
        expect(confirmationCount == 1, "Set must require exactly one explicit confirmation")

        controller.returnToRealLocation()
        waitUntil(timeout: 3) {
            // `clearSent` is a protocol acknowledgement, while the helper may still
            // need a brief moment to close its long-lived process. Wait for both the
            // honest reset claim and coordinator cleanup before asserting that the
            // global mutation lock has been released.
            if case .resetRequestSent = controller.simulationKnowledge {
                return !controller.blocksDeviceMutation
            }
            return false
        }
        if case .resetRequestSent = controller.simulationKnowledge {
            expect(true, "valid clear stream must report reset request sent")
        } else {
            expect(
                false,
                "valid clear stream must not remain active or uncertain (status: \(controller.statusText); detail: \(controller.detailText); error: \(controller.lastError ?? "none"))"
            )
        }
        expect(journalRecord == nil, "clearSent must remove the crash-safety journal")
        expect(!controller.blocksDeviceMutation, "reset-request-sent state must release the mutation lock")
        expect(preflightCount == 5, "Return to Real Location must recheck exact target and Trust both before and after any confirmation boundary")

        if let coordinate = try? MockLocationCoordinate(latitude: 13.7563, longitude: 100.5018) {
            controller.setLocation(coordinate, mode: .persistentUntilClearOrReboot)
        }
        waitUntil(timeout: 3) { controller.isAssumedPersistent && !controller.isBusy }
        expect(controller.isAssumedPersistent, "persistent Set must promote only after its marked active event and clean process exit")
        expect(controller.blocksDeviceMutation, "assumed-persistent state must hold the global mutation lock after backend exit")
        expect(journalRecord?.state == .assumedPersistent, "clean persistent exit must be durably journaled")
        expect(journalRecord?.setMode == .persistentUntilClearOrReboot, "persistent journal must retain the explicit mode")
        expect(persistentConfirmationCount == 1, "experimental persistent Set must receive its distinct confirmation mode")
        expect(preflightCount == 7, "persistent Set must retain both exact-target and Trust preflights")

        snapshot = DeviceSnapshot()
        controller.refreshLocalState()
        expect(controller.isAssumedPersistent, "expected USB disconnect must preserve assumed-persistent state")
        expect(journalRecord?.state == .assumedPersistent, "disconnect must not remove or downgrade the persistent journal")
        expect(!controller.canReturnToRealLocation, "Clear must remain unavailable while the pinned phone is disconnected")

        var wrongPhone = targetFixture()
        wrongPhone.ecid = "0xABCDEF12345678"
        wrongPhone.udid = "00008030-00ABCDEF12345678"
        snapshot = wrongPhone
        controller.refreshLocalState()
        expect(controller.isAssumedPersistent, "a different connected phone must not take ownership of the original persistent record")
        expect(!controller.canReturnToRealLocation, "a different phone must never be eligible for Clear")

        var reconnected = targetFixture()
        reconnected.locationID = 2_097_152
        snapshot = reconnected
        controller.refreshLocalState()
        expect(controller.canReturnToRealLocation, "the same stable phone on a new USB path must be eligible for guarded Clear")
        controller.returnToRealLocation()
        waitUntil(timeout: 3) {
            if case .resetRequestSent = controller.simulationKnowledge {
                return !controller.blocksDeviceMutation
            }
            return false
        }
        expect(reconnectedClearConfirmationCount == 1, "changed-port Clear must require one critical confirmation")
        expect(preflightCount == 9, "changed-port Clear must verify exact target and Trust before and after confirmation")
        let persistentClearWrites = journalHistory.suffix(3)
        expect(
            persistentClearWrites.contains { $0.state == .pendingClear && !$0.requestDispatched },
            "Clear must durably write pendingClear before the backend can be launched"
        )
        expect(journalRecord == nil, "successful changed-port Clear must remove the persistent journal")
        expect(!controller.blocksDeviceMutation, "successful changed-port Clear must release the persistent mutation lock")

        var trustCheckCount = 0
        var rejectedJournal: MockLocationJournalRecord?
        let secondTrustFailure = MockLocationController(
            resolveBackend: { .success(descriptor) },
            journal: MockLocationJournalClient(
                load: { rejectedJournal },
                write: { rejectedJournal = try $0.validated() },
                remove: { rejectedJournal = nil }
            )
        )
        secondTrustFailure.configureHost(.init(
            currentSnapshot: { snapshot },
            hostGate: { .idle },
            requestFreshEvidence: { completion in
                trustCheckCount += 1
                completion(MockLocationFreshEvidence(
                    snapshot: snapshot,
                    pairingAndTrustVerified: trustCheckCount != 3
                ))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in true },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        secondTrustFailure.checkReadiness()
        waitUntil(timeout: 3) {
            if case .ready = secondTrustFailure.readiness { return true }
            return false
        }
        if let coordinate = try? MockLocationCoordinate(latitude: 1, longitude: 1) {
            secondTrustFailure.setLocation(coordinate)
        }
        waitUntil(timeout: 3) { !secondTrustFailure.isBusy }
        expect(trustCheckCount == 3, "Set must perform the post-confirmation Trust recheck")
        expect(!secondTrustFailure.isAssumedActive, "a failed second Trust check must never start simulation")
        expect(rejectedJournal == nil, "a failed second Trust check must not create a mutation journal")
        expect(
            secondTrustFailure.lastError == MockLocationReadinessIssue.pairingRequired.userDescription,
            "a failed second Trust check must report the pairing requirement"
        )
    }

    private static func testPersistentFailureLifecycle(expect: (Bool, String) -> Void) {
        let scenarios: [(String, String)] = [
            (
                "missing-marker",
                "/usr/bin/printf '%s\\n' '{\"event\":\"requestDispatched\"}'; /usr/bin/printf '%s\\n' '{\"event\":\"active\"}'; exit 0"
            ),
            (
                "stderr-after-active",
                "/usr/bin/printf '%s\\n' '{\"event\":\"requestDispatched\"}'; /usr/bin/printf '%s\\n' '{\"event\":\"active\",\"persistence\":\"experimental\"}'; /usr/bin/printf '%s\\n' 'sanitized fixture stderr' >&2; exit 0"
            ),
            (
                "nonzero-after-active",
                "/usr/bin/printf '%s\\n' '{\"event\":\"requestDispatched\"}'; /usr/bin/printf '%s\\n' '{\"event\":\"active\",\"persistence\":\"experimental\"}'; exit 7"
            ),
            (
                "cleanup-hang",
                "/usr/bin/printf '%s\\n' '{\"event\":\"requestDispatched\"}'; /usr/bin/printf '%s\\n' '{\"event\":\"active\",\"persistence\":\"experimental\"}'; while true; do :; done"
            )
        ]

        for (name, persistentBody) in scenarios {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("YIOS-Persistent-Failure-\(name)-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let executable = root.appendingPathComponent("mock-backend")
            let script = """
            #!/bin/zsh
            IFS= read -r initial_request
            /usr/bin/printf '%s\\n' '{"event":"hello","protocol":1,"backend_version":"fixture-1"}'
            /usr/bin/printf '%s\\n' '{"event":"attested","product_type":"iPhone12,8"}'
            /usr/bin/printf '%s\\n' '{"event":"ready"}'
            case "$1" in
              probe) exit 0 ;;
              set-persistent) \(persistentBody) ;;
            esac
            exit 2
            """
            do {
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try Data(script.utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            } catch {
                expect(false, "\(name) persistent fixture could not be created: \(error)")
                continue
            }

            let descriptor = MockLocationBackendDescriptor(executableURL: executable)
            var journalRecord: MockLocationJournalRecord?
            let controller = MockLocationController(
                resolveBackend: { .success(descriptor) },
                journal: MockLocationJournalClient(
                    load: { journalRecord },
                    write: { journalRecord = try $0.validated() },
                    remove: { journalRecord = nil }
                ),
                persistentTeardownTimeout: 1
            )
            let snapshot = targetFixture()
            controller.configureHost(.init(
                currentSnapshot: { snapshot },
                hostGate: { .idle },
                requestFreshEvidence: { completion in
                    completion(MockLocationFreshEvidence(snapshot: snapshot, pairingAndTrustVerified: true))
                },
                confirmForgetUnavailableRecord: { _ in false },
                confirmDeveloperModeOptionRequest: { _ in false },
                confirmSet: { _, _, _ in true },
                confirmUnpinnedClear: { _ in false },
                confirmReconnectedClear: { _, _ in false }
            ))
            controller.checkReadiness()
            waitUntil(timeout: 3) {
                if case .ready = controller.readiness { return true }
                return false
            }
            if let coordinate = try? MockLocationCoordinate(latitude: 1, longitude: 1) {
                controller.setLocation(coordinate, mode: .persistentUntilClearOrReboot)
            }
            waitUntil(timeout: 5) { !controller.isBusy }
            expect(!controller.isAssumedPersistent, "\(name) must never promote to assumed persistent")
            expect(controller.reviewRequired, "\(name) must retain a conservative review lock")
            expect(controller.blocksDeviceMutation, "\(name) must keep every other device mutation blocked")
            expect(journalRecord?.state == .uncertain, "\(name) must end with a durable uncertain journal")
        }
    }

    private static func testPersistentClearGuards(expect: (Bool, String) -> Void) {
        guard let originalTarget = try? MockLocationExactTarget(snapshot: targetFixture()) else { return }
        var reconnectedSnapshot = targetFixture()
        reconnectedSnapshot.locationID = 2_097_152
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        let persistent = MockLocationJournalRecord(
            state: .assumedPersistent,
            pin: originalTarget.pin,
            stablePin: originalTarget.stablePin,
            setMode: .persistentUntilClearOrReboot,
            requestDispatched: true,
            createdAt: timestamp,
            updatedAt: timestamp
        )
        let descriptor = MockLocationBackendDescriptor(executableURL: URL(fileURLWithPath: "/fixture/mock-backend"))

        // Build these cases directly instead of launching the nonexistent fixture helper:
        // every rejected path must stop before a Clear subprocess can start.
        for scenario in ["cancel", "first-trust", "second-trust"] {
            var record: MockLocationJournalRecord? = persistent
            var evidenceCount = 0
            var confirmationCount = 0
            let trustResults: [Bool]
            let confirms: Bool
            switch scenario {
            case "cancel":
                trustResults = [true]
                confirms = false
            case "first-trust":
                trustResults = [false]
                confirms = true
            default:
                trustResults = [true, false]
                confirms = true
            }
            let controller = MockLocationController(
                resolveBackend: { .success(descriptor) },
                journal: MockLocationJournalClient(
                    load: { record },
                    write: { record = try $0.validated() },
                    remove: { record = nil }
                )
            )
            controller.configureHost(.init(
                currentSnapshot: { reconnectedSnapshot },
                hostGate: { .idle },
                requestFreshEvidence: { completion in
                    let index = evidenceCount
                    evidenceCount += 1
                    let trusted = index < trustResults.count ? trustResults[index] : false
                    completion(MockLocationFreshEvidence(snapshot: reconnectedSnapshot, pairingAndTrustVerified: trusted))
                },
                confirmForgetUnavailableRecord: { _ in false },
                confirmDeveloperModeOptionRequest: { _ in false },
                confirmSet: { _, _, _ in false },
                confirmUnpinnedClear: { _ in false },
                confirmReconnectedClear: { _, _ in
                    confirmationCount += 1
                    return confirms
                }
            ))
            controller.returnToRealLocation()
            waitUntil(timeout: 1) { !controller.isBusy }
            expect(controller.isAssumedPersistent, "\(scenario) changed-port rejection must preserve assumed-persistent state")
            expect(controller.blocksDeviceMutation, "\(scenario) changed-port rejection must retain the mutation lock")
            expect(record == persistent, "\(scenario) changed-port rejection must preserve the original journal")
            switch scenario {
            case "cancel":
                expect(evidenceCount == 1 && confirmationCount == 1, "cancel must stop after the first fresh Trust check and confirmation")
            case "first-trust":
                expect(evidenceCount == 1 && confirmationCount == 0, "first Trust failure must stop before confirmation")
            default:
                expect(evidenceCount == 2 && confirmationCount == 1, "second Trust failure must occur only after confirmation and the second fresh check")
            }
        }
    }

    private static func testOutOfOrderActiveKeepsDeadline(expect: (Bool, String) -> Void) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-MockLocation-Deadline-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("bad-backend")
        let script = "#!/bin/zsh\nIFS= read -r initial_request\n/usr/bin/printf '%s\\n' '{\"event\":\"active\"}'\nIFS= read -r never_sent\n"
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        } catch {
            expect(false, "deadline fixture backend could not be created: \(error)")
            return
        }

        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()),
              let coordinate = try? MockLocationCoordinate(latitude: 1, longitude: 1) else { return }
        let command = MockLocationCommandBuilder.set(
            backend: MockLocationBackendDescriptor(executableURL: executable),
            target: target,
            coordinate: coordinate
        )
        let coordinator = MockLocationProcessCoordinator()
        var sawActive = false
        var completion: MockLocationProcessCompletion?
        let result = coordinator.start(
            command,
            handshakeTimeout: 1,
            onEvent: { _, event in
                if event.kind == .active { sawActive = true }
            },
            completion: { _, value in completion = value }
        )
        if case .failure = result {
            expect(false, "out-of-order lifecycle fixture must launch")
            return
        }
        waitUntil(timeout: 5) { completion != nil }
        expect(sawActive, "fixture must emit the out-of-order active event")
        expect(completion?.timedOut == true, "an unvalidated active event must never cancel the handshake deadline")
    }

    private static func waitUntil(timeout: TimeInterval, condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !condition() {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }
}
