import Foundation

private func require(_ condition: Bool, _ message: String) {
    if !condition { fatalError("Companion test failed: \(message)") }
}

private func expectFailure(_ expected: CompanionFailure, _ operation: () throws -> Void) {
    do { try operation(); fatalError("Expected Companion failure: \(expected)") }
    catch let error as CompanionFailure { require(error == expected, "expected \(expected), got \(error)") }
    catch { fatalError("Unexpected error type") }
}

private final class CompanionHarness {
    let identifier = UUID(uuidString: "12345678-1234-1234-1234-123456789ABC")!
    var snapshot = DeviceSnapshot(mode: .normal, deviceCount: 1, usbPID: 0x12A8, locationID: 0x100000,
                                  ecid: "0x123456", udid: "00008030-0011223344556677", productType: "iPhone12,8",
                                  productVersion: "27.3", modeVerified: true)
    let payload = CompanionPayload(url: URL(fileURLWithPath: "/test/Companion.app"),
                                   version: CompanionVersion(marketing: "1.0", build: "1"), minimumIOS: "17.0")
    var installed: CompanionVersion?
    var paired = true
    var payloadFailure: CompanionFailure?
    var validationFailure: CompanionFailure?
    var nativeFailure: CompanionFailure?
    var failInstall = false
    var verifyInstalled = true
    var swapFinalUSB = false
    var readCount = 0
    var installs = 0
    var requests = 0
    var hostAllowed = true
    var recordOverride: [String: Any]?
    var retainFresh = false
    var freshCallbacks: [(MockLocationFreshEvidence) -> Void] = []

    var target: MockLocationExactTarget { try! MockLocationExactTarget(snapshot: snapshot) }

    var record: [String: Any] {
        recordOverride ?? [
            "identifier": identifier.uuidString,
            "properties": [
                "hardware": ["udid": snapshot.udid!, "ecid": 0x123456, "productType": "iPhone12,8", "deviceType": "iPhone", "platform": "iOS"],
                "connection": ["pairingState": "paired", "state": "connected", "transportType": "wired"],
                "state": ["developerModeStatus": ["enabled": ["mode": "normal"]]]
            ]
        ]
    }

    func apps() -> [String: Any] {
        let values: [[String: Any]] = installed.map {
            [["bundleIdentifier": CompanionPayload.bundleIdentifier, "version": $0.marketing, "bundleVersion": $0.build]]
        } ?? []
        return ["deviceIdentifier": identifier.uuidString, "matchingBundleIdentifier": CompanionPayload.bundleIdentifier, "apps": values]
    }

    var dependencies: CompanionDependencies {
        CompanionDependencies(inspectPayload: { [unowned self] in
            if let failure = self.payloadFailure { throw failure }; return self.payload
        }, validatePayload: { [unowned self] _, _ in
            if let failure = self.validationFailure { throw failure }
        }, verifyNativeTool: { [unowned self] in
            if let failure = self.nativeFailure { throw failure }
        }, request: { [unowned self] request in
            self.requests += 1
            switch request {
            case .devices: return ["devices": [self.record]]
            case .details(let identifier):
                require(identifier == self.identifier, "details uses exact UUID"); return self.record
            case .apps(let identifier):
                require(identifier == self.identifier, "apps uses exact UUID"); return self.apps()
            case .install(let identifier, let url):
                require(identifier == self.identifier && url == self.payload.url, "fixed bundle and exact UUID")
                self.installs += 1
                if self.failInstall { throw CompanionFailure.commandFailed }
                if self.verifyInstalled { self.installed = self.payload.version }
                return [:]
            }
        }, detect: { [unowned self] in
            self.readCount += 1
            var observed = self.snapshot
            if self.swapFinalUSB && self.readCount >= 2 { observed.locationID = 0x200000 }
            return observed
        }, validatePairing: { [unowned self] _ in self.paired })
    }

    @MainActor var host: CompanionController.HostCallbacks {
        .init(currentSnapshot: { [unowned self] in self.snapshot },
              canInstall: { [unowned self] in self.hostAllowed },
              requestFreshEvidence: { [unowned self] completion in
                  if self.retainFresh { self.freshCallbacks.append(completion) }
                  else { completion(.init(snapshot: self.snapshot, pairingAndTrustVerified: self.paired)) }
              })
    }
}

@main
struct CompanionTestMain {
    @MainActor
    static func wait(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        fatalError("Companion asynchronous operation did not finish")
    }

