import Foundation

private func commandResult(
    exitCode: Int32 = 0,
    stdout: String = "",
    stderr: String = "",
    timedOut: Bool = false
) -> CommandResult {
    CommandResult(
        exitCode: exitCode,
        stdout: stdout,
        stderr: stderr,
        stdoutData: Data(stdout.utf8),
        stderrData: Data(stderr.utf8),
        timedOut: timedOut
    )
}

private final class RecoveryTransitionHarness {
    var detections: [DeviceSnapshot]
    var pairings: [PairingValidation]
    var competingResults: [Bool]
    var command = commandResult()

    private(set) var detectCount = 0
    private(set) var pairingUDIDs: [String] = []
    private(set) var competingCount = 0
    private(set) var runs: [(tool: String, arguments: [String], timeout: TimeInterval)] = []

    init(
        detections: [DeviceSnapshot],
        pairings: [PairingValidation] = [
            PairingValidation(isValid: true, detail: "SUCCESS"),
            PairingValidation(isValid: true, detail: "SUCCESS")
        ],
        competingResults: [Bool] = [false, false]
    ) {
        self.detections = detections
        self.pairings = pairings
        self.competingResults = competingResults
    }

    var dependencies: RecoveryTransitionDependencies {
        RecoveryTransitionDependencies(
            detect: { [unowned self] in
                let index = min(self.detectCount, self.detections.count - 1)
                self.detectCount += 1
                return self.detections[index]
            },
            validatePairing: { [unowned self] udid in
                self.pairingUDIDs.append(udid)
                let index = min(self.pairingUDIDs.count - 1, self.pairings.count - 1)
                return self.pairings[index]
            },
            run: { [unowned self] tool, arguments, timeout in
                self.runs.append((tool, arguments, timeout))
                return self.command
            },
            hasCompetingClient: { [unowned self] in
                let index = min(self.competingCount, self.competingResults.count - 1)
                self.competingCount += 1
                return self.competingResults[index]
            }
        )
    }
}

@main
struct RecoveryTransitionTestMain {
    private static func normalSnapshot(
        productType: String = "iPhone12,8",
        ecid: String? = "0x1399A1401402E",
        udid: String? = "00008030-0001399A1401402E",
        locationID: Int? = 1_048_576
    ) -> DeviceSnapshot {
        DeviceSnapshot(
            mode: .normal,
            deviceCount: 1,
            usbPID: 0x12A8,
            locationID: locationID,
            ecid: ecid,
            udid: udid,
            productType: productType,
            hardwareModel: nil,
            productVersion: "17.7",
            buildVersion: "21H16",
            activationState: "Activated",
            modeVerified: true
        )
    }

    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let familyFixtures: [(String, IPhoneButtonFamily)] = [
            ("iPhone1,1", .homeButton),
            ("iPhone8,4", .homeButton),
            ("iPhone9,1", .iPhone7),
            ("iPhone9,4", .iPhone7),
            ("iPhone10,1", .modern),
            ("iPhone12,8", .modern),
            ("iPhone18,3", .modern),
            ("iPhone100,0", .modern)
        ]
        for (productType, expectedFamily) in familyFixtures {
            expect(
                IPhoneButtonFamily.classify(productType: productType) == expectedFamily,
                "\(productType) must classify as \(expectedFamily.rawValue)"
            )
        }
        let malformedProductTypes: [String?] = [
            nil, "", " iPhone12,8", "iPhone12,8 ", "iphone12,8",
            "iPad13,1", "iPhone", "iPhone12", "iPhone12,", "iPhone,8",
            "iPhone0,1", "iPhone01,1", "iPhone12,-1", "iPhone12,01",
            "iPhone12,8,1", "iPhone12.8"
        ]
        for productType in malformedProductTypes {
            expect(
                IPhoneButtonFamily.classify(productType: productType) == nil,
                "malformed ProductType \(String(describing: productType)) must be rejected"
            )
        }
        for family in [IPhoneButtonFamily.homeButton, .iPhone7, .modern] {
            expect(family.recoverySteps.count == 4, "every known family needs four Recovery guide steps")
            expect(family.dfuSteps.count == 4, "every known family needs four DFU guide steps")
            expect(
                family.dfuSteps.joined(separator: " ").localizedCaseInsensitiveContains("physical buttons"),
                "every DFU guide must state that physical buttons are required"
            )
        }

