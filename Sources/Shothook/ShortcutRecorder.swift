import AppKit
import ShothookCore

/// A small HUD that records a new shortcut: tap a modifier combo (⇧⇧, ⌘⇧⇧, right ⌘…) or press a
/// key combo (⌥⇧3). Shows held keys live. Esc cancels, ⌫ turns the shortcut off.
final class ShortcutRecorder: NSObject, NSWindowDelegate {
    enum Result: Equatable {
        case set(String) // a config spec
        case off
        case cancelled
    }

    private let panel: NSPanel
    private let keys = NSTextField(labelWithString: "")
    private let hint = NSTextField(wrappingLabelWithString: "")
    private let validate: (String) -> String? // an error message, or nil if the spec is acceptable
    private var monitor: Any?
    private var detector = ChordDetector()
    private var keyDuringChord = false
    private var continuation: CheckedContinuation<Result, Never>?
    private static let instructions = "Tap a modifier combo like ⇧⇧, or press a shortcut like ⌥⇧3.\nEsc cancels  ·  ⌫ turns it off"

    init(action: String, current: String, validate: @escaping (String) -> String?) {
        self.validate = validate
        panel = NSPanel(contentRect: CGRect(x: 0, y: 0, width: 360, height: 150),
                        styleMask: [.titled, .closable, .hudWindow, .utilityWindow, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "Shortcut for \(action)"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false // a menu-bar app may not be granted activation; stay visible regardless
        panel.becomesKeyOnlyIfNeeded = false
        panel.delegate = self

        keys.font = .systemFont(ofSize: 30, weight: .semibold)
        keys.alignment = .center
        keys.stringValue = (try? Trigger(parsing: current).display) ?? "Off"
        keys.textColor = .tertiaryLabelColor // the current shortcut, until keys go down
        hint.font = .systemFont(ofSize: 11)
        hint.alignment = .center
        hint.textColor = .secondaryLabelColor
        hint.stringValue = Self.instructions
        let stack = NSStackView(views: [keys, hint])
        stack.orientation = .vertical
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 22, left: 18, bottom: 18, right: 18)
        panel.contentView = stack
    }

    func run() async -> Result {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            NSApp.activate()
            panel.center()
            panel.orderFrontRegardless()
            panel.makeKey() // non-activating: takes keystrokes even if activation is refused
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                self?.handle(event)
                return nil // swallow: these keys are being recorded, not typed
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        finish(.cancelled)
    }

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .flagsChanged:
            let held = ModifierKeys(rawValue: event.modifierFlags.rawValue).intersection(.all)
            if !held.isEmpty {
                show(Trigger.spec(forChord: held), color: .labelColor)
                if !keyDuringChord { hint.stringValue = "Release to set it" }
            }
            guard let fired = detector.update(held, at: event.timestamp) else { return }
            defer { keyDuringChord = false }
            if !keyDuringChord { accept(Trigger.spec(forChord: fired.keys)) }
        case .keyDown:
            let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if mods.isEmpty, event.keyCode == 53 { return finish(.cancelled) } // Esc
            if mods.isEmpty, [51, 117].contains(event.keyCode) { return finish(.off) } // ⌫ / ⌦
            keyDuringChord = true // a key combo, so releasing the modifiers mustn't also record a chord
            guard !event.isARepeat else { return }
            var carbon: UInt32 = 0
            for (flag, modifier) in [(NSEvent.ModifierFlags.command, Hotkey.Modifier.command), (.option, .option),
                                     (.control, .control), (.shift, .shift)] where mods.contains(flag) {
                carbon |= modifier.rawValue
            }
            guard let spec = Trigger.spec(keyCode: UInt32(event.keyCode), carbonModifiers: carbon) else {
                return reject("That key can't be a shortcut")
            }
            accept(spec)
        default:
            break
        }
    }

    private func accept(_ spec: String) {
        if spec == "lshift" || spec == "rshift" { return reject("A lone Shift is too easy to hit. Add another key") }
        do { _ = try Trigger(parsing: spec) } catch { return reject("Add ⌘, ⌃ or ⌥, or use an F-key") }
        if let problem = validate(spec) { return reject(problem) }
        show(spec, color: .controlAccentColor)
        hint.stringValue = "Saved ✓"
        removeMonitor()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in self?.finish(.set(spec)) }
    }

    private func reject(_ message: String) {
        keys.textColor = .systemOrange
        hint.stringValue = message + "\nEsc cancels  ·  ⌫ turns it off"
        NSSound.beep()
    }

    private func show(_ spec: String, color: NSColor) {
        keys.stringValue = (try? Trigger(parsing: spec).display) ?? spec
        keys.textColor = color
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func finish(_ result: Result) {
        guard let continuation else { return }
        self.continuation = nil
        removeMonitor()
        panel.delegate = nil
        panel.orderOut(nil)
        continuation.resume(returning: result)
    }
}
