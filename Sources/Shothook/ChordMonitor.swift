import AppKit
import ShothookCore

/// Fires modifier-only chords (e.g. both Shifts) on release. Watches `flagsChanged` only, so
/// ordinary typing never wakes it. A chord is discarded if any key or mouse button was pressed
/// while it was held (Shift+letter, ⌘⇧T, shift-click…) or if it was held too long to be a tap.
/// Needs Accessibility (already required for pasting) to see other apps' modifier events.
final class ChordMonitor {
    private var detector = ChordDetector()
    private var chords: [(chord: ModifierChord, action: () -> Void)] = []
    private var monitors: [Any] = []

    func set(_ chords: [(chord: ModifierChord, action: () -> Void)]) {
        self.chords = chords
        if chords.isEmpty {
            monitors.forEach(NSEvent.removeMonitor)
            monitors.removeAll()
        } else if monitors.isEmpty {
            // Global: other apps are frontmost. Local: our menu or overlay is.
            if let global = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
            }) { monitors.append(global) }
            if let local = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }) { monitors.append(local) }
        }
    }

    private func handle(_ event: NSEvent) {
        let held = ModifierKeys(rawValue: event.modifierFlags.rawValue).intersection(.all)
        guard let fired = detector.update(held, at: event.timestamp) else { return }
        let heldFor = event.timestamp - fired.began
        guard heldFor < 1.5, !anyKeyOrClick(since: heldFor) else { return }
        chords.first { $0.chord.matches(fired.keys) }?.action()
    }

    /// Asks the window server instead of monitoring every keystroke: zero cost while typing.
    private func anyKeyOrClick(since seconds: Double) -> Bool {
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return kinds.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds }
    }
}