    @MainActor
    private static func makeController(_ harness: CompanionHarness) -> (CompanionController, UserDefaults, String) {
        let domain = "YIOSCompanionTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: domain)!
        defaults.set(false, forKey: CompanionController.preferenceKey)
        let controller = CompanionController(defaults: defaults, dependencies: harness.dependencies)
        controller.configureHost(harness.host)
        return (controller, defaults, domain)
    }

    @MainActor
    static func main() async {
        let version = CompanionVersion(marketing: "1.0", build: "9")
        require(version < CompanionVersion(marketing: "1.0", build: "10"), "numeric build comparison")
        require(version < CompanionVersion(marketing: "1.1", build: "1"), "marketing version precedence")
        require(!CompanionVersion.valid("1.0-beta") && !CompanionVersion.valid("../1"), "strict version strings")

        do {
            let h = CompanionHarness()
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            require(prepared.needsInstall, "missing app needs install")
            let result = try! installer.install(prepared, target: h.target)
            require(h.installs == 1 && result == h.payload.version, "one verified install")
            require(h.readCount == 2, "fresh USB attestation before prepare and dispatch")
            let next = try! installer.prepare(target: h.target)
            require(!next.needsInstall, "same installed version is not an automatic update")
        }
        do {
            let h = CompanionHarness(); h.paired = false
            expectFailure(.pairingRequired) { _ = try CompanionInstaller(dependencies: h.dependencies).prepare(target: h.target) }
            require(h.requests == 0 && h.installs == 0, "untrusted phone receives no Apple device commands")
        }
        do {
            let h = CompanionHarness(); h.validationFailure = .phoneNotProvisioned
            expectFailure(.phoneNotProvisioned) { _ = try CompanionInstaller(dependencies: h.dependencies).prepare(target: h.target) }
            require(h.requests == 0, "provisioned UDID required before device queries")
        }
        do {
            let h = CompanionHarness(); h.snapshot.productVersion = "16.7"
            expectFailure(.unsupportedIOS) { _ = try CompanionInstaller(dependencies: h.dependencies).prepare(target: h.target) }
            require(h.requests == 0, "minimum iOS enforced")
        }
        do {
            let h = CompanionHarness(); h.swapFinalUSB = true
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            expectFailure(.targetChanged) { _ = try installer.install(prepared, target: h.target) }
            require(h.installs == 0, "USB identity rechecked immediately before install")
        }
        do {
            let h = CompanionHarness()
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            expectFailure(.installationCancelled) { _ = try installer.install(prepared, target: h.target, mayDispatch: { false }) }
            require(h.installs == 0, "cancelled automatic dispatch sends no install")
        }
        do {
            let h = CompanionHarness(); h.failInstall = true
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            expectFailure(.installUncertain) { _ = try installer.install(prepared, target: h.target) }
            require(h.installs == 1, "failed dispatched installation is uncertain and never replayed")
        }
        do {
            let h = CompanionHarness(); h.verifyInstalled = false
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            expectFailure(.installUncertain) { _ = try installer.install(prepared, target: h.target) }
            require(h.installs == 1, "successful CLI alone does not prove installed version")
        }
        do {
            let h = CompanionHarness()
            var record = h.record
            record["hardwareProperties"] = ["udid": h.snapshot.udid!, "ecid": 0x999999, "productType": "iPhone12,8", "deviceType": "iPhone", "platform": "iOS"]
            expectFailure(.targetChanged) { _ = try CompanionNativeParser.attest(record, target: h.target) }
            var result = h.apps(); result["deviceIdentifier"] = UUID().uuidString
            expectFailure(.malformedResponse) { _ = try CompanionNativeParser.installedVersion(result, identifier: h.identifier) }
            result = h.apps(); result["matchingBundleIdentifier"] = "other.app"
            expectFailure(.malformedResponse) { _ = try CompanionNativeParser.installedVersion(result, identifier: h.identifier) }
            expectFailure(.malformedResponse) { _ = try CompanionNativeParser.result(Data("{\"info\":{\"outcome\":\"failure\"},\"result\":{}}".utf8)) }
            require(h.installs == 0, "parser failures are read-only")
        }
        do {
            let h = CompanionHarness()
            let installer = CompanionInstaller(dependencies: h.dependencies)
            let prepared = try! installer.prepare(target: h.target)
            h.installed = CompanionVersion(marketing: "2.0", build: "1")
            let newer = try! installer.install(prepared, target: h.target, repairSameVersion: true)
            require(h.installs == 0 && newer.marketing == "2.0", "late external update cannot be downgraded")
        }
        do {
            let h = CompanionHarness(); h.hostAllowed = false
            let (controller, defaults, domain) = makeController(h)
            defer { defaults.removePersistentDomain(forName: domain) }
            controller.refreshAvailability()
            await wait { controller.payloadAvailable }
            controller.setAutoInstallEnabled(true)
            controller.observeConnection(h.snapshot)
            require(h.installs == 0 && !controller.isBusy, "busy host defers connection instead of consuming attempt")
            h.hostAllowed = true
            controller.observeConnection(h.snapshot)
            await wait { !controller.isBusy }
            require(h.installs == 1 && controller.installedVersion == "1.0 (1)", "gate clear installs on same connection")
            controller.observeConnection(h.snapshot)
            controller.observeConnection(h.snapshot)
            require(h.installs == 1 && !controller.isBusy, "repeated scans do not reinstall")
        }
        do {
            let h = CompanionHarness(); h.installed = h.payload.version
            let (controller, defaults, domain) = makeController(h)
            defer { defaults.removePersistentDomain(forName: domain) }
            controller.installNow()
            await wait { !controller.isBusy }
            require(h.installs == 1, "explicit repair reinstalls same-version freshly signed app")
        }
        do {
            let h = CompanionHarness(); h.failInstall = true
            let (controller, defaults, domain) = makeController(h)
            defer { defaults.removePersistentDomain(forName: domain) }
            controller.refreshAvailability()
            await wait { controller.payloadAvailable }
            controller.setAutoInstallEnabled(true)
            await wait { !controller.isBusy }
            controller.observeConnection(h.snapshot)
            require(h.installs == 1 && !controller.isBusy, "uncertain install is not retried on same connection")
            controller.observeConnection(DeviceSnapshot(mode: .notDetected))
            controller.observeConnection(h.snapshot)
            require(h.installs == 1 && !controller.isBusy, "failed enrichment cannot reopen automatic retry")
            controller.confirmedUSBDisconnected()
            controller.observeConnection(h.snapshot)
            await wait { !controller.isBusy }
            require(h.installs == 2, "real disconnect permits one new connection attempt")
        }
        do {
            let h = CompanionHarness(); h.retainFresh = true
            let (controller, defaults, domain) = makeController(h)
            defer { defaults.removePersistentDomain(forName: domain) }
            controller.refreshAvailability()
            await wait { controller.payloadAvailable }
            controller.setAutoInstallEnabled(true)
            require(controller.isBusy && h.freshCallbacks.count == 1, "automatic preflight pending")
            controller.setAutoInstallEnabled(false)
            h.freshCallbacks.removeFirst()(.init(snapshot: h.snapshot, pairingAndTrustVerified: true))
            require(!controller.isBusy && h.installs == 0 && h.requests == 0, "turning automatic off vetoes pending dispatch")
        }
        do {
            let h = CompanionHarness(); h.retainFresh = true
            let (controller, defaults, domain) = makeController(h)
            defer { defaults.removePersistentDomain(forName: domain) }
            let mock = MockLocationController.offlineFixture()
            let model = RecoveryModel(mockLocationController: mock, companionController: controller)
            model.snapshot = h.snapshot
            model.snapshot.hardwareModel = "d79ap"
            model.snapshot.chipID = "0x8030"
            model.snapshot.boardID = "0x10"
            // Replace the real host's evidence callback before requesting work.
            // No start(), device detector or physical phone command is invoked.
            controller.configureHost(h.host)
            controller.installNow()
            require(controller.isBusy, "held evidence acquires global installer gate")
            require(!model.canRestore && !model.canFactoryReset && !model.canRevive,
                    "Companion installation excludes Restore, reset and Revive")
            require(!model.canUseNormalDeviceUtilities && !model.canOpenFinderBackup && !model.canCopyCrashReports,
                    "Companion installation excludes normal phone utilities")
            require(!model.canStartDFUAssistant && !model.primaryActionEnabled && !model.canChooseIPSW && !model.canRefreshDeviceCenter,
                    "Companion installation excludes DFU, primary action, firmware selection and detail refresh")
            mock.checkReadiness()
            require(!mock.isBusy, "Mock Location rejects work while Companion installer owns host")
            h.freshCallbacks.removeFirst()(.init(snapshot: h.snapshot, pairingAndTrustVerified: false))
            require(!controller.isBusy && h.installs == 0, "model integration test releases gate without device work")
        }
        print("Companion installer tests passed")
    }
}
