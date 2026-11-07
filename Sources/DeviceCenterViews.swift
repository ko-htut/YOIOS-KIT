import AppKit
import Combine
import SwiftUI

struct DeviceCenterOverviewView: View {
    @ObservedObject var model: RecoveryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealsSensitiveValues = false
    @State private var revealGeneration = UUID()

    private var details: DeviceCenterSnapshot { model.displayedDeviceCenterSnapshot }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    detailStatusStrip

                    if geometry.size.width >= 980 {
                    HStack(alignment: .top, spacing: 14) {
                        deviceHero
                            .frame(width: 220)
                        VStack(alignment: .leading, spacing: 14) {
                            factPanel("Identity", image: "person.text.rectangle", groups: [.identity])
                            factPanel("Software & activation", image: "gearshape.2", groups: [.software, .security])
                            factPanel("Cellular & network", image: "antenna.radiowaves.left.and.right", groups: [.cellular])
                        }
                        .frame(minWidth: 360, maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 14) {
                            batteryCard
                            storageCard
                            verificationCard
                        }
                        .frame(width: 300)
                    }
                    } else {
                    VStack(alignment: .leading, spacing: 14) {
                        HStack(alignment: .top, spacing: 14) {
                            deviceHero.frame(width: 220)
                            VStack(alignment: .leading, spacing: 14) {
                                factPanel("Identity", image: "person.text.rectangle", groups: [.identity])
                                factPanel("Software & activation", image: "gearshape.2", groups: [.software, .security])
                            }
                            .frame(maxWidth: .infinity)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            factPanel("Cellular & network", image: "antenna.radiowaves.left.and.right", groups: [.cellular])
                            VStack(alignment: .leading, spacing: 14) {
                                batteryCard
                                storageCard
                                verificationCard
                            }
                        }
                    }
                }
                }
                .frame(maxWidth: 1_260, alignment: .topLeading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
            }
            .scrollIndicators(.hidden)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(YIOSWorkspaceBackdrop(accent: .blue))
        .accessibilityIdentifier("deviceCenterOverview")
        .onChange(of: model.snapshot.ecid) { _ in
            revealsSensitiveValues = false
            revealGeneration = UUID()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            hideSensitiveValues()
        }
    }

    private var detailStatusStrip: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: model.isLoadingDeviceCenter ? "arrow.triangle.2.circlepath" : "info.circle.fill")
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(detailStatusMessage)
                    .font(.callout.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
                Text("Every value is labelled by source. Missing data is never converted into a healthy/normal verdict.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 10)
            if details.facts.contains(where: { $0.sensitivity != .none }) {
                Button(revealsSensitiveValues ? "Hide identifiers" : "Reveal for 60s") {
                    revealsSensitiveValues ? hideSensitiveValues() : requestReveal()
                }
                .controlSize(.small)
                .accessibilityIdentifier("revealIdentifiersButton")
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.blue.opacity(colorScheme == .dark ? 0.13 : 0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.blue.opacity(0.22), lineWidth: 1)
        )
        .accessibilityIdentifier("deviceCenterDetailStatus")
    }

    private var detailStatusMessage: String {
        if model.postResetReviewRequired {
            return "Pre-reset private details were discarded. Confirm the Hello screen, then use the manual Scan action for a fresh snapshot."
        }
        return model.deviceCenterStatusText
    }

    private var deviceHero: some View {
        DCPanel(
            title: model.snapshot.deviceCount == 0 ? "No iPhone connected" : "Connected iPhone",
            systemImage: "iphone.gen2"
        ) {
            VStack(spacing: 11) {
                ZStack {
                    RoundedRectangle(cornerRadius: 34, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [Color.blue.opacity(0.20), Color.purple.opacity(0.10)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 112, height: 184)
                    RoundedRectangle(cornerRadius: 30, style: .continuous)
                        .stroke(Color.primary.opacity(0.72), lineWidth: 4)
                        .frame(width: 96, height: 168)
                    VStack(spacing: 9) {
                        Image(systemName: modeSymbol)
                            .font(.system(size: 31, weight: .medium))
                            .foregroundStyle(modeColor)
                        Text(details.mode.title)
                            .font(.caption2.weight(.semibold))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 14)
                    }
                }
                .accessibilityHidden(true)

                VStack(spacing: 3) {
                    Text(modelName)
                        .font(.headline)
                        .multilineTextAlignment(.center)
                    if let name = details.fact("deviceName") {
                        Text(name.displayValue(revealSensitive: revealsSensitiveValues))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(lastUpdatedText)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 6) {
                    Label(details.mode.title, systemImage: modeSymbol)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(modeColor)
                        .lineLimit(1)
                    if let battery = details.batteryPercent {
                        Text("• \(battery)%")
                            .font(.caption2.weight(.semibold))
                    }
                }

                Divider()

                VStack(spacing: 7) {
                    Button {
                        model.refreshDeviceCenter()
                    } label: {
                        Label("Refresh details", systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!model.canRefreshDeviceCenter)
                    .accessibilityIdentifier("refreshDeviceDetailsButton")

                    Button {
                        model.copyDeviceSummary()
                    } label: {
                        Label("Copy summary", systemImage: "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(details.facts.isEmpty)
                    .accessibilityIdentifier("copyDeviceSummaryButton")

                    Button {
                        model.saveDeviceReport()
                    } label: {
                        Label("Export report…", systemImage: "square.and.arrow.up")
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(details.facts.isEmpty)
                    .accessibilityIdentifier("exportDeviceReportButton")

                    Button {
                        model.openAppleCoverage()
                    } label: {
                        Label("Check coverage with Apple", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .help("Opens Apple's official page without sending the serial number")
                    .accessibilityIdentifier("appleCoverageButton")

                    Divider()

                    HStack(spacing: 7) {
                        Button {
                            model.restartIPhone()
                        } label: {
                            Label("Restart…", systemImage: "arrow.clockwise.circle")
                        }
                        .disabled(!model.canUseNormalDeviceUtilities)
            .help("Verified supported iPhone in Normal iOS only; the exact model and target are checked again")
                        .accessibilityIdentifier("restartIPhoneButton")

                        Button {
                            model.shutDownIPhone()
                        } label: {
                            Label("Shut Down…", systemImage: "power")
                        }
                        .tint(.red)
                        .disabled(!model.canUseNormalDeviceUtilities)
            .help("Powers off the exact verified supported iPhone after confirmation")
                        .accessibilityIdentifier("shutDownIPhoneButton")
                    }
                }
                .controlSize(.small)
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier("deviceHeroPanel")
    }

    private func factPanel(
        _ title: String,
        image: String,
        groups: [DeviceFactGroup]
    ) -> some View {
        let facts = groups.flatMap { details.facts(in: $0) }
        return DCPanel(title: title, systemImage: image) {
            if facts.isEmpty {
                UnavailableDetailRow(text: unavailableText(for: groups))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                        DeviceDetailRow(fact: fact, revealsSensitiveValues: revealsSensitiveValues)
                        if index < facts.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var batteryCard: some View {
        DCPanel(title: "Battery & power", systemImage: batterySymbol, accent: .orange) {
            if let percent = details.batteryPercent {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .stroke(Color.orange.opacity(0.18), lineWidth: 7)
                        Circle()
                            .trim(from: 0, to: CGFloat(percent) / 100)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(percent)%")
                            .font(.headline)
                    }
                    .frame(width: 62, height: 62)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.isCharging == true ? "Charging" : "Current charge")
                            .font(.subheadline.weight(.semibold))
                        Text("Device-reported now — not Battery Health")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                ForEach(details.facts(in: .battery).filter { $0.id != "batteryPercent" }) { fact in
                    DeviceDetailRow(fact: fact, revealsSensitiveValues: false)
                }
            } else {
                UnavailableDetailRow(text: "Current charge is unavailable in this mode or Trust state. Battery Health and cycle count are not invented.")
            }
        }
        .accessibilityIdentifier("batteryPanel")
    }

    private var storageCard: some View {
        DCPanel(title: "Storage", systemImage: "internaldrive", accent: .blue) {
            if let total = details.totalStorageBytes {
                VStack(alignment: .leading, spacing: 8) {
                    if let available = details.availableStorageBytes {
                        let used = max(0, total - available)
                        ProgressView(value: Double(used), total: Double(total))
                        HStack {
                            Text("Used \(formatBytes(used))")
                            Spacer()
                            Text("Free \(formatBytes(available))")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    Text("Total \(formatBytes(total))")
                        .font(.subheadline.weight(.semibold))
                    ForEach(details.facts(in: .storage).filter { !["storageTotal", "storageAvailable", "storageUsed"].contains($0.id) }) { fact in
                        DeviceDetailRow(fact: fact, revealsSensitiveValues: false)
                    }
                }
            } else {
                UnavailableDetailRow(text: "Storage is read only from a trusted Normal-iOS session. Recovery/DFU values are intentionally not guessed.")
            }
        }
        .accessibilityIdentifier("storagePanel")
    }

    private var verificationCard: some View {
        DCPanel(title: "Connection evidence", systemImage: "checkmark.shield", accent: .green) {
            VStack(spacing: 0) {
                let facts = details.facts(in: .connection) + details.facts(in: .tooling)
                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: statusSymbol(fact.status))
                            .foregroundStyle(statusColor(fact.status))
                            .accessibilityHidden(true)
                        Text(fact.label)
                            .font(.caption)
                        Spacer(minLength: 6)
                        Text(fact.value)
                            .font(.caption.weight(.medium))
                            .multilineTextAlignment(.trailing)
                            .lineLimit(2)
                    }
                    .padding(.vertical, 5)
                    .help("\(fact.source) — \(fact.explanation)")
                    if index < facts.count - 1 { Divider() }
                }
            }
            Text("Connection evidence only — not a motherboard, camera, display, Face ID/Touch ID, or parts-authenticity diagnostic.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("connectionEvidencePanel")
    }

    private var modelName: String {
        guard let value = details.fact("productType")?.value else {
            return "iPhone not identified"
        }
        return SupportedDeviceCatalog.marketingName(for: value) ?? value
    }

    private var lastUpdatedText: String {
        guard model.snapshot.deviceCount == 1 else { return "Not scanned yet" }
        guard details.capturedAt.timeIntervalSince1970 > 0 else { return "Not scanned yet" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return "Observed \(formatter.string(from: details.capturedAt))"
    }

    private var modeColor: Color {
        switch details.mode {
        case .normal: return .green
        case .recovery: return .blue
        case .dfu: return .purple
        case .restoreOS, .usbUnavailable: return .orange
        case .multiple: return .red
        case .notDetected, .unknown: return .secondary
        }
    }

    private var modeSymbol: String {
        switch details.mode {
        case .normal: return "checkmark.circle.fill"
        case .recovery: return "arrow.clockwise.circle.fill"
        case .dfu: return "iphone"
        case .restoreOS: return "exclamationmark.triangle.fill"
        case .usbUnavailable: return "cable.connector"
        case .multiple: return "exclamationmark.triangle.fill"
        case .notDetected: return "iphone.slash"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var batterySymbol: String {
        if details.isCharging == true { return "battery.100.bolt" }
        guard let percent = details.batteryPercent else { return "battery.0" }
        if percent >= 75 { return "battery.100" }
        if percent >= 40 { return "battery.50" }
        return "battery.25"
    }

    private func unavailableText(for groups: [DeviceFactGroup]) -> String {
        groups.contains(.cellular)
            ? "Cellular identifiers are shown only when a trusted Normal-iOS service returns them. Missing fields do not prove no SIM/eSIM is installed."
            : "This information is unavailable in the current mode or Trust state."
    }

    private func requestReveal() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reveal linkable device identifiers for 60 seconds?"
        alert.informativeText = "Serial, ECID, UDID, IMEI, SIM, phone, network addresses, and device name can identify you or the iPhone. Copied values may remain in clipboard history."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Reveal for 60 Seconds")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        revealsSensitiveValues = true
        let generation = UUID()
        revealGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard revealGeneration == generation else { return }
            revealsSensitiveValues = false
        }
    }

    private func hideSensitiveValues() {
        revealGeneration = UUID()
        revealsSensitiveValues = false
    }
}

struct DeviceEvidenceView: View {
    @ObservedObject var model: RecoveryModel

    private var details: DeviceCenterSnapshot { model.displayedDeviceCenterSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Source-attributed evidence")
                            .font(.title3.weight(.semibold))
                        Text("Verified means a protocol/cross-source check passed. Reported means one trusted Apple/device source returned the value. Neither is a hardware health score.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Refresh") { model.refreshDeviceCenter() }
                        .disabled(!model.canRefreshDeviceCenter)
                        .accessibilityIdentifier("evidenceRefreshButton")
                    Button("Export…") { model.saveDeviceReport() }
                        .disabled(details.facts.isEmpty)
                        .accessibilityIdentifier("evidenceExportButton")
                }

                ForEach(DeviceFactGroup.allCases, id: \.self) { group in
                    let facts = details.facts(in: group)
                    if !facts.isEmpty {
                        DCPanel(title: group.rawValue, systemImage: groupSymbol(group)) {
                            VStack(spacing: 0) {
                                ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                                    EvidenceDetailRow(fact: fact)
                                    if index < facts.count - 1 { Divider() }
                                }
                            }
                        }
                    }
                }

                if !details.notes.isEmpty {
                    DCPanel(title: "Collection notes", systemImage: "note.text", accent: .orange) {
                        ForEach(Array(details.notes.enumerated()), id: \.offset) { _, note in
                            Label(note, systemImage: "info.circle")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: 1_100, alignment: .topLeading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(YIOSWorkspaceBackdrop(accent: .blue))
        .accessibilityIdentifier("deviceEvidenceView")
    }
}

enum DeviceActivityFocus: String {
    case history
    case tools
    case logs
    case crashReview = "crash-review"
}

struct DeviceActivityView: View {
    @ObservedObject var model: RecoveryModel
    let focus: DeviceActivityFocus

    private var details: DeviceCenterSnapshot { model.displayedDeviceCenterSnapshot }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                focusedSections
            }
            .frame(maxWidth: 1_100, alignment: .topLeading)
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(YIOSWorkspaceBackdrop(accent: model.crashCopyReviewRequired ? .red : .blue))
        .accessibilityIdentifier("deviceActivityView")
        .accessibilityValue(focus.rawValue)
    }

    @ViewBuilder
    private var focusedSections: some View {
        switch focus {
        case .history:
            currentOperationPanel
            timelineCenter
            diagnosticLogPanel
            lastErrorPanel
            backupCenter
            crashReportCenter
        case .tools:
            currentOperationPanel
            backupCenter
            crashReportCenter
            timelineCenter
            diagnosticLogPanel
            lastErrorPanel
        case .logs:
            currentOperationPanel
            lastErrorPanel
            diagnosticLogPanel
            timelineCenter
            backupCenter
            crashReportCenter
        case .crashReview:
            crashReportCenter
            currentOperationPanel
            lastErrorPanel
            diagnosticLogPanel
            backupCenter
            timelineCenter
        }
    }

    private var currentOperationPanel: some View {
        DCPanel(title: "Current operation state", systemImage: "waveform.path.ecg") {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.crashCopyReviewRequired ? "exclamationmark.octagon.fill" : (model.operationRunning ? "arrow.triangle.2.circlepath" : "checkmark.circle"))
                    .foregroundStyle(model.crashCopyReviewRequired ? Color.red : (model.operationRunning ? Color.blue : Color.secondary))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(model.statusText)
                        .font(.headline)
                    if model.crashCopyReviewRequired {
                        Text("Manual review lock is active")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                    }
                    Text(model.detailText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if model.operationRunning {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView()
                        }
                        Text(model.operationStep)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .accessibilityIdentifier("currentOperationPanel")
    }

    @ViewBuilder
    private var lastErrorPanel: some View {
        if let error = model.lastError {
            DCPanel(title: "Exact last error", systemImage: "exclamationmark.triangle.fill", accent: .red) {
                Text(error)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Copy error") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(error, forType: .string)
                }
                .accessibilityIdentifier("copyLastErrorButton")
            }
        }
    }

    private var diagnosticLogPanel: some View {
        DCPanel(title: "Diagnostic activity log", systemImage: "doc.text.magnifyingglass") {
            Text("This is the assistant's redacted recovery log—not the iPhone's private crash reports or syslog.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.logText.isEmpty ? "No log entries yet." : model.logText)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
                        .id("activity-log-end")
                }
                .padding(10)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 1)
                )
                .onReceive(model.$logText) { _ in
                    proxy.scrollTo("activity-log-end", anchor: .bottom)
                }
            }
            HStack {
                Button("Save log…") { model.saveLog() }
                    .accessibilityIdentifier("activitySaveLogButton")
                Button("Export device report…") { model.saveDeviceReport() }
                    .disabled(model.displayedDeviceCenterSnapshot.facts.isEmpty)
                    .accessibilityIdentifier("activityExportReportButton")
            }
        }
        .accessibilityIdentifier("diagnosticLogPanel")
    }

    private var backupCenter: some View {
        DCPanel(title: "Backup Center", systemImage: "externaldrive.badge.timemachine") {
            VStack(alignment: .leading, spacing: 9) {
                Label("Finder remains in control", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.blue)
                Text("Open Finder, select the iPhone under Locations, then choose Back Up Now yourself. This handoff does not start or verify a backup, and the app never receives your backup password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Divider()

                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Computer backup encryption")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(details.fact("backupEncrypted")?.value ?? "Not reported")
                        .font(.callout.weight(.medium))
                }
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Cloud backups")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(details.fact("cloudBackup")?.value ?? "Not reported")
                        .font(.callout.weight(.medium))
                }

                Text("These are device/Configurator-reported settings, not proof that a current, complete, or restorable backup exists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.canOpenFinderBackup {
                    Label("Requires exactly one verified supported iPhone in Normal iOS and no active scan, monitor, recovery, reset review, or device operation.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                ViewThatFits(in: .horizontal) {
                    HStack {
                        Button("Open Finder…") { model.openFinderBackup() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canOpenFinderBackup)
                            .accessibilityIdentifier("openFinderBackupButton")
                        Button("Apple backup guide") { model.openAppleBackupGuide() }
                            .accessibilityIdentifier("appleBackupGuideButton")
                    }
                    VStack(alignment: .leading) {
                        Button("Open Finder…") { model.openFinderBackup() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!model.canOpenFinderBackup)
                            .accessibilityIdentifier("openFinderBackupButton")
                        Button("Apple backup guide") { model.openAppleBackupGuide() }
                            .accessibilityIdentifier("appleBackupGuideButton")
                    }
                }
            }
        }
        .accessibilityIdentifier("backupCenterPanel")
    }

    private var crashReportCenter: some View {
        DCPanel(title: "Crash & Panic Reports", systemImage: "waveform.path.ecg.rectangle", accent: .orange) {
            VStack(alignment: .leading, spacing: 9) {
                Text("Copies reports into a new private local folder with idevicecrashreport --keep. Reports can contain app names, paths, identifiers, and diagnostic or user context. This app does not upload contents, interpret them as a hardware verdict, or request removal from the iPhone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !model.canCopyCrashReports {
                    Label("Requires one unlocked/trusted, protocol-verified supported iPhone in Normal iOS, the keep-capable crash-report tool, and no competing iPhone operation.", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if model.crashCopyReviewRequired {
                    Label("Manual review required: inspect the iPhone and copied folder before clearing this one-session safety lock. Another crash copy is blocked.", systemImage: "exclamationmark.octagon.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                crashReportActions

                if let summary = model.crashReportSummary {
                    Divider()
                    HStack(spacing: 18) {
                        Label("\(summary.fileCount) file(s)", systemImage: "doc.on.doc")
                        Label("\(summary.panicNamedFileCount) panic-named", systemImage: "exclamationmark.triangle")
                    }
                    .font(.caption.weight(.semibold))
                    Text("Folder: \(summary.directoryURL.lastPathComponent)")
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                    Label(
                        summary.privacySecured ? "Private folder/file permissions verified" : "Private permissions were not fully verified",
                        systemImage: summary.privacySecured ? "lock.shield.fill" : "lock.trianglebadge.exclamationmark"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.privacySecured ? Color.green : Color.red)
                    Label(
                        summary.targetVerifiedAfterCopy ? "Same trusted supported iPhone re-verified after copy" : "Post-copy target/Trust was not fully re-verified",
                        systemImage: summary.targetVerifiedAfterCopy ? "checkmark.shield.fill" : "person.crop.circle.badge.questionmark"
                    )
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.targetVerifiedAfterCopy ? Color.green : Color.orange)
                    if summary.enumerationWasTruncated {
                        Label("The local folder contains more than the 20,000-entry inspection limit; counts are partial.", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

            }
        }
        .accessibilityIdentifier("crashReportCenterPanel")
    }

    private var crashReportActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack {
                crashReportActionButtons
            }
            VStack(alignment: .leading) {
                crashReportActionButtons
            }
        }
    }

    @ViewBuilder
    private var crashReportActionButtons: some View {
        if model.crashCopyReviewRequired {
            Button("I reviewed them — Clear Lock…") { model.clearCrashCopyReview() }
                .accessibilityIdentifier("clearCrashReviewButton")
        }
        if model.crashReportSummary != nil {
            Button("Open copied folder") { model.openCopiedCrashReports() }
                .accessibilityIdentifier("openCrashReportFolderButton")
        }
        Button("Copy from iPhone…") { model.copyCrashReports() }
            .buttonStyle(.borderedProminent)
            .disabled(!model.canCopyCrashReports)
            .accessibilityIdentifier("copyCrashReportsButton")
    }

    private var timelineCenter: some View {
        DCPanel(title: "USB & Recovery Timeline", systemImage: "point.3.connected.trianglepath.dotted") {
            VStack(alignment: .leading, spacing: 9) {
                Text("Passive observations from this app session only. Mode/PID transitions and this app's Apple-operation outcomes are recorded; Finder progress, cable failure, and hardware causes are never inferred.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if model.deviceTimeline.isEmpty {
                    Label("No timeline events yet.", systemImage: "clock")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(model.deviceTimeline.suffix(12).reversed())) { event in
                            DeviceTimelineRow(event: event)
                            if event.id != model.deviceTimeline.suffix(12).first?.id { Divider() }
                        }
                    }
                }

                HStack {
                    Button("Copy timeline") { model.copyDeviceTimeline() }
                        .disabled(model.deviceTimeline.isEmpty)
                        .accessibilityIdentifier("copyDeviceTimelineButton")
                    Button("Export timeline…") { model.saveDeviceTimeline() }
                        .disabled(model.deviceTimeline.isEmpty)
                        .accessibilityIdentifier("exportDeviceTimelineButton")
                }
            }
        }
        .accessibilityIdentifier("deviceTimelinePanel")
    }
}

private struct DeviceTimelineRow: View {
    let event: DeviceTimelineEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: timelineSymbol(event.severity))
                .foregroundStyle(timelineColor(event.severity))
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 8)
                    Text(event.observedAt.formatted(date: .omitted, time: .standard))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Text(event.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 7) {
                    Text(event.category.rawValue)
                    if let mode = event.mode { Text("• \(mode.title)") }
                    if let pid = event.usbPID { Text(String(format: "• PID 0x%04X", pid)) }
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [
            event.observedAt.formatted(date: .omitted, time: .standard),
            event.category.rawValue,
            event.severity.rawValue,
            event.title,
            event.detail
        ]
        if let mode = event.mode { parts.append(mode.title) }
        if let pid = event.usbPID { parts.append(String(format: "PID 0x%04X", pid)) }
        return parts.joined(separator: ", ")
    }
}

private struct DeviceDetailRow: View {
    let fact: DeviceFact
    let revealsSensitiveValues: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(fact.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 108, alignment: .leading)
            Spacer(minLength: 4)
            Text(fact.displayValue(revealSensitive: revealsSensitiveValues))
                .font(fact.sensitivity == .none ? .callout : .system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 7)
        .help("\(fact.status.title) • \(fact.source) — \(fact.explanation)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fact.label): \(fact.displayValue(revealSensitive: revealsSensitiveValues)). \(fact.status.title). Source \(fact.source).")
    }
}

private struct EvidenceDetailRow: View {
    let fact: DeviceFact

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: statusSymbol(fact.status))
                .foregroundStyle(statusColor(fact.status))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(fact.label)
                        .font(.subheadline.weight(.semibold))
                    Spacer(minLength: 10)
                    Text(fact.status.title)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor(fact.status))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(statusColor(fact.status).opacity(0.10)))
                }
                Text(fact.displayValue(revealSensitive: false))
                    .font(fact.sensitivity == .none ? .callout : .system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                Text(fact.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Label(fact.source, systemImage: "link")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(fact.label), \(fact.status.title), \(fact.displayValue(revealSensitive: false)), source \(fact.source). \(fact.explanation)")
    }
}

private struct UnavailableDetailRow: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "minus.circle")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct DCPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color?
    let content: Content

    init(
        title: String,
        systemImage: String,
        accent: Color? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            YIOSPanelHeader(title, systemImage: systemImage, accent: accent)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .yiosCardSurface(accent: accent, cornerRadius: 12)
    }
}

private func statusColor(_ status: DeviceFactStatus) -> Color {
    switch status {
    case .verified, .ready: return .green
    case .reported: return .blue
    case .warning: return .orange
    case .unavailable: return .secondary
    }
}

private func statusSymbol(_ status: DeviceFactStatus) -> String {
    switch status {
    case .verified: return "checkmark.seal.fill"
    case .ready: return "checkmark.circle.fill"
    case .reported: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .unavailable: return "minus.circle.fill"
    }
}

private func timelineColor(_ severity: DeviceTimelineSeverity) -> Color {
    switch severity {
    case .info: return .blue
    case .success: return .green
    case .warning: return .orange
    case .error: return .red
    }
}

private func timelineSymbol(_ severity: DeviceTimelineSeverity) -> String {
    switch severity {
    case .info: return "info.circle.fill"
    case .success: return "checkmark.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .error: return "xmark.octagon.fill"
    }
}

private func groupSymbol(_ group: DeviceFactGroup) -> String {
    switch group {
    case .connection: return "cable.connector"
    case .identity: return "person.text.rectangle"
    case .software: return "gearshape.2"
    case .cellular: return "antenna.radiowaves.left.and.right"
    case .battery: return "battery.50"
    case .storage: return "internaldrive"
    case .security: return "lock.shield"
    case .tooling: return "wrench.and.screwdriver"
    case .limitations: return "eye.slash"
    }
}

private func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}
