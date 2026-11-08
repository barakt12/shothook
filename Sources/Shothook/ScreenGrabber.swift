import AppKit
import ImageIO
import ScreenCaptureKit
import ShothookCore

enum CaptureMode: String {
    case region, screen
}

/// One display, frozen: what it looked like the instant the hotkey fired.
struct Frame {
    let screen: NSScreen
    let image: CGImage

    /// Cocoa-space frame of the display (points).
    var rect: CGRect { screen.frame }
}

/// Grabs displays in-process with ScreenCaptureKit (macOS 15.2+, ~tens of ms, no PNG round trip),
/// falling back to the `screencapture` tool on older systems.
enum ScreenGrabber {
    enum Failure: Error, CustomStringConvertible {
        case noDisplay, permission, other(String)

        var description: String {
            switch self {
            case .noDisplay: "no display found"
            case .permission: "grant Screen Recording to Shothook"
            case .other(let message): message
            }
        }
    }

    static func grab(_ screens: [NSScreen]) async throws(Failure) -> [Frame] {
        guard let primary = NSScreen.screens.first, !screens.isEmpty else { throw .noDisplay }
        var frames: [Frame] = []
        for screen in screens {
            // Display space is top-left based, anchored on the primary display.
            let rect = Geometry.topLeftRect(for: screen.frame, primaryHeight: primary.frame.height)
            guard let image = await capture(rect) else {
                throw CGPreflightScreenCaptureAccess() ? .other("couldn't capture the screen") : .permission
            }
            frames.append(Frame(screen: screen, image: image))
        }
        return frames
    }

    static func screenUnderMouse() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main ?? NSScreen.screens.first
    }

    private static func capture(_ rect: CGRect) async -> CGImage? {
        if #available(macOS 15.2, *) {
            return try? await SCScreenshotManager.captureImage(in: rect)
        }
        return await captureWithTool(rect)
    }

    private static func captureWithTool(_ rect: CGRect) async -> CGImage? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shothook-grab-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-t", "png", "-R", Geometry.regionArgument(rect), url.path]
        let ran = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
            process.terminationHandler = { _ in done.resume(returning: true) }
            do { try process.run() } catch {
                process.terminationHandler = nil
                done.resume(returning: false)
            }
        }
        guard ran, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}
