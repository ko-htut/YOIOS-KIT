import AppKit
import Combine
import SwiftUI

struct DashboardOverviewView: View {
    @ObservedObject var model: RecoveryModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealsSensitiveValues = false
    @State private var revealGeneration = UUID()

    let openMoreTools: () -> Void

    init(model: RecoveryModel, openMoreTools: @escaping () -> Void = {}) {
        self.model = model
        self.openMoreTools = openMoreTools
    }

    private var details: DeviceCenterSnapshot { model.displayedDeviceCenterSnapshot }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    YIOSPageHeader(
                        title: "Dashboard",
                        subtitle: "Your connected iPhone, current status, and available actions."
                    )
                    Group {
                        if geometry.size.width >= 1_020 {
                            wideDashboard
                        } else {
                            compactDashboard
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(24)
            }
            .scrollIndicators(.hidden)
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
        VStack(alignment: .leading, spacing: 20) {
            statusHero
            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 20) {
                    deviceSummaryCard
                    quickActionsSection
                }
                .frame(minWidth: 590, maxWidth: .infinity, alignment: .topLeading)

                VStack(alignment: .leading, spacing: 20) {
                    connectionEvidenceCard
                    batteryCard
                    storageCard
                }
                .frame(width: 286)
            }
            systemReadinessSection
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var compactDashboard: some View {
        VStack(alignment: .leading, spacing: 20) {
            statusHero
            deviceSummaryCard
            quickActionsSection
            systemReadinessSection
            connectionEvidenceCard
            HStack(alignment: .top, spacing: 20) {
                batteryCard
                storageCard
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(heroAccent.opacity(colorScheme == .dark ? 0.16 : 0.09))
                    Image(systemName: heroSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(heroAccent)
                }
                .frame(width: 48, height: 48)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 7) {
                    if reviewEyebrow != nil {
                        Text(reviewEyebrow ?? "")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(heroAccent)
                    }

                    Text(model.statusText)
                        .font(.system(size: 17, weight: .semibold))
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

                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 20) {
                    heroObservation
                    Spacer(minLength: 12)
                    heroPrimaryAction
                }
                VStack(alignment: .leading, spacing: 14) {
                    heroObservation
                    heroPrimaryAction
                }
            }
        }
        .padding(20)
        .yiosCardSurface(cornerRadius: 14, elevated: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceCenterDetailStatus")
    }

    private var heroObservation: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                Circle().fill(heroAccent).frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(heroBadgeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Text(lastUpdatedText)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var heroPrimaryAction: some View {
        Button(dashboardPrimaryTitle) { model.performPrimaryAction() }
            .buttonStyle(YIOSActionButtonStyle())
            .disabled(!dashboardPrimaryEnabled)
            .accessibilityIdentifier("primaryActionButton")
    }

    private var deviceSummaryCard: some View {
        DashboardPanel(title: "Device Summary", systemImage: "iphone.gen2") {
            compactDeviceHero
            Divider()
            if model.snapshot.deviceCount == 0 {
                Text("Connect an iPhone with a data-capable USB cable, then choose Scan. Device details will appear here after detection.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 4)
            } else {
                summaryFactsGrid
            }
            Divider()
            deviceUtilityToolbar
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("deviceSummaryPanel")
    }

    private var compactDeviceHero: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(Color.blue.opacity(0.08))
                Image(systemName: model.snapshot.deviceCount == 0 ? "iphone.slash" : "iphone")
                    .font(.system(size: 25, weight: .regular))
                    .foregroundStyle(.blue)
            }
            .frame(width: 50, height: 58)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(modelName)
                    .font(.system(size: 16, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Label(connectionLabel, systemImage: model.snapshot.deviceCount == 1 ? "cable.connector" : "iphone.slash")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("deviceHeroPanel")
    }

    private var summaryFactsGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 170), spacing: 18)],
            alignment: .leading,
            spacing: 14
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
        return VStack(alignment: .leading, spacing: 5) {
            Label(fact?.label ?? fallbackLabel, systemImage: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(fact?.displayValue(revealSensitive: revealsSensitiveValues) ?? "—")
                .font(.system(size: 13, weight: .medium, design: (fact?.sensitivity ?? DeviceFactSensitivity.none) == DeviceFactSensitivity.none ? .default : .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .topLeading)
        .help(fact.map { "\($0.status.title) • \($0.source) — \($0.explanation)" } ?? "Unavailable in this mode or Trust state")
        .accessibilityElement(children: .combine)
    }

    private var deviceUtilityToolbar: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 130), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            utilityButtons
        }
        .controlSize(.regular)
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
            .help("Verified supported iPhone in Normal iOS only; the exact model and target are checked again")
            .accessibilityIdentifier("restartIPhoneButton")

