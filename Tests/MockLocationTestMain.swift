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

    @MainActor
    private final class WiFiHostState {
        var snapshot = MockLocationTestMain.targetFixture(productType: "iPhone18,3")
        var gate: MockLocationHostGate = .idle
        var trustResults: [Bool] = []
        var preflightCount = 0
        var enableConfirmationCount = 0
        var setConfirmationCount = 0
        var reconnectConfirmationCount = 0
        var confirmEnable = true
        var confirmReconnect = true
        var afterEnableConfirmation: (() -> Void)?
    }

    static func main() {
        var failures: [String] = []
        func expect(_ condition: Bool, _ message: String) {
            if !condition { failures.append(message) }
        }

        testCoordinates(expect: expect)
        testExactTarget(expect: expect)
        testGenericTargets(expect: expect)
        testJournal(expect: expect)
        testBackendCommand(expect: expect)
        testBackendProtocol(expect: expect)
        testWiFiCommandAndProtocol(expect: expect)
        testBundledResolver(expect: expect)
        testOfflineController(expect: expect)
        testDeveloperModeOptionLifecycle(expect: expect)
        testDeveloperModeStablePinRecoveryGate(expect: expect)
        testForgetUnavailableRecord(expect: expect)
        testControllerLifecycle(expect: expect)
        testGenericControllerAttestation(expect: expect)
        testWiFiSetupGuards(expect: expect)
        testWiFiSessionLifecycle(expect: expect)
        testWiFiConnectionLossRecovery(expect: expect)
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

    private static func targetFixture(productType: String = "iPhone12,8") -> DeviceSnapshot {
        DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: 1_048_576,
            ecid: "0x123456789ABCDE",
            udid: "00008030-00123456789ABCDE",
            productType: productType,
            hardwareModel: productType == "iPhone12,8" ? "d79ap" : nil,
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
        expect(target.pin.fingerprint == "225c9b6d88ef87b0d43fff786436a8476ab2dd26ece32940019f145d62c79d70", "existing SE2 connection fingerprints must remain backward-compatible")
        expect(target.stablePin.fingerprint == "0d8ff32e4e4ec48838d3bacfd3425b444bf65c3143b6741bf05ca7ba76108283", "existing SE2 stable fingerprints must remain backward-compatible")
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

    private static func testGenericTargets(expect: (Bool, String) -> Void) {
        let products = ["iPhone8,4", "iPhone10,4", "iPhone12,1", "iPhone12,8", "iPhone13,1", "iPhone15,4", "iPhone18,3", "iPhone99,9", "iPhone19,0"]
        var connectionPins = Set<MockLocationTargetPin>()
        var stablePins = Set<MockLocationTargetPin>()
        for product in products {
            var snapshot = targetFixture()
            snapshot.productType = product
            snapshot.hardwareModel = nil
            snapshot.chipID = nil
            snapshot.boardID = nil
            guard let target = try? MockLocationExactTarget(snapshot: snapshot) else {
                expect(false, "generic verified iPhone \(product) must not require SE2 or a hardware catalog entry")
                continue
            }
            expect(target.productType == product && target.matches(snapshot), "generic target must preserve its exact ProductType")
            expect(MockLocationExactTarget.stablePin(for: snapshot) == target.stablePin, "generic stable pin must preserve exact product identity")
            connectionPins.insert(target.pin)
            stablePins.insert(target.stablePin)
            var swappedProduct = snapshot
            swappedProduct.productType = product == "iPhone15,4" ? "iPhone13,1" : "iPhone15,4"
            expect(!target.matches(swappedProduct), "a different valid iPhone ProductType must never match the pinned target")
            var changedPort = snapshot
            changedPort.locationID = 2_097_152
            expect(!target.matches(changedPort), "generic exact pin must still reject a changed USB connection")
            expect(MockLocationExactTarget.stablePin(for: changedPort) == target.stablePin, "generic stable pin must survive only a connection change")
        }
        expect(connectionPins.count == products.count && stablePins.count == products.count, "different iPhone ProductTypes must produce distinct connection and stable pins")

        let invalidSnapshots: [(String, (inout DeviceSnapshot) -> Void)] = [
            ("no device", { $0.deviceCount = 0 }),
            ("multiple devices", { $0.deviceCount = 2 }),
            ("Recovery", { $0.mode = .recovery }),
            ("DFU", { $0.mode = .dfu }),
            ("unverified Normal iOS", { $0.modeVerified = false }),
            ("identity conflict", { $0.identityConflict = true }),
            ("missing ECID", { $0.ecid = nil }),
            ("zero ECID", { $0.ecid = "0" }),
            ("invalid ECID", { $0.ecid = "not-an-ecid" }),
            ("missing UDID", { $0.udid = nil }),
            ("empty UDID", { $0.udid = "" }),
            ("malformed UDID", { $0.udid = "bad udid" }),
            ("short UDID", { $0.udid = "short" }),
            ("oversized UDID", { $0.udid = String(repeating: "A", count: 65) }),
            ("missing USB location", { $0.locationID = nil }),
            ("invalid USB location", { $0.locationID = -1 }),
            ("missing ProductType", { $0.productType = nil }),
            ("empty ProductType", { $0.productType = "" }),
            ("non-iPhone", { $0.productType = "iPad13,1" }),
            ("zero major", { $0.productType = "iPhone0,1" }),
            ("leading-zero major", { $0.productType = "iPhone013,1" }),
            ("leading-zero minor", { $0.productType = "iPhone13,01" }),
            ("padded ProductType", { $0.productType = " iPhone13,1" }),
            ("newline ProductType", { $0.productType = "iPhone13,1\n" }),
            ("overflowing major", { $0.productType = "iPhone9223372036854775808,1" }),
            ("overflowing minor", { $0.productType = "iPhone13,9223372036854775808" }),
            ("oversized ProductType", { $0.productType = "iPhone" + String(repeating: "9", count: 30) + ",1" })
        ]
        for (name, mutate) in invalidSnapshots {
            var invalid = targetFixture()
            invalid.productType = "iPhone18,3"
            mutate(&invalid)
            expect((try? MockLocationExactTarget(snapshot: invalid)) == nil, "generic target must reject \(name)")
        }
        var conflicted = targetFixture()
        conflicted.identityConflict = true
        expect(MockLocationExactTarget.stablePin(for: conflicted) == nil, "stable pin must not accept conflicting identity evidence")
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
            expect(try store.load() == persistent, "persistent journal must round-trip with separate stable and connection pins")

            let wifiActive = MockLocationJournalRecord(
                state: .assumedActive,
                pin: target.pin,
                stablePin: target.stablePin,
                transport: .wifi,
                requestDispatched: true,
                createdAt: created,
                updatedAt: created.addingTimeInterval(3)
            )
            try store.write(wifiActive)
            expect(try store.load() == wifiActive, "schema-v3 Wi-Fi recovery must round-trip its explicit transport")
            let wifiText = try String(contentsOf: url, encoding: .utf8)
            expect(wifiText.contains("wifi"), "Wi-Fi journal must retain transport without connection addresses")
            expect(!wifiText.contains(target.udid) && !wifiText.localizedCaseInsensitiveContains(target.ecid), "Wi-Fi journal must never retain raw stable device identifiers")
            expect(!wifiText.contains(String(target.locationID)) && !wifiText.contains("16.8409") && !wifiText.contains("96.1735"), "Wi-Fi journal must contain neither USB location nor coordinates")

            var schemaTwoObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(persistent)) as? [String: Any] ?? [:]
            schemaTwoObject["schema"] = 2
            schemaTwoObject.removeValue(forKey: "transport")
            let schemaTwo = try JSONDecoder().decode(MockLocationJournalRecord.self, from: JSONSerialization.data(withJSONObject: schemaTwoObject))
            expect(try schemaTwo.validated().transport == .usb, "existing schema-v2 journals must default missing transport to USB")
            expect(schemaTwo.stablePin == persistent.stablePin && schemaTwo.pin == persistent.pin, "schema migration must preserve the original stable and connection fingerprints")

            var forgedWiFiObject = schemaTwoObject
            forgedWiFiObject["transport"] = "wifi"
            let forgedWiFi = try JSONDecoder().decode(MockLocationJournalRecord.self, from: JSONSerialization.data(withJSONObject: forgedWiFiObject))
            do {
                _ = try forgedWiFi.validated()
                expect(false, "pre-Wi-Fi schemas must reject a forged Network transport")
            } catch {
                expect(true, "legacy schema transport confusion must fail closed")
            }
            let persistentWiFi = MockLocationJournalRecord(
                state: .assumedPersistent,
                pin: target.pin,
                stablePin: target.stablePin,
                setMode: .persistentUntilClearOrReboot,
                transport: .wifi,
                requestDispatched: true,
                createdAt: created,
                updatedAt: created.addingTimeInterval(4)
            )
            do {
                _ = try persistentWiFi.validated()
                expect(false, "Wi-Fi journals must reject unsupported one-shot persistent mode")
            } catch {
                expect(true, "invalid Wi-Fi mode must fail closed")
            }

            var legacyObject = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(pending)
            ) as? [String: Any] ?? [:]
            legacyObject["schema"] = 1
            legacyObject.removeValue(forKey: "stableTargetFingerprint")
            legacyObject.removeValue(forKey: "setMode")
            legacyObject.removeValue(forKey: "transport")
            let legacyData = try JSONSerialization.data(withJSONObject: legacyObject)
            let legacy = try JSONDecoder().decode(MockLocationJournalRecord.self, from: legacyData)
            expect(try legacy.validated().schema == 1, "schema-v1 journals must remain decodable for conservative recovery")
            expect(legacy.stablePin == nil, "schema-v1 journals must not invent a stable identity pin")
            expect(legacy.transport == .usb, "schema-v1 journals must default missing transport to USB")

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

        var genericSnapshot = targetFixture()
        genericSnapshot.productType = "iPhone18,3"
        genericSnapshot.hardwareModel = nil
        guard let genericTarget = try? MockLocationExactTarget(snapshot: genericSnapshot) else {
            expect(false, "generic command fixture must initialize")
            return
        }
        let genericCommands = [
            MockLocationCommandBuilder.probe(backend: backend, target: genericTarget),
            MockLocationCommandBuilder.set(backend: backend, target: genericTarget, coordinate: coordinate),
            MockLocationCommandBuilder.setPersistent(backend: backend, target: genericTarget, coordinate: coordinate),
            MockLocationCommandBuilder.clear(backend: backend, target: genericTarget),
            MockLocationCommandBuilder.revealDeveloperMode(backend: backend, target: genericTarget)
        ]
        for genericCommand in genericCommands {
            let request = try? JSONSerialization.jsonObject(with: Data(genericCommand.initialRequest.dropLast())) as? [String: Any]
            expect(request?["expectedProductType"] as? String == genericTarget.productType, "every generic operation must pin the requested ProductType over stdin")
            expect(request?["udid"] as? String == genericTarget.udid, "every generic operation must pin the requested UDID over stdin")
            expect(!genericCommand.arguments.joined().contains(genericTarget.udid), "generic identifiers must remain absent from process argv")
        }
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

        for product in ["iPhone8,4", "iPhone15,4", "iPhone18,3", "iPhone19,0"] {
            let result = MockLocationBackendEventParser.parse(line: "{\"event\":\"attested\",\"product_type\":\"\(product)\"}")
            if case .success(let event) = result {
                expect(event.kind == .attested && event.productType == product, "generic backend product attestation must preserve exact syntax")
            } else {
                expect(false, "valid generic attestation \(product) should parse")
            }
        }
        for product in ["iPad13,1", "iPhone", "iPhone0,1", "iPhone13,01", " iPhone13,1", "iPhone13,1 ", "iPhone9223372036854775808,1", "iPhone13,9223372036854775808"] {
            let result = MockLocationBackendEventParser.parse(line: "{\"event\":\"attested\",\"product_type\":\"\(product)\"}")
            if case .failure(.invalidEvent) = result {
                expect(true, "invalid product attestation must fail closed")
            } else {
                expect(false, "malformed or non-iPhone attestation \(product) must be rejected")
            }
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

    private static func testWiFiCommandAndProtocol(expect: (Bool, String) -> Void) {
        guard let target = try? MockLocationExactTarget(snapshot: targetFixture()),
              let coordinate = try? MockLocationCoordinate(latitude: 16.8409, longitude: 96.1735) else {
            expect(false, "Wi-Fi command fixtures must initialize")
            return
        }
        let backend = MockLocationBackendDescriptor(executableURL: URL(fileURLWithPath: "/fixture/private-backend"))
        let commands = [
            MockLocationCommandBuilder.probe(backend: backend, target: target, transport: .wifi),
            MockLocationCommandBuilder.set(backend: backend, target: target, coordinate: coordinate, transport: .wifi),
            MockLocationCommandBuilder.clear(backend: backend, target: target, transport: .wifi)
        ]
        for command in commands {
            let request = try? JSONSerialization.jsonObject(with: Data(command.initialRequest.dropLast())) as? [String: Any]
            expect(request?["transport"] as? String == "wifi", "Wi-Fi commands must force the network transport over private stdin")
            expect(request?["expectedECID"] as? String == target.ecid, "Wi-Fi commands must attest the exact stable ECID")
            expect(request?["udid"] as? String == target.udid, "Wi-Fi commands must pin the bootstrapped UDID")
            expect(request?["expectedProductType"] as? String == target.productType, "Wi-Fi commands must pin the exact ProductType")
            expect(command.arguments == [command.operation.rawValue], "Wi-Fi identifiers and coordinates must never enter argv")
        }
        let enable = MockLocationCommandBuilder.enableWiFi(backend: backend, target: target)
        let setupRequest = try? JSONSerialization.jsonObject(with: Data(enable.initialRequest.dropLast())) as? [String: Any]
        expect(enable.arguments == ["enable-wifi"] && enable.operation == .enableWiFi, "Wi-Fi setup must have its own allowlisted USB operation")
        expect(setupRequest?["expectedECID"] as? String == target.ecid, "Wi-Fi setup must pin ECID before changing the connection preference")
        expect(setupRequest?["udid"] as? String == target.udid && setupRequest?["expectedProductType"] as? String == target.productType, "Wi-Fi setup must preserve all stable target fields")
        expect(setupRequest?["latitude"] == nil && setupRequest?["longitude"] == nil, "Wi-Fi setup must never carry a coordinate")

        let enabled = MockLocationBackendEventParser.parse(line: #"{"event":"wifiEnabled","status":"ok"}"#)
        if case .success(let event) = enabled {
            expect(event.kind == .wifiEnabled, "Wi-Fi setup acknowledgement must parse distinctly from location activation")
        } else {
            expect(false, "valid Wi-Fi setup acknowledgement must parse")
        }
        let lost = MockLocationBackendEventParser.parse(line: #"{"event":"error","status":"uncertain","code":"connection_lost","phase":"transport"}"#)
        if case .success(let event) = lost {
            expect(event.errorCode == .connectionLost, "connection loss must remain a structured privacy-safe error")
        } else {
            expect(false, "transport connection loss must parse")
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

    private static func testControllerLifecycle(productType: String = "iPhone12,8", expect: (Bool, String) -> Void) {
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
"""#.replacingOccurrences(of: "iPhone12,8", with: productType)
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
        var snapshot = targetFixture(productType: productType)
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

        var wrongPhone = targetFixture(productType: productType)
        wrongPhone.ecid = "0xABCDEF12345678"
        wrongPhone.udid = "00008030-00ABCDEF12345678"
        snapshot = wrongPhone
        controller.refreshLocalState()
        expect(controller.isAssumedPersistent, "a different connected phone must not take ownership of the original persistent record")
        expect(!controller.canReturnToRealLocation, "a different phone must never be eligible for Clear")

        var reconnected = targetFixture(productType: productType)
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

    private static func writeWiFiBackendFixture(
        directory: URL,
        lossTrigger: URL? = nil
    ) throws -> (executable: URL, requestLog: URL) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("private-fake-backend")
        let requestLog = directory.appendingPathComponent("requests.jsonl")
        var script = #"""
#!/bin/zsh
IFS= read -r initial_request
/usr/bin/printf '%s|%s\n' "$1" "$initial_request" >> REQUEST_LOG
/usr/bin/printf '%s\n' '{"event":"hello","protocol":1,"backend_version":"1.3.0"}'
/usr/bin/printf '%s\n' '{"event":"attested","product_type":"iPhone18,3"}'
if [[ "$1" == "enable-wifi" ]]; then
  /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
  /usr/bin/printf '%s\n' '{"event":"wifiEnabled","status":"ok"}'
  exit 0
fi
/usr/bin/printf '%s\n' '{"event":"ready"}'
case "$1" in
  probe)
    exit 0
    ;;
  set)
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"active"}'
    LIVE_CONTROL
    /usr/bin/printf '%s|%s\n' 'live-control' "$clear_request" >> REQUEST_LOG
    /usr/bin/printf '%s\n' '{"event":"requestDispatched"}'
    /usr/bin/printf '%s\n' '{"event":"clearSent"}'
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
        // Paths are quoted as data; fixture requests never reach a device.
        let quotedLog = "'" + requestLog.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        script = script.replacingOccurrences(of: "REQUEST_LOG", with: quotedLog)
        let liveControl: String
        if let lossTrigger {
            let quotedTrigger = "'" + lossTrigger.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            liveControl = """
            while [[ ! -f \(quotedTrigger) ]]; do /bin/sleep 0.02; done
                /usr/bin/printf '%s\\n' '{"event":"error","status":"uncertain","code":"connection_lost","phase":"transport"}'
                exit 5
            """
        } else {
            liveControl = "IFS= read -r clear_request"
        }
        script = script.replacingOccurrences(of: "LIVE_CONTROL", with: liveControl)
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return (executable, requestLog)
    }

    private static func makeWiFiController(
        executable: URL,
        state: WiFiHostState,
        stored: Box<MockLocationJournalRecord?>
    ) -> MockLocationController {
        let controller = MockLocationController(
            resolveBackend: { .success(MockLocationBackendDescriptor(executableURL: executable)) },
            journal: MockLocationJournalClient(
                load: { stored.value },
                write: { stored.value = try $0.validated() },
                remove: { stored.value = nil }
            )
        )
        var callbacks = MockLocationController.HostCallbacks(
            currentSnapshot: { state.snapshot },
            hostGate: { state.gate },
            requestFreshEvidence: { completion in
                let index = state.preflightCount
                state.preflightCount += 1
                let trusted = index < state.trustResults.count ? state.trustResults[index] : true
                completion(MockLocationFreshEvidence(snapshot: state.snapshot, pairingAndTrustVerified: trusted))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in
                state.setConfirmationCount += 1
                return true
            },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in
                state.reconnectConfirmationCount += 1
                return state.confirmReconnect
            }
        )
        callbacks.confirmEnableWiFi = { _ in
            state.enableConfirmationCount += 1
            state.afterEnableConfirmation?()
            return state.confirmEnable
        }
        controller.configureHost(callbacks)
        return controller
    }

    private static func testWiFiSetupGuards(expect: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-WiFi-Setup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            for scenario in ["success", "cancel", "first-trust", "second-trust", "changed-after-confirmation"] {
                let fixture = try writeWiFiBackendFixture(directory: directory.appendingPathComponent(scenario))
                let state = WiFiHostState()
                let stored = Box<MockLocationJournalRecord?>(nil)
                switch scenario {
                case "cancel": state.confirmEnable = false
                case "first-trust": state.trustResults = [false]
                case "second-trust": state.trustResults = [true, false]
                case "changed-after-confirmation":
                    state.afterEnableConfirmation = { state.snapshot.ecid = "0xFFFFFFFF" }
                default: break
                }
                let controller = makeWiFiController(executable: fixture.executable, state: state, stored: stored)
                controller.selectTransport(.wifi)
                expect(controller.canEnableWiFi, "\(scenario): exact USB bootstrap must enable the guarded Wi-Fi setup action")
                controller.enableWiFiConnection()
                waitUntil(timeout: 3) { !controller.isBusy }
                expect(stored.value == nil, "\(scenario): Wi-Fi setup must not alter the simulation safety journal")
                expect(!controller.isAssumedActive && !controller.reviewRequired, "\(scenario): Wi-Fi setup must never claim an active simulated location")
                let launched = FileManager.default.fileExists(atPath: fixture.requestLog.path)
                if scenario == "success" {
                    expect(launched, "successful Wi-Fi setup must launch its exact USB operation")
                    expect(state.preflightCount == 2 && state.enableConfirmationCount == 1, "Wi-Fi setup must verify Trust before and after explicit confirmation")
                    expect(controller.readiness == .notChecked, "enabling Wi-Fi must require an independent Network readiness probe")
                } else {
                    expect(!launched, "\(scenario): rejected Wi-Fi setup must stop before launching a device operation")
                    expect(state.preflightCount == (scenario == "first-trust" || scenario == "cancel" ? 1 : 2), "\(scenario): setup must stop at the failing guard")
                }
                expect(!controller.blocksDeviceMutation, "\(scenario): completed Wi-Fi setup must release its temporary mutation lock")
            }
        } catch {
            expect(false, "Wi-Fi setup fixture could not be created")
        }
    }

    private static func testWiFiSessionLifecycle(expect: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-WiFi-Live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let fixture = try writeWiFiBackendFixture(directory: directory)
            let state = WiFiHostState()
            let stored = Box<MockLocationJournalRecord?>(nil)
            let controller = makeWiFiController(executable: fixture.executable, state: state, stored: stored)
            controller.checkReadiness()
            waitUntil(timeout: 3) { controller.canSetLocation }
            expect(controller.canSetLocation, "USB bootstrap fixture must first reach USB readiness")
            controller.selectTransport(.wifi)
            expect(controller.selectedTransport == .wifi && !controller.canSetLocation, "changing transport must invalidate USB readiness")
            controller.checkReadiness()
            waitUntil(timeout: 3) { controller.canSetLocation }
            expect(controller.canSetLocation, "an explicitly selected Wi-Fi readiness probe must permit live Set")

            let coordinate = try MockLocationCoordinate(latitude: 16.8409, longitude: 96.1735)
            let preflightBeforePersistent = state.preflightCount
            controller.setLocation(coordinate, mode: .persistentUntilClearOrReboot)
            expect(!controller.isBusy && stored.value == nil, "Wi-Fi must reject the experimental one-shot mode in core logic")
            expect(state.preflightCount == preflightBeforePersistent && state.setConfirmationCount == 0, "rejected Wi-Fi persistence must never launch a preflight or confirmation")

            controller.setLocation(coordinate)
            waitUntil(timeout: 3) { controller.isWiFiSessionActive }
            expect(controller.isWiFiSessionActive && controller.isAssumedActive, "Wi-Fi Set must reach active only after ordered backend acknowledgement")
            expect(controller.liveWiFiProductType == "iPhone18,3", "live Wi-Fi identity must come from the attested run")
            expect(!controller.canSelectTransport, "a live Network session must lock its selected transport")
            controller.selectTransport(.usb)
            expect(controller.selectedTransport == .wifi, "an active Wi-Fi session must never switch its live channel to USB")
            expect(stored.value?.transport == .wifi && stored.value?.state == .assumedActive, "Wi-Fi acknowledgement must durably retain its recovery transport")
            let preflightBeforeClear = state.preflightCount
            state.snapshot = DeviceSnapshot()
            controller.refreshLocalState()
            expect(controller.isWiFiSessionActive && !controller.reviewRequired, "expected USB removal must preserve the already-attested live Wi-Fi session")
            expect(controller.canReturnToRealLocation, "the captured Network session must support Clear without a USB snapshot")

            var different = targetFixture(productType: "iPhone18,3")
            different.ecid = "0xABCDEF1234"
            different.udid = "00008030-00ABCDEF12345678"
            different.productType = "iPhone15,4"
            state.snapshot = different
            controller.refreshLocalState()
            expect(controller.isWiFiSessionActive && !controller.reviewRequired, "a different USB phone must not take ownership of the attested Network channel")
            expect(controller.liveWiFiProductType == "iPhone18,3", "an unrelated USB ProductType must never replace the live Wi-Fi target facts")
            expect(controller.blocksDeviceMutation, "live Wi-Fi must hold the app-wide mutation lock even when another phone is plugged in")

            controller.returnToRealLocation()
            waitUntil(timeout: 3) { !controller.blocksDeviceMutation }
            if case .resetRequestSent = controller.simulationKnowledge {
                expect(true, "same-channel Wi-Fi Clear must report only that the reset request was sent")
            } else {
                expect(false, "same-channel Wi-Fi Clear must complete without requiring the unrelated USB phone")
            }
            expect(state.preflightCount == preflightBeforeClear, "same-channel Wi-Fi Clear must not run a USB Trust probe against another connected phone")
            expect(stored.value == nil && !controller.blocksDeviceMutation, "acknowledged Wi-Fi Clear must remove the journal and release the lock")
            let log = try String(contentsOf: fixture.requestLog, encoding: .utf8)
            let lines = log.split(separator: "\n").map(String.init)
            expect(lines.contains { $0.hasPrefix("probe|") && $0.contains("\"transport\":\"wifi\"") }, "Wi-Fi readiness must actually select Network in the private backend request")
            expect(lines.contains { $0.hasPrefix("set|") && $0.contains("\"transport\":\"wifi\"") }, "Wi-Fi live Set must actually select Network in the private backend request")
            expect(lines.filter { $0.hasPrefix("live-control|") }.count == 1, "Wi-Fi Clear must use exactly one command on the captured session")
            expect(!lines.contains { $0.hasPrefix("clear|") }, "live Wi-Fi Clear must never discover or launch a second target session")
            expect(!lines.contains { $0.hasPrefix("set-persistent|") }, "core Wi-Fi rejection must prevent one-shot persistence dispatch")
        } catch {
            expect(false, "Wi-Fi lifecycle fixture failed")
        }
    }

    private static func testWiFiConnectionLossRecovery(expect: (Bool, String) -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-WiFi-Loss-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        do {
            let lossTrigger = directory.appendingPathComponent("disconnect-network")
            let fixture = try writeWiFiBackendFixture(directory: directory, lossTrigger: lossTrigger)
            let state = WiFiHostState()
            let originalSnapshot = state.snapshot
            let stored = Box<MockLocationJournalRecord?>(nil)
            let controller = makeWiFiController(executable: fixture.executable, state: state, stored: stored)
            controller.selectTransport(.wifi)
            controller.checkReadiness()
            waitUntil(timeout: 3) { controller.canSetLocation }
            controller.setLocation(try MockLocationCoordinate(latitude: 13.7563, longitude: 100.5018))
            waitUntil(timeout: 3) { controller.isWiFiSessionActive }
            expect(controller.isWiFiSessionActive, "loss fixture must first establish an acknowledged Network session")
            state.snapshot = DeviceSnapshot()
            controller.refreshLocalState()
            try Data().write(to: lossTrigger)
            waitUntil(timeout: 3) { controller.reviewRequired && !controller.isBusy }
            expect(controller.reviewRequired && !controller.isAssumedActive, "transport loss must promptly downgrade assumed activity to review")
            expect(controller.blocksDeviceMutation && stored.value?.state == .uncertain, "transport loss must preserve the durable reset obligation")
            expect(!controller.canSetLocation && !controller.canReturnToRealLocation, "a lost Wi-Fi session must neither Set nor silently reconnect without USB identity recovery")

            state.snapshot = originalSnapshot
            state.snapshot.ecid = "0xABCDEF1234"
            state.snapshot.udid = "00008030-00ABCDEF12345678"
            controller.refreshLocalState()
            expect(!controller.canReturnToRealLocation, "a different USB iPhone must never satisfy a Wi-Fi recovery journal")

            state.snapshot = originalSnapshot
            state.snapshot.locationID = 2_097_152
            controller.refreshLocalState()
            // The structured loss event precedes process termination. Recovery
            // must wait until the old channel is fully gone before opening USB.
            waitUntil(timeout: 3) { controller.canReturnToRealLocation }
            expect(controller.canReturnToRealLocation, "the same stable iPhone on a new USB port must permit guarded Wi-Fi recovery Clear")
            let preflightBeforeRecovery = state.preflightCount
            controller.returnToRealLocation()
            waitUntil(timeout: 3) { !controller.blocksDeviceMutation }
            expect(state.preflightCount == preflightBeforeRecovery + 2 && state.reconnectConfirmationCount == 1, "lost Wi-Fi recovery must use two fresh USB Trust checks and explicit stable-identity confirmation")
            expect(stored.value == nil && !controller.reviewRequired, "acknowledged USB recovery Clear must resolve the Wi-Fi journal")
            let log = try String(contentsOf: fixture.requestLog, encoding: .utf8)
            let clearLines = log.split(separator: "\n").filter { $0.hasPrefix("clear|") }
            expect(clearLines.count == 1 && !clearLines[0].contains("\"transport\":\"wifi\""), "lost Wi-Fi recovery must explicitly use the freshly attested USB target without network retry")
        } catch {
            expect(false, "Wi-Fi connection-loss fixture failed")
        }
    }

    private static func testGenericControllerAttestation(expect: (Bool, String) -> Void) {
        testControllerLifecycle(productType: "iPhone18,3", expect: expect)

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("YIOS-Generic-Location-Attestation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let wrongProductExecutable = root.appendingPathComponent("wrong-product-backend")
        let exactProductExecutable = root.appendingPathComponent("exact-product-backend")
        let script = #"""
#!/bin/zsh
IFS= read -r initial_request
/usr/bin/printf '%s\n' '{"event":"hello","protocol":1,"backend_version":"fixture-generic"}'
/usr/bin/printf '%s\n' '{"event":"attested","product_type":"iPhone15,4"}'
/usr/bin/printf '%s\n' '{"event":"ready"}'
exit 0
"""#
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data(script.utf8).write(to: wrongProductExecutable)
            try Data(script.replacingOccurrences(of: "iPhone15,4", with: "iPhone18,3").utf8).write(to: exactProductExecutable)
            for executable in [wrongProductExecutable, exactProductExecutable] {
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
            }
        } catch {
            expect(false, "generic attestation fixture could not be created: \(error)")
            return
        }

        let snapshot = targetFixture(productType: "iPhone18,3")
        var wrongProductWrites = 0
        let wrongProductController = MockLocationController(
            resolveBackend: { .success(MockLocationBackendDescriptor(executableURL: wrongProductExecutable)) },
            journal: MockLocationJournalClient(
                load: { nil },
                write: { _ in wrongProductWrites += 1 },
                remove: { wrongProductWrites += 1 }
            )
        )
        wrongProductController.configureHost(.init(
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
        wrongProductController.checkReadiness()
        waitUntil(timeout: 3) { !wrongProductController.isBusy }
        expect(wrongProductController.readiness == .failed(.backendProtocolError), "another syntactically valid iPhone from the backend must fail exact ProductType attestation")
        expect(!wrongProductController.canSetLocation && wrongProductWrites == 0, "wrong-other-iPhone attestation must neither enable Set nor write a mutation journal")

        var freshEvidenceCount = 0
        var swapConfirmations = 0
        var swapWrites = 0
        let swappingController = MockLocationController(
            resolveBackend: { .success(MockLocationBackendDescriptor(executableURL: exactProductExecutable)) },
            journal: MockLocationJournalClient(
                load: { nil },
                write: { _ in swapWrites += 1 },
                remove: { swapWrites += 1 }
            )
        )
        swappingController.configureHost(.init(
            currentSnapshot: { snapshot },
            hostGate: { .idle },
            requestFreshEvidence: { completion in
                freshEvidenceCount += 1
                var fresh = snapshot
                if freshEvidenceCount == 3 { fresh.productType = "iPhone15,4" }
                completion(MockLocationFreshEvidence(snapshot: fresh, pairingAndTrustVerified: true))
            },
            confirmForgetUnavailableRecord: { _ in false },
            confirmDeveloperModeOptionRequest: { _ in false },
            confirmSet: { _, _, _ in swapConfirmations += 1; return true },
            confirmUnpinnedClear: { _ in false },
            confirmReconnectedClear: { _, _ in false }
        ))
        swappingController.checkReadiness()
        waitUntil(timeout: 3) { !swappingController.isBusy }
        expect(swappingController.canSetLocation, "an exact generic ProductType attestation must enable Set")
        if let coordinate = try? MockLocationCoordinate(latitude: 1, longitude: 2) {
            swappingController.setLocation(coordinate)
        }
        waitUntil(timeout: 3) { !swappingController.isBusy }
        expect(freshEvidenceCount == 3 && swapConfirmations == 1, "generic Set must preserve both fresh target checks around confirmation")
        expect(swapWrites == 0 && !swappingController.isAssumedActive, "post-confirmation ProductType swap must block dispatch before any mutation journal")
        expect(swappingController.lastError == MockLocationReadinessIssue.targetChanged.userDescription, "generic post-confirmation target swap must report the exact-target change")
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
