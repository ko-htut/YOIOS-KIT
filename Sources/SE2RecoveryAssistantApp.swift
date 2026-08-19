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
                model?.crashCopyReviewRequired == true else {
            return .terminateNow
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "iPhone operation is still active"
        alert.informativeText = "Do not quit, close the window, disconnect the cable, or let the Mac sleep while USB monitoring, target verification, Factory Reset, Apple recovery, post-reset Hello-screen review, or crash-copy manual review is active."
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
                ) { state in
                    let active = state.0
                    appDelegate.setWindowClosingEnabled(!(active.0 || active.1 || active.2 || active.3 || state.1))
                }
        }
        .defaultSize(width: 1420, height: 880)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) { }
        }
    }
}
