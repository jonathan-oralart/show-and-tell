import AppKit

/// Logs mouse presses and releases anywhere on screen while it's running, so recordings can draw them onto their
/// frames. Clicks on Show & Tell's own windows, like the stop pill, aren't seen.
final class ClickLog {
    /// A press in global points from the top left of the primary display, timed by system uptime.
    private struct Press {
        var time: TimeInterval
        var point: CGPoint
        var button: Click.Button
        var release: (time: TimeInterval, point: CGPoint)?
    }

    private var presses: [Press] = []
    /// The press each held mouse button made, by button number, until it's let go.
    private var held: [Int: Int] = [:]
    private var monitor: Any?
    /// Presses older than this are forgotten, so an always-on log stays small. Nil keeps them all.
    private let keeps: TimeInterval?

    init(keeps: TimeInterval? = nil) {
        self.keeps = keeps
        let events: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp]
        monitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            self?.log(event)
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// The presses on a display from `start` on, in display points and seconds after `start`.
    func clicks(on display: CGRect, from start: TimeInterval) -> [Click] {
        presses.compactMap { press in
            let local = CGRect(origin: .zero, size: display.size)
            let point = CGPoint(x: press.point.x - display.minX, y: press.point.y - display.minY)
            guard press.time >= start, local.contains(point) else { return nil }
            var click = Click(time: press.time - start, x: point.x, y: point.y, button: press.button)
            if let release = press.release {
                click.release = Click.Release(time: release.time - start, x: release.point.x - display.minX,
                                              y: release.point.y - display.minY)
            }
            return click
        }
    }

    /// Adds a press, or the release to the press it ends.
    private func log(_ event: NSEvent) {
        // Screen coordinates, bottom-left origin, since a global event has no window.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let point = CGPoint(x: event.locationInWindow.x, y: primaryHeight - event.locationInWindow.y)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button: Click.Button = switch event.type {
            case .leftMouseDown: event.modifierFlags.contains(.control) ? .right : .left
            case .rightMouseDown: .right
            default: .other
            }
            forgetOld(before: event.timestamp)
            held[event.buttonNumber] = presses.count
            presses.append(Press(time: event.timestamp, point: point, button: button))
        default:
            guard let index = held.removeValue(forKey: event.buttonNumber) else { return }
            presses[index].release = (event.timestamp, point)
        }
    }

    private func forgetOld(before now: TimeInterval) {
        guard let keeps, !presses.isEmpty, held.isEmpty else { return }
        presses.removeAll { now - $0.time > keeps }
    }
}
