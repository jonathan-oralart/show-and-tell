import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppWindows.watchForLastWindowClosing()
        MoveToApplications.offerIfNeeded()
        PermissionsWindow.showIfNeeded()
        CaptureCoordinator.shared.warmUp()
        ReplayBuffer.shared.restart()
        #if DEBUG
        DemoTake.listen()
        #endif
    }

    /// Opening Show & Tell again while it's running (Finder, Spotlight) shows Settings, since the menu bar
    /// icon can be hidden by the notch or a menu bar manager and opening would otherwise seem to do nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows {
            SettingsWindow.show()
        }
        return true
    }
}
