import AppKit
import Combine
import Darwin
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: RecoveryModel?
    private var lockFD: Int32 = -1
    private var windowClosingEnabled = true

    func applicationDidFinishLaunching(_ notification: Notification) {
        let path = "/private/tmp/local.minthanhtut.SE2RecoveryAssistant.lock"
        lockFD = Darwin.open(path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard lockFD >= 0, Darwin.lockf(lockFD, F_TLOCK, 0) == 0 else {
            if lockFD >= 0 { Darwin.close(lockFD) }
            lockFD = -1
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "YIOS-KIT is already open"
            alert.informativeText = "Use the existing window. Only one recovery controller may run at a time."
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func setWindowClosingEnabled(_ enabled: Bool) {
        windowClosingEnabled = enabled
        configureMainWindow()
    }

    func applicationDidUpdate(_ notification: Notification) {
        configureMainWindow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag, let window = sender.windows.first(where: { $0.title == "YIOS-KIT" }) {
            window.makeKeyAndOrderFront(nil)
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model?.operationRunning == true ||
                model?.isMonitoring == true ||
                model?.destructiveWorkflowActive == true ||
                model?.postResetReviewRequired == true ||
                model?.crashCopyReviewRequired == true ||
                model?.companionController.isBusy == true ||
                model?.mockLocationController.blocksDeviceMutation == true else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        let locationSafetyRecordOnly = model?.mockLocationController.blocksDeviceMutation == true &&
            model?.operationRunning != true &&
            model?.isMonitoring != true &&
            model?.destructiveWorkflowActive != true &&
            model?.postResetReviewRequired != true &&
            model?.crashCopyReviewRequired != true &&
            model?.companionController.isBusy != true
        let unavailableRecordedIPhone = locationSafetyRecordOnly &&
            model?.mockLocationController.shouldOfferForgetUnavailableRecord == true
        let persistentLocationOnly = model?.mockLocationController.isAssumedPersistent == true &&
            locationSafetyRecordOnly
        if model?.companionController.isBusy == true {
            alert.messageText = "Companion installation is in progress"
            alert.informativeText = "Keep YIOS-KIT open and the iPhone connected until installation and verification finish."
        } else if unavailableRecordedIPhone {
            alert.messageText = "Mock Location safety record still locks this Mac"
            alert.informativeText = "The saved record belongs to a different iPhone. If the recorded iPhone is permanently unavailable, open Mock Location and choose Forget Unavailable iPhone Record. That explicit action deletes only YIOS-KIT's local record and unlocks this Mac; it sends no command and cannot reset or verify the recorded iPhone's location."
        } else if persistentLocationOnly {
            alert.messageText = "iPhone operation is still active"
            alert.informativeText = "Experimental persistent location is assumed active. Cable disconnect is allowed for this mode, but quit and window close remain blocked so the durable reset obligation cannot be hidden. Reconnect the same stable iPhone and choose Return to Real Location; rebooting is expected to restore phone-side GPS but does not clear the app safety record."
        } else {
            alert.messageText = "iPhone operation is still active"
            alert.informativeText = "Do not quit, close the window, disconnect the cable, or let the Mac sleep while USB monitoring, target verification, Factory Reset, Apple recovery, live-session Mock Location, post-reset Hello-screen review, or crash-copy manual review is active. Return to Real Location before quitting when simulation may be active."
        }
        alert.addButton(withTitle: "Keep Running")
        alert.runModal()
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if lockFD >= 0 {
            _ = Darwin.lockf(lockFD, F_ULOCK, 0)
            Darwin.close(lockFD)
            lockFD = -1
        }
    }

    private func configureMainWindow() {
        for window in NSApplication.shared.windows where window.title == "YIOS-KIT" {
            window.isReleasedWhenClosed = false
            window.standardWindowButton(.closeButton)?.isEnabled = windowClosingEnabled
        }
    }
}

@main
struct SE2RecoveryAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = RecoveryModel()

    var body: some Scene {
        Window("YIOS-KIT", id: "main") {
            ContentView(model: model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
                .onReceive(
                    model.$operationRunning.combineLatest(
                        model.$isMonitoring,
                        model.$destructiveWorkflowActive,
                        model.$postResetReviewRequired
                    ).combineLatest(model.$crashCopyReviewRequired)
                        .combineLatest(model.mockLocationController.$blocksDeviceMutation)
                ) { state in
                    let existing = state.0
                    let active = existing.0
                    appDelegate.setWindowClosingEnabled(!(
                        active.0 || active.1 || active.2 || active.3 || existing.1 || state.1 || model.companionController.isBusy
                    ))
                }
                .onReceive(model.companionController.$isBusy) { installing in
                    appDelegate.setWindowClosingEnabled(!(
                        installing || model.operationRunning || model.isMonitoring ||
                        model.destructiveWorkflowActive || model.postResetReviewRequired ||
                        model.crashCopyReviewRequired || model.mockLocationController.blocksDeviceMutation
                    ))
                }
        }
        .defaultSize(width: 1420, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
