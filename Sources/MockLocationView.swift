import SwiftUI

struct MockLocationView: View {
    @ObservedObject var model: RecoveryModel
    @ObservedObject var controller: MockLocationController

    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var inputError: String?
    @State private var persistentModeEnabled = false
    @State private var showsReadinessDetails = false

    private struct Preset: Identifiable {
        let id: String
        let title: String
        let latitude: String
        let longitude: String
    }

    private let presets = [
        Preset(id: "yangon", title: "Yangon", latitude: "16.8409", longitude: "96.1735"),
        Preset(id: "bangkok", title: "Bangkok", latitude: "13.7563", longitude: "100.5018"),
        Preset(id: "singapore", title: "Singapore", latitude: "1.3521", longitude: "103.8198"),
        Preset(id: "tokyo", title: "Tokyo", latitude: "35.6762", longitude: "139.6503")
    ]

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    YIOSPageHeader(
                        title: "Mock Location",
                        subtitle: "Set a test coordinate on your iPhone and return to real location when finished."
                    )
                    statusHero

                    if geometry.size.width >= 940 {
                        HStack(alignment: .top, spacing: 20) {
                            VStack(alignment: .leading, spacing: 20) {
                                coordinatePanel
                                safetyPanel
                            }
                            .frame(minWidth: 400, maxWidth: .infinity, alignment: .topLeading)

                            VStack(alignment: .leading, spacing: 20) {
                                readinessPanel
                                targetPanel
                            }
                            .frame(width: 310, alignment: .topLeading)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 20) {
                            readinessPanel
                            coordinatePanel
                            targetPanel
                            safetyPanel
                        }
                    }
                }
                .frame(maxWidth: 1_260, alignment: .topLeading)
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollIndicators(.hidden)
        }
        .background(YIOSWorkspaceBackdrop(accent: statusColor))
        .accessibilityIdentifier("mockLocationWorkspace")
        .onAppear {
            if controller.isAssumedPersistent { persistentModeEnabled = true }
            controller.refreshLocalState()
            if controller.shouldOfferDeveloperModeOptionRequest { showsReadinessDetails = true }
        }
        .onChange(of: model.snapshot) { _ in controller.refreshLocalState() }
        .onChange(of: controller.isAssumedPersistent) { isPersistent in
            persistentModeEnabled = isPersistent
        }
        .onChange(of: controller.shouldOfferDeveloperModeOptionRequest) { shouldOffer in
            if shouldOffer { showsReadinessDetails = true }
        }
    }

    private var statusHero: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: statusSymbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(statusColor)
                    .frame(width: 42, height: 42)
                    .background(RoundedRectangle(cornerRadius: 12).fill(statusColor.opacity(0.08)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                Text(controller.statusText)
                    .font(.headline)
                Text(controller.detailText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if controller.isBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Keep the iPhone connected and unlocked.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let error = inputError ?? controller.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("Connected: \(controller.connectedTargetToken ?? "No target")")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                if let recorded = controller.recordedTargetToken,
                   recorded != controller.connectedTargetToken {
                    Text("Saved: \(recorded)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Text(statusBadge)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(statusColor.opacity(0.10)))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .yiosCardSurface(elevated: false)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mockLocationStatusPanel")
    }

    private var coordinatePanel: some View {
        MockLocationPanel(
            title: "Choose a test location",
            systemImage: "mappin.and.ellipse",
            accent: .blue
        ) {
            VStack(alignment: .leading, spacing: 18) {
                Text("Enter latitude and longitude, or choose a city preset. Coordinates are sent to the iPhone and are not saved in the local safety record.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        coordinateField(
                            title: "Latitude (-90…90)",
                            text: $latitudeText,
                            identifier: "mockLocationLatitudeField"
                        )
                        coordinateField(
                            title: "Longitude (-180…180)",
                            text: $longitudeText,
                            identifier: "mockLocationLongitudeField"
                        )
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        coordinateField(
                            title: "Latitude (-90…90)",
                            text: $latitudeText,
                            identifier: "mockLocationLatitudeField"
                        )
                        coordinateField(
                            title: "Longitude (-180…180)",
                            text: $longitudeText,
                            identifier: "mockLocationLongitudeField"
                        )
                    }
                }

                Toggle(isOn: $persistentModeEnabled) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Persistent until Clear/Reboot (Experimental)")
                            .font(.callout.weight(.semibold))
                        Text("The test location may stay active after USB is disconnected. Check the result on your iPhone; persistence is experimental and cannot be verified automatically. Reconnect this iPhone to return to real location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
                .disabled(controller.isBusy || controller.isAssumedActive || controller.reviewRequired)
                .accessibilityIdentifier("mockLocationPersistentModeToggle")

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) {
                    Menu("Presets") {
                        ForEach(presets) { preset in
                            Button(preset.title) { apply(preset) }
                        }
                    }
                    .accessibilityIdentifier("mockLocationPresetMenu")
                    Spacer(minLength: 0)
                    Button(setButtonTitle) { prepareSetConfirmation() }
                        .buttonStyle(YIOSActionButtonStyle())
                        .disabled(!controller.canSetLocation)
                        .accessibilityIdentifier("mockLocationSetButton")
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Menu("Presets") {
                            ForEach(presets) { preset in
                                Button(preset.title) { apply(preset) }
                            }
                        }
                        .accessibilityIdentifier("mockLocationPresetMenu")
                        Button(setButtonTitle) { prepareSetConfirmation() }
                            .buttonStyle(YIOSActionButtonStyle())
                            .disabled(!controller.canSetLocation)
                            .accessibilityIdentifier("mockLocationSetButton")
                    }
                }
                .controlSize(.large)

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Return to Real Location")
                            .font(.callout.weight(.semibold))
                        Text(clearGuidance)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Return to Real Location") { controller.returnToRealLocation() }
                        .disabled(!controller.canReturnToRealLocation)
                        .accessibilityIdentifier("mockLocationClearButton")
                }

                if controller.shouldOfferForgetUnavailableRecord {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Original iPhone unavailable?")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.red)
                        Text("The connected iPhone has a different stable identity. You may explicitly delete only YIOS-KIT's local safety record. This sends no device command and cannot restore or verify the unavailable iPhone's real location.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Forget Unavailable iPhone Record") {
                            model.forgetUnavailableMockLocationRecord()
                        }
                        .buttonStyle(YIOSActionButtonStyle(tint: .red))
                        .disabled(!controller.canForgetUnavailableRecord)
                        .accessibilityIdentifier("mockLocationForgetUnavailableRecordButton")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
                    .accessibilityIdentifier("mockLocationForgetUnavailableRecordPanel")
                }
            }
        }
        .accessibilityIdentifier("mockLocationCoordinatePanel")
    }

    private func coordinateField(
        title: String,
        text: Binding<String>,
        identifier: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            TextField("0.0", text: text)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))
                .accessibilityIdentifier(identifier)
                .onChange(of: text.wrappedValue) { _ in inputError = nil }
        }
        .frame(minWidth: 200, maxWidth: .infinity, alignment: .leading)
    }

    private var targetPanel: some View {
        MockLocationPanel(title: "Exact target", systemImage: "scope", accent: targetPanelAccent) {
            VStack(spacing: 0) {
                MockLocationFactRow(label: "Mode", value: model.snapshot.mode.title)
                Divider()
                MockLocationFactRow(label: "Product", value: model.snapshot.productType ?? "Unavailable")
                Divider()
                MockLocationFactRow(label: "iOS", value: versionSummary)
                Divider()
                MockLocationFactRow(label: "Connected token", value: controller.connectedTargetToken ?? "Unavailable", monospaced: true)
                if let recorded = controller.recordedTargetToken {
                    Divider()
                    MockLocationFactRow(label: "Recorded target", value: recorded, monospaced: true)
                }
                Divider()
                MockLocationFactRow(
                    label: "Safety-record match",
                    value: identityMatchText
                )
            }
        }
        .accessibilityIdentifier("mockLocationTargetPanel")
    }

    private var readinessPanel: some View {
        MockLocationPanel(title: "Before you start", systemImage: "checkmark.shield", accent: readinessColor) {
            Text(developerChecksReady
                 ? "The developer connection is ready. Enter your coordinate to continue."
                 : "Connect and unlock your iPhone, accept Trust, then check the developer connection.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Check Readiness") { controller.checkReadiness() }
                .buttonStyle(YIOSActionButtonStyle())
                .controlSize(.large)
                .disabled(!controller.canCheckReadiness)
                .accessibilityIdentifier("mockLocationCheckReadinessButton")

            DisclosureGroup("Connection checks", isExpanded: $showsReadinessDetails) {
                VStack(spacing: 0) {
                readinessRow(
                    title: "Exact Normal-iOS SE2",
                    detail: identityMatchText,
                    state: identityRowState
                )
                Divider()
                readinessRow(
                    title: "Pairing & Trust",
                    detail: developerChecksReady ? "Verified by probe" : readinessDetail(for: .pairingRequired),
                    state: developerChecksReady ? .ready : readinessState(for: .pairingRequired)
                )
                Divider()
                readinessRow(
                    title: "Developer Mode / DDI",
                    detail: developerChecksReady ? "Developer service opened" : developerSetupDetail,
                    state: developerChecksReady ? .ready : developerSetupState
                )

                if controller.shouldOfferDeveloperModeOptionRequest {
                    Divider()
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Developer Mode option missing from Settings?")
                            .font(.caption.weight(.semibold))
                        Text("Send one exact-target, non-reboot request. This only makes the Settings option expected; it does not enable Developer Mode or restart the iPhone.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Request Developer Mode Settings Option") {
                            controller.requestDeveloperModeOption()
                        }
                        .disabled(!controller.canRequestDeveloperModeOption)
                        .accessibilityIdentifier("mockLocationShowDeveloperModeButton")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
                }
                Divider()
                readinessRow(
                    title: "iOS 17+ USB tunnel",
                    detail: developerChecksReady ? "Probe succeeded" : readinessDetail(for: .tunnelUnavailable),
                    state: developerChecksReady ? .ready : readinessState(for: .tunnelUnavailable)
                )

                if case .ready(_, let checkedAt, let backendVersion) = controller.readiness {
                    Divider()
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Checked \(checkedAt.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let backendVersion {
                            Text(backendVersion)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 9)
                }

                }
                .padding(.top, 8)
            }
            .font(.callout)
        }
        .accessibilityIdentifier("mockLocationReadinessPanel")
    }

    private var safetyPanel: some View {
        MockLocationPanel(title: "Using test locations", systemImage: "info.circle", accent: .blue) {
            Text("A simulated location can affect Maps, navigation, location sharing and other apps. Use Return to Real Location when you finish.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            DisclosureGroup("How sessions and safety records work") {
                VStack(alignment: .leading, spacing: 10) {
                safetyLine("The Set action is always pinned to one verified UDID/product and is rechecked immediately before launch.")
                safetyLine("Simulation is reported as assumed active because the developer service has no getter.")
                safetyLine("Experimental persistence is recorded only after Set returns and the backend exits cleanly without sending Clear; it is never described as verified or permanent.")
                safetyLine("Recovery, Restore, Factory Reset, power controls, and other device mutations must remain blocked while simulation is active or uncertain.")
                safetyLine("The journal stores only a one-way target fingerprint and state timestamps—never coordinates or raw device identifiers.")
                }
                .padding(.top, 12)
            }
            .font(.callout)
        }
        .accessibilityIdentifier("mockLocationSafetyPanel")
    }

    private func safetyLine(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "circle.fill")
                .font(.system(size: 4))
                .foregroundStyle(.secondary)
                .padding(.top, 5)
                .accessibilityHidden(true)
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func prepareSetConfirmation() {
        do {
            let coordinate = try MockLocationCoordinate.parse(
                latitude: latitudeText,
                longitude: longitudeText
            )
            inputError = nil
            controller.setLocation(
                coordinate,
                mode: persistentModeEnabled
                    ? .persistentUntilClearOrReboot
                    : .liveSession
            )
        } catch {
            inputError = (error as? LocalizedError)?.errorDescription ?? "The coordinate is invalid."
        }
    }

    private func apply(_ preset: Preset) {
        latitudeText = preset.latitude
        longitudeText = preset.longitude
        inputError = nil
    }

    private var targetReady: Bool {
        (try? MockLocationExactTarget(snapshot: model.snapshot)) != nil
    }

    private var identityMatchText: String {
        switch controller.safetyRecordMatch {
        case .none:
            return targetReady ? "ECID + UDID + USB captured" : "Scan required"
        case .connectedUnavailable:
            return "Saved record present; connected target unavailable"
        case .exactConnection:
            return "Matches saved iPhone and USB connection"
        case .sameStableIPhoneNewConnection:
            return "Same saved iPhone; USB connection changed"
        case .differentStableIPhone:
            return "Different from saved iPhone — locked"
        }
    }

    private var identityRowState: RowState {
        switch controller.safetyRecordMatch {
        case .none:
            return targetReady ? .ready : .warning
        case .exactConnection, .sameStableIPhoneNewConnection:
            return .ready
        case .connectedUnavailable, .differentStableIPhone:
            return .warning
        }
    }

    private var targetPanelAccent: Color {
        identityRowState == .ready ? .green : .orange
    }

    private var versionSummary: String {
        switch (model.snapshot.productVersion, model.snapshot.buildVersion) {
        case let (version?, build?): return "\(version) (\(build))"
        case let (version?, nil): return version
        default: return "Unavailable"
        }
    }

    private var developerChecksReady: Bool {
        if case .ready = controller.readiness { return true }
        return false
    }

    private var setButtonTitle: String {
        persistentModeEnabled
            ? "Set Persistent Location (Experimental)"
            : "Start Mock Location"
    }

    private var clearGuidance: String {
        if persistentModeEnabled || controller.isAssumedPersistent {
            return "Persistent mode may outlive a cable disconnect. Reconnect the same iPhone and use this button to restore real location; app quit remains blocked until that reset is recorded."
        }
        return "Use this before disconnecting or quitting while the live simulation session may be active."
    }

    private enum RowState { case ready, warning, waiting }

    private func readinessRow(
        title: String,
        detail: String,
        state: RowState
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: rowSymbol(state))
                .foregroundStyle(rowColor(state))
                .frame(width: 17)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.callout.weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(state == .warning ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private func readinessState(for issue: MockLocationReadinessIssue) -> RowState {
        if case .failed(let observed) = controller.readiness, observed == issue { return .warning }
        if case .blocked(let observed, _) = controller.readiness, observed == issue { return .warning }
        return .waiting
    }

    private func readinessDetail(for issue: MockLocationReadinessIssue) -> String {
        let state = readinessState(for: issue)
        return state == .warning ? issue.userDescription : "Not checked"
    }

    private var developerSetupState: RowState {
        for issue in [MockLocationReadinessIssue.developerModeRequired, .developerDiskImageRequired, .developerServiceUnavailable] {
            if readinessState(for: issue) == .warning { return .warning }
        }
        return .waiting
    }

    private var developerSetupDetail: String {
        for issue in [MockLocationReadinessIssue.developerModeRequired, .developerDiskImageRequired, .developerServiceUnavailable] {
            if readinessState(for: issue) == .warning { return issue.userDescription }
        }
        return "Not checked"
    }

    private func rowSymbol(_ state: RowState) -> String {
        switch state {
        case .ready: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .waiting: return "circle.dotted"
        }
    }

    private func rowColor(_ state: RowState) -> Color {
        switch state {
        case .ready: return .green
        case .warning: return .orange
        case .waiting: return .secondary
        }
    }

    private var statusColor: Color {
        if controller.reviewRequired { return .red }
        if controller.isAssumedActive { return .purple }
        if controller.isBusy { return .blue }
        if case .resetRequestSent = controller.simulationKnowledge { return .blue }
        if case .ready = controller.readiness { return .green }
        if case .failed = controller.readiness { return .orange }
        return .secondary
    }

    private var statusSymbol: String {
        if controller.reviewRequired { return "exclamationmark.octagon.fill" }
        if controller.isAssumedActive { return "location.fill" }
        if controller.isBusy { return "arrow.triangle.2.circlepath" }
        if case .resetRequestSent = controller.simulationKnowledge { return "location.slash" }
        if case .ready = controller.readiness { return "checkmark.circle.fill" }
        return "location.circle"
    }

    private var statusBadge: String {
        if controller.reviewRequired { return "REVIEW REQUIRED" }
        if controller.isAssumedPersistent { return "PERSISTENCE ASSUMED" }
        if controller.isAssumedActive { return "ASSUMED ACTIVE" }
        if controller.isBusy { return "WORKING" }
        if case .resetRequestSent = controller.simulationKnowledge { return "RESET SENT" }
        if case .ready = controller.readiness { return "READY" }
        return "READ ONLY"
    }

    private var readinessColor: Color {
        if developerChecksReady { return .green }
        if case .failed = controller.readiness { return .orange }
        return .blue
    }
}

private struct MockLocationPanel<Content: View>: View {
    let title: String
    let systemImage: String
    let accent: Color
    let content: Content

    init(
        title: String,
        systemImage: String,
        accent: Color,
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

private struct MockLocationFactRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(monospaced ? .system(.callout, design: .monospaced) : .callout)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
