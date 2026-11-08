import AppKit
import ApplicationServices
import ServiceManagement
import ShothookCore
import SwiftUI

/// What the guide shows. Polled live while the guide (or the Settings helper) is on screen.
@Observable
final class SetupModel {
    enum Permission: CaseIterable, Identifiable {
        case screenRecording, accessibility
        var id: Self { self }
    }

    var screenRecording = CGPreflightScreenCaptureAccess()
    var accessibility = AXIsProcessTrusted()
    var askedForScreenRecording = false
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var regionKeys = ""
    var screenKeys = ""
    var preview = false // debug: pretend nothing is granted yet

    var allGranted: Bool { screenRecording && accessibility }

    func isGranted(_ permission: Permission) -> Bool {
        permission == .screenRecording ? screenRecording : accessibility
    }

    /// Re-reads the real state; returns the permissions that just flipped to granted.
    func refresh() -> [Permission] {
        guard !preview else { return [] }
        let screen = CGPreflightScreenCaptureAccess(), ax = AXIsProcessTrusted()
        var newlyGranted: [Permission] = []
        if screen && !screenRecording { newlyGranted.append(.screenRecording) }
        if ax && !accessibility { newlyGranted.append(.accessibility) }
        if screen != screenRecording || ax != accessibility {
            withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
                screenRecording = screen
                accessibility = ax
            }
        }
        return newlyGranted
    }
}

/// The first-run guide: explains each permission, opens the exact Settings pane, follows System
/// Settings with a "switch me on" helper, and ticks permissions off live as they're granted.
final class SetupGuide: NSObject, NSWindowDelegate {
    static let shared = SetupGuide()
    static var isComplete: Bool {
        get { UserDefaults.standard.bool(forKey: "setupComplete") }
        set { UserDefaults.standard.set(newValue, forKey: "setupComplete") }
    }

    private let model = SetupModel()
    private let helper = SettingsHelper()
    private var window: NSWindow?
    private var timer: Timer?

    func show(region: String, screen: String, preview: Bool = false) {
        model.regionKeys = (try? Trigger(parsing: region).display) ?? ""
        model.screenKeys = (try? Trigger(parsing: screen).display) ?? ""
        model.preview = preview
        if preview {
            model.screenRecording = false
            model.accessibility = false
        } else {
            _ = model.refresh()
        }
        if window == nil { window = makeWindow() }
        NSApp.activate()
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        helper.hide()
        stopPolling()
    }

    // MARK: Actions

    private func grant(_ permission: SetupModel.Permission) {
        let pane: String
        switch permission {
        case .screenRecording:
            model.askedForScreenRecording = true
            CGRequestScreenCaptureAccess() // adds Shothook to the list (first time: a system prompt)
            pane = "Privacy_ScreenCapture"
        case .accessibility:
            AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary) // adds it to the list
            pane = "Privacy_Accessibility"
        }
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
        helper.show(for: permission)
        startPolling()
    }

    #if DEBUG
    func grantForTesting(_ permission: SetupModel.Permission) { grant(permission) }
    #endif

    private func done() {
        Self.isComplete = model.allGranted
        window?.close()
        NSApp.hide(nil) // back to whatever you were doing
    }

    private func setLaunchAtLogin(_ on: Bool) {
        let service = SMAppService.mainApp
        try? on ? service.register() : service.unregister()
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        model.launchAtLogin = service.status == .enabled
    }

    /// Screen Recording is read once per launch, so a fresh grant can need a restart.
    static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "sleep 0.8; /usr/bin/open \"$0\"", Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    // MARK: Live status

    private func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let granted = model.refresh()
        if let showing = helper.permission, granted.contains(showing) || model.isGranted(showing) {
            helper.hide()
        }
        if !granted.isEmpty, let window { // you flipped the switch: come back and show the tick
            NSApp.activate()
            window.orderFrontRegardless()
            window.makeKey()
        }
        if window == nil && helper.permission == nil { stopPolling() }
    }

    private func makeWindow() -> NSWindow {
        let view = SetupView(model: model, grant: { [weak self] in self?.grant($0) },
                             relaunch: { Self.relaunch() }, done: { [weak self] in self?.done() },
                             setLaunchAtLogin: { [weak self] in self?.setLaunchAtLogin($0) })
        let host = NSHostingController(rootView: view)
        host.sizingOptions = .preferredContentSize
        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = "Shothook Setup"
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.delegate = self
        return window
    }
}

