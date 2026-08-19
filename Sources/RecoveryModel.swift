import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

private struct RestorePlan {
    let ipsw: IPSWInfo?

    var firmwareDescription: String {
        ipsw?.title ?? "latest currently signed iOS from Apple"
    }
}

@MainActor
final class RecoveryModel: ObservableObject {
    @Published var snapshot = DeviceSnapshot()
    @Published var statusText = "Ready to scan"
    @Published var detailText = "Connect one iPhone SE (2nd generation) directly by USB."
    @Published var logText = ""
    @Published var isScanning = false
    @Published var isMonitoring = false
    @Published var operationRunning = false
    @Published var destructiveWorkflowActive = false
    @Published var postResetReviewRequired = false
    @Published var isDestructiveOperation = false
    @Published var progress: Double?
    @Published var operationStep = ""
    @Published var selectedIPSW: IPSWInfo?
    @Published var isValidatingFirmware = false
    @Published var lastError: String?
    @Published var deviceCenterSnapshot = DeviceCenterSnapshot.empty
    @Published var isLoadingDeviceCenter = false
    @Published var deviceCenterStatusText = "Scan a connected iPhone to load read-only details."
    @Published var deviceTimeline: [DeviceTimelineEvent] = []
    @Published var crashReportSummary: CrashReportCopySummary?
    @Published var crashCopyReviewRequired = false

    private let workQueue = DispatchQueue(label: "local.minthanhtut.SE2RecoveryAssistant.work", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "local.minthanhtut.SE2RecoveryAssistant.monitor", qos: .userInitiated)
    private var monitorTimer: DispatchSourceTimer?
    private var monitorGeneration = UUID()
    private var activeProcess: Process?
    private var caffeinateProcess: Process?
    private var appleCommandSucceeded = false
    private var appleCommandErrored = false
    private var expectedOperationECID: String?
    private var expectedOperationCommand: String?
    private var expectedOperationUDID: String?
    private var hasStarted = false
    private var deviceCenterGeneration = UUID()

    var cfgutilAvailable: Bool { ToolPaths.hasConfigurator }
    var mobileToolsAvailable: Bool {
        ToolPaths.ideviceID != nil && ToolPaths.ideviceInfo != nil &&
        ToolPaths.idevicePair != nil && ToolPaths.irecovery != nil
    }

