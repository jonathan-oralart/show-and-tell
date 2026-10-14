import KeyboardShortcuts
import Sparkle
import SwiftUI

@main
struct ShowAndTellApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Checks GitHub Releases for new versions. Off in debug builds, so a development build isn't replaced by a release.
    private let updater = SPUStandardUpdaterController(startingUpdater: !isDebugBuild, updaterDelegate: nil, userDriverDelegate: nil)

    init() {
        KeyboardShortcuts.onKeyDown(for: .capture) {
            CaptureCoordinator.shared.toggleCapture()
        }
        KeyboardShortcuts.onKeyDown(for: .record) {
            CaptureCoordinator.shared.toggleRecording()
        }
        KeyboardShortcuts.onKeyDown(for: .replay) {
            CaptureCoordinator.shared.replay()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent(updater: updater.updater)
        } label: {
            Image(nsImage: menuBarIcon)
        }
        Window("Show & Tell History", id: "history") {
            HistoryView()
        }
        .defaultSize(width: 760, height: 540)
        .defaultLaunchBehavior(.suppressed)
    }
}

private struct MenuContent: View {
    let updater: SPUUpdater
    @Environment(\.openWindow) private var openWindow
    private let store = CaptureStore.shared

    var body: some View {
        Button("Capture Front Window") {
            CaptureCoordinator.shared.toggleCapture()
        }
        .globalKeyboardShortcut(.capture)
        Button(ScreenRecorder.shared.isRecording ? "Stop Recording" : "Record Screen") {
            CaptureCoordinator.shared.toggleRecording()
        }
        .globalKeyboardShortcut(.record)
        Button("Replay Last 30 Seconds") {
            CaptureCoordinator.shared.replay()
        }
        .globalKeyboardShortcut(.replay)
        .disabled(!ReplayBuffer.shared.isOn)
        Menu("Recent") {
            ForEach(store.captures) { saved in
                Button {
                    CaptureCoordinator.shared.reopen(saved)
                } label: {
                    if let thumbnail = store.thumbnails[saved.id] {
                        Image(nsImage: menuIcon(thumbnail))
                    }
                    Text("\(saved.appName) — \(saved.displayDate)")
                }
            }
            if !store.captures.isEmpty { Divider() }
            Button("Show All…") {
                AppWindows.show(id: "history") { openWindow(id: "history") }
            }
        }
        Divider()
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(isDebugBuild)
        Button("Settings…") {
            SettingsWindow.show()
        }
        .keyboardShortcut(",")
        Button("Quit Show & Tell") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}

/// Menu items draw images at their own size, so shrink the thumbnail to fit a menu row.
private func menuIcon(_ image: NSImage) -> NSImage {
    let height: CGFloat = 32
    let width = image.size.height > 0 ? min(image.size.width / image.size.height * height, 64) : height
    let icon = image.copy() as! NSImage
    icon.size = NSSize(width: width, height: height)
    return icon
}

#if DEBUG
private let isDebugBuild = true
#else
private let isDebugBuild = false
#endif