// MARK: - The window

private struct SetupView: View {
    @Bindable var model: SetupModel
    let grant: (SetupModel.Permission) -> Void
    let relaunch: () -> Void
    let done: () -> Void
    let setLaunchAtLogin: (Bool) -> Void

    var body: some View {
        VStack(spacing: 22) {
            VStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 84, height: 84)
                    .shadow(color: .black.opacity(0.18), radius: 10, y: 5)
                Text(model.allGranted ? "You're all set" : "Set up Shothook")
                    .font(.system(size: 24, weight: .bold))
                    .contentTransition(.opacity)
                Text(model.allGranted
                     ? "Tap a hotkey anywhere and the shot lands in the AI app you used last."
                     : "Two permissions and you're ready to throw screenshots at your AI.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 14)

            VStack(spacing: 10) {
                ForEach(SetupModel.Permission.allCases) { permission in
                    PermissionCard(permission: permission, granted: model.isGranted(permission),
                                   needsRestart: permission == .screenRecording && model.askedForScreenRecording,
                                   grant: { grant(permission) }, relaunch: relaunch)
                }
            }

            if model.allGranted {
                ReadySection(model: model, setLaunchAtLogin: setLaunchAtLogin)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack {
                Label("Lives in your menu bar", systemImage: "camera.viewfinder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(model.allGranted ? "Done" : "Later", action: done)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(model.allGranted ? .accentColor : .secondary)
            }
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
        .frame(width: 470)
        .background(.background)
    }
}

private struct PermissionCard: View {
    let permission: SetupModel.Permission
    let granted: Bool
    let needsRestart: Bool
    let grant: () -> Void
    let relaunch: () -> Void

    private var title: String { permission == .screenRecording ? "Screen Recording" : "Accessibility" }
    private var detail: String {
        permission == .screenRecording
            ? "To capture your screen. Shots never leave your Mac unless you send them."
            : "To catch your hotkeys and paste into your AI app."
    }
    private var symbol: String { permission == .screenRecording ? "rectangle.dashed.badge.record" : "keyboard" }
    private var tint: Color { permission == .screenRecording ? .purple : .blue }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.gradient)
                .frame(width: 38, height: 38)
                .overlay(Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if needsRestart && !granted {
                    HStack(spacing: 4) {
                        Text("Switched it on?").foregroundStyle(.secondary)
                        Button("Restart Shothook", action: relaunch).buttonStyle(.link)
                    }
                    .font(.caption)
                    .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            Group {
                if granted {
                    Label("Allowed", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Allow…", action: grant)
                        .buttonStyle(.borderedProminent)
                        .transition(.opacity)
                }
            }
            .frame(minHeight: 38)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(granted ? AnyShapeStyle(Color.green.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.6)))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(granted ? Color.green.opacity(0.35) : .clear, lineWidth: 1)
        }
    }
}

private struct ReadySection: View {
    @Bindable var model: SetupModel
    let setLaunchAtLogin: (Bool) -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Shortcut(keys: model.screenKeys, label: "Whole screen")
                Shortcut(keys: model.regionKeys, label: "Viewfinder")
            }
            Toggle("Open Shothook at login", isOn: Binding(get: { model.launchAtLogin }, set: { setLaunchAtLogin($0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)
        }
    }
}

/// A hotkey as keycaps, e.g. ⇧ ⇧ / ⌘ ⇧ ⇧, with what it does underneath.
private struct Shortcut: View {
    let keys: String
    let label: String

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(Self.caps(keys).enumerated()), id: \.offset) { _, cap in
                    Text(cap)
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .frame(minWidth: 26, minHeight: 26)
                        .padding(.horizontal, 4)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.background))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(.quaternary))
                        .shadow(color: .black.opacity(0.08), radius: 0, y: 1)
                }
            }
            Text(keys.isEmpty ? "\(label) (off)" : label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.quaternary.opacity(0.6)))
    }

    /// "L⌘⇧⇧" → ["L⌘", "⇧", "⇧"]; "⌥⇧Space" → ["⌥", "⇧", "Space"].
    static func caps(_ display: String) -> [String] {
        var caps: [String] = []
        var rest = Substring(display)
        while let c = rest.first {
            if "⌃⌥⇧⌘".contains(c) {
                caps.append(String(c))
                rest = rest.dropFirst()
            } else if (c == "L" || c == "R"), let next = rest.dropFirst().first, "⌃⌥⇧⌘".contains(next) {
                caps.append(String(rest.prefix(2)))
                rest = rest.dropFirst(2)
            } else {
                caps.append(String(rest))
                break
            }
        }
        return caps
    }
}

