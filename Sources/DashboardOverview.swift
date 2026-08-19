import AppKit
import Combine
import SwiftUI

struct DashboardOverviewView: View {
    @ObservedObject var model: RecoveryModel
    @Environment(\.colorScheme) private var colorScheme
    @State private var revealsSensitiveValues = false
    @State private var revealGeneration = UUID()

    let openMoreTools: () -> Void

    init(model: RecoveryModel, openMoreTools: @escaping () -> Void = {}) {
        self.model = model
        self.openMoreTools = openMoreTools
    }

    private var details: DeviceCenterSnapshot { model.displayedDeviceCenterSnapshot }

    var body: some View {
        ScrollView {
            ViewThatFits(in: .horizontal) {
                wideDashboard
                compactDashboard
            }
            .padding(18)
        }
        .background(dashboardBackground)
        .accessibilityIdentifier("deviceCenterOverview")
        .onChange(of: model.snapshot.ecid) { _ in
            hideSensitiveValues()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            hideSensitiveValues()
        }
    }

    private var wideDashboard: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 16) {
                statusHero
                deviceSummaryCard
                quickActionsSection
                systemReadinessSection
            }
            .frame(minWidth: 650, maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 16) {
                connectionEvidenceCard
                batteryCard
                storageCard
            }
            .frame(width: 296)
        }
        .frame(minWidth: 960, maxWidth: .infinity, alignment: .topLeading)
    }

    private var compactDashboard: some View {
        VStack(alignment: .leading, spacing: 16) {
            statusHero
            deviceSummaryCard
            quickActionsSection
            systemReadinessSection

            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 14) {
                    connectionEvidenceCard
                    batteryCard
                    storageCard
                }
                VStack(alignment: .leading, spacing: 14) {
                    connectionEvidenceCard
                    HStack(alignment: .top, spacing: 14) {
                        batteryCard
                        storageCard
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusHero: some View {
        ZStack(alignment: .trailing) {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [heroAccent.opacity(colorScheme == .dark ? 0.18 : 0.08), Color.blue.opacity(colorScheme == .dark ? 0.08 : 0.025)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            dashboardPhoneDecoration
                .padding(.trailing, 22)
                .opacity(model.snapshot.deviceCount == 0 ? 0.42 : 0.88)

            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    Circle()
                        .fill(heroAccent.opacity(colorScheme == .dark ? 0.22 : 0.11))
                    Circle()
                        .stroke(heroAccent.opacity(0.16), lineWidth: 8)
                    Image(systemName: heroSymbol)
                        .font(.system(size: 27, weight: .semibold))
                        .foregroundStyle(heroAccent)
                }
                .frame(width: 58, height: 58)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    if reviewEyebrow != nil {
                        Text(reviewEyebrow ?? "")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(heroAccent)
                    }

                    Text(model.statusText)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    Text(model.detailText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if model.operationRunning {
                        VStack(alignment: .leading, spacing: 5) {
                            if let progress = model.progress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView()
                            }
                            Text(model.operationStep)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 470)
                    }

                    if let error = model.lastError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 540, alignment: .leading)
                    }

                    Text(heroBadgeText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(heroAccent)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(heroAccent.opacity(colorScheme == .dark ? 0.20 : 0.09)))
                }
                .padding(.trailing, 160)

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .frame(minHeight: 156)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(heroAccent.opacity(0.25), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceCenterDetailStatus")
    }

    private var dashboardPhoneDecoration: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.blue.opacity(0.50), lineWidth: 5)
                .frame(width: 100, height: 164)
                .rotationEffect(.degrees(7))
            Circle()
                .fill(Color.blue)
                .frame(width: 42, height: 42)
                .overlay(
                    Image(systemName: heroSymbol)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                )
        }
        .accessibilityHidden(true)
    }

    private var deviceSummaryCard: some View {
        DashboardPanel(title: "Device Summary", systemImage: "iphone.gen2") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 18) {
                    compactDeviceHero
                        .frame(width: 180)
                    Divider()
                    summaryFactsGrid
                }

                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top, spacing: 16) {
                        compactDeviceHero
                            .frame(width: 165)
                        Divider()
                        summaryFactsGrid
                    }
                }
            }

            Divider()

            deviceUtilityToolbar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceSummaryPanel")
    }

    private var compactDeviceHero: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(Color.secondary.opacity(0.62), lineWidth: 4)
                    .frame(width: 78, height: 134)
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.32))
                    .frame(width: 24, height: 4)
                    .offset(y: -57)
                Circle()
                    .fill(heroAccent)
                    .frame(width: 36, height: 36)
                    .overlay(
                        Image(systemName: heroSymbol)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                    )
            }
            .accessibilityHidden(true)

            Text(modelName)
                .font(.headline)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Text(lastUpdatedText)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Label(connectionLabel, systemImage: model.snapshot.deviceCount == 1 ? "cable.connector" : "iphone.slash")
                .font(.caption)
                .foregroundStyle(model.snapshot.deviceCount == 1 ? Color.green : Color.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceHeroPanel")
    }

    private var summaryFactsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(minimum: 190), spacing: 12), GridItem(.flexible(minimum: 190), spacing: 12)],
            alignment: .leading,
            spacing: 0
        ) {
            summaryFact("productType", fallbackLabel: "Product Type", icon: "iphone")
            summaryFact("ecid", fallbackLabel: "ECID", icon: "tag")
            summaryFact("hardwareModel", fallbackLabel: "Model", icon: "cpu")
            summaryFact("udid", fallbackLabel: "UDID", icon: "link")
            summaryFact("productVersion", fallbackLabel: "iOS Version", icon: "apple.logo")
            summaryFact("activationState", fallbackLabel: "Activation", icon: "checkmark.shield")
            summaryFact("buildVersion", fallbackLabel: "Build", icon: "number.square")
            summaryFact("usbPID", fallbackLabel: "USB Product ID", icon: "cable.connector")
            summaryFact("chipID", fallbackLabel: "Chip ID (CPID)", icon: "cpu.fill")
            summaryFact("usbLocation", fallbackLabel: "USB Location", icon: "point.3.connected.trianglepath.dotted")
            summaryFact("boardID", fallbackLabel: "Board ID (BDID)", icon: "rectangle.3.group")
            summaryFact("usbLink", fallbackLabel: "USB Link", icon: "bolt.horizontal")
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func summaryFact(_ id: String, fallbackLabel: String, icon: String) -> some View {
        let fact = details.fact(id)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.blue)
                .frame(width: 18)
                .accessibilityHidden(true)
            Text(fact?.label ?? fallbackLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(fact?.displayValue(revealSensitive: revealsSensitiveValues) ?? "—")
                .font((fact?.sensitivity ?? DeviceFactSensitivity.none) == DeviceFactSensitivity.none ? .callout : .system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 7)
        .help(fact.map { "\($0.status.title) • \($0.source) — \($0.explanation)" } ?? "Unavailable in this mode or Trust state")
        .accessibilityElement(children: .combine)
    }

    private var deviceUtilityToolbar: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 108, maximum: 180), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            utilityButtons
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var utilityButtons: some View {
        Button {
            model.refreshDeviceCenter()
        } label: {
            Label("Refresh details", systemImage: "arrow.clockwise")
        }
        .disabled(!model.canRefreshDeviceCenter)
        .accessibilityIdentifier("refreshDeviceDetailsButton")

        if details.facts.contains(where: { $0.sensitivity != .none }) {
            Button(revealsSensitiveValues ? "Hide identifiers" : "Reveal for 60s") {
                revealsSensitiveValues ? hideSensitiveValues() : requestReveal()
            }
            .accessibilityIdentifier("revealIdentifiersButton")
        }

        Button("Copy summary") { model.copyDeviceSummary() }
            .disabled(details.facts.isEmpty)
            .accessibilityIdentifier("copyDeviceSummaryButton")

        Button("Export report…") { model.saveDeviceReport() }
            .disabled(details.facts.isEmpty)
            .accessibilityIdentifier("exportDeviceReportButton")

        Button("Apple coverage") { model.openAppleCoverage() }
            .help("Opens Apple's official page without sending the serial number")
            .accessibilityIdentifier("appleCoverageButton")

        Button("Restart…") { model.restartIPhone() }
            .disabled(!model.canUseNormalDeviceUtilities)
            .help("Verified Normal SE2 only; exact target is checked again before the command")
            .accessibilityIdentifier("restartIPhoneButton")

        Button("Shut Down…") { model.shutDownIPhone() }
            .tint(.red)
            .disabled(!model.canUseNormalDeviceUtilities)
            .help("Powers off the exact verified Normal-mode SE2 after confirmation")
            .accessibilityIdentifier("shutDownIPhoneButton")

    }

    private var quickActionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quick Actions")
                .font(.title3.weight(.semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 112), spacing: 10), count: 5),
                spacing: 10
            ) {
                DashboardActionTile(
                    title: dashboardPrimaryTitle,
                    subtitle: primaryActionSubtitle,
                    systemImage: "arrow.clockwise",
                    accent: .blue,
                    action: model.performPrimaryAction
                )
                .disabled(!dashboardPrimaryEnabled)
                .accessibilityIdentifier("primaryActionButton")

                DashboardActionTile(
                    title: "Factory Reset",
                    subtitle: "Erase content & settings",
                    systemImage: "trash",
                    accent: .purple,
                    action: model.startFactoryReset
                )
                .disabled(!model.canFactoryReset)
                .accessibilityIdentifier("factoryResetButton")

                DashboardActionTile(
                    title: "Erase & Restore",
                    subtitle: "Reinstall signed iOS",
                    systemImage: "iphone.and.arrow.forward",
                    accent: .orange,
                    action: model.startRestore
                )
                .disabled(!model.canRestore)
                .accessibilityIdentifier("restoreButton")

                DashboardActionTile(
                    title: "Try Revive",
                    subtitle: "Preserve data when possible",
                    systemImage: "waveform.path.ecg",
                    accent: .green,
                    action: model.performPrimaryAction
                )
                .disabled(!model.canRevive)
                .accessibilityIdentifier("reviveButton")

                DashboardActionTile(
                    title: "More Tools",
                    subtitle: "Reports, backup & timeline",
                    systemImage: "square.grid.2x2",
                    accent: .indigo,
                    action: openMoreTools
                )
                .accessibilityIdentifier("moreToolsButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickActionsPanel")
    }

    private var systemReadinessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("System Readiness")
                .font(.title3.weight(.semibold))

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(minimum: 115), spacing: 9), count: 5),
                spacing: 9
            ) {
                readinessTile(
                    title: "Apple Configurator",
                    component: .appleConfigurator,
                    icon: "checkmark.seal"
                )
                readinessTile(
                    title: "iPhone CLI Tools",
                    component: .libimobiledevice,
                    icon: "shield.lefthalf.filled"
                )
                DashboardReadinessTile(
                    title: "Lockdown",
                    detail: details.pairingValidated ? "Trust validated" : (model.snapshot.mode == .normal && model.snapshot.modeVerified ? "Detected" : "Unavailable"),
                    isReady: details.pairingValidated || (model.snapshot.mode == .normal && model.snapshot.modeVerified),
                    systemImage: "info.circle.fill"
                )
                DashboardReadinessTile(
                    title: "USB Connection",
                    detail: model.snapshot.deviceCount == 1 && model.snapshot.locationID != nil ? "Stable target" : "Not pinned",
                    isReady: model.snapshot.deviceCount == 1 && model.snapshot.locationID != nil,
                    systemImage: "cable.connector"
                )
                DashboardReadinessTile(
                    title: "Protocol Access",
                    detail: model.snapshot.modeVerified ? "Verified" : "USB evidence only",
                    isReady: model.snapshot.modeVerified,
                    systemImage: "checkmark.shield"
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("dashboardReadinessPanel")
    }

    private func readinessTile(title: String, component: DependencyComponent, icon: String) -> some View {
        let status = model.dependencyDoctorSnapshot.component(component)
        let isReady = status?.health == .ready || status?.health == .notRequired
        let detail: String
        if isReady {
            detail = status?.version.map { "Ready • v\($0)" } ?? "Ready"
        } else if status?.health == .degraded {
            detail = "Degraded"
        } else {
            detail = component == .appleConfigurator ? "Optional / missing" : "Unavailable"
        }
        return DashboardReadinessTile(
            title: title,
            detail: detail,
            isReady: isReady,
            systemImage: icon
        )
    }

    private var connectionEvidenceCard: some View {
        DashboardPanel(
            title: "Connection Evidence",
            systemImage: connectionEvidenceSymbol,
            accent: connectionEvidenceAccent
        ) {
            let facts = details.facts(in: .connection) + details.facts(in: .tooling)
            if facts.isEmpty {
                Label("No current connection evidence.", systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(facts.enumerated()), id: \.element.id) { index, fact in
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            Image(systemName: evidenceSymbol(fact.status))
                                .foregroundStyle(evidenceColor(fact.status))
                                .accessibilityHidden(true)
                            Text(fact.label)
                                .font(.caption)
                            Spacer(minLength: 6)
                            Text(fact.displayValue(revealSensitive: false))
                                .font(.caption.weight(.medium))
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 5)
                        .help("\(fact.source) — \(fact.explanation)")
                        if index < facts.count - 1 { Divider() }
                    }
                }
            }

            Divider()
            Label("Evidence observed \(lastUpdatedClock)", systemImage: "clock")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text("Connection evidence only — not a hardware-health or parts-authenticity test.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityIdentifier("connectionEvidencePanel")
    }

    private var batteryCard: some View {
        DashboardPanel(title: "Battery & Power", systemImage: batterySymbol, accent: .orange) {
            if let percent = details.batteryPercent {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().stroke(Color.orange.opacity(0.18), lineWidth: 6)
                        Circle()
                            .trim(from: 0, to: CGFloat(percent) / 100)
                            .stroke(Color.orange, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                        Text("\(percent)%")
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(width: 54, height: 54)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.isCharging == true ? "Charging" : "Current charge")
                            .font(.callout.weight(.semibold))
                        Text("Device-reported now — not Battery Health")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Battery data is unavailable in this mode or Trust state.", systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Battery Health and cycle count are not inventoried.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("batteryPanel")
    }

    private var storageCard: some View {
        DashboardPanel(title: "Storage", systemImage: "internaldrive", accent: .blue) {
            if let total = details.totalStorageBytes {
                if let available = details.availableStorageBytes {
                    let used = max(0, total - available)
                    ProgressView(value: Double(used), total: Double(total))
                    HStack {
                        Text("Used \(dashboardFormatBytes(used))")
                        Spacer()
                        Text("Free \(dashboardFormatBytes(available))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Text("Total \(dashboardFormatBytes(total))")
                    .font(.callout.weight(.semibold))
            } else {
                Label("Storage is read only from a trusted Normal-iOS session.", systemImage: "minus.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Recovery/DFU values are intentionally not guessed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("storagePanel")
    }

    private var modelName: String {
        if let marketing = details.fact("marketingName")?.value { return marketing }
        switch details.fact("productType")?.value {
        case "iPhone12,8": return "iPhone SE (2nd generation)"
        case let value?: return value
        case nil: return model.snapshot.deviceCount == 0 ? "No iPhone" : "iPhone not identified"
        }
    }

    private var primaryActionSubtitle: String {
        switch model.snapshot.mode {
        case .normal: return "Boot to Recovery (keep data)"
        case .recovery: return "Try Apple Revive first"
        case .restoreOS, .usbUnavailable, .unknown: return "Open the physical guide"
        case .notDetected: return "Look for a connected iPhone"
        case .dfu: return "Use Restore below"
        case .multiple: return "Disconnect extra devices"
        }
    }

    private var dashboardPrimaryTitle: String {
        if model.postResetReviewRequired { return model.primaryActionTitle }
        switch model.snapshot.mode {
        case .normal:
            return model.primaryActionTitle.hasPrefix("Enter Recovery")
                ? "Enter Recovery"
                : model.primaryActionTitle
        case .notDetected: return "Scan for iPhone"
        case .restoreOS, .usbUnavailable, .unknown: return "Recovery Guide"
        case .recovery: return "Recovery Confirmed"
        case .dfu: return "DFU Confirmed"
        case .multiple: return "Extra Devices"
        }
    }

    private var connectionEvidenceAccent: Color {
        if model.snapshot.deviceCount > 1 { return .red }
        if model.snapshot.deviceCount == 0 { return .secondary }
        if model.snapshot.modeVerified { return .green }
        return .orange
    }

    private var connectionEvidenceSymbol: String {
        if model.snapshot.deviceCount > 1 { return "exclamationmark.triangle" }
        if model.snapshot.deviceCount == 0 { return "iphone.slash" }
        return model.snapshot.modeVerified ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var dashboardPrimaryEnabled: Bool {
        if model.postResetReviewRequired { return model.primaryActionEnabled }
        switch model.snapshot.mode {
        case .normal, .notDetected, .restoreOS, .usbUnavailable, .unknown:
            return model.primaryActionEnabled
        case .recovery, .dfu, .multiple:
            return false
        }
    }

    private var heroAccent: Color {
        if model.crashCopyReviewRequired { return .red }
        if model.postResetReviewRequired { return .orange }
        switch model.snapshot.mode {
        case .normal: return model.snapshot.modeVerified ? .green : .orange
        case .recovery: return .blue
        case .dfu: return .purple
        case .restoreOS, .usbUnavailable: return .orange
        case .multiple: return .red
        case .notDetected, .unknown: return .secondary
        }
    }

    private var heroSymbol: String {
        if model.crashCopyReviewRequired { return "exclamationmark.octagon.fill" }
        if model.postResetReviewRequired { return "eye.circle.fill" }
        switch model.snapshot.mode {
        case .normal: return model.snapshot.modeVerified ? "checkmark" : "exclamationmark"
        case .recovery: return "arrow.clockwise"
        case .dfu: return "iphone"
        case .restoreOS, .multiple: return "exclamationmark"
        case .usbUnavailable: return "cable.connector"
        case .notDetected: return "questionmark"
        case .unknown: return "questionmark"
        }
    }

    private var heroBadgeText: String {
        if model.crashCopyReviewRequired { return "Crash-copy review locked" }
        if model.postResetReviewRequired { return "Manual Hello-screen review required" }
        return model.snapshot.deviceCount == 1
            ? "\(model.snapshot.mode.title) • \(model.snapshot.modeVerified ? "protocol verified" : "USB evidence only")"
            : model.snapshot.mode.title
    }

    private var reviewEyebrow: String? {
        if model.crashCopyReviewRequired { return "MANUAL CRASH-COPY REVIEW REQUIRED" }
        if model.postResetReviewRequired { return "MANUAL CONFIRMATION REQUIRED" }
        return nil
    }

    private var connectionLabel: String {
        if model.snapshot.deviceCount == 0 { return "Not connected" }
        if model.snapshot.deviceCount > 1 { return "Multiple devices" }
        return "Connected via USB"
    }

    private var lastUpdatedText: String {
        guard model.snapshot.deviceCount == 1, details.capturedAt.timeIntervalSince1970 > 0 else {
            return "No current observation"
        }
        return "Observed \(lastUpdatedClock)"
    }

    private var lastUpdatedClock: String {
        guard details.capturedAt.timeIntervalSince1970 > 0 else { return "—" }
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: details.capturedAt)
    }

    private var batterySymbol: String {
        if details.isCharging == true { return "battery.100percent.bolt" }
        guard let percent = details.batteryPercent else { return "battery.0percent" }
        if percent >= 75 { return "battery.100percent" }
        if percent >= 40 { return "battery.50percent" }
        return "battery.25percent"
    }

    private var dashboardBackground: some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor),
                Color.blue.opacity(colorScheme == .dark ? 0.025 : 0.018)
            ],
            startPoint: .top,
            endPoint: .bottomTrailing
        )
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

struct DashboardSettingsView: View {
    @ObservedObject var model: RecoveryModel
    let openDashboard: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Settings & Dependency Doctor")
                            .font(.title2.weight(.semibold))
                        Text("Read-only readiness for the built-in mobile-device tools and optional Apple Configurator. Opening this page does not contact the iPhone.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button {
                        openDashboard()
                    } label: {
                        Label("Back to Dashboard", systemImage: "arrow.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settingsBackButton")
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        dependencyComponentsCard
                        capabilityCard
                    }
                    VStack(alignment: .leading, spacing: 16) {
                        dependencyComponentsCard
                        capabilityCard
                    }
                }

                HStack(alignment: .top, spacing: 16) {
                    DashboardPanel(title: "Toolchain policy", systemImage: "shippingbox.and.arrow.backward", accent: .blue) {
                        Label("Built-in helpers are preferred", systemImage: "checkmark.shield.fill")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.green)
                        Text("A complete libimobiledevice suite must resolve from one source. YIOS-KIT never combines a partial built-in suite with Homebrew helpers during one capability.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Apple Configurator is not bundled. It is required only for Apple Revive, Full Restore, and Factory Reset.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    DashboardPanel(title: "Appearance & privacy", systemImage: "hand.raised", accent: .purple) {
                        Text("Use the appearance control in the header to cycle System, Light, and Dark modes for this session.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("ECID, UDID, serial, IMEI, device name, SIM, and network identifiers stay masked until an explicit 60-second reveal. Reports remain redacted by default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settingsWorkspace")
    }

    private var dependencyComponentsCard: some View {
        DashboardPanel(title: "Components", systemImage: "wrench.and.screwdriver") {
            VStack(spacing: 0) {
                ForEach(Array(model.dependencyDoctorSnapshot.components.enumerated()), id: \.element.component) { index, status in
                    dependencyComponentRow(status)
                    if index < model.dependencyDoctorSnapshot.components.count - 1 { Divider() }
                }
            }
            Text("Checked \(model.dependencyDoctorSnapshot.capturedAt.formatted(date: .abbreviated, time: .standard))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("settingsDependencyPanel")
    }

    private var capabilityCard: some View {
        DashboardPanel(title: "Capabilities", systemImage: "list.bullet.clipboard") {
            VStack(spacing: 0) {
                ForEach(Array(model.dependencyDoctorSnapshot.capabilities.enumerated()), id: \.element.capability) { index, resolution in
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        Image(systemName: resolution.isAvailable ? "checkmark.circle.fill" : "minus.circle.fill")
                            .foregroundStyle(resolution.isAvailable ? Color.green : Color.orange)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(capabilityTitle(resolution.capability))
                                .font(.callout.weight(.medium))
                            if !resolution.unavailableTools.isEmpty {
                                Text("Missing: \(resolution.unavailableTools.map(\.executableName).joined(separator: ", "))")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 8)
                        Text(resolution.isAvailable ? "Ready" : "Unavailable")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(resolution.isAvailable ? Color.green : Color.orange)
                    }
                    .padding(.vertical, 8)
                    .accessibilityElement(children: .combine)
                    if index < model.dependencyDoctorSnapshot.capabilities.count - 1 { Divider() }
                }
            }
        }
        .frame(minWidth: 360, maxWidth: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("settingsCapabilitiesPanel")
    }

    private func dependencyComponentRow(_ status: DependencyComponentStatus) -> some View {
        let isReady = status.health == .ready || status.health == .notRequired
        let color: Color = isReady ? .green : (status.health == .degraded ? .orange : .red)
        let summary = [status.sourceSummary, status.version.map { "v\($0)" }]
            .compactMap { $0 }
            .joined(separator: " • ")
        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: isReady ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(color)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(status.component.title)
                    .font(.callout.weight(.medium))
                Text(status.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(summary)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func capabilityTitle(_ capability: ToolCapability) -> String {
        switch capability {
        case .normalIdentity: return "Normal-iOS identity"
        case .pairingValidation: return "Pairing & Trust validation"
        case .recoveryModeVerification: return "Recovery / DFU verification"
        case .normalToRecovery: return "Enter Recovery"
        case .normalPowerControl: return "Restart / Shut Down"
        case .crashReportCopy: return "Crash-report copy"
        case .appleReviveRestore: return "Apple Revive / Restore"
        case .factoryReset: return "Factory Reset"
        }
    }
}

private struct DashboardPanel<Content: View>: View {
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
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .foregroundStyle(accent ?? Color.primary)
            content
        }
        .padding(15)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke((accent ?? Color(nsColor: .separatorColor)).opacity(accent == nil ? 0.42 : 0.26), lineWidth: 1)
        )
    }
}

private struct DashboardActionTile: View {
    @Environment(\.isEnabled) private var isEnabled

    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: 23, weight: .medium))
                    .foregroundStyle(isEnabled ? accent : Color.secondary)
                    .frame(height: 25)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                HStack {
                    Spacer()
                    Image(systemName: "arrow.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isEnabled ? accent : Color.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 126, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill((isEnabled ? accent : Color.secondary).opacity(0.045))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke((isEnabled ? accent : Color.secondary).opacity(0.24), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DashboardReadinessTile: View {
    let title: String
    let detail: String
    let isReady: Bool
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: isReady ? systemImage : "exclamationmark.circle")
                .foregroundStyle(isReady ? Color.green : Color.orange)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption.weight(.medium))
                    .lineLimit(2)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(isReady ? Color.green : Color.orange)
                    .lineLimit(2)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, minHeight: 66, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.42), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

private func evidenceColor(_ status: DeviceFactStatus) -> Color {
    switch status {
    case .verified, .ready: return .green
    case .reported: return .blue
    case .warning: return .orange
    case .unavailable: return .secondary
    }
}

private func evidenceSymbol(_ status: DeviceFactStatus) -> String {
    switch status {
    case .verified: return "checkmark.seal.fill"
    case .ready: return "checkmark.circle.fill"
    case .reported: return "info.circle.fill"
    case .warning: return "exclamationmark.triangle.fill"
    case .unavailable: return "minus.circle.fill"
    }
}

private func dashboardFormatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.isAdaptive = true
    return formatter.string(fromByteCount: bytes)
}
