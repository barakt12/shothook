import AppKit
import OSLog
import ServiceManagement
import ShothookCore
import UniformTypeIdentifiers

let log = Logger(subsystem: "dev.shothook", category: "app")

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let hotkeys = HotkeyCenter()
    private let chords = ChordMonitor()
    private let store = ShotStore()
    var config = Config.default
    private(set) var tracker: HarnessTracker!
    private var statusItem: NSStatusItem!
    private(set) var icon: StatusIcon!
    private var problems: [String] = []
    private var busy = false
    private var recording = false

    // "will" rather than "did": a cold launch via shothook:// can deliver the URL before didFinishLaunching.
    func applicationWillFinishLaunching(_ notification: Notification) {
        // One Shothook at a time: a second copy (e.g. /Applications and a dev build) would register
        // the same hotkeys and capture twice. The one already running wins.
        let me = NSRunningApplication.current
        if NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .contains(where: { $0 != me && !$0.isTerminated }) {
            log.notice("another Shothook is already running; quitting")
            exit(0)
        }

        // First launch: start near the clock rather than at the far left, where menu-bar managers
        // (Hidden Bar, Bartender, Ice) and the notch hide new icons. ⌘-dragging it later sticks.
        let positionKey = "NSStatusItem Preferred Position shothook"
        if UserDefaults.standard.object(forKey: positionKey) == nil {
            UserDefaults.standard.set(150.0, forKey: positionKey)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "shothook"
        statusItem.menu = NSMenu()
        statusItem.menu?.delegate = self
        icon = StatusIcon(statusItem.button!)

        reloadConfig()
        tracker = HarnessTracker(config: config)
        store.prune()

        // First run, or a permission is missing (e.g. after a re-sign): the guide walks you through.
        if !Self.permissionsGranted || !SetupGuide.isComplete {
            DispatchQueue.main.async { self.showSetupGuide() }
        }
    }

    static var permissionsGranted: Bool { AXIsProcessTrusted() && CGPreflightScreenCaptureAccess() }

    func showSetupGuide(preview: Bool = false) {
        SetupGuide.shared.show(region: config.hotkeys.region, screen: config.hotkeys.screen, preview: preview)
    }

    // shothook://region — for Raycast, Shortcuts, BetterTouchTool, scripts. Only the viewfinder:
    // it captures nothing until the user clicks or drags, so no other app can use this URL to take
    // a silent screenshot and read it off the clipboard (a Screen Recording permission bypass).
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            #if DEBUG
            if let mode = CaptureMode(rawValue: url.host() ?? "") { capture(mode) } // tests drive both modes
            debugHook(url)
            #else
            if url.host() == CaptureMode.region.rawValue { capture(.region) }
            #endif
        }
    }

    // MARK: Capture

    func capture(_ mode: CaptureMode) {
        guard !busy else { return }
        busy = true
        // Opt out of App Nap timer throttling while a capture is in flight.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Shothook capture")
        Task {
            defer {
                busy = false
                ProcessInfo.processInfo.endActivity(activity)
            }
            let t0 = ContinuousClock.now
            let screens = mode == .screen ? [ScreenGrabber.screenUnderMouse()].compactMap { $0 } : NSScreen.screens
            let frames: [Frame]
            do throws(ScreenGrabber.Failure) {
                frames = try await ScreenGrabber.grab(screens)
            } catch {
                log.error("grab failed: \(error.description, privacy: .public)")
                return icon.show(.failed(reason: error.description))
            }
            let grabbed = ContinuousClock.now

            var shot = (image: frames[0].image, rect: frames[0].rect, screen: frames[0].screen)
            if mode == .region {
                guard let selection = await RegionOverlay(frames: frames).run() else { return } // Esc
                let source = selection.frame
                let pixels = Geometry.pixelRect(of: selection.rect, in: source.rect, imageWidth: source.image.width, imageHeight: source.image.height)
                guard let cropped = source.image.cropping(to: pixels) else { return icon.show(.failed(reason: "empty selection")) }
                shot = (cropped, selection.rect, source.screen)
            }
            await send(shot.image, from: shot.rect, on: shot.screen)
            log.notice("\(mode.rawValue, privacy: .public): grab \(grabbed - t0, privacy: .public), total \(ContinuousClock.now - t0, privacy: .public)")
            store.prune()
        }
    }

    /// Delivers (harness or clipboard) while the shot is thrown at its destination.
    func send(_ image: CGImage, from rect: CGRect, on screen: NSScreen) async {
        guard let url = try? store.newShotURL() else { return icon.show(.failed(reason: "can't write to \(store.directory.path)")) }
        let target = config.mode == .harness ? tracker.target() : nil
        let landing = target.flatMap { Deliverer.landingPoint(in: $0.app) } ?? icon.center
        let started = ContinuousClock.now

        async let outcome = config.mode == .harness
            ? Deliverer.deliver(image, file: url, to: target, maxLongEdge: config.maxLongEdge)
            : Deliverer.copy(image, file: url, maxLongEdge: config.maxLongEdge)
        if config.effects {
            await Flight.throwShot(image, from: rect, on: screen, to: landing, sound: config.sound)
        } else if config.sound {
            Sounds.whomp()
        }
        let result = await outcome
        icon.show(result) // lands with the impact (or right after delivery, if that's slower)
        log.notice("deliver \(ContinuousClock.now - started, privacy: .public) → \(String(describing: result), privacy: .public)")
    }

    // MARK: Config

    /// Opens the JSON in the default plain-text editor (not whatever claims .json — often Xcode).
    private func openConfig() {
        _ = try? Config.loadOrCreate() // make sure the file exists
        if let editor = NSWorkspace.shared.urlForApplication(toOpen: .plainText) {
            NSWorkspace.shared.open([Config.fileURL], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(Config.fileURL)
        }
    }

    private func reloadConfig() {
        problems.removeAll()
        do {
            config = try Config.loadOrCreate()
        } catch {
            problems.append("Config error — keeping previous settings: \(error)")
        }
        tracker?.update(config: config)

        hotkeys.unregisterAll()
        var chordActions: [(chord: ModifierChord, action: () -> Void)] = []
        for (spec, mode) in [(config.hotkeys.region, CaptureMode.region), (config.hotkeys.screen, .screen)] where !spec.isEmpty {
            do {
                switch try Trigger(parsing: spec) {
                case .keys(let hotkey):
                    if let error = hotkeys.register(hotkey, action: { [weak self] in self?.capture(mode) }) { problems.append(error) }
                case .chord(let chord):
                    chordActions.append((chord, { [weak self] in self?.capture(mode) }))
                }
            } catch {
                problems.append("\(error)")
            }
        }
        chords.set(chordActions)
    }

    private func setMode(_ mode: DeliveryMode) {
        config.mode = mode
        saveConfig()
        icon.show(mode == .harness ? "arrow.down.app" : "doc.on.clipboard", bounce: true)
    }

    private func setMuted(_ muted: Bool) {
        config.sound = !muted
        saveConfig()
        icon.show(muted ? "speaker.slash" : "speaker.wave.2", bounce: !muted)
        if !muted { Sounds.whomp() } // let them hear what they turned on
    }

    /// Records a new shortcut for `mode` from the menu. Live hotkeys are paused meanwhile, so
    /// pressing ⇧⇧ to set it doesn't also fire a capture.
    func recordShortcut(for mode: CaptureMode) {
        guard !recording else { return }
        recording = true
        hotkeys.unregisterAll()
        chords.set([])
        let (name, otherName) = mode == .region ? ("Capture Region", "Capture Screen") : ("Capture Screen", "Capture Region")
        let current = mode == .region ? config.hotkeys.region : config.hotkeys.screen
        let other = mode == .region ? config.hotkeys.screen : config.hotkeys.region
        let recorder = ShortcutRecorder(action: name, current: current) { spec in
            (try? Trigger(parsing: spec)) == (try? Trigger(parsing: other)) ? "Already used by \(otherName)" : nil
        }
        Task {
            let result = await recorder.run()
            NSApp.hide(nil) // hand focus back to wherever you were
            if result != .cancelled {
                var spec = ""
                if case .set(let s) = result { spec = s }
                if mode == .region { config.hotkeys.region = spec } else { config.hotkeys.screen = spec }
                saveConfig()
            }
            reloadConfig() // re-registers the (possibly new) shortcuts
            recording = false
        }
    }

    private func resetShortcuts() {
        config.hotkeys = Config.default.hotkeys
        saveConfig()
        reloadConfig()
    }

    private func saveConfig() {
        do { try config.save() } catch { problems.append("Couldn't save config: \(error.localizedDescription)") }
    }

    // MARK: Menu (built lazily, only when opened)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        if !Self.permissionsGranted {
            menu.addItem(item("⚠︎ Finish Setup…") { [weak self] in self?.showSetupGuide() })
            menu.addItem(.separator())
        }
        let harness = item("Paste into Harness") { [weak self] in self?.setMode(.harness) }
        harness.state = config.mode == .harness ? .on : .off
        let clipboard = item("Copy to Clipboard Only") { [weak self] in self?.setMode(.clipboard) }
        clipboard.state = config.mode == .clipboard ? .on : .off
        menu.addItem(harness)
        if config.mode == .harness {
            let name = tracker.target().map { $0.app.localizedName ?? $0.harness.name ?? $0.harness.bundleId }
            let note = menu.addItem(withTitle: name.map { "    → \($0)" } ?? "    → no harness running (copies instead)", action: nil, keyEquivalent: "")
            note.isEnabled = false
        }
        menu.addItem(clipboard)
        menu.addItem(.separator())
        let mute = item("Mute Sounds") { [weak self] in self?.setMuted(self?.config.sound ?? false) }
        mute.state = config.sound ? .off : .on
        menu.addItem(mute)
        menu.addItem(.separator())
        menu.addItem(item("Capture Region", trigger: config.hotkeys.region) { [weak self] in self?.capture(.region) })
        menu.addItem(item("Capture Screen", trigger: config.hotkeys.screen) { [weak self] in self?.capture(.screen) })
        let shortcuts = NSMenu()
        shortcuts.addItem(item("Capture Region…", trigger: config.hotkeys.region) { [weak self] in self?.recordShortcut(for: .region) })
        shortcuts.addItem(item("Capture Screen…", trigger: config.hotkeys.screen) { [weak self] in self?.recordShortcut(for: .screen) })
        shortcuts.addItem(.separator())
        shortcuts.addItem(item("Reset to Defaults") { [weak self] in self?.resetShortcuts() })
        let shortcutsItem = NSMenuItem(title: "Shortcuts", action: nil, keyEquivalent: "")
        shortcutsItem.submenu = shortcuts
        menu.addItem(shortcutsItem)

        if !problems.isEmpty {
            menu.addItem(.separator())
            for problem in problems {
                menu.addItem(item("⚠︎ " + problem) { [weak self] in self?.openConfig() })
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Setup Guide…") { [weak self] in self?.showSetupGuide() })
        menu.addItem(item("Open Config…") { [weak self] in self?.openConfig() })
        menu.addItem(item("Reload Config") { [weak self] in self?.reloadConfig() })
        let login = item("Launch at Login") { [weak self] in
            let service = SMAppService.mainApp
            do {
                try service.status == .enabled ? service.unregister() : service.register()
            } catch {
                self?.icon.show(.failed(reason: "Launch at Login: \(error.localizedDescription)"))
            }
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        }
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shothook", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func item(_ title: String, trigger: String? = nil, _ handler: @escaping () -> Void) -> NSMenuItem {
        var shortcut = trigger.flatMap { try? Trigger(parsing: $0) }.map { "\t\($0.display)" } ?? ""
        if trigger == "" { shortcut = "\tOff" }
        let action = MenuAction(handler)
        let item = NSMenuItem(title: title + shortcut, action: #selector(MenuAction.fire), keyEquivalent: "")
        item.target = action
        item.representedObject = action // target is weak; this keeps the action alive with the item
        return item
    }
}

/// The menu-bar icon: an SF Symbol that morphs (native "replace" transition) to report outcomes.
final class StatusIcon {
    private let view = PassthroughImageView()
    private let button: NSStatusBarButton
    private var reset: Task<Void, Never>?
    private static let idle = "camera.viewfinder"

    init(_ button: NSStatusBarButton) {
        self.button = button
        view.frame = button.bounds
        view.autoresizingMask = [.width, .height]
        view.imageScaling = .scaleNone
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        view.image = Self.symbol(Self.idle)
        button.addSubview(view)
        button.toolTip = "Shothook"
    }

    /// Centre of the icon on screen: where clipboard-bound shots fly to.
    var center: CGPoint {
        guard let window = button.window else { return NSEvent.mouseLocation }
        let frame = window.convertToScreen(button.convert(button.bounds, to: nil))
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func show(_ outcome: Outcome) {
        switch outcome {
        case .pasted(let name): show("checkmark.circle.fill", bounce: true, tip: "Pasted into \(name)")
        case .copied: show("doc.on.clipboard.fill", bounce: true, tip: "Copied to clipboard")
        case .clipboardOnly(let reason): show("doc.on.clipboard.fill", bounce: true, tip: "Copied to clipboard: \(reason)")
        case .failed(let reason): show("exclamationmark.triangle.fill", bounce: false, tip: "Shothook: \(reason)")
        }
    }

    func show(_ symbol: String, bounce: Bool, tip: String? = nil) {
        view.setSymbolImage(Self.symbol(symbol), contentTransition: .replace)
        if bounce { view.addSymbolEffect(.bounce) }
        if let tip { button.toolTip = tip }
        reset?.cancel()
        reset = Task {
            try? await Task.sleep(for: .seconds(1.6))
            guard !Task.isCancelled else { return }
            view.setSymbolImage(Self.symbol(Self.idle), contentTransition: .replace)
            button.toolTip = "Shothook"
        }
    }

    private static func symbol(_ name: String) -> NSImage {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "Shothook") ?? NSImage()
        image.isTemplate = true
        return image
    }
}

/// Lets clicks fall through to the status bar button underneath.
final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Lets menu items run closures instead of needing a selector per action.
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}
