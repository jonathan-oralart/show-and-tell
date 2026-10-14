import AppKit
import ScreenCaptureKit

/// Runs one capture: grab the front window, annotate it in place, then save or copy it.
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var panel: OverlayPanel?
    private var captureTask: Task<Void, Never>?
    private var pill: RecordingPill?
    #if DEBUG
    /// The real overlay session and copy progress, for demo takes.
    private(set) var demoSession: AnnotationSession?
    private(set) var demoIsSending = false

    #endif
    /// A capture from history is being opened; recordings take a moment, and steps shouldn't overtake each other.
    private var isNavigating = false
    /// The new capture the overlay opened with, kept while stepping through history so . can come back to it
    /// even though it isn't worth saving to Recent.
    private var draft: AnnotationSession?

    /// Does the slow first-time work of a capture at launch, so the first shortcut press opens as fast as later ones:
    /// ScreenCaptureKit's first window list, and laying out an overlay offscreen.
    func warmUp() {
        // Asking for the window list without permission would prompt for it.
        guard Permission.screenRecording.isGranted else { return }
        Task { _ = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) }
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let image = context?.makeImage(), let screen = NSScreen.main else { return }
        let capture = CapturedWindow(image: image, frame: CGRect(x: 0, y: 0, width: 1, height: 1), screen: screen,
                                     appName: "", windowTitle: nil)
        let view = OverlayView(session: AnnotationSession(capture: capture), animatesIn: false, hasDraft: false,
                               onSend: {}, onCopy: {}, onSave: {}, onDiscard: {}, onNavigate: { _ in })
        // Never ordered in, so it's never seen.
        _ = OverlayPanel(screen: screen, content: view)
        SendSound.current.preload()
    }

    /// Captures the front window, or dismisses the current capture on a second press.
    func toggleCapture() {
        if panel != nil || captureTask != nil {
            dismiss()
            return
        }
        guard !ScreenRecorder.shared.isRecording else { return }
        guard Permission.allGranted else {
            PermissionsWindow.showIfNeeded()
            return
        }
        captureTask = Task {
            // A cancelled task may finish after another capture has started.
            defer { if !Task.isCancelled { captureTask = nil } }
            do {
                let capture = try await WindowCapture.captureFrontWindow()
                guard !Task.isCancelled else { return }
                present(AnnotationSession(capture: capture))
            } catch {
                guard !Task.isCancelled else { return }
                NSSound.beep()
            }
        }
    }

    /// Starts recording the screen, or stops and opens the recording to pick frames from.
    func toggleRecording() {
        let recorder = ScreenRecorder.shared
        if recorder.isRecording {
            stopRecording()
            return
        }
        guard panel == nil else { return }
        guard Permission.allGranted else {
            PermissionsWindow.showIfNeeded()
            return
        }
        Task {
            var pill: RecordingPill?
            do {
                // The pill is up before recording starts, so Show & Tell has a window on screen to leave out of it.
                try await recorder.start { [weak self] screen in
                    let shown = RecordingPill(screen: screen, started: .now) { self?.stopRecording() }
                    shown.orderFrontRegardless()
                    self?.pill = shown
                    pill = shown
                    return CGWindowID(shown.windowNumber)
                }
            } catch {
                pill?.orderOut(nil)
                self.pill = nil
                NSSound.beep()
                return
            }
            try? await Task.sleep(for: ScreenRecorder.limit)
            // Still the same recording: stop it at the limit.
            if let pill, self.pill === pill { stopRecording() }
        }
    }

    /// Opens the recording at its first frame, cropped to the window that was in front.
    private func stopRecording() {
        // Stopping before capture has begun would leave it running with no pill.
        guard ScreenRecorder.shared.hasStarted else { return }
        pill?.orderOut(nil)
        pill = nil
        Task {
            do {
                try await open(ScreenRecorder.shared.stop(), atEnd: false)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// Opens the last 30 seconds of the front window's display at the latest frame, to step back from what just happened.
    func replay() {
        guard panel == nil, captureTask == nil, !ScreenRecorder.shared.isRecording, ReplayBuffer.shared.isOn else {
            NSSound.beep()
            return
        }
        captureTask = Task {
            defer { if !Task.isCancelled { captureTask = nil } }
            do {
                let saved = try await ReplayBuffer.shared.save()
                guard !Task.isCancelled else { return }
                try await open(saved, atEnd: true)
            } catch {
                guard !Task.isCancelled else { return }
                NSSound.beep()
            }
        }
    }

    /// Opens a finished recording, cropped to the window that was in front, at its first or last frame.
    private func open(_ finished: ScreenRecording, atEnd: Bool) async throws {
        let recording = try await Recording.open(finished.url, clicks: finished.clicks, displaySize: finished.frame.size,
                                                 deletesFile: true)
        let time = atEnd ? recording.times[recording.times.count - 1] : recording.times[0]
        let image = try await recording.image(at: time, exact: true).image
        let display = CapturedWindow(image: image, frame: finished.frame, screen: finished.screen,
                                     appName: finished.appName, windowTitle: finished.windowTitle)
        let crop = finished.windowRect ?? CGRect(origin: .zero, size: finished.frame.size)
        present(AnnotationSession(recording: recording, display: display, crop: crop.integral, frames: [], time: time))
    }

    /// Opens a saved capture in the overlay to change and copy again.
    func reopen(_ saved: SavedCapture) {
        guard panel == nil, !ScreenRecorder.shared.isRecording else { return }
        Task {
            guard panel == nil, let session = await CaptureStore.shared.restore(saved) else { return }
            present(session)
        }
    }

    /// Shows a session in the overlay, reusing the open overlay when stepping through history.
    private func present(_ session: AnnotationSession) {
        #if DEBUG
        demoSession = session
        #endif
        let view = OverlayView(
            session: session,
            animatesIn: panel == nil,
            hasDraft: draft != nil,
            onSend: { [weak self] in self?.close(session, to: .chat) },
            onCopy: { [weak self] in self?.close(session, to: .clipboard) },
            onSave: { [weak self] in self?.close(session, to: .recent) },
            onDiscard: { [weak self] in self?.dismiss() },
            onNavigate: { [weak self] step in self?.navigate(from: session, by: step) }
        )
        if let panel {
            panel.show(view)
        } else {
            let panel = OverlayPanel(screen: session.capture.screen, content: view)
            self.panel = panel
            panel.makeKeyAndOrderFront(nil)
        }
        // Once the overlay is up, so neither delays it.
        CaptureStore.shared.prefetchNeighbours(of: session.savedID)
        SendSound.current.preload()
    }

    /// Steps through Recent while annotating: +1 is older, −1 newer. The capture being left is saved first,
    /// as closing would.
    private func navigate(from session: AnnotationSession, by step: Int) {
        let store = CaptureStore.shared
        // An unsaved capture sits just before the newest saved one.
        let current = session.savedID.flatMap { id in store.captures.firstIndex { $0.id == id } } ?? -1
        let target = current + step
        let backToDraft = target == -1 && draft != nil
        guard store.captures.indices.contains(target) || backToDraft, !isNavigating else { return }
        let saves = session.hasChanges && session.isWorthSaving
        // Leaving the new capture: it goes into Recent if it's worth saving, otherwise it's kept here.
        if session.savedID == nil { draft = saves ? nil : session }
        isNavigating = true
        Task {
            defer { isNavigating = false }
            // Decoding a recording's frames takes a moment; the overlay may have closed meanwhile.
            let next = if backToDraft { draft } else { await store.restore(store.captures[target]) }
            guard let next, panel != nil else { return }
            present(next)
            // Show the next capture first; save the one left behind (only if it changed) once that's on screen.
            if saves {
                await Task.yield()
                store.save(session, png: FeedbackImage.png(for: session))
            }
        }
    }

    /// Where a capture goes when the overlay closes. It's always kept in Recent as well.
    /// `chat` copies it and brings Claude or Codex, as chosen in Settings, to the front to paste it into.
    private enum Destination {
        case recent, chat, clipboard
    }

    private func close(_ session: AnnotationSession, to destination: Destination) {
        guard destination != .recent || (session.hasChanges && session.isWorthSaving) else {
            dismiss()
            return
        }
        #if DEBUG
        demoIsSending = destination == .chat
        #endif
        let screen = panel?.screen
        // Close first so the overlay is gone the moment you press the button; render once it's off screen.
        dismiss()
        // Copy sounds and shows the moment you press it; the image follows once rendered.
        switch destination {
        case .recent: break
        case .chat: CopiedToast.show("Copied — paste with ⌘V", on: screen)
        case .clipboard: CopiedToast.show("Copied to clipboard", on: screen)
        }
        if destination != .recent { SendSound.current.play() }
        Task {
            await Task.yield()
            let png = FeedbackImage.png(for: session)
            // Deliver before saving to history, so the image and sound don't wait on writing files.
            switch destination {
            case .recent: break
            case .chat:
                Clipboard.copy(png: png)
                AppActivator.activate(SendTarget.current)
            case .clipboard: Clipboard.copy(png: png)
            }
            CaptureStore.shared.save(session, png: png)
            #if DEBUG
            demoIsSending = false
            #endif
        }
    }

    private func dismiss() {
        captureTask?.cancel()
        captureTask = nil
        #if DEBUG
        demoSession = nil
        #endif
        panel?.orderOut(nil)
        panel = nil
        draft = nil
    }
}