    var canChooseIPSW: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isMonitoring && !isScanning && !isValidatingFirmware && !isLoadingDeviceCenter
    }

    var canRestore: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isScanning && !isMonitoring && snapshot.deviceCount == 1 &&
        (snapshot.mode == .recovery || snapshot.mode == .dfu) && snapshot.isSE2 &&
        snapshot.ecid != nil && snapshot.modeVerified && cfgutilAvailable &&
        !isValidatingFirmware && !isLoadingDeviceCenter
    }

    var canRevive: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isScanning && !isMonitoring && snapshot.deviceCount == 1 &&
        snapshot.mode == .recovery && snapshot.isSE2 && snapshot.ecid != nil &&
        snapshot.modeVerified && cfgutilAvailable && !isValidatingFirmware && !isLoadingDeviceCenter
    }

    var canFactoryReset: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isScanning && !isMonitoring &&
        !isValidatingFirmware && !isLoadingDeviceCenter &&
        snapshot.deviceCount == 1 && snapshot.mode == .normal &&
        snapshot.modeVerified && snapshot.isSE2 && snapshot.ecid != nil && snapshot.udid != nil &&
        snapshot.locationID != nil && cfgutilAvailable && ToolPaths.idevicePair != nil
    }

    var canUseNormalDeviceUtilities: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isScanning && !isMonitoring && !isValidatingFirmware && !isLoadingDeviceCenter &&
        snapshot.deviceCount == 1 && snapshot.mode == .normal && snapshot.modeVerified &&
        snapshot.isSE2 && snapshot.ecid != nil && snapshot.udid != nil &&
        snapshot.locationID != nil && ToolPaths.ideviceDiagnostics != nil &&
        ToolPaths.idevicePair != nil
    }

    var canOpenFinderBackup: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired && !crashCopyReviewRequired &&
        !isScanning && !isMonitoring && !isValidatingFirmware && !isLoadingDeviceCenter &&
        snapshot.deviceCount == 1 && snapshot.mode == .normal && snapshot.modeVerified &&
        snapshot.isSE2 && snapshot.ecid != nil && snapshot.udid != nil && snapshot.locationID != nil
    }

    var canCopyCrashReports: Bool {
        canOpenFinderBackup && !crashCopyReviewRequired &&
        ToolPaths.idevicePair != nil && ToolPaths.ideviceCrashReport != nil
    }

    var primaryActionTitle: String {
        if postResetReviewRequired { return "I checked the iPhone — Scan" }
        switch snapshot.mode {
        case .normal:
            return canEnterRecoveryWithSoftware ? "Enter Recovery (keep data)" : "Guide me to Recovery"
        case .restoreOS: return isMonitoring ? "Monitoring USB…" : "Guide me to Recovery"
        case .recovery: return "Try Apple Revive (keep data)"
        case .dfu: return "DFU confirmed — choose Restore below"
        case .notDetected: return "Scan for iPhone"
        case .usbUnavailable:
            return snapshot.deviceCount == 1 && snapshot.ecid != nil ? "Guide me to Recovery" : "Scan again"
        case .unknown:
            return snapshot.deviceCount == 1 && snapshot.ecid != nil ? "Guide me to Recovery" : "Scan again"
        case .multiple: return "Disconnect extra devices"
        }
    }

    private var canEnterRecoveryWithSoftware: Bool {
        snapshot.mode == .normal && snapshot.modeVerified && snapshot.isSE2 &&
        snapshot.udid != nil && snapshot.ecid != nil && ToolPaths.enterRecovery != nil &&
        !isLoadingDeviceCenter
    }

    var primaryActionEnabled: Bool {
        if postResetReviewRequired {
            return !operationRunning && !destructiveWorkflowActive && !isScanning && !isMonitoring
        }
        guard !operationRunning, !destructiveWorkflowActive, !isScanning, !isMonitoring,
              !isValidatingFirmware, !isLoadingDeviceCenter, !crashCopyReviewRequired else { return false }
        switch snapshot.mode {
        case .normal:
            return snapshot.modeVerified && snapshot.isSE2 && snapshot.ecid != nil
        case .restoreOS:
            return !isMonitoring && snapshot.deviceCount == 1 && snapshot.ecid != nil
        case .recovery:
            return canRevive
        case .usbUnavailable:
            return true
        case .notDetected:
            return true
        case .unknown:
            return true
        case .dfu, .multiple:
            return false
        }
    }

    init(autoSelectFirmware: Bool = false) {
        appendLog("SE2 Recovery Assistant started.")
        appendLog("No exploit, jailbreak, activation bypass, or raw write command is used.")
        recordTimeline(
            category: .app,
            title: "Assistant launched",
            detail: "Waiting for a stable USB and Apple-device scan."
        )
        if autoSelectFirmware { autoSelectCachedIPSW() }
    }

    var displayedDeviceCenterSnapshot: DeviceCenterSnapshot {
        if postResetReviewRequired || (operationRunning && expectedOperationCommand == "erase") {
            let timestamp = deviceCenterSnapshot.capturedAt.timeIntervalSince1970 > 0
                ? deviceCenterSnapshot.capturedAt
                : Date()
            return DeviceCenterCollector.postMutationBaseline(for: snapshot, capturedAt: timestamp)
        }
        let sameMode = deviceCenterSnapshot.mode == snapshot.mode
        let sameTarget = DeviceDetector.normalizeECID(deviceCenterSnapshot.targetECID) ==
            DeviceDetector.normalizeECID(snapshot.ecid)
        if sameMode && sameTarget && deviceCenterSnapshot.capturedAt.timeIntervalSince1970 > 0 {
            return deviceCenterSnapshot
        }
        return DeviceCenterCollector.baseline(for: snapshot)
    }

    var canRefreshDeviceCenter: Bool {
        !operationRunning && !destructiveWorkflowActive && !postResetReviewRequired &&
        !isScanning && !isMonitoring && !isValidatingFirmware && !isLoadingDeviceCenter &&
        snapshot.deviceCount == 1
    }

    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        scan()
    }

    func scan(preserveError: Bool = false) {
        guard !postResetReviewRequired,
              !operationRunning, !destructiveWorkflowActive, !isScanning, !isMonitoring,
              !isValidatingFirmware, !isLoadingDeviceCenter else { return }
        isScanning = true
        if !preserveError { lastError = nil }
        statusText = "Scanning USB and Apple device services…"
        detailText = "Two stable USB samples are required before actions are enabled."

        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                self.apply(detected)
                if detected.deviceCount == 1 && detected.mode == .normal && detected.modeVerified {
                    self.refreshDeviceCenter()
                }
            }
        }
    }

    func refreshDeviceCenter() {
        guard canRefreshDeviceCenter else { return }
        let captured = snapshot

        guard captured.deviceCount == 1 else {
            deviceCenterStatusText = captured.deviceCount == 0
                ? "No connected iPhone is available for detailed collection."
                : "Disconnect extra devices before loading a single-target detail snapshot."
            return
        }

        guard captured.mode == .normal && captured.modeVerified else {
            deviceCenterStatusText = "Refreshing current USB mode and identity evidence…"
            appendLog("Device Center requested a fresh \(captured.mode.title) scan; cached evidence was not re-timestamped.")
            scan(preserveError: true)
            return
        }

        guard let ecid = DeviceDetector.canonicalECIDHex(captured.ecid),
              let udid = captured.udid,
              let location = captured.locationID else {
            deviceCenterStatusText = "Detailed collection requires a fresh exact ECID, UDID, and USB location. Scan again."
            appendLog("Device Center detail collection was blocked because exact target identifiers were incomplete.")
            return
        }
        let pin = FactoryResetPin(ecid: ecid, udid: udid, locationID: location)
        let generation = UUID()
        deviceCenterGeneration = generation

        isLoadingDeviceCenter = true
        deviceCenterStatusText = "Reading trusted identity, battery, storage, and Configurator properties…"
        appendLog("Device Center read-only detail collection started for \(masked(captured.ecid)).")

        workQueue.async { [weak self] in
            let preflight = DeviceDetector.enriched()
            guard DeviceDetector.matchesPinnedNormalTarget(
                preflight,
                pinnedECID: pin.ecid,
                pinnedUDID: pin.udid,
                pinnedLocation: pin.locationID
            ) else {
                DispatchQueue.main.async {
                    guard let self, self.deviceCenterGeneration == generation else { return }
                    self.isLoadingDeviceCenter = false
                    self.apply(preflight)
                    self.deviceCenterStatusText = "The exact Normal-iOS target changed before details were read. Stale fields were discarded."
                    self.appendLog("Device Center preflight rejected a disconnected, changed, or unverified target.")
                }
                return
            }

            let details = DeviceCenterCollector.collect(preflight)
            let finalUSB = DeviceDetector.stableUSB()
            DispatchQueue.main.async {
                guard let self, self.deviceCenterGeneration == generation else { return }
                self.isLoadingDeviceCenter = false
                let requestStillPinned = self.snapshot.mode == captured.mode &&
                    self.sameECID(self.snapshot.ecid, pin.ecid) &&
                    self.snapshot.udid?.caseInsensitiveCompare(pin.udid) == .orderedSame &&
                    self.snapshot.locationID == pin.locationID
                let targetStillMatches = requestStillPinned &&
                    finalUSB.mode == .usbUnavailable &&
                    self.sameECID(finalUSB.ecid, pin.ecid) &&
                    finalUSB.locationID == pin.locationID
                guard targetStillMatches else {
                    self.apply(finalUSB)
                    self.deviceCenterStatusText = "The target or mode changed while details were loading. Stale Normal-iOS fields were discarded; scan again."
                    self.appendLog("Discarded Device Center details because the target or mode changed.")
                    let samePhysicalTarget = self.sameECID(finalUSB.ecid, pin.ecid) &&
                        finalUSB.locationID == pin.locationID
                    if samePhysicalTarget,
                       [DeviceMode.recovery, .dfu, .restoreOS].contains(finalUSB.mode) {
                        self.deviceCenterStatusText = "The same iPhone changed mode during collection. Re-verifying current mode and identity…"
                        self.scan(preserveError: true)
                    }
                    return
                }

                guard details.pairingValidated else {
                    self.apply(finalUSB)
                    self.deviceCenterStatusText = "Trust is no longer validated. Private details were not queried; unlock the iPhone, confirm Trust, then Scan again."
                    self.appendLog("Device Center discarded the Normal snapshot because pairing/Trust was unavailable.")
                    return
                }

                self.snapshot = preflight
                self.deviceCenterSnapshot = details
                self.deviceCenterStatusText = details.hasLiveNormalDetails
                    ? "Detailed read-only snapshot updated. Values are source-labelled and timestamped."
                    : "The device is connected, but Trust or optional Apple services did not expose detailed properties."
                self.appendLog("Device Center snapshot updated with \(details.facts.count) evidence records.")
            }
        }
    }

    func copyDeviceSummary() {
        let summary = DeviceCenterReportBuilder.redactedSummary(for: displayedDeviceCenterSnapshot)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(summary, forType: .string)
        appendLog("Copied a redacted Device Center summary to the clipboard.")
    }

    func saveDeviceReport() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SE2-Device-Report-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Identifiers are masked. App lists, crash contents, syslog, screenshots, backups, accounts, and Mac paths are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = DeviceCenterReportBuilder.redactedText(for: displayedDeviceCenterSnapshot)
            try Data(report.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            appendLog("Saved a privacy-safe Device Center report.")
        } catch {
            showAlert(title: "Could not save device report", message: error.localizedDescription)
        }
    }

    func openAppleCoverage() {
        guard let url = URL(string: "https://checkcoverage.apple.com/") else { return }
        NSWorkspace.shared.open(url)
        appendLog("Opened Apple's coverage page without sending a device identifier.")
    }

    func openFinderBackup() {
        guard canOpenFinderBackup else {
            showAlert(
                title: "Finder backup is not ready",
                message: "Connect exactly one verified SE2 in Normal iOS. Unlock and Trust it, finish any active operation, then Scan again."
            )
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Open Finder for a local backup?"
        alert.informativeText = "Select the iPhone under Locations, open General, and choose Back Up Now. Enable Encrypt local backup if you need saved passwords, Health data, and other protected categories. This app never asks for or stores the backup password."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open Finder")
        guard alert.runModal() == .alertSecondButtonReturn else { return }

        NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser)
        appendLog("Opened Finder for a user-controlled backup handoff; no backup command was started by this app.")
        recordTimeline(
            category: .support,
            title: "Finder backup handoff",
            detail: "Finder was opened; the user remains in control of backup and encryption settings."
        )
    }

    func openAppleBackupGuide() {
        guard let url = URL(string: "https://support.apple.com/108353") else { return }
        NSWorkspace.shared.open(url)
        appendLog("Opened Apple's encrypted-backup guide.")
    }

    func copyCrashReports() {
        guard canCopyCrashReports,
              let ecid = DeviceDetector.canonicalECIDHex(snapshot.ecid),
              let udid = snapshot.udid,
              let location = snapshot.locationID,
              let crashTool = ToolPaths.ideviceCrashReport else {
            showAlert(
                title: "Crash-report copy is not available",
                message: "Exactly one trusted, verified SE2 in Normal iOS plus idevicecrashreport is required. No report was read or removed."
            )
            return
        }

        let pin = FactoryResetPin(ecid: ecid, udid: udid, locationID: location)
        operationRunning = true
        isDestructiveOperation = false
        progress = nil
        operationStep = "Verifying the exact target and Trust before reading crash reports…"
        statusText = "Preparing a privacy-sensitive crash-report copy…"
        detailText = "Nothing has been copied yet. Originals will remain on the iPhone."
        lastError = nil
        expectedOperationECID = pin.ecid
        expectedOperationUDID = pin.udid
        expectedOperationCommand = "crash-copy"
        appendLog("Crash-report copy preflight started for \(masked(pin.ecid)).")

        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let currentEvidence = pairing.isValid ? detected : DeviceDetector.stableUSB()
            DispatchQueue.main.async {
                guard let self else { return }
                guard DeviceDetector.matchesPinnedNormalTarget(
                    detected,
                    pinnedECID: pin.ecid,
                    pinnedUDID: pin.udid,
                    pinnedLocation: pin.locationID
                ), pairing.isValid else {
                    self.finishSupportOperationState()
                    self.apply(currentEvidence)
                    self.statusText = "Crash-report copy blocked — target or Trust changed."
                    self.showAlert(
                        title: "Target verification failed",
                        message: "The same trusted Normal-mode SE2 was not verified at the original USB port. No crash report was copied or removed."
                    )
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.finishSupportOperationState()
                    self.statusText = "Crash-report copy blocked — another iPhone tool is open."
                    self.showAlert(
                        title: "Another iPhone tool is open",
                        message: "Close Apple Configurator, 3uTools, idevicerestore, another cfgutil session, and any Finder device operation. No crash report was copied."
                    )
                    return
                }
                guard self.confirmCrashReportCopy(pin: pin) else {
                    self.finishSupportOperationState()
                    self.statusText = "Crash-report copy cancelled."
                    self.detailText = "No report was read, copied, or removed."
                    self.appendLog("Crash-report copy was cancelled before destination selection.")
                    return
                }
                guard let parent = self.chooseCrashReportParentDirectory() else {
                    self.finishSupportOperationState()
                    self.statusText = "Crash-report copy cancelled."
                    self.detailText = "No destination was selected and no report was read."
                    return
                }
                self.operationStep = "Running the final exact-target and Trust check…"
                self.finalizeCrashReportCopy(pin: pin, crashTool: crashTool, parent: parent)
            }
        }
    }

    func openCopiedCrashReports() {
        guard let directory = crashReportSummary?.directoryURL else { return }
        NSWorkspace.shared.open(directory)
    }

    func clearCrashCopyReview() {
        guard crashCopyReviewRequired, !operationRunning, !destructiveWorkflowActive else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear the crash-copy review lock?"
        alert.informativeText = "Only continue after you inspected the iPhone and the selected folder. Clearing this lock does not prove that reports remained on the iPhone or that every local file is private and complete."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "I reviewed them — Clear Lock")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        crashCopyReviewRequired = false
        statusText = "Crash-copy review lock cleared manually."
        detailText = "Scan and verify the same iPhone before starting another target-bound support action."
        appendLog("The user manually cleared the crash-copy review lock after inspecting the phone and folder.")
        recordTimeline(
            category: .support,
            severity: .warning,
            title: "Crash-copy review cleared manually",
            detail: "This action did not certify the prior copy outcome."
        )
    }

    func copyDeviceTimeline() {
        let report = DeviceTimelineReportBuilder.redactedText(
            events: deviceTimeline,
            snapshot: displayedDeviceCenterSnapshot
        )
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        appendLog("Copied the redacted USB and recovery timeline.")
    }

    func saveDeviceTimeline() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SE2-USB-Timeline-\(formatter.string(from: Date())).txt"
        panel.allowedContentTypes = [.plainText]
        panel.message = "Identifiers and local paths are masked. iPhone crash-report and syslog contents are not included."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let report = DeviceTimelineReportBuilder.redactedText(
                events: deviceTimeline,
                snapshot: displayedDeviceCenterSnapshot
            )
            try Data(report.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            appendLog("Saved a redacted USB and recovery timeline.")
        } catch {
            showAlert(title: "Could not save timeline", message: error.localizedDescription)
        }
    }

    private func finalizeCrashReportCopy(
        pin: FactoryResetPin,
        crashTool: String,
        parent: URL
    ) {
        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let currentEvidence = pairing.isValid ? detected : DeviceDetector.stableUSB()
            DispatchQueue.main.async {
                guard let self else { return }
                guard DeviceDetector.matchesPinnedNormalTarget(
                    detected,
                    pinnedECID: pin.ecid,
                    pinnedUDID: pin.udid,
                    pinnedLocation: pin.locationID
                ), pairing.isValid else {
                    self.finishSupportOperationState()
                    self.apply(currentEvidence)
                    self.statusText = "Crash-report copy blocked by the final target check."
                    self.showAlert(
                        title: "Final verification failed",
                        message: "The same trusted SE2 or USB port changed after confirmation. No crash report was copied or removed."
                    )
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.finishSupportOperationState()
                    self.statusText = "Crash-report copy blocked — another iPhone tool is open."
                    self.showAlert(
                        title: "Another iPhone tool is open",
                        message: "Close other iPhone tools and Finder device operations. No crash report was copied."
                    )
                    return
                }
                guard self.hasEnoughFreeSpace(at: parent, minimumBytes: 1_000_000_000) else {
                    self.finishSupportOperationState()
                    self.statusText = "Crash-report copy blocked — destination space is too low or unavailable."
                    self.showAlert(
                        title: "Destination space could not be verified",
                        message: "Choose a writable local volume with at least 1 GB free. No crash-report command was sent."
                    )
                    return
                }

                self.statusText = "Copying crash reports while preserving the iPhone originals…"
                self.detailText = "Keep the cable connected. Reports may contain private app names, paths, identifiers, and diagnostic content."
                self.operationStep = "Copying with idevicecrashreport --keep…"
                self.startTimedKeepAwake(seconds: 330)

                self.workQueue.async { [weak self] in
                    let destination: URL
                    do {
                        destination = try CrashReportInspector.createPrivateDestination(in: parent)
                    } catch {
                        DispatchQueue.main.async {
                            guard let self else { return }
                            let safe = self.redactSupportMessage(error.localizedDescription, localPaths: [parent.path])
                            self.finishSupportOperationState()
                            self.lastError = safe
                            self.statusText = "Crash-report destination could not be created."
                            self.detailText = "No device command was started."
                            self.showAlert(title: "Could not create private folder", message: safe)
                        }
                        return
                    }

                    let result = ProcessRunner.run(
                        crashTool,
                        DeviceSupportCommandBuilder.copyCrashReports(udid: pin.udid, destination: destination),
                        timeout: 300
                    )
                    var summary = CrashReportInspector.summarizeAndSecure(directory: destination)
                    let postflight = DeviceDetector.enriched()
                    let postPairing = PairingProbe.validate(udid: pin.udid)
                    DispatchQueue.main.async {
                        guard let self else { return }
                        let validationIssue = CrashReportOutputValidator.issue(
                            exitCode: result.exitCode,
                            stdout: result.stdout,
                            stderr: result.stderr
                        )
                        let targetVerified = DeviceDetector.matchesPinnedNormalTarget(
                            postflight,
                            pinnedECID: pin.ecid,
                            pinnedUDID: pin.udid,
                            pinnedLocation: pin.locationID
                        ) && postPairing.isValid
                        summary.targetVerifiedAfterCopy = targetVerified
                        let privacyVerified = summary.privacySecured && !summary.enumerationWasTruncated
                        let commandSucceeded = validationIssue == nil && privacyVerified && targetVerified
                        let needsManualReview = CrashReportReviewPolicy.requiresReview(
                            timedOut: result.timedOut,
                            validationIssue: validationIssue,
                            privacyVerified: privacyVerified,
                            targetVerified: targetVerified
                        )
                        if needsManualReview { self.crashCopyReviewRequired = true }
                        self.finishSupportOperationState()
                        if !targetVerified {
                            self.apply(postflight)
                        }
                        self.crashReportSummary = summary

                        if commandSucceeded {
                            self.statusText = "Crash-report copy completed"
                            self.detailText = "Copied \(summary.fileCount) file(s). Private local permissions and the same trusted target were re-verified; no move/remove output was reported."
                            self.appendLog("Crash-report copy completed with \(summary.fileCount) file(s); originals were preserved with --keep.")
                            self.recordTimeline(
                                category: .support,
                                severity: .success,
                                title: "Crash reports copied",
                                detail: "\(summary.fileCount) local file(s); iPhone originals preserved."
                            )
                            self.showAlert(
                                title: "Crash reports copied",
                                message: "Copied \(summary.fileCount) file(s). \(summary.panicNamedFileCount) filename(s) contain “panic”. The same trusted target and private local permissions were re-verified. This app did not inspect or upload report contents."
                            )
                        } else {
                            var reasons = CrashReportFailureReasonBuilder.commandReasons(
                                timedOut: result.timedOut,
                                validationIssue: validationIssue
                            )
                            if !privacyVerified {
                                reasons.append("Private 0700/0600 permissions could not be verified for every local entry (\(summary.securityIssueCount) issue(s)).")
                            }
                            if !targetVerified {
                                reasons.append("The same ECID, UDID, USB location, Normal mode, SE2 identity, and Trust could not all be re-verified after the copy.")
                            }
                            reasons.append("No automatic retry ran. Inspect the selected folder and iPhone before continuing.")
                            let safe = reasons.joined(separator: " ")
                            self.lastError = safe
                            self.statusText = needsManualReview || result.timedOut
                                ? "Crash-report copy outcome requires manual review"
                                : "Crash-report copy failed"
                            self.detailText = needsManualReview
                                ? "The crash-copy action is locked until you inspect the phone and folder and explicitly clear the review lock."
                                : "The tool did not provide a clean completion. Partial local files may exist; no automatic retry ran."
                            self.appendLog("Crash-report copy did not receive a clean, privacy-verified, same-target completion. Exit \(result.exitCode); no raw tool output was retained.")
                            self.recordTimeline(
                                category: .support,
                                severity: .error,
                                title: "Crash-report copy not verified",
                                detail: "No raw report filename/output was retained and no automatic retry ran."
                            )
                            self.showAlert(
                                title: needsManualReview ? "Crash-copy review required" : "Crash-report copy failed",
                                message: safe
                            )
                        }
                    }
                }
            }
        }
    }

    private func confirmCrashReportCopy(pin: FactoryResetPin) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Copy private crash reports?"
        alert.informativeText = "Target: iPhone12,8 • ECID \(pin.ecid) • UDID …\(pin.udid.suffix(8)). Reports can contain app names, paths, identifiers, and diagnostic or user context. They stay in a new local folder. Originals are requested with mandatory --keep. This app does not upload; a separate sync service may upload files if you choose one of its folders."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Choose Folder…")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func chooseCrashReportParentDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose Folder"
        panel.message = "A new permission-0700 SE2-Crash-Reports folder will be created here. Existing files will not be overwritten."
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private func startTimedKeepAwake(seconds: Int) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ToolPaths.caffeinate)
        process.arguments = ["-dimsu", "-t", String(seconds)]
        do {
            try process.run()
            caffeinateProcess = process
        } catch {
            appendLog("Warning: macOS caffeinate could not start for the support copy: \(error.localizedDescription)")
        }
    }

    private func finishSupportOperationState() {
        if caffeinateProcess?.isRunning == true { caffeinateProcess?.terminate() }
        caffeinateProcess = nil
        operationRunning = false
        isDestructiveOperation = false
        progress = nil
        operationStep = ""
        expectedOperationECID = nil
        expectedOperationUDID = nil
        expectedOperationCommand = nil
    }

    private func redactSupportMessage(_ value: String, localPaths: [String]) -> String {
        DeviceCenterPrivacy.redactOperationalText(
            value,
            ecids: [snapshot.ecid, expectedOperationECID].compactMap { $0 },
            udids: [snapshot.udid, expectedOperationUDID].compactMap { $0 },
            facts: deviceCenterSnapshot.facts,
            localPaths: localPaths + [FileManager.default.homeDirectoryForCurrentUser.path]
        )
    }

    func restartIPhone() {
        startNormalDevicePowerAction(.restart)
    }

    func shutDownIPhone() {
        startNormalDevicePowerAction(.shutdown)
    }

    private enum NormalDevicePowerAction: String {
        case restart
        case shutdown

        var title: String { self == .restart ? "Restart iPhone" : "Shut Down iPhone" }
        var command: String { self == .restart ? "restart" : "shutdown" }
        var buttonTitle: String { self == .restart ? "Restart" : "Shut Down" }
    }

    private func startNormalDevicePowerAction(_ action: NormalDevicePowerAction) {
        guard canUseNormalDeviceUtilities,
              let ecid = DeviceDetector.canonicalECIDHex(snapshot.ecid),
              let udid = snapshot.udid,
              let location = snapshot.locationID,
              let diagnostics = ToolPaths.ideviceDiagnostics else {
            showAlert(
                title: "\(action.title) is not available",
                message: "Exactly one trusted, verified SE2 in Normal iOS plus idevicediagnostics is required. Recovery, DFU, RestoreOS, and USB-only states are blocked."
            )
            return
        }

        let pin = FactoryResetPin(ecid: ecid, udid: udid, locationID: location)
        lastError = nil
        operationRunning = true
        isDestructiveOperation = false
        progress = nil
        operationStep = "Rechecking the exact Normal-iOS target and Trust…"
        statusText = "Preparing to \(action.command) the exact SE2…"
        appendLog("\(action.title) preflight started for \(masked(ecid)).")

        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let currentEvidence = pairing.isValid ? detected : DeviceDetector.stableUSB()
            DispatchQueue.main.async {
                guard let self else { return }
                guard DeviceDetector.matchesPinnedNormalTarget(
                    detected,
                    pinnedECID: pin.ecid,
                    pinnedUDID: pin.udid,
                    pinnedLocation: pin.locationID
                ), pairing.isValid else {
                    self.operationRunning = false
                    self.operationStep = ""
                    self.apply(currentEvidence)
                    self.deviceCenterStatusText = "The previous Normal-iOS details were invalidated because the target or Trust check failed."
                    self.statusText = "\(action.title) blocked — target or Trust changed."
                    self.showAlert(
                        title: "Target verification failed",
                        message: "The same trusted Normal-mode SE2 was not verified at the original USB port. No \(action.command) command was sent."
                    )
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.operationRunning = false
                    self.operationStep = ""
                    self.statusText = "\(action.title) blocked — another iPhone tool is open."
                    self.showAlert(
                        title: "Another iPhone tool is open",
                        message: "Close Apple Configurator, 3uTools, idevicerestore, another cfgutil session, and any Finder device operation. No \(action.command) command was sent."
                    )
                    return
                }
                guard self.confirmNormalDevicePowerAction(action, pin: pin) else {
                    self.operationRunning = false
                    self.operationStep = ""
                    self.statusText = "\(action.title) cancelled — no command was sent."
                    self.appendLog("\(action.title) was cancelled before the final target check.")
                    return
                }
                self.operationStep = "Running the final exact-target check after confirmation…"
                self.finalizeNormalDevicePowerAction(action, pin: pin, diagnostics: diagnostics)
            }
        }
    }

    private func finalizeNormalDevicePowerAction(
        _ action: NormalDevicePowerAction,
        pin: FactoryResetPin,
        diagnostics: String
    ) {
        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let currentEvidence = pairing.isValid ? detected : DeviceDetector.stableUSB()
            DispatchQueue.main.async {
                guard let self else { return }
                guard DeviceDetector.matchesPinnedNormalTarget(
                    detected,
                    pinnedECID: pin.ecid,
                    pinnedUDID: pin.udid,
                    pinnedLocation: pin.locationID
                ), pairing.isValid else {
                    self.operationRunning = false
                    self.operationStep = ""
                    self.apply(currentEvidence)
                    self.deviceCenterStatusText = "The previous Normal-iOS details were invalidated because the final target or Trust check failed."
                    self.statusText = "\(action.title) blocked by the final target check."
                    self.showAlert(
                        title: "Final verification failed",
                        message: "The same trusted SE2 or USB port changed after confirmation. No \(action.command) command was sent."
                    )
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.operationRunning = false
                    self.operationStep = ""
                    self.statusText = "\(action.title) blocked — another iPhone tool is open."
                    self.showAlert(
                        title: "Another iPhone tool is open",
                        message: "Close Apple Configurator, 3uTools, idevicerestore, another cfgutil session, and any Finder device operation. No \(action.command) command was sent."
                    )
                    return
                }

                self.statusText = action == .restart ? "Restarting the exact SE2…" : "Shutting down the exact SE2…"
                self.detailText = action == .restart
                    ? "Keep the cable connected. The iPhone will temporarily disappear from USB; scan again after it finishes booting."
                    : "The iPhone will power off and disconnect. Turn it on manually when you are ready."
                self.operationStep = action == .restart ? "Waiting for the iPhone to disconnect…" : "Waiting for the iPhone to power off…"

                self.workQueue.async { [weak self] in
                    let result = ProcessRunner.run(
                        diagnostics,
                        ["-u", pin.udid, action.command],
                        timeout: 35
                    )
                    let postCommandUSB = DeviceDetector.stableUSB()
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.operationRunning = false
                        self.operationStep = ""
                        self.snapshot = postCommandUSB
                        self.deviceCenterSnapshot = DeviceCenterCollector.baseline(for: postCommandUSB)
                        self.deviceCenterStatusText = "The previous detailed snapshot is stale after the \(action.command) attempt. Scan the same iPhone again before trusting values."
                        let detail = (result.stdout + "\n" + result.stderr)
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if result.exitCode == 0 {
                            self.statusText = action == .restart ? "Restart requested successfully" : "Shut Down requested successfully"
                            self.detailText = action == .restart
                                ? "Wait for the same iPhone to finish booting, unlock it, then Scan. The command was not retried."
                                : "The iPhone should be off. Turn it on manually when needed; the command was not retried."
                            self.appendLog("\(action.title) command completed for the exact pinned UDID; no retry was attempted.")
                        } else {
                            let message: String
                            if result.timedOut {
                                message = "The diagnostics client timed out after the command may have been sent. The outcome is uncertain: inspect the iPhone and scan again. The command was not retried."
                            } else {
                                message = detail.isEmpty
                                    ? "idevicediagnostics exited with code \(result.exitCode)."
                                    : detail
                            }
                            let safeMessage = self.redact(message)
                            self.lastError = safeMessage
                            self.statusText = result.timedOut ? "\(action.title) outcome is uncertain" : "\(action.title) failed"
                            self.detailText = "Inspect the iPhone, then scan again. The command was not retried and no erase or restore fallback was attempted."
                            self.appendLog("\(action.title) failed: \(safeMessage)")
                            self.showAlert(title: "\(action.title) failed", message: safeMessage)
                        }
                    }
                }
            }
        }
    }

    private func confirmNormalDevicePowerAction(
        _ action: NormalDevicePowerAction,
        pin: FactoryResetPin
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = action == .restart ? .warning : .critical
        alert.messageText = action.title + "?"
        let suffix = String(pin.udid.suffix(8))
        alert.informativeText = action == .restart
            ? "Target: iPhone12,8 • ECID \(pin.ecid) • UDID …\(suffix). Restart interrupts apps and temporarily disconnects USB. It does not intentionally erase data. Close Finder device operations first."
            : "Target: iPhone12,8 • ECID \(pin.ecid) • UDID …\(suffix). The iPhone will power off, disconnect, and must be turned on manually. Unsaved work may be lost. Close Finder device operations first."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: action.buttonTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }

    func performPrimaryAction() {
        if postResetReviewRequired {
            confirmPostResetReviewAndScan()
            return
        }
        guard !crashCopyReviewRequired else { return }
        switch snapshot.mode {
        case .normal:
            canEnterRecoveryWithSoftware ? enterRecovery() : startLiveMonitor()
        case .restoreOS: startLiveMonitor()
        case .recovery: tryRevive()
        case .usbUnavailable:
            if snapshot.deviceCount == 1, snapshot.ecid != nil { startLiveMonitor() } else { scan() }
        case .unknown:
            if snapshot.deviceCount == 1, snapshot.ecid != nil { startLiveMonitor() } else { scan() }
        case .notDetected: scan()
        case .dfu, .multiple: break
        }
    }

    private func confirmPostResetReviewAndScan() {
        guard postResetReviewRequired,
              !operationRunning, !destructiveWorkflowActive, !isScanning, !isMonitoring else { return }
        postResetReviewRequired = false
        appendLog("The user confirmed the post-reset iPhone screen; starting the only review-clearing fresh scan.")
        scan(preserveError: true)
    }

    func chooseIPSW() {
        guard canChooseIPSW else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose an IPSW for iPhone SE (2nd generation)"
        panel.message = "The BuildManifest will be checked for iPhone12,8 compatibility. Apple signing is verified during restore."
        panel.allowedContentTypes = [UTType(filenameExtension: "ipsw") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        validateAndSelectIPSW(url)
    }

    func useAppleLatest() {
        guard canChooseIPSW else { return }
        selectedIPSW = nil
        appendLog("Firmware selection: latest currently signed iOS from Apple (recommended).")
    }

    func useConfiguratorCache() {
        guard canChooseIPSW else { return }
        autoSelectCachedIPSW(showMissingAlert: true)
    }

    func startFactoryReset() {
        guard canFactoryReset,
              let canonicalECID = DeviceDetector.canonicalECIDHex(snapshot.ecid),
              let udid = snapshot.udid,
              let locationID = snapshot.locationID else {
            showAlert(
                title: "Factory Reset is not available",
                message: "Exactly one trusted, verified iPhone SE2 in Normal iOS is required. Recovery, DFU, RestoreOS, and USB-only states are blocked."
            )
            return
        }

        let pin = FactoryResetPin(ecid: canonicalECID, udid: udid, locationID: locationID)
        destructiveWorkflowActive = true
        isScanning = true
        statusText = "Rechecking the exact Normal-iOS target before Factory Reset…"

        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let configurator = ConfiguratorTargetProbe.inspect(ecid: pin.ecid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                switch self.validateFactoryResetPreflight(
                    detected: detected,
                    pairing: pairing,
                    configurator: configurator,
                    pin: pin
                ) {
                case .failure(let error):
                    self.destructiveWorkflowActive = false
                    self.apply(detected)
                    self.showAlert(
                        title: "Factory Reset preflight failed",
                        message: "\(error.localizedDescription) No erase command was started."
                    )
                case .success(let info):
                    guard !self.hasCompetingRestoreClient() else {
                        self.destructiveWorkflowActive = false
                        self.statusText = "Factory Reset blocked — another device tool is open."
                        self.detailText = "Close the other tool or Finder device operation, then scan again."
                        self.showAlert(
                            title: "Another device tool is open",
                            message: "Close Apple Configurator, 3uTools, idevicerestore, another cfgutil session, and any Finder device operation before continuing."
                        )
                        return
                    }
                    self.snapshot = detected
                    guard self.confirmFactoryReset(target: detected, info: info, pin: pin) else {
                        self.destructiveWorkflowActive = false
                        self.statusText = "Factory Reset cancelled — no data was erased."
                        self.appendLog("Factory Reset confirmation was cancelled or incomplete.")
                        return
                    }
                    self.finalizeFactoryResetStart(pin: pin)
                }
            }
        }
    }

    private func finalizeFactoryResetStart(pin: FactoryResetPin) {
        statusText = "Final target and Trust check after Factory Reset confirmation…"
        isScanning = true
        workQueue.async { [weak self] in
            let detected = DeviceDetector.enriched()
            let pairing = PairingProbe.validate(udid: pin.udid)
            let configurator = ConfiguratorTargetProbe.inspect(ecid: pin.ecid)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                switch self.validateFactoryResetPreflight(
                    detected: detected,
                    pairing: pairing,
                    configurator: configurator,
                    pin: pin
                ) {
                case .failure(let error):
                    self.destructiveWorkflowActive = false
                    self.apply(detected)
                    self.showAlert(
                        title: "Final Factory Reset check failed",
                        message: "\(error.localizedDescription) No erase command was started."
                    )
                case .success:
                    guard !self.hasCompetingRestoreClient() else {
                        self.destructiveWorkflowActive = false
                        self.statusText = "Factory Reset blocked — another device tool appeared after confirmation."
                        self.detailText = "No erase command was started. Close the other tool, then scan again."
                        self.showAlert(
                            title: "Another device tool is open",
                            message: "Close Apple Configurator, 3uTools, idevicerestore, another cfgutil session, and any Finder device operation. No erase command was started."
                        )
                        return
                    }
                    self.snapshot = detected
                    let arguments = AppleCommandBuilder.factoryReset(ecid: pin.ecid)
                    self.beginAppleOperation(
                        command: "erase",
                        arguments: arguments,
                        expectedECID: pin.ecid,
                        destructive: true,
                        expectedUDID: pin.udid
                    )
                    self.destructiveWorkflowActive = false
                }
            }
        }
    }

    func startRestore() {
        guard canRestore, let pinnedECID = snapshot.ecid else {
            showAlert(
                title: "Restore is not available",
                message: "The app requires exactly one verified iPhone SE2 in Recovery or DFU mode. RestoreOS and unknown modes are blocked."
            )
            return
        }
        let plan = RestorePlan(ipsw: selectedIPSW)
        destructiveWorkflowActive = true

        statusText = "Rechecking the exact target before restore…"
        isScanning = true
        workQueue.async { [weak self] in
            let rechecked = DeviceDetector.enriched()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                guard self.sameECID(pinnedECID, rechecked.ecid),
                      rechecked.deviceCount == 1,
                      (rechecked.mode == .recovery || rechecked.mode == .dfu),
                      rechecked.isSE2,
                      rechecked.modeVerified else {
                    self.destructiveWorkflowActive = false
                    self.apply(rechecked)
                    self.showAlert(
                        title: "Target verification failed",
                        message: "The same SE2 was not stably detected in Recovery/DFU. No erase command was started."
                    )
                    return
                }
                self.snapshot = rechecked
                guard self.confirmErase(target: rechecked, firmware: plan.firmwareDescription) else {
                    self.destructiveWorkflowActive = false
                    self.statusText = "Restore cancelled — no data was erased."
                    self.appendLog("Erase confirmation was cancelled or did not match ERASE.")
                    return
                }
                self.finalizeRestoreStart(pinnedECID: pinnedECID, plan: plan)
            }
        }
    }

    private func finalizeRestoreStart(pinnedECID: String, plan: RestorePlan) {
        statusText = "Final target check after ERASE confirmation…"
        isScanning = true
        workQueue.async { [weak self] in
            let finalTarget = DeviceDetector.enriched()
            let firmwareCheck = plan.ipsw.map { IPSWValidator.revalidatePinned($0) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                guard self.sameECID(pinnedECID, finalTarget.ecid),
                      finalTarget.deviceCount == 1,
                      (finalTarget.mode == .recovery || finalTarget.mode == .dfu),
                      finalTarget.isSE2,
                      finalTarget.modeVerified else {
                    self.destructiveWorkflowActive = false
                    self.apply(finalTarget)
                    self.showAlert(
                        title: "Final target check failed",
                        message: "The same SE2 was not still present in Recovery/DFU after confirmation. No erase command was started."
                    )
                    return
                }
                if let firmwareCheck, case .failure(let error) = firmwareCheck {
                    self.destructiveWorkflowActive = false
                    self.showAlert(
                        title: "Firmware changed after confirmation",
                        message: "\(error.localizedDescription) No erase command was started."
                    )
                    self.appendLog("Final IPSW revalidation failed: \(error.localizedDescription)")
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.destructiveWorkflowActive = false
                    self.showAlert(
                        title: "Another restore tool is open",
                        message: "Close Apple Configurator, 3uTools, idevicerestore, or another cfgutil session, then scan again."
                    )
                    return
                }
                guard self.hasEnoughFreeSpace() else {
                    self.destructiveWorkflowActive = false
                    self.showAlert(
                        title: "Not enough free disk space",
                        message: "At least 20 GB of free Mac storage is required before restore. No erase command was started."
                    )
                    return
                }
                if let ipsw = plan.ipsw, !ipsw.compatibleWithSE2 {
                    self.destructiveWorkflowActive = false
                    self.showAlert(title: "Wrong IPSW", message: "The selected IPSW does not contain an iPhone12,8 build identity.")
                    return
                }
                self.snapshot = finalTarget
                let args = AppleCommandBuilder.restore(ecid: pinnedECID, ipsw: plan.ipsw?.url)
                self.beginAppleOperation(
                    command: "restore",
                    arguments: args,
                    expectedECID: pinnedECID,
                    destructive: true,
                    firmware: plan.ipsw
                )
                self.destructiveWorkflowActive = false
            }
        }
    }

    func stopMonitoring() {
        monitorGeneration = UUID()
        monitorTimer?.cancel()
        monitorTimer = nil
        isMonitoring = false
        if !operationRunning {
            statusText = "USB monitoring stopped."
        }
    }

    func saveLog() {
        let panel = NSSavePanel()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        panel.nameFieldStringValue = "SE2-Recovery-\(formatter.string(from: Date())).log"
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText, .plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(logText.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            showAlert(title: "Could not save log", message: error.localizedDescription)
        }
    }

    private func apply(_ detected: DeviceSnapshot) {
        let targetChanged = DeviceDetector.normalizeECID(snapshot.ecid) !=
            DeviceDetector.normalizeECID(detected.ecid)
        if targetChanged || detected.mode != .normal {
            crashReportSummary = nil
        }
        snapshot = detected
        deviceCenterGeneration = UUID()
        isLoadingDeviceCenter = false
        deviceCenterSnapshot = DeviceCenterCollector.baseline(for: detected)
        switch detected.mode {
        case .normal where detected.modeVerified:
            deviceCenterStatusText = "Fresh Normal-iOS identity is loaded. Refresh Details verifies Trust before collecting private fields."
        case .notDetected:
            deviceCenterStatusText = "No connected iPhone is available for a detail snapshot."
        case .multiple:
            deviceCenterStatusText = "Multiple devices are present; no single-target details are retained."
        default:
            deviceCenterStatusText = "Current \(detected.mode.title) USB and identity evidence is loaded; stale Normal-iOS private fields are not reused."
        }
        switch detected.mode {
        case .notDetected:
            statusText = "No iPhone detected"
            detailText = "Connect one SE2 directly to the Mac with a data-capable cable, then scan again."
        case .multiple:
            statusText = "Multiple Apple mobile devices detected"
            detailText = "Disconnect every device except the one SE2 you intend to recover. No write action is available."
        case .normal:
            statusText = "Normal iOS mode detected"
            detailText = detected.modeVerified && detected.isSE2
                ? "The device can communicate with lockdownd. Back up first if data matters. Factory Reset is available below; Recovery remains available for a firmware repair."
                : "Normal iOS communication or SE2 identity was not verified. Write actions are disabled."
        case .recovery:
            statusText = detected.modeVerified ? "Recovery Mode confirmed" : "Recovery USB detected — protocol verification unavailable"
            detailText = detected.modeVerified && detected.isSE2
                ? "Try Apple Revive first to preserve data. Full Restore is available only with typed erase confirmation."
                : "Recovery PID is visible, but irecovery and SE2 identity must both be verified before any write action."
        case .dfu:
            statusText = detected.modeVerified ? "DFU Mode confirmed" : "DFU USB detected — protocol verification unavailable"
            detailText = detected.modeVerified && detected.isSE2
                ? "The display should remain black. Full Restore will erase all data and requires typed confirmation."
                : "DFU PID is visible, but irecovery and SE2 identity must both be verified before any write action."
        case .restoreOS:
            statusText = "RestoreOS intermediate mode detected"
            detailText = "Apple restore cannot start from this RestoreOS intermediate state. Use the live button guide to reach verified Recovery or DFU first."
        case .usbUnavailable:
            statusText = "iPhone USB detected, but iOS communication is unavailable"
            detailText = "The USB link is present, but lockdownd did not answer. Normal mode is not verified and all write actions are disabled."
        case .unknown:
            statusText = "USB detected, mode is not stable or supported"
            detailText = "No write action is permitted. Reconnect directly, wait for the device to settle, and scan again."
        }
        let severity: DeviceTimelineSeverity
        switch detected.mode {
        case .restoreOS, .usbUnavailable, .unknown, .multiple: severity = .warning
        case .recovery where detected.modeVerified,
             .dfu where detected.modeVerified:
            severity = .success
        default: severity = .info
        }
        recordTimeline(
            category: .detection,
            severity: severity,
            title: detected.mode.title,
            detail: "\(detected.modeVerified ? "Protocol verified" : "USB evidence only") • target \(masked(detected.ecid))",
            mode: detected.mode,
            usbPID: detected.usbPID
        )
        appendLog("Detected: \(detected.mode.title), PID \(detected.pidHex), ECID \(masked(detected.ecid)).")
    }

    private func enterRecovery() {
        guard snapshot.mode == .normal,
              snapshot.modeVerified,
              snapshot.isSE2,
              let udid = snapshot.udid,
              let tool = ToolPaths.enterRecovery,
              let expectedECID = snapshot.ecid else {
            showAlert(title: "Cannot enter Recovery", message: "Normal SE2 communication, UDID, ECID, and ideviceenterrecovery are all required.")
            return
        }
        operationRunning = true
        statusText = "Requesting one non-destructive transition to Recovery…"
        appendLog("Requesting Recovery transition for verified Normal iOS target \(masked(expectedECID)).")
        recordTimeline(
            category: .recovery,
            title: "Recovery transition requested",
            detail: "One non-destructive software request was sent to the exact verified Normal-iOS target.",
            mode: .normal,
            usbPID: snapshot.usbPID
        )
        workQueue.async { [weak self] in
            let result = ProcessRunner.run(tool, [udid], timeout: 30)
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationRunning = false
                let combined = result.stdout + result.stderr
                self.appendLog(combined.isEmpty ? "ideviceenterrecovery exit \(result.exitCode)." : combined)
                if result.exitCode == 0 {
                    self.startLiveMonitor(expectedECID: expectedECID)
                } else {
                    self.lastError = "ideviceenterrecovery exit \(result.exitCode)"
                    self.statusText = "Software Recovery transition failed; switching to the physical guide."
                    self.startLiveMonitor(expectedECID: expectedECID)
                }
            }
        }
    }

    private func startLiveMonitor(expectedECID: String? = nil) {
        guard !isMonitoring else { return }
        let pinned = expectedECID ?? snapshot.ecid
        guard let pinned else {
            showAlert(title: "ECID missing", message: "The target ECID must be known before monitoring mode changes.")
            return
        }
        let pinnedLocation = snapshot.locationID
        let generation = UUID()
        monitorGeneration = generation
        isMonitoring = true
        statusText = "Watching USB for Recovery or DFU…"
        detailText = "Quick Volume Up, quick Volume Down, then hold Side through black screen and Apple logo until Connect-to-computer appears."
        appendLog("Live USB monitor started for target \(masked(pinned)).")
        recordTimeline(
            category: .usb,
            title: "Live USB watcher started",
            detail: "Observing mode/PID changes only; no write is triggered automatically.",
            mode: snapshot.mode,
            usbPID: snapshot.usbPID
        )

        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        var lastMode: DeviceMode?
        var stableTargetCount = 0
        let deadline = Date().addingTimeInterval(300)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        timer.setEventHandler { [weak self, weak timer] in
            guard let self, let timer else { return }
            let detected = DeviceDetector.usbOnly()
            if detected.mode != lastMode {
                lastMode = detected.mode
                DispatchQueue.main.async {
                    guard self.monitorGeneration == generation, self.isMonitoring else { return }
                    self.appendLog("USB transition: \(detected.mode.title), PID \(detected.pidHex).")
                    self.recordTimeline(
                        category: .usb,
                        severity: [.restoreOS, .usbUnavailable, .unknown].contains(detected.mode) ? .warning : .info,
                        title: "USB mode transition",
                        detail: detected.modeVerified ? "Protocol verified for the pinned target." : "USB evidence observed for the pinned target.",
                        mode: detected.mode,
                        usbPID: detected.usbPID
                    )
                    if detected.mode == .restoreOS {
                        self.detailText = "RestoreOS returned: the timing was missed. Let it settle, then retry while this monitor stays active."
                    }
                }
            }

            if DeviceDetector.matchesPinnedTransition(
                detected,
                pinnedECID: pinned,
                pinnedLocation: pinnedLocation
            ) {
                stableTargetCount += 1
            } else {
                stableTargetCount = 0
            }

            if stableTargetCount >= 5 {
                timer.cancel()
                DispatchQueue.main.async {
                    guard self.monitorGeneration == generation, self.isMonitoring else { return }
                    self.monitorTimer = nil
                    self.isMonitoring = false
                    self.statusText = "\(detected.mode.title) detected — verifying identity…"
                    self.scan()
                }
                return
            }

            if Date() >= deadline {
                timer.cancel()
                DispatchQueue.main.async {
                    guard self.monitorGeneration == generation, self.isMonitoring else { return }
                    self.monitorTimer = nil
                    self.isMonitoring = false
                    self.statusText = "Monitor timed out — no stable Recovery/DFU was detected."
                    self.appendLog("Live monitor timed out after five minutes.")
                }
            }
        }
        monitorTimer = timer
        timer.resume()
    }

    private func tryRevive() {
        guard canRevive, let pinnedECID = snapshot.ecid else { return }
        statusText = "Rechecking the Recovery target before Revive…"
        isScanning = true
        workQueue.async { [weak self] in
            let rechecked = DeviceDetector.enriched()
            DispatchQueue.main.async {
                guard let self else { return }
                self.isScanning = false
                guard self.sameECID(pinnedECID, rechecked.ecid),
                      rechecked.mode == .recovery,
                      rechecked.isSE2,
                      rechecked.modeVerified else {
                    self.apply(rechecked)
                    self.showAlert(title: "Revive target changed", message: "The same SE2 is no longer verified in Recovery. No operation was started.")
                    return
                }
                guard !self.hasCompetingRestoreClient() else {
                    self.showAlert(title: "Another restore tool is open", message: "Close Apple Configurator, 3uTools, idevicerestore, or another cfgutil session first.")
                    return
                }
                guard self.hasEnoughFreeSpace() else {
                    self.showAlert(
                        title: "Not enough free disk space",
                        message: "At least 20 GB of free Mac storage is required before Apple Revive. No operation was started."
                    )
                    return
                }
                let alert = NSAlert()
                alert.alertStyle = .informational
                alert.messageText = "Try Apple Revive?"
                alert.informativeText = "Revive attempts to reinstall the latest iOS without erasing user data. It can still fail, but the app will not automatically fall through to Restore."
                alert.addButton(withTitle: "Try Revive")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                let args = AppleCommandBuilder.revive(ecid: pinnedECID)
                self.beginAppleOperation(command: "revive", arguments: args, expectedECID: pinnedECID, destructive: false)
            }
        }
    }

    private func beginAppleOperation(
        command: String,
        arguments: [String],
        expectedECID: String,
        destructive: Bool,
        expectedUDID: String? = nil,
        firmware: IPSWInfo? = nil
    ) {
        operationRunning = true
        isDestructiveOperation = destructive
        progress = 0
        switch command {
        case "restore": operationStep = "Starting official Apple restore…"
        case "revive": operationStep = "Starting Apple Revive…"
        case "erase": operationStep = "Starting Factory Reset — Erase All Content & Settings…"
        default: operationStep = "Starting Apple device operation…"
        }
        statusText = operationStep
        lastError = nil
        appleCommandSucceeded = false
        appleCommandErrored = false
        expectedOperationECID = expectedECID
        expectedOperationCommand = command
        expectedOperationUDID = expectedUDID
        if command == "erase" {
            deviceCenterGeneration = UUID()
            isLoadingDeviceCenter = false
            crashReportSummary = nil
            snapshot = DeviceCenterCollector.postMutationDeviceEvidence(for: snapshot)
            deviceCenterSnapshot = DeviceCenterCollector.postMutationBaseline(for: snapshot)
            deviceCenterStatusText = "Factory Reset was attempted. All earlier Normal-iOS private details are stale until the Hello screen is checked and a fresh Scan completes."
        }
        appendLog("Starting cfgutil \(command) for \(masked(expectedECID)).")
        recordTimeline(
            category: .operation,
            severity: destructive ? .warning : .info,
            title: "Apple \(command) started",
            detail: destructive ? "A confirmed destructive operation was sent to the pinned ECID." : "A data-preserving Apple operation was sent to the pinned ECID.",
            mode: snapshot.mode,
            usbPID: snapshot.usbPID
        )
        if let ipsw = firmware, command == "restore" {
            appendLog("Validated firmware: \(ipsw.title), iPhone12,8 compatible = \(ipsw.compatibleWithSE2).")
        } else if command == "restore" {
            appendLog("Firmware source: latest currently signed release obtained by Apple Configurator.")
        }

        activeProcess = ProcessRunner.stream(
            ToolPaths.cfgutil,
            arguments,
            onLine: { [weak self] line in
                DispatchQueue.main.async { self?.handleAppleLine(line) }
            },
            onExit: { [weak self] code, launchError in
                DispatchQueue.main.async { self?.finishAppleOperation(exitCode: code, launchError: launchError) }
            }
        )

        if let pid = activeProcess?.processIdentifier {
            let keepAwake = Process()
            keepAwake.executableURL = URL(fileURLWithPath: ToolPaths.caffeinate)
            keepAwake.arguments = ["-dimsu", "-w", String(pid)]
            do {
                try keepAwake.run()
                caffeinateProcess = keepAwake
            } catch {
                appendLog("Warning: macOS caffeinate could not start: \(error.localizedDescription)")
            }
        }
    }

    private func handleAppleLine(_ rawLine: String) {
        let line = redact(rawLine)
        appendLog(line)
        guard let event = AppleOperationParser.parse(
            rawLine,
            expectedECID: expectedOperationECID,
            expectedCommand: expectedOperationCommand
        ) else {
            if rawLine.localizedCaseInsensitiveContains("error") || rawLine.localizedCaseInsensitiveContains("failed") {
                lastError = line
            }
            return
        }
        if let value = event.progress { progress = value }
        if let step = event.step, !step.isEmpty {
            operationStep = step
            statusText = step
            let percent = event.progress.map { " • \(Int(($0 * 100).rounded()))%" } ?? ""
            recordTimeline(
                category: .operation,
                title: "Apple operation progress",
                detail: step + percent,
                mode: snapshot.mode,
                usbPID: snapshot.usbPID
            )
        }
        if let error = event.errorMessage {
            appleCommandErrored = true
            lastError = redact(error)
            recordTimeline(
                category: .operation,
                severity: .error,
                title: "Apple operation error",
                detail: redact(error),
                mode: snapshot.mode,
                usbPID: snapshot.usbPID
            )
        }
        if event.matchingSuccess { appleCommandSucceeded = true }
    }

    private func finishAppleOperation(exitCode: Int32, launchError: String?) {
        activeProcess = nil
        caffeinateProcess = nil
        let safeLaunchError = launchError.map { redact($0) }
        let expected = expectedOperationECID
        let completedCommand = expectedOperationCommand
        let completedUDID = expectedOperationUDID
        expectedOperationECID = nil
        expectedOperationCommand = nil
        expectedOperationUDID = nil
        isDestructiveOperation = false

        if let safeLaunchError {
            lastError = safeLaunchError
            operationRunning = false
            statusText = "Apple operation could not start."
            appendLog("Launch error: \(safeLaunchError)")
            recordTimeline(
                category: .operation,
                severity: .error,
                title: "Apple operation did not launch",
                detail: safeLaunchError
            )
            return
        }

        appendLog("cfgutil exited with code \(exitCode).")
        guard exitCode == 0,
              appleCommandSucceeded,
              !appleCommandErrored,
              let expected,
              let completedCommand else {
            let eraseOutcomeNeedsReview = completedCommand == "erase"
            if eraseOutcomeNeedsReview { postResetReviewRequired = true }
            operationRunning = false
            statusText = "Apple operation failed — it was not retried."
            if lastError == nil { lastError = "cfgutil exit \(exitCode); no matching successful CommandOutput." }
            showAlert(
                title: completedCommand == "erase" ? "Factory Reset failed" : "Recovery operation failed",
                message: lastError ?? "Unknown Apple device-operation error. The app will not retry automatically."
            )
            if eraseOutcomeNeedsReview {
                detailText = "The erase outcome is uncertain. Check the iPhone for a restart or Hello screen before scanning. Do not retry automatically."
            } else {
                scan(preserveError: true)
            }
            recordTimeline(
                category: .operation,
                severity: .error,
                title: "Apple operation failed",
                detail: "cfgutil exit \(exitCode); no automatic retry was attempted."
            )
            return
        }

        progress = 1
        if completedCommand == "erase" {
            guard let completedUDID else {
                postResetReviewRequired = true
                operationRunning = false
                statusText = "Factory Reset reported success, but the pinned UDID was unavailable for post-reset verification."
                detailText = "Check for the Hello screen, then use the manual Scan action. Do not retry automatically."
                return
            }
            postResetReviewRequired = true
            statusText = "Apple accepted Factory Reset; waiting for reset evidence and the same iPhone to return — keep the cable connected."
            operationStep = "Post-Reset target verification"
            verifyPostFactoryReset(expectedECID: expected, expectedUDID: completedUDID)
        } else {
            statusText = "Apple operation completed; waiting for the same iPhone to boot…"
            operationStep = completedCommand == "revive" ? "Post-Revive verification" : "Post-Restore verification"
            verifyPostBoot(expectedECID: expected, completedCommand: completedCommand)
        }
        recordTimeline(
            category: .operation,
            severity: .success,
            title: "Apple \(completedCommand) reported success",
            detail: "The matching target CommandOutput was accepted; post-operation device verification is still required."
        )
    }

    private func verifyPostFactoryReset(expectedECID: String, expectedUDID: String) {
        workQueue.async { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            let pairingEvidenceNotBefore = Date().addingTimeInterval(3)
            var tracker = PostFactoryResetTracker()
            var resetEvidenceObserved = false
            var stableReturnCount = 0
            while Date() < deadline {
                let detected = DeviceDetector.enriched()
                let returnedAfterTransition = tracker.observe(detected, pinnedECID: expectedECID)
                let isCandidate = DeviceDetector.matchesPostFactoryResetCandidate(
                    detected,
                    pinnedECID: expectedECID
                )
                if returnedAfterTransition { resetEvidenceObserved = true }
                if isCandidate,
                   !resetEvidenceObserved,
                   Date() >= pairingEvidenceNotBefore,
                   !PairingProbe.validate(udid: expectedUDID).isValid {
                    resetEvidenceObserved = true
                }

                if resetEvidenceObserved && isCandidate {
                    stableReturnCount += 1
                } else {
                    stableReturnCount = 0
                }

                if stableReturnCount >= 2 {
                    DispatchQueue.main.async {
                        guard let self else { return }
                        self.operationRunning = false
                        let currentEvidence = DeviceCenterCollector.postMutationDeviceEvidence(for: detected)
                        self.snapshot = currentEvidence
                        self.deviceCenterGeneration = UUID()
                        self.deviceCenterSnapshot = DeviceCenterCollector.postMutationBaseline(for: currentEvidence)
                        self.deviceCenterStatusText = "Factory Reset evidence was observed. Earlier private details remain discarded until manual Hello-screen review and a fresh Scan."
                        self.statusText = "Factory Reset was accepted and reset evidence was observed for the same SE2."
                        self.detailText = "Confirm the Hello screen on the iPhone, then click Scan. Activation Lock may still require the legitimate Apple Account, and cellular eSIMs may remain."
                        self.appendLog("Post-reset evidence passed: transition/pairing change plus a stable same-ECID SE2 return.")
                    }
                    return
                }
                Thread.sleep(forTimeInterval: 2)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationRunning = false
                self.statusText = "Apple reported Factory Reset success, but the same SE2 was not re-verified within three minutes."
                self.detailText = "Check for the Hello screen and keep the cable connected, then click the manual Scan action. Do not retry automatically; the erase may already be complete."
                self.appendLog("Post-reset target verification timed out; no automatic retry was attempted.")
            }
        }
    }

    private func verifyPostBoot(expectedECID: String, completedCommand: String) {
        workQueue.async { [weak self] in
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline {
                let usb = DeviceDetector.usbOnly()
                if usb.deviceCount == 1,
                   (usb.mode == .usbUnavailable || usb.mode == .unknown),
                   DeviceDetector.normalizeECID(usb.ecid) == DeviceDetector.normalizeECID(expectedECID) {
                    let enriched = DeviceDetector.enriched()
                    if enriched.mode == .normal,
                       enriched.modeVerified,
                       enriched.isSE2,
                       enriched.productVersion != nil,
                       DeviceDetector.normalizeECID(enriched.ecid) == DeviceDetector.normalizeECID(expectedECID) {
                        DispatchQueue.main.async {
                            guard let self else { return }
                            self.operationRunning = false
                            self.snapshot = enriched
                            self.statusText = "Success — the same SE2 booted into Normal iOS."
                            let version = enriched.productVersion ?? "installed iOS"
                            let build = enriched.buildVersion.map { " (\($0))" } ?? ""
                            if completedCommand == "revive" {
                                self.detailText = "\(version)\(build) is booted after Revive. Unlock the iPhone and verify that your data and apps are present."
                            } else {
                                self.detailText = "\(version)\(build) is booted after Restore. Complete Setup Assistant; Activation Lock still requires the legitimate Apple Account."
                            }
                            self.appendLog("Post-\(completedCommand) verification passed: Normal iOS \(version)\(build).")
                        }
                        return
                    }
                }
                Thread.sleep(forTimeInterval: 2)
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationRunning = false
                self.statusText = "Apple reported success, but Normal iOS was not verified within three minutes."
                self.detailText = "Keep the cable connected and inspect the current USB mode before attempting anything else. Do not auto-retry."
                self.appendLog("Post-restore verification timed out; recovery is incomplete until Normal iOS is confirmed.")
                self.scan()
            }
        }
    }

    private func validateAndSelectIPSW(_ url: URL) {
        guard !isValidatingFirmware, !operationRunning, !isMonitoring, !isScanning else { return }
        isValidatingFirmware = true
        statusText = "Validating IPSW BuildManifest…"
        workQueue.async { [weak self] in
            let result = IPSWValidator.inspect(url)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isValidatingFirmware = false
                switch result {
                case .success(let info):
                    guard info.compatibleWithSE2 else {
                        self.showAlert(title: "Incompatible IPSW", message: "This IPSW does not contain the iPhone12,8 / d79ap build identity.")
                        self.appendLog("Rejected incompatible IPSW: \(url.lastPathComponent).")
                        return
                    }
                    self.selectedIPSW = info
                    self.statusText = "Validated \(info.title) for iPhone12,8."
                    self.appendLog("Selected validated IPSW: \(info.title).")
                case .failure(let error):
                    self.showAlert(title: "Invalid IPSW", message: error.localizedDescription)
                    self.appendLog("IPSW validation failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func autoSelectCachedIPSW(showMissingAlert: Bool = false) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let directories = [
            home.appendingPathComponent("Library/Group Containers/K36BKF7T3D.group.com.apple.configurator/Library/Caches/Firmware")
        ]
        for directory in directories {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }
            let candidates = files.filter {
                $0.pathExtension.lowercased() == "ipsw" && $0.lastPathComponent.hasPrefix("iPhone12,8_")
            }.sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
            if let newest = candidates.first {
                validateAndSelectIPSW(newest)
                return
            }
        }
        appendLog("No cached iPhone12,8 IPSW selected; Apple latest remains available.")
        if showMissingAlert {
            showAlert(
                title: "No Configurator-cached SE2 firmware found",
                message: "Keep Apple latest selected, or choose an official iPhone12,8 IPSW manually."
            )
        }
    }

    private func validateFactoryResetPreflight(
        detected: DeviceSnapshot,
        pairing: PairingValidation,
        configurator: Result<ConfiguratorTargetInfo, Error>,
        pin: FactoryResetPin
    ) -> Result<ConfiguratorTargetInfo, Error> {
        let info: ConfiguratorTargetInfo
        switch configurator {
        case .failure(let error): return .failure(error)
        case .success(let value): info = value
        }
        if let issue = FactoryResetSafety.validationIssue(
            detected: detected,
            pairing: pairing,
            info: info,
            pin: pin
        ) {
            return .failure(factoryResetError(issue))
        }
        return .success(info)
    }

    private func confirmFactoryReset(
        target: DeviceSnapshot,
        info: ConfiguratorTargetInfo,
        pin: FactoryResetPin
    ) -> Bool {
        let suffix = String(pin.ecid.suffix(6)).uppercased()
        let phrase = "FACTORY RESET \(suffix)"
        let version = info.firmwareVersion ?? target.productVersion ?? "current iOS"
        let build = (info.buildVersion ?? target.buildVersion).map { " (\($0))" } ?? ""

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Factory Reset this exact iPhone SE2?"
        alert.informativeText = "Target: iPhone12,8\nECID: \(pin.ecid)\nUDID ending: \(pin.udid.suffix(8))\niOS: \(version)\(build)\n\nALL USER DATA AND SETTINGS WILL BE IRREVERSIBLY ERASED. The current iOS stays installed; firmware is not downloaded or reinstalled. This app does not request eSIM deletion, so cellular eSIMs may remain. Factory Reset does not bypass Activation Lock.\n\nClose Finder device operations and every other iPhone tool. Type \(phrase) to continue."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase All Content & Settings")

        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 470, height: 90))
        let backup = NSButton(checkboxWithTitle: "I have a backup, or I accept permanent data loss.", target: nil, action: nil)
        backup.frame = NSRect(x: 0, y: 62, width: 470, height: 20)
        let findMy = NSButton(checkboxWithTitle: "I signed out of Find My on this iPhone.", target: nil, action: nil)
        findMy.frame = NSRect(x: 0, y: 36, width: 470, height: 20)
        let field = NSTextField(frame: NSRect(x: 0, y: 2, width: 320, height: 24))
        field.placeholderString = phrase
        field.setAccessibilityLabel("Type \(phrase) to confirm Factory Reset")
        field.setAccessibilityHelp("Factory Reset cannot start unless both acknowledgments are checked and the target-bound phrase is exact.")
        accessory.addSubview(backup)
        accessory.addSubview(findMy)
        accessory.addSubview(field)
        alert.accessoryView = accessory

        let response = alert.runModal()
        return response == .alertSecondButtonReturn &&
            backup.state == .on && findMy.state == .on && field.stringValue == phrase
    }

    private func factoryResetError(_ message: String) -> NSError {
        NSError(
            domain: "local.minthanhtut.SE2RecoveryAssistant.FactoryReset",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func confirmErase(target: DeviceSnapshot, firmware: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Permanently erase this iPhone SE2?"
        alert.informativeText = "Target: iPhone12,8\nECID: \(target.displayECID)\nFirmware: \(firmware)\n\nALL DATA AND SETTINGS WILL BE IRREVERSIBLY ERASED. Activation Lock may require the original Apple Account afterward.\n\nType ERASE to continue."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Erase and Restore")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.placeholderString = "Type ERASE"
        field.setAccessibilityLabel("Type ERASE to confirm permanent erase")
        field.setAccessibilityHelp("The restore cannot start unless this field contains the exact uppercase word ERASE.")
        alert.accessoryView = field
        let response = alert.runModal()
        return response == .alertSecondButtonReturn && field.stringValue == "ERASE"
    }

    private func hasCompetingRestoreClient() -> Bool {
        let result = ProcessRunner.run(ToolPaths.ps, ["-axo", "pid=,command="], timeout: 5)
        guard result.exitCode == 0 else { return true }
        for line in result.stdout.components(separatedBy: .newlines) {
            let lower = line.lowercased()
            if lower.contains("/3utools.app/") ||
                lower.contains("/apple configurator.app/contents/macos/apple configurator") ||
                lower.contains("idevicerestore") ||
                (lower.contains("/cfgutil") && !lower.contains("se2 recovery assistant")) {
                return true
            }
        }
        return false
    }

    private func hasEnoughFreeSpace() -> Bool {
        let path = FileManager.default.homeDirectoryForCurrentUser.path
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return false }
        return free.int64Value >= 20_000_000_000
    }

    private func hasEnoughFreeSpace(at directory: URL, minimumBytes: Int64) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
              let free = attrs[.systemFreeSize] as? NSNumber else { return false }
        return free.int64Value >= minimumBytes
    }

    private func sameECID(_ left: String?, _ right: String?) -> Bool {
        guard let left, let right else { return false }
        return DeviceDetector.normalizeECID(left) == DeviceDetector.normalizeECID(right)
    }

    private func recordTimeline(
        category: DeviceTimelineCategory,
        severity: DeviceTimelineSeverity = .info,
        title: String,
        detail: String,
        mode: DeviceMode? = nil,
        usbPID: Int? = nil
    ) {
        let event = DeviceTimelineEvent(
            category: category,
            severity: severity,
            title: redact(title),
            detail: redact(detail),
            mode: mode,
            usbPID: usbPID
        )
        if let previous = deviceTimeline.last,
           previous.category == event.category,
           previous.severity == event.severity,
           previous.title == event.title,
           previous.detail == event.detail,
           previous.mode == event.mode,
           previous.usbPID == event.usbPID,
           event.observedAt.timeIntervalSince(previous.observedAt) < 2 {
            return
        }
        deviceTimeline.append(event)
        if deviceTimeline.count > 200 {
            deviceTimeline.removeFirst(deviceTimeline.count - 200)
        }
    }

    private func appendLog(_ message: String) {
        guard !message.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        let clean = redact(message).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        logText += "[\(formatter.string(from: Date()))] \(clean)\n"
    }

    private func redact(_ value: String) -> String {
        let ecids = [snapshot.ecid, expectedOperationECID].compactMap { $0 }
        let udids = [snapshot.udid, expectedOperationUDID].compactMap { $0 }
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [
            selectedIPSW?.url.path,
            homePath,
            NSTemporaryDirectory().trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            FileManager.default.currentDirectoryPath
        ].compactMap { path -> String? in
            guard let path, !path.isEmpty else { return nil }
            return path.hasPrefix("/") ? path : "/" + path
        }
        return DeviceCenterPrivacy.redactOperationalText(
            value,
            ecids: ecids,
            udids: udids,
            facts: deviceCenterSnapshot.facts,
            localPaths: paths
        )
    }

    private func masked(_ value: String?) -> String {
        guard let value, value.count > 8 else { return value ?? "unknown" }
        return "…" + value.suffix(6)
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
