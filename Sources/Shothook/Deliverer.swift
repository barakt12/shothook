import AppKit
import ApplicationServices
import ImageIO
import ShothookCore
import UniformTypeIdentifiers

enum Outcome {
    case pasted(into: String)
    case copied // clipboard mode: on the clipboard by design
    case clipboardOnly(reason: String) // harness mode, but pasting wasn't safe
    case failed(reason: String)
}

/// Puts the shot on the clipboard, focuses the target harness, and sends ⌘V.
/// Never presses Return: you still write the prompt. Anything uncertain falls back to
/// "it's on your clipboard" rather than pasting somewhere unexpected.
enum Deliverer {
    /// Clipboard mode: PNG on the clipboard (and on disk), nothing else.
    static func copy(_ image: CGImage, file: URL, maxLongEdge: Int) async -> Outcome {
        guard let png = await encode(image, to: file, maxLongEdge: maxLongEdge) else {
            return .failed(reason: "couldn't save the capture")
        }
        NSPasteboard.general.clearContents()
        return NSPasteboard.general.setData(png, forType: .png) ? .copied : .failed(reason: "couldn't write to the clipboard")
    }

    static func deliver(_ image: CGImage, file: URL, to target: (app: NSRunningApplication, harness: Harness)?, maxLongEdge: Int) async -> Outcome {
        // Ask for the app switch first so the window-server animation overlaps PNG encoding.
        let element = target.map { axElement(for: $0.app) }
        if let app = target?.app, let element, AXIsProcessTrusted(), !isFrontmost(app) {
            app.unhide()
            app.activate()
            // Accessory apps are often refused cooperative activation; the AX request is authoritative.
            let ax = AXUIElementSetAttributeValue(element, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
            if ax != .success {
                log.error("AX frontmost failed for \(app.bundleIdentifier ?? "?", privacy: .public): \(ax.rawValue)")
            }
        }

        guard let png = await encode(image, to: file, maxLongEdge: maxLongEdge) else {
            return .failed(reason: "couldn't save the capture")
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // Path mode is text only: terminals paste it and Claude Code / Codex attach the file.
        // (An image type alongside could be grabbed by image-aware terminals instead.)
        let wrote = target?.harness.paste == .path
            ? pasteboard.setString(file.path, forType: .string)
            : pasteboard.setData(png, forType: .png)
        guard wrote else { return .failed(reason: "couldn't write to the clipboard") }
        let ourClipboard = pasteboard.changeCount
        // Only promise "it's on your clipboard" while it still is.
        func fallback(_ reason: String) -> Outcome {
            pasteboard.changeCount == ourClipboard ? .clipboardOnly(reason: reason) : .failed(reason: "clipboard changed before pasting")
        }

        guard let (app, harness) = target, let element else {
            return fallback("no harness is running")
        }
        let name = app.localizedName ?? harness.name ?? harness.bundleId
        guard AXIsProcessTrusted() else {
            return fallback("grant Accessibility to paste into \(name)")
        }
        guard await waitUntil(timeout: .seconds(1), { isFrontmost(app) }) else {
            return fallback("couldn't focus \(name)")
        }
        // A running harness with its windows closed or minimized would swallow ⌘V silently.
        var windowStatus = AXError.success
        guard await waitUntil(timeout: .milliseconds(500), { windowStatus = focusedWindow(element); return windowStatus == .success }) else {
            log.notice("no focused window in \(harness.bundleId, privacy: .public): AXError \(windowStatus.rawValue)")
            return fallback(windowProblem(name, windowStatus))
        }
        try? await Task.sleep(for: .milliseconds(80)) // let the window hand focus back to its composer
        // ⌥⇧ from the hotkey still held would turn ⌘V into ⌥⇧⌘V ("Paste and Match Style").
        guard await waitUntil(timeout: .milliseconds(1500), modifiersReleased) else {
            return fallback("hotkey still held")
        }
        // Final re-check with no suspension point before posting. The AX query (≤0.25 s) goes first
        // so the cheap frontmost/clipboard checks are the very last thing before ⌘V.
        windowStatus = focusedWindow(element)
        guard windowStatus == .success else { return fallback(windowProblem(name, windowStatus)) }
        guard isFrontmost(app) else { return fallback("focus moved away from \(name)") }
        guard pasteboard.changeCount == ourClipboard else { return .failed(reason: "clipboard changed before pasting") }
        await pressCommandV(to: app.processIdentifier)
        return .pasted(into: name)
    }

    /// PNG-encodes off the main thread (downscaling past `maxLongEdge`) and writes it to `file`,
    /// which path-mode terminals read when the path is pasted.
    private static func encode(_ image: CGImage, to file: URL, maxLongEdge: Int) async -> Data? {
        let box = ImageBox(image)
        let png = await Task.detached(priority: .userInitiated) { pngData(box.image, maxLongEdge: maxLongEdge) }.value
        guard let png, (try? png.write(to: file, options: .atomic)) != nil else { return nil }
        return png
    }

    private nonisolated static func pngData(_ image: CGImage, maxLongEdge: Int) -> Data? {
        var image = image
        if let size = Geometry.fittedSize(width: image.width, height: image.height, maxLongEdge: maxLongEdge),
           let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB),
           let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
                                   space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
            image = context.makeImage() ?? image
        }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    /// Where the thrown shot should land: the composer zone of the harness's focused window.
    static func landingPoint(in app: NSRunningApplication) -> CGPoint? {
        let element = axElement(for: app)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window) == .success
                || AXUIElementCopyAttributeValue(element, kAXMainWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID()
        else { return nil }
        let w = window as! AXUIElement
        var position = CGPoint.zero, size = CGSize.zero
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &value) == .success,
              let pos = value, AXValueGetValue(pos as! AXValue, .cgPoint, &position),
              AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &value) == .success,
              let sz = value, AXValueGetValue(sz as! AXValue, .cgSize, &size),
              let primary = NSScreen.screens.first
        else { return nil }
        return Geometry.landingPoint(windowTopLeft: CGRect(origin: position, size: size), primaryHeight: primary.frame.height)
    }

    private static func axElement(for app: NSRunningApplication) -> AXUIElement {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.25) // never hang on a beachballing app
        return element
    }

    private static func isFrontmost(_ app: NSRunningApplication) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
    }

    /// `.success` only if the app reports a focused window; `.noValue` if it has none.
    private static func focusedWindow(_ element: AXUIElement) -> AXError {
        var window: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &window)
        return status == .success && window == nil ? .noValue : status
    }

    private static func windowProblem(_ name: String, _ status: AXError) -> String {
        switch status {
        case .cannotComplete: "\(name) isn't responding" // AX timed out: app busy or hung
        case .noValue: "\(name) has no open window"
        default: "\(name) has no focused window (AX error \(status.rawValue))"
        }
    }

    private static func modifiersReleased() -> Bool {
        let held: CGEventFlags = [.maskCommand, .maskAlternate, .maskShift, .maskControl]
        return CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty
    }

    /// Polls `condition` every 10 ms (only during a delivery) until true or timeout.
    private static func waitUntil(timeout: Duration, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// ⌘V aimed at `pid`. A private source keeps the chord out of the session modifier
    /// table (Command would otherwise stick), and a zero suppression interval keeps
    /// the prompt the user types next from being eaten.
    private static func pressCommandV(to pid: pid_t) async {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        let vKey = KeyboardLayout.keyCode(for: "v", fallback: 9) // 9 = V on ANSI/QWERTY
        // 0x8 = left-⌘ device bit; a few apps check it in addition to the generic flag.
        let flags = CGEventFlags.maskCommand.union(CGEventFlags(rawValue: 0x8))
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: keyDown)
            event?.flags = flags
            event?.postToPid(pid)
            if keyDown { try? await Task.sleep(for: .milliseconds(10)) }
        }
    }
}

/// CGImage is immutable and thread-safe; this just carries it across the detached encode.
private struct ImageBox: @unchecked Sendable {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}
