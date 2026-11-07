import Foundation

@main
struct DFUAssistantTestMain {
    static func main() {
        var failures: [String] = []
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() { failures.append(message) }
        }

        let ecid = "0x1399A1401402E"
        let location = 1_048_576
        func sample(
            _ mode: DeviceMode,
            ecid sampleECID: String? = ecid,
            location sampleLocation: Int? = location,
            pid: Int? = nil
        ) -> DeviceSnapshot {
            DeviceSnapshot(
                mode: mode,
                deviceCount: 1,
                usbPID: pid ?? {
                    switch mode {
                    case .dfu: return 0x1227
                    case .recovery: return 0x1281
                    default: return 0x12A8
                    }
                }(),
                locationID: sampleLocation,
                ecid: sampleECID
            )
        }

        var general = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .recoveryOrDFU
        )
        for _ in 0..<4 {
            expect(general.observe(sample(.recovery)) == .none, "Recovery must be stable before a general watcher accepts it")
        }
        expect(general.observe(sample(.recovery)) == .recoveryOrDFUCandidate(.recovery), "five exact Recovery samples must satisfy a general watcher")

        var generalDFU = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .recoveryOrDFU
        )
        for _ in 0..<4 { _ = generalDFU.observe(sample(.dfu)) }
        expect(generalDFU.observe(sample(.dfu)) == .recoveryOrDFUCandidate(.dfu), "five exact DFU samples must satisfy a general watcher")

        var dfuOnly = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .dfuOnly
        )
        for _ in 0..<4 {
            expect(dfuOnly.observe(sample(.recovery)) == .none, "Recovery must not immediately satisfy a DFU-only watcher")
        }
        expect(dfuOnly.observe(sample(.recovery)) == .missedRecovery, "stable Recovery must report missed DFU timing")
        expect(dfuOnly.observe(sample(.recovery)) == .none, "one Recovery streak must report missed timing only once")
        for _ in 0..<4 {
            expect(dfuOnly.observe(sample(.dfu)) == .none, "DFU-only watcher must require stable exact DFU")
        }
        expect(dfuOnly.observe(sample(.dfu)) == .dfuCandidate, "DFU-only watcher must continue after Recovery and accept stable DFU")

        var wrongTarget = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .dfuOnly
        )
        for _ in 0..<4 { _ = wrongTarget.observe(sample(.dfu)) }
        expect(wrongTarget.observe(sample(.dfu, ecid: "0x511EA2E30C02E")) == .none, "wrong ECID must reset DFU stability")
        expect(wrongTarget.observe(sample(.dfu)) == .none, "DFU stability must restart after wrong ECID")
        for _ in 0..<3 { _ = wrongTarget.observe(sample(.dfu)) }
        expect(wrongTarget.observe(sample(.dfu)) == .dfuCandidate, "DFU may be accepted only after a fresh stable exact-target streak")

        var wrongPort = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .recoveryOrDFU
        )
        for _ in 0..<4 { _ = wrongPort.observe(sample(.recovery)) }
        expect(wrongPort.observe(sample(.recovery, location: 2_097_152)) == .none, "wrong USB location must reset Recovery stability")
        expect(wrongPort.observe(sample(.recovery)) == .none, "Recovery stability must restart after wrong USB location")

        var kis = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .dfuOnly
        )
        let kisSample = sample(.unknown, pid: 0x1881)
        expect(kis.observe(kisSample) == .observedKISUnverified, "exact KIS/Debug USB must be reported as unverified")
        expect(kis.observe(kisSample) == .none, "one KIS streak must not repeatedly notify")
        for _ in 0..<10 {
            expect(kis.observe(kisSample) != .dfuCandidate, "KIS PID must never become a verified DFU candidate")
        }
        expect(kis.observe(sample(.unknown, ecid: "0x511EA2E30C02E", pid: 0x1881)) == .none, "wrong-target KIS must not be reported")

        var alternating = DFUMonitorTracker(
            pinnedECID: ecid,
            pinnedLocation: location,
            intent: .recoveryOrDFU
        )
        for index in 0..<10 {
            let mode: DeviceMode = index.isMultiple(of: 2) ? .recovery : .dfu
            expect(alternating.observe(sample(mode)) == .none, "alternating modes must not count as one stable transition")
        }

        guard let verificationPin = DFUVerificationPin(
            ecid: ecid,
            locationID: location,
            productType: "iPhone13,1"
        ) else {
            fputs("FAIL: valid DFU verification pin did not initialize\n", stderr)
            exit(1)
        }
        var verifiedUnsupported = sample(.dfu)
        verifiedUnsupported.modeVerified = true
        verifiedUnsupported.productType = "iPhone13,1"
        verifiedUnsupported.hardwareModel = "d52gap"
        verifiedUnsupported.chipID = "0x8101"
        verifiedUnsupported.boardID = "0x0A"
        expect(verificationPin.matches(verifiedUnsupported), "exact protocol-verified unsupported iPhone must satisfy the non-destructive DFU identity pin")
        expect(!verifiedUnsupported.hasVerifiedSupportedDeviceIdentity, "DFU verification must not place unsupported hardware in the destructive catalog")

        var rejected = verifiedUnsupported
        rejected.ecid = "0x511EA2E30C02E"
        expect(!verificationPin.matches(rejected), "wrong ECID must fail final DFU verification")
        rejected = verifiedUnsupported
        rejected.locationID = 2_097_152
        expect(!verificationPin.matches(rejected), "wrong USB location must fail final DFU verification")
        rejected = verifiedUnsupported
        rejected.productType = "iPhone12,8"
        expect(!verificationPin.matches(rejected), "changed ProductType must fail final DFU verification")
        rejected = verifiedUnsupported
        rejected.identityConflict = true
        expect(!verificationPin.matches(rejected), "conflicting identity must fail final DFU verification")
        rejected = verifiedUnsupported
        rejected.modeVerified = false
        expect(!verificationPin.matches(rejected), "unverified DFU protocol must fail final identity verification")
        rejected = verifiedUnsupported
        rejected.mode = .recovery
        expect(!verificationPin.matches(rejected), "Recovery must never satisfy final DFU verification")
        rejected = verifiedUnsupported
        rejected.mode = .unknown
        rejected.usbPID = 0x1881
        expect(!verificationPin.matches(rejected), "KIS/Debug USB must never satisfy classic DFU verification")
        rejected = verifiedUnsupported
        rejected.productType = nil
        expect(!verificationPin.matches(rejected), "missing ProductType must fail final DFU verification")

        let productAgnosticPin = DFUVerificationPin(ecid: ecid, locationID: location, productType: nil)
        expect(productAgnosticPin?.matches(verifiedUnsupported) == true, "a watcher started before ProductType enrichment may accept a freshly verified valid iPhone ProductType")
        expect(DFUVerificationPin(ecid: "0", locationID: location, productType: nil) == nil, "zero ECID must not create a DFU verification pin")
        expect(DFUVerificationPin(ecid: ecid, locationID: location, productType: "iPad13,1") == nil, "non-iPhone ProductType must not create a DFU verification pin")

        func makeKISTarget(
            ecid targetECID: String = ecid,
            locationID targetLocation: Int = location,
            productType: String = "iPhone13,1"
        ) -> DFURestoreTarget? {
            DFURestoreTarget(snapshot: DeviceSnapshot(
                mode: .dfu,
                deviceCount: 1,
                usbPID: 0x1881,
                locationID: targetLocation,
                ecid: targetECID,
                productType: productType,
                modeVerified: false,
                configuratorDFURestoreVerified: true
            ))
        }
        guard let kisVerificationPin = KISVerificationPin(
            ecid: ecid,
            locationID: location,
            productType: "iPhone13,1"
        ), let exactKISTarget = makeKISTarget() else {
            fputs("FAIL: valid KIS verification pin or target did not initialize\n", stderr)
            exit(1)
        }
        expect(kisVerificationPin.matches(exactKISTarget), "exact Configurator-attested KIS target must satisfy the raw watcher pin")
        if let wrongECIDKIS = makeKISTarget(ecid: "0x511EA2E30C02E") {
            expect(!kisVerificationPin.matches(wrongECIDKIS), "wrong KIS ECID must fail the raw watcher pin")
        } else {
            failures.append("wrong-ECID KIS fixture did not initialize")
        }
        if let wrongLocationKIS = makeKISTarget(locationID: 2_097_152) {
            expect(!kisVerificationPin.matches(wrongLocationKIS), "wrong KIS USB location must fail the raw watcher pin")
        } else {
            failures.append("wrong-location KIS fixture did not initialize")
        }
        if let wrongProductKIS = makeKISTarget(productType: "iPhone15,4") {
            expect(!kisVerificationPin.matches(wrongProductKIS), "wrong KIS ProductType must fail the raw watcher pin")
        } else {
            failures.append("wrong-ProductType KIS fixture did not initialize")
        }
        expect(KISVerificationPin(ecid: "0", locationID: location, productType: nil) == nil, "zero ECID must not create a KIS verification pin")
        expect(KISVerificationPin(ecid: ecid, locationID: location, productType: "iPad13,1") == nil, "non-iPhone ProductType must not create a KIS verification pin")

        var sameVerifiedDFU = verifiedUnsupported
        expect(
            DFUAssistantStatePolicy.reconciled(
                current: .verified,
                previous: verifiedUnsupported,
                detected: sameVerifiedDFU,
                isMonitoring: false,
                hasPendingVerification: false
            ) == .verified,
            "a repeated scan of the same verified DFU target may retain its result"
        )
        sameVerifiedDFU.mode = .normal
        expect(
            DFUAssistantStatePolicy.reconciled(
                current: .verified,
                previous: verifiedUnsupported,
                detected: sameVerifiedDFU,
                isMonitoring: false,
                hasPendingVerification: false
            ) == .idle,
            "a mode change must clear the previous target's DFU success state"
        )
        var differentDFUTarget = verifiedUnsupported
        differentDFUTarget.ecid = "0x511EA2E30C02E"
        expect(
            DFUAssistantStatePolicy.reconciled(
                current: .verified,
                previous: verifiedUnsupported,
                detected: differentDFUTarget,
                isMonitoring: false,
                hasPendingVerification: false
            ) == .idle,
            "a target change must clear the previous iPhone's DFU success state"
        )
        expect(
            DFUAssistantStatePolicy.reconciled(
                current: .verifying,
                previous: verifiedUnsupported,
                detected: sameVerifiedDFU,
                isMonitoring: false,
                hasPendingVerification: true
            ) == .verifying,
            "the enriched verification scan must preserve its pending lifecycle state"
        )
        expect(
            DFUAssistantStatePolicy.reconciled(
                current: .missedRecovery,
                previous: verifiedUnsupported,
                detected: differentDFUTarget,
                isMonitoring: true,
                hasPendingVerification: false
            ) == .missedRecovery,
            "transient raw samples must not reset state while the pinned watcher is still active"
        )

        expect(DFUAssistantState.idle != .verified, "DFU assistant lifecycle states must remain distinct")
        expect(USBMonitorIntent.recoveryOrDFU != .dfuOnly, "monitor intent must distinguish general and DFU-only watching")

        if failures.isEmpty {
            print("DFU ASSISTANT TEST PASS")
            exit(0)
        }
        for failure in failures { fputs("FAIL: \(failure)\n", stderr) }
        exit(1)
    }
}