        for productType in ["iPhone8,4", "iPhone9,3", "iPhone12,8", "iPhone13,1", "iPhone18,3"] {
            let snapshot = normalSnapshot(productType: productType)
            let target = RecoveryTransitionTarget(snapshot: snapshot)
            expect(target != nil, "valid exact Normal target \(productType) must be accepted for non-destructive Recovery")
            expect(target?.productType == productType, "Recovery target must retain exact ProductType")
        }
        expect(
            SupportedDeviceCatalog.model(productType: "iPhone9,3") == nil,
            "iPhone 7 must remain outside the destructive catalog"
        )
        expect(
            SupportedDeviceCatalog.model(productType: "iPhone13,1") == nil,
            "iPhone 12 mini must remain outside the destructive catalog"
        )

        let exactSnapshot = normalSnapshot()
        guard let target = RecoveryTransitionTarget(snapshot: exactSnapshot) else {
            fputs("FAIL: exact Recovery target fixture did not initialize\n", stderr)
            exit(1)
        }
        expect(target.ecid == "0x1399A1401402E", "Recovery target ECID must be canonical hexadecimal")
        expect(target.matches(exactSnapshot), "target must match the same exact fresh snapshot")

        var invalid = exactSnapshot
        invalid.deviceCount = 2
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "multiple devices must be rejected")
        invalid = exactSnapshot
        invalid.mode = .recovery
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "non-Normal mode must be rejected")
        invalid = exactSnapshot
        invalid.modeVerified = false
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "unverified Normal mode must be rejected")
        invalid = exactSnapshot
        invalid.identityConflict = true
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "conflicting identity must be rejected")
        invalid = exactSnapshot
        invalid.ecid = nil
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "missing ECID must be rejected")
        invalid = exactSnapshot
        invalid.ecid = "0"
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "zero ECID must be rejected")
        invalid = exactSnapshot
        invalid.udid = nil
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "missing UDID must be rejected")
        invalid = exactSnapshot
        invalid.udid = "   "
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "blank UDID must be rejected")
        invalid = exactSnapshot
        invalid.locationID = nil
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "missing USB location must be rejected")
        invalid = exactSnapshot
        invalid.productType = nil
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "missing ProductType must be rejected")
        invalid = exactSnapshot
        invalid.productType = "iPad13,1"
        expect(RecoveryTransitionTarget(snapshot: invalid) == nil, "non-iPhone ProductType must be rejected")

        var changed = exactSnapshot
        changed.ecid = "0x511EA2E30C02E"
        expect(!target.matches(changed), "changed ECID must reject the fresh target")
        changed = exactSnapshot
        changed.udid = "00008030-000511EA2E30C02E"
        expect(!target.matches(changed), "changed UDID must reject the fresh target")
        changed = exactSnapshot
        changed.locationID = 2_097_152
        expect(!target.matches(changed), "changed USB location must reject the fresh target")
        changed = exactSnapshot
        changed.productType = "iPhone13,1"
        expect(!target.matches(changed), "changed ProductType must reject the fresh target")

        let successHarness = RecoveryTransitionHarness(detections: [exactSnapshot, exactSnapshot])
        let success = RecoveryTransitionExecutor.execute(
            tool: "/reviewed/ideviceenterrecovery",
            target: target,
            dependencies: successHarness.dependencies
        )
        if case .succeeded(let latest, let command) = success {
            expect(target.matches(latest), "successful execution must return the final matched snapshot")
            expect(command.exitCode == 0 && !command.timedOut, "success must carry a completed zero-exit command")
        } else {
            failures.append("two exact fresh checks must reach one successful command")
        }
        expect(successHarness.detectCount == 2, "success must perform exactly two fresh detections")
        expect(successHarness.pairingUDIDs == [target.udid, target.udid], "success must validate Trust twice for the pinned UDID")
        expect(successHarness.competingCount == 2, "success must check competing clients at both launch boundaries")
        expect(successHarness.runs.count == 1, "one user action must invoke the Recovery helper exactly once")
        if let run = successHarness.runs.first {
            expect(run.tool == "/reviewed/ideviceenterrecovery", "executor must use the caller-resolved helper path")
            expect(run.arguments == [target.udid], "Recovery helper argv must contain only the exact pinned UDID")
            expect(run.timeout == 30, "Recovery helper must use the bounded 30-second timeout")
        }

        changed = exactSnapshot
        changed.udid = "different-device"
        let firstSwap = RecoveryTransitionHarness(detections: [changed])
        let firstSwapResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: firstSwap.dependencies)
        if case .targetChanged(_, let stage) = firstSwapResult {
            expect(stage == .firstFreshCheck, "first target swap must identify the first fresh-check stage")
        } else {
            failures.append("first target swap must fail as targetChanged")
        }
        expect(firstSwap.runs.isEmpty && firstSwap.pairingUDIDs.isEmpty, "first target swap must launch nothing and skip Trust probing")

        let finalSwap = RecoveryTransitionHarness(detections: [exactSnapshot, changed])
        let finalSwapResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: finalSwap.dependencies)
        if case .targetChanged(_, let stage) = finalSwapResult {
            expect(stage == .finalFreshCheck, "second target swap must identify the final fresh-check stage")
        } else {
            failures.append("second target swap must fail as targetChanged")
        }
        expect(finalSwap.runs.isEmpty && finalSwap.pairingUDIDs.count == 1, "final target swap must launch nothing")

        let firstPairingFailure = RecoveryTransitionHarness(
            detections: [exactSnapshot],
            pairings: [PairingValidation(isValid: false, detail: "not paired")]
        )
        let firstPairingResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: firstPairingFailure.dependencies)
        if case .pairingFailed(_, let stage, let detail) = firstPairingResult {
            expect(stage == .firstFreshCheck && detail == "not paired", "first Trust failure must preserve its stage and detail")
        } else {
            failures.append("invalid first Trust sample must return pairingFailed")
        }
        expect(firstPairingFailure.runs.isEmpty, "first Trust failure must launch nothing")

        let finalPairingFailure = RecoveryTransitionHarness(
            detections: [exactSnapshot, exactSnapshot],
            pairings: [
                PairingValidation(isValid: true, detail: "SUCCESS"),
                PairingValidation(isValid: false, detail: "Trust changed")
            ]
        )
        let finalPairingResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: finalPairingFailure.dependencies)
        if case .pairingFailed(_, let stage, _) = finalPairingResult {
            expect(stage == .finalFreshCheck, "second Trust failure must identify the final stage")
        } else {
            failures.append("invalid final Trust sample must return pairingFailed")
        }
        expect(finalPairingFailure.runs.isEmpty, "final Trust failure must launch nothing")

        let firstBusy = RecoveryTransitionHarness(
            detections: [exactSnapshot],
            competingResults: [true]
        )
        let firstBusyResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: firstBusy.dependencies)
        if case .competingClient(_, let stage) = firstBusyResult {
            expect(stage == .firstFreshCheck, "first busy-host result must preserve its stage")
        } else {
            failures.append("first competing client must block the request")
        }
        expect(firstBusy.runs.isEmpty, "first competing-client check must launch nothing")

        let finalBusy = RecoveryTransitionHarness(
            detections: [exactSnapshot, exactSnapshot],
            competingResults: [false, true]
        )
        let finalBusyResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: finalBusy.dependencies)
        if case .competingClient(_, let stage) = finalBusyResult {
            expect(stage == .finalFreshCheck, "final busy-host result must preserve its stage")
        } else {
            failures.append("final competing client must block the request")
        }
        expect(finalBusy.runs.isEmpty, "final competing-client check must launch nothing")

        let timeoutHarness = RecoveryTransitionHarness(detections: [exactSnapshot, exactSnapshot])
        timeoutHarness.command = commandResult(exitCode: -2, stderr: "timed out", timedOut: true)
        let timeoutResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: timeoutHarness.dependencies)
        if case .commandFailed(_, let command) = timeoutResult {
            expect(command.timedOut && command.exitCode == -2, "timeout must be returned as an uncertain command failure")
        } else {
            failures.append("a timed-out command must not report success")
        }
        expect(timeoutHarness.runs.count == 1, "timeout must never cause an automatic retry")

        let nonzeroHarness = RecoveryTransitionHarness(detections: [exactSnapshot, exactSnapshot])
        nonzeroHarness.command = commandResult(exitCode: 1, stderr: "request rejected")
        let nonzeroResult = RecoveryTransitionExecutor.execute(tool: "/tool", target: target, dependencies: nonzeroHarness.dependencies)
        if case .commandFailed(_, let command) = nonzeroResult {
            expect(command.exitCode == 1 && !command.timedOut, "nonzero exit must remain distinguishable from timeout")
        } else {
            failures.append("a nonzero command must not report success")
        }
        expect(nonzeroHarness.runs.count == 1, "nonzero command failure must never cause an automatic retry")

        if failures.isEmpty {
            print("RECOVERY TRANSITION TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
