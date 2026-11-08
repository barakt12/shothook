#if DEBUG
import AppKit
import ImageIO
import ShothookCore

/// Debug builds only: `shothook://debug-*` URLs that synthesize real input, so the overlay,
/// chords and delivery can be exercised end to end without a human at the keyboard.
/// Points are "x,y" in global top-left (CG) coordinates.
extension AppDelegate {
    func debugHook(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let q = Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
        func point(_ s: String?) -> CGPoint? {
            guard let parts = s?.split(separator: ",").compactMap({ Double($0) }), parts.count == 2 else { return nil }
            return CGPoint(x: parts[0], y: parts[1])
        }
        switch url.host() {
        case "debug-deliver": // ?file=/abs.png — send it as if snipped from the middle of the main screen
            guard let path = q["file"],
                  let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
                  let screen = NSScreen.main else { return }
            let rect = CGRect(x: screen.frame.midX - 200, y: screen.frame.midY - 100, width: 400, height: 200)
            Task { await send(image, from: rect, on: screen) }
        case "debug-move":
            if let p = point(q["to"]) { postMouse(.mouseMoved, p) }
        case "debug-drag": // ?from=&to=[&hold=1 leaves the button down for screenshots]
            guard let a = point(q["from"]), let b = point(q["to"]) else { return }
            Task {
                postMouse(.mouseMoved, a)
                try? await Task.sleep(for: .milliseconds(60))
                postMouse(.leftMouseDown, a)
                for i in 1...12 {
                    try? await Task.sleep(for: .milliseconds(16))
                    let t = Double(i) / 12
                    postMouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t))
                }
                if q["hold"] == nil { postMouse(.leftMouseUp, b) }
            }
        case "debug-up":
            if let p = point(q["at"]) { postMouse(.leftMouseUp, p) }
        case "debug-click":
            if let p = point(q["at"]) {
                Task {
                    postMouse(.mouseMoved, p)
                    try? await Task.sleep(for: .milliseconds(60))
                    postMouse(.leftMouseDown, p)
                    postMouse(.leftMouseUp, p)
                }
            }
        case "debug-key": // ?code=53 (Esc)
            if let code = UInt16(q["code"] ?? "") {
                for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)?.post(tap: .cghidEventTap) }
            }
        case "debug-record": // ?mode=screen|region — opens the shortcut recorder
            recordShortcut(for: CaptureMode(rawValue: q["mode"] ?? "") ?? .screen)
        case "debug-close-windows": // closes any recorder panel (cancel path)
            NSApp.windows.filter { $0.title.hasPrefix("Shortcut for") }.forEach { $0.performClose(nil) }
        case "debug-chord": // ?keys=lshift,rshift[,lcmd] — pressed in order, released in reverse
            let names = (q["keys"] ?? "").split(separator: ",").map(String.init)
            Task { await postChord(names) }
        default:
            break
        }
    }

    private func postMouse(_ type: CGEventType, _ p: CGPoint) {
        CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
    }

    private func postChord(_ names: [String]) async {
        let keys: [String: (code: CGKeyCode, device: UInt64, flag: CGEventFlags)] = [
            "lshift": (56, 0x2, .maskShift), "rshift": (60, 0x4, .maskShift),
            "lcmd": (55, 0x8, .maskCommand), "rcmd": (54, 0x10, .maskCommand),
        ]
        var device: UInt64 = 0
        func emit(_ code: CGKeyCode) {
            var flags = CGEventFlags(rawValue: device)
            for key in keys.values where device & key.device != 0 { flags.insert(key.flag) }
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)
            event?.type = .flagsChanged
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
        for name in names {
            guard let key = keys[name] else { continue }
            device |= key.device
            emit(key.code)
            try? await Task.sleep(for: .milliseconds(40))
        }
        for name in names.reversed() {
            guard let key = keys[name] else { continue }
            device &= ~key.device
            emit(key.code)
            try? await Task.sleep(for: .milliseconds(40))
        }
    }
}
#endif