        Button("Shut Down…") { model.shutDownIPhone() }
            .tint(.red)
            .disabled(!model.canUseNormalDeviceUtilities)
            .help("Powers off the exact verified supported iPhone after confirmation")
            .accessibilityIdentifier("shutDownIPhoneButton")

    }

    private var quickActionsSection: some View {
        DashboardPanel(title: "Quick Actions", systemImage: "bolt") {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                spacing: 10
            ) {
                DashboardActionTile(
                    title: "Try Revive",
                    subtitle: "Preserve data when possible",
                    systemImage: "waveform.path.ecg",
                    accent: .blue,
                    action: model.performPrimaryAction
                )
                .disabled(!model.canRevive)
                .accessibilityIdentifier("reviveButton")

                DashboardActionTile(
                    title: "More Tools",
                    subtitle: "Reports, backup & timeline",
                    systemImage: "square.grid.2x2",
                    accent: .blue,
                    action: openMoreTools
                )
                .accessibilityIdentifier("moreToolsButton")
            }

            Divider()

            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Erase actions")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("Confirmation required")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
                DashboardActionTile(
                    title: "Factory Reset",
                    subtitle: "Erase content & settings",
                    systemImage: "trash",
                    accent: .red,
                    compact: true,
                    action: model.startFactoryReset
                )
                .disabled(!model.canFactoryReset)
                .accessibilityIdentifier("factoryResetButton")

                DashboardActionTile(
                    title: model.isGenericDFURestoreTarget ? "DFU Factory Restore" : "Erase & Restore",
                    subtitle: model.isGenericDFURestoreTarget ? "Erase & reinstall signed iOS" : "Reinstall signed iOS",
                    systemImage: "iphone.and.arrow.forward",
                    accent: .red,
                    compact: true,
                    action: model.startRestore
                )
                .disabled(!model.canRestore)
                .accessibilityIdentifier("restoreButton")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("quickActionsPanel")
    }

    private var systemReadinessSection: some View {
        DashboardPanel(title: "System Readiness", systemImage: "checkmark.shield") {
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 165), spacing: 12)],
                spacing: 12
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
                                .font(.system(size: 12))
                            Spacer(minLength: 6)
                            Text(fact.displayValue(revealSensitive: false))
                                .font(.system(size: 12, weight: .medium))
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        .padding(.vertical, 7)
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
        guard let value = details.fact("productType")?.value else {
            return model.snapshot.deviceCount == 0 ? "No iPhone" : "iPhone not identified"
        }
        return SupportedDeviceCatalog.marketingName(for: value) ?? value
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
        return Self.observedTimeFormatter.string(from: details.capturedAt)
    }

    private var batterySymbol: String {
        if details.isCharging == true { return "battery.100.bolt" }
        guard let percent = details.batteryPercent else { return "battery.0" }
        if percent >= 75 { return "battery.100" }
        if percent >= 40 { return "battery.50" }
        return "battery.25"
    }

    private var dashboardBackground: some View {
        YIOSWorkspaceBackdrop(accent: heroAccent)
    }

    private static let observedTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

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
    @AppStorage("yoiosAppearance") private var appearancePreference = "system"
    let openDashboard: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(alignment: .top, spacing: 16) {
                    YIOSPageHeader(
                        title: "Settings",
                        subtitle: "Appearance, privacy, and the tools available on this Mac."
                    )
                    Spacer(minLength: 12)
                    Button {
                        openDashboard()
                    } label: {
                        Label("Dashboard", systemImage: "arrow.left")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("settingsBackButton")
                }

                DashboardPanel(title: "Appearance & privacy", systemImage: "slider.horizontal.3") {
                    HStack(alignment: .top, spacing: 24) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Appearance")
                                .font(.callout.weight(.medium))
                            Text("Choose how YIOS-KIT looks on this Mac.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 20)
                        Picker("Appearance", selection: $appearancePreference) {
                            Text("System").tag("system")
                            Text("Light").tag("light")
                            Text("Dark").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .frame(width: 240)
                        .accessibilityIdentifier("settingsAppearancePicker")
                    }
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "hand.raised")
                            .foregroundStyle(.blue)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Device identifiers stay private")
                                .font(.callout.weight(.medium))
                            Text("ECID, UDID, serial, IMEI, and network identifiers stay masked until a 60-second reveal. Reports are redacted by default.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(minimum: 300), spacing: 20, alignment: .top), count: 2),
                    alignment: .leading,
                    spacing: 20
                ) {
                    dependencyComponentsCard
                    capabilityCard
                }

                DashboardPanel(title: "About the built-in tools", systemImage: "shippingbox") {
                    Label("Built-in helpers are preferred", systemImage: "checkmark.shield.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                    Text("YIOS-KIT includes the mobile-device helpers it needs for inspection and Recovery. Each capability uses a complete, verified set of tools.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Apple Configurator is not bundled. It is required only for Apple Revive, Full Restore, and Factory Reset.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(24)
        }
        .scrollIndicators(.hidden)
        .background(YIOSWorkspaceBackdrop(accent: .blue))
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        .frame(maxWidth: .infinity, alignment: .topLeading)
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
        VStack(alignment: .leading, spacing: 16) {
            YIOSPanelHeader(title, systemImage: systemImage, accent: accent)
            content
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .yiosCardSurface(accent: accent, cornerRadius: 13)
    }
}

private struct DashboardActionTile: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    let title: String
    let subtitle: String
    let systemImage: String
    let accent: Color
    var compact = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: systemImage)
                    .font(.system(size: compact ? 15 : 17, weight: .medium))
                    .foregroundStyle(isEnabled ? accent : Color.secondary)
                    .frame(width: 22, height: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(isEnabled ? Color.primary : Color.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 4)
                    .accessibilityHidden(true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: compact ? 64 : 82, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.primary.opacity(isHovered && isEnabled ? 0.055 : 0.025))
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(YIOSPressButtonStyle())
        .onHover { hovering in
            withAnimation(YIOSMotion.quick(reduceMotion: reduceMotion)) {
                isHovered = hovering
            }
        }
    }
}

private struct DashboardReadinessTile: View {
    let title: String
    let detail: String
    let isReady: Bool
    let systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill((isReady ? Color.green : Color.orange).opacity(0.10))
                Image(systemName: isReady ? systemImage : "exclamationmark.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isReady ? Color.green : Color.orange)
            }
                .frame(width: 25, height: 25)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(2)
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(isReady ? Color.green : Color.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .topLeading)
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
    dashboardByteFormatter.string(fromByteCount: bytes)
}

private let dashboardByteFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .decimal
    formatter.allowedUnits = [.useGB, .useMB]
    formatter.isAdaptive = true
    return formatter
}()