// MARK: - The helper that rides along with System Settings

/// A small card pinned under the System Settings window: "Switch on Shothook", with an app icon
/// you can drag into the list if Shothook isn't there. Follows the window as you move it.
final class SettingsHelper {
    private(set) var permission: SetupModel.Permission?
    private var panel: NSPanel?
    private var follow: Timer?

    func show(for permission: SetupModel.Permission) {
        self.permission = permission
        let title = permission == .screenRecording ? "Screen Recording" : "Accessibility"
        let host = NSHostingView(rootView: HelperCard(listName: title))
        host.frame.size = host.fittingSize
        let panel = self.panel ?? NSPanel(contentRect: host.frame, styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        follow?.invalidate()
        follow = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
    }

    func hide() {
        follow?.invalidate()
        follow = nil
        panel?.orderOut(nil)
        permission = nil
    }

    private func reposition() {
        guard let panel, let settings = Self.settingsWindowFrame() else {
            panel?.orderOut(nil) // Settings not open (yet): wait for it
            return
        }
        let size = panel.frame.size
        var origin = CGPoint(x: settings.midX - size.width / 2, y: settings.minY - size.height - 14)
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(settings) }), origin.y < screen.visibleFrame.minY + 8 {
            origin.y = settings.minY + 18 // no room below: overlap the window's bottom edge
        }
        panel.setFrameOrigin(origin)
        panel.orderFrontRegardless()
    }

    /// System Settings' main window in Cocoa coordinates (bounds need no extra permission).
    private static func settingsWindowFrame() -> CGRect? {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let info = list.first(where: { $0[kCGWindowOwnerName as String] as? String == "System Settings" && $0[kCGWindowLayer as String] as? Int == 0 }),
              let dict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dict)
        else { return nil }
        return Geometry.topLeftRect(for: bounds, primaryHeight: primary.frame.height)
    }
}

private struct HelperCard: View {
    let listName: String

    var body: some View {
        HStack(spacing: 12) {
            DraggableAppIcon()
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("Switch on **Shothook** in \(listName)")
                    .font(.callout)
                Text("Not in the list? Drag this icon in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.white.opacity(0.15)))
        .padding(1)
    }
}

/// The app icon as a drag source: dropping it on a Privacy list adds Shothook there.
private struct DraggableAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> DragSourceIcon { DragSourceIcon() }
    func updateNSView(_ nsView: DragSourceIcon, context: Context) {}
}

final class DragSourceIcon: NSImageView, NSDraggingSource {
    init() {
        super.init(frame: .zero)
        image = NSApp.applicationIconImage
        imageScaling = .scaleProportionallyUpOrDown
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }
}
