import AppKit
import QuartzCore
import ShothookCore

/// The viewfinder. Freezes every display, dims it, and follows the pointer with a pixel loupe.
/// Hovering a window wraps it in viewfinder brackets that glide from window to window.
/// Click = that window · drag = a region · click the desktop = the whole display · Esc = cancel.
final class RegionOverlay {
    struct Selection {
        let frame: Frame
        let rect: CGRect // Cocoa global points, within frame.rect
    }

    private struct Window {
        let rect: CGRect // Cocoa global points
        let name: String
    }

    private let frames: [Frame]
    private let windows: [Window]
    private var stages: [OverlayStage] = []
    private var continuation: CheckedContinuation<Selection?, Never>?
    private var dragStart: CGPoint?
    private var dragging = false
    private var hovered: Window?

    init(frames: [Frame]) {
        self.frames = frames
        windows = Self.visibleWindows() // taken before our own panels exist
    }

    func run() async -> Selection? {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            stages = frames.map { OverlayStage(frame: $0, overlay: self) }
            let mouse = NSEvent.mouseLocation
            for stage in stages { stage.present(at: mouse) }
            (stages.first { NSMouseInRect(mouse, $0.frame, false) } ?? stages.first)?.makeKey()
            pointerMoved(to: mouse, animated: true)
        }
    }

    // MARK: Pointer (all points are Cocoa global)

    func pointerMoved(to p: CGPoint, animated: Bool = true) {
        if !dragging {
            let window = windows.first { $0.rect.contains(p) }
            let changed = window?.rect != hovered?.rect
            hovered = window
            render(p, animated: animated && changed)
        }
    }

    func pointerDown(at p: CGPoint) {
        dragStart = p
        dragging = false
    }

    func pointerDragged(to p: CGPoint) {
        guard let start = dragStart else { return }
        if !dragging, hypot(p.x - start.x, p.y - start.y) < 4 { return } // hysteresis: a click isn't a drag
        if !dragging { dragging = true; hovered = nil }
        render(p, animated: false) // 1:1 with the pointer
    }

    func pointerUp(at p: CGPoint) {
        defer { dragStart = nil; dragging = false }
        guard let frame = frame(at: dragStart ?? p) else { return }
        if dragging, let start = dragStart {
            let rect = Geometry.rect(from: start, to: p).intersection(frame.rect)
            if rect.width >= 4, rect.height >= 4 { finish(Selection(frame: frame, rect: rect)) }
            return
        }
        // A click: the window under it, or the whole display over the desktop.
        let rect = (hovered?.rect ?? frame.rect).intersection(frame.rect)
        finish(Selection(frame: frame, rect: rect))
    }

    func cancel() {
        finish(nil)
    }

    // MARK: Rendering

    private func render(_ p: CGPoint, animated: Bool) {
        var hole: CGRect?
        var label: String?
        if dragging, let start = dragStart, let frame = frame(at: start) {
            let r = Geometry.rect(from: start, to: p).intersection(frame.rect)
            hole = r
            label = "\(Int(r.width.rounded())) × \(Int(r.height.rounded()))"
        } else if let hovered {
            hole = hovered.rect
            label = hovered.name
        }
        for stage in stages {
            stage.view.update(hole: hole, label: label, pointer: p, animated: animated)
        }
    }

    private func finish(_ selection: Selection?) {
        guard let continuation else { return }
        self.continuation = nil
        for stage in stages { stage.dismiss(fast: selection == nil) }
        stages.removeAll()
        continuation.resume(returning: selection)
    }

    private func frame(at p: CGPoint) -> Frame? {
        frames.first { NSMouseInRect(p, $0.rect, false) }
    }

    /// On-screen app windows, front to back, in Cocoa coordinates. Bounds need no extra permission.
    private static func visibleWindows() -> [Window] {
        guard let primary = NSScreen.screens.first,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return list.compactMap { info in
            guard info[kCGWindowLayer as String] as? Int == 0,
                  info[kCGWindowOwnerPID as String] as? Int32 != me,
                  (info[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let dict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict),
                  bounds.width >= 40, bounds.height >= 40
            else { return nil }
            // topLeftRect is its own inverse: it maps CG (top-left) bounds back to Cocoa too.
            return Window(rect: Geometry.topLeftRect(for: bounds, primaryHeight: primary.frame.height),
                          name: info[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

/// One display's overlay window. Non-activating, so the app you were in keeps focus.
final class OverlayStage: NSPanel {
    let view: OverlayView
    private weak var overlay: RegionOverlay?

    init(frame: Frame, overlay: RegionOverlay) {
        view = OverlayView(frame: frame, overlay: overlay)
        self.overlay = overlay
        super.init(contentRect: frame.rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(self)
        acceptsMouseMovedEvents = true
        contentView = view
        setFrame(frame.rect, display: false)
    }

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { overlay?.cancel() } // Esc
    override func rightMouseDown(with event: NSEvent) { overlay?.cancel() }

    func present(at pointer: CGPoint) {
        view.prepare(pointer: pointer)
        orderFrontRegardless()
    }

    func dismiss(fast: Bool) {
        ignoresMouseEvents = true
        view.fadeOut(duration: fast ? 0.12 : 0.22) { [weak self] in self?.close() }
    }
}

/// Shared setup for Shothook's full-screen, click-through-capable overlay panels.
func configureAsOverlay(_ panel: NSPanel) {
    panel.level = .screenSaver // above the menu bar and Dock
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
}

final class OverlayView: NSView {
    private weak var overlay: RegionOverlay?
    private let shot: Frame
    private let content = CALayer()
    private let frozen = CALayer()
    private let dim = CAShapeLayer()
    private let outline = CAShapeLayer()
    private let brackets = CAShapeLayer()
    private let pill = CALayer()
    private let pillText = CATextLayer()
    private let loupe = CALayer()
    private let loupeImage = CALayer()
    private let loupeMarks = CAShapeLayer()

    private static let loupeSize: CGFloat = 116
    private static let zoom: CGFloat = 8

    init(frame shot: Frame, overlay: RegionOverlay) {
        self.shot = shot
        self.overlay = overlay
        super.init(frame: CGRect(origin: .zero, size: shot.rect.size))
        layer = CALayer() // layer-hosting: we own the tree
        wantsLayer = true
        buildLayers()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Events

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .cursorUpdate, .activeAlways, .inVisibleRect], owner: self))
    }

    override func cursorUpdate(with event: NSEvent) { NSCursor.crosshair.set() }
    override func mouseMoved(with event: NSEvent) { NSCursor.crosshair.set(); overlay?.pointerMoved(to: NSEvent.mouseLocation) }
    override func mouseDown(with event: NSEvent) { overlay?.pointerDown(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { overlay?.pointerDragged(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { overlay?.pointerUp(at: NSEvent.mouseLocation) }

    // MARK: Layers

    private var scale: CGFloat { shot.screen.backingScaleFactor }

    private func buildLayers() {
        guard let root = layer else { return }
        content.frame = bounds
        root.addSublayer(content)

        frozen.frame = bounds
        frozen.contents = shot.image
        frozen.contentsGravity = .resize
        content.addSublayer(frozen)

        dim.frame = bounds
        dim.fillRule = .evenOdd
        dim.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        content.addSublayer(dim)

        outline.fillColor = nil
        outline.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
        outline.lineWidth = 1
        content.addSublayer(outline)

        brackets.fillColor = nil
        brackets.strokeColor = NSColor.white.cgColor
        brackets.lineWidth = 3
        brackets.lineCap = .round
        brackets.lineJoin = .round
        brackets.shadowColor = NSColor.black.cgColor
        brackets.shadowOpacity = 0.45
        brackets.shadowRadius = 3
        brackets.shadowOffset = .zero
        content.addSublayer(brackets)

        pill.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        pill.borderColor = NSColor.white.withAlphaComponent(0.14).cgColor
        pill.borderWidth = 0.5
        pill.opacity = 0
        pillText.contentsScale = scale
        pillText.alignmentMode = .center
        pill.addSublayer(pillText)
        content.addSublayer(pill)

        let s = Self.loupeSize
        loupe.bounds = CGRect(x: 0, y: 0, width: s, height: s)
        loupe.shadowColor = NSColor.black.cgColor
        loupe.shadowOpacity = 0.4
        loupe.shadowRadius = 10
        loupe.shadowOffset = CGSize(width: 0, height: -4)
        loupe.opacity = 0
        loupeImage.frame = loupe.bounds
        loupeImage.contents = shot.image
        loupeImage.magnificationFilter = .nearest // crisp pixels
        loupeImage.cornerRadius = s / 2
        loupeImage.masksToBounds = true
        loupeImage.borderColor = NSColor.white.cgColor
        loupeImage.borderWidth = 3
        loupe.addSublayer(loupeImage)
        loupeMarks.frame = loupe.bounds
        loupeMarks.fillColor = nil
        loupeMarks.strokeColor = NSColor.white.withAlphaComponent(0.9).cgColor
        loupeMarks.lineWidth = 1.5
        loupeMarks.shadowColor = NSColor.black.cgColor
        loupeMarks.shadowOpacity = 0.6
        loupeMarks.shadowRadius = 1
        loupeMarks.shadowOffset = .zero
        let px = Self.zoom / scale // one captured pixel, magnified
        let c = s / 2
        let marks = CGMutablePath()
        marks.addRect(CGRect(x: c - px / 2, y: c - px / 2, width: px, height: px))
        for (a, b) in [(CGPoint(x: 10, y: c), CGPoint(x: c - px, y: c)), (CGPoint(x: c + px, y: c), CGPoint(x: s - 10, y: c)),
                       (CGPoint(x: c, y: 10), CGPoint(x: c, y: c - px)), (CGPoint(x: c, y: c + px), CGPoint(x: c, y: s - 10))] {
            marks.move(to: a)
            marks.addLine(to: b)
        }
        loupeMarks.path = marks
        loupeMarks.opacity = 0.75
        loupe.addSublayer(loupeMarks)
        content.addSublayer(loupe)
    }

    /// Initial state + entrance: the dim and loupe ease in over the frozen screen.
    func prepare(pointer: CGPoint) {
        let local = toLocal(pointer)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let start = CGRect(origin: local, size: .zero)
        dim.path = dimPath(start)
        brackets.path = bracketPath(start)
        outline.path = CGPath(rect: start, transform: nil)
        brackets.opacity = 0
        outline.opacity = 0
        CATransaction.commit()

        dim.add(fade(from: 0, to: 1, duration: 0.18), forKey: "in")
        if bounds.contains(local) {
            let pop = CASpringAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.5
            pop.toValue = 1
            pop.damping = 18
            pop.stiffness = 260
            pop.duration = pop.settlingDuration
            loupe.add(pop, forKey: "in")
        }
    }

    func update(hole: CGRect?, label: String?, pointer: CGPoint, animated: Bool) {
        let p = toLocal(pointer)
        let onThisScreen = bounds.contains(p)
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        // Hole + brackets: glide between windows, track drags 1:1.
        let target = hole.map { $0.offsetBy(dx: -shot.rect.minX, dy: -shot.rect.minY) } ?? CGRect(origin: p, size: .zero)
        let duration: CFTimeInterval = animated ? 0.2 : 0
        set(dim, path: dimPath(target), duration: duration)
        set(brackets, path: bracketPath(target), duration: duration)
        set(outline, path: CGPath(rect: target, transform: nil), duration: duration)
        let visible: Float = hole == nil || !bounds.intersects(target) ? 0 : 1
        if brackets.opacity != visible {
            brackets.add(fade(from: brackets.presentation()?.opacity ?? brackets.opacity, to: visible, duration: 0.15), forKey: "opacity")
            outline.add(fade(from: outline.presentation()?.opacity ?? outline.opacity, to: visible, duration: 0.15), forKey: "opacity")
        }
        brackets.opacity = visible
        outline.opacity = visible

        layoutPill(label, under: target, visible: visible == 1)
        layoutLoupe(at: p, visible: onThisScreen)
        CATransaction.commit()
    }

    func fadeOut(duration: CFTimeInterval, completion: @escaping () -> Void) {
        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        content.add(fade(from: 1, to: 0, duration: duration), forKey: "out")
        content.opacity = 0
        CATransaction.commit()
    }

    // MARK: Pieces

    private func layoutPill(_ label: String?, under hole: CGRect, visible: Bool) {
        guard visible, let label, !label.isEmpty else { pill.opacity = 0; return }
        let text = NSAttributedString(string: label, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white,
        ])
        let size = text.size()
        let w = ceil(size.width) + 20, h = ceil(size.height) + 8
        var origin = CGPoint(x: hole.minX, y: hole.minY - h - 8)
        if origin.y < 8 { origin.y = hole.minY + 8 } // no room below: tuck inside
        origin.x = min(max(8, origin.x), bounds.width - w - 8)
        pill.frame = CGRect(origin: origin, size: CGSize(width: w, height: h))
        pill.cornerRadius = h / 2
        pillText.string = text
        pillText.frame = CGRect(x: 0, y: (h - ceil(size.height)) / 2, width: w, height: ceil(size.height))
        pill.opacity = 1
    }

    private func layoutLoupe(at p: CGPoint, visible: Bool) {
        loupe.opacity = visible ? 1 : 0
        guard visible else { return }
        let s = Self.loupeSize, gap: CGFloat = 22
        var center = CGPoint(x: p.x + gap + s / 2, y: p.y - gap - s / 2) // below-right of the pointer
        if center.x + s / 2 > bounds.maxX - 6 { center.x = p.x - gap - s / 2 }
        if center.y - s / 2 < bounds.minY + 6 { center.y = p.y + gap + s / 2 }
        loupe.position = center
        let span = s / Self.zoom // points of screen shown in the loupe
        loupeImage.contentsRect = CGRect(x: (p.x - span / 2) / bounds.width, y: (p.y - span / 2) / bounds.height,
                                         width: span / bounds.width, height: span / bounds.height)
    }

    private func dimPath(_ hole: CGRect) -> CGPath {
        let path = CGMutablePath()
        path.addRect(bounds)
        path.addRect(hole)
        return path
    }

    /// Viewfinder corners just outside `r`. Always the same element count, so paths interpolate.
    private func bracketPath(_ r: CGRect) -> CGPath {
        let o = r.insetBy(dx: -4, dy: -4)
        let l = max(6, min(24, o.width / 3, o.height / 3))
        let path = CGMutablePath()
        let corners: [(CGPoint, CGPoint, CGPoint)] = [
            (CGPoint(x: o.minX, y: o.maxY - l), CGPoint(x: o.minX, y: o.maxY), CGPoint(x: o.minX + l, y: o.maxY)),
            (CGPoint(x: o.maxX - l, y: o.maxY), CGPoint(x: o.maxX, y: o.maxY), CGPoint(x: o.maxX, y: o.maxY - l)),
            (CGPoint(x: o.maxX, y: o.minY + l), CGPoint(x: o.maxX, y: o.minY), CGPoint(x: o.maxX - l, y: o.minY)),
            (CGPoint(x: o.minX + l, y: o.minY), CGPoint(x: o.minX, y: o.minY), CGPoint(x: o.minX, y: o.minY + l)),
        ]
        for (a, b, c) in corners {
            path.move(to: a)
            path.addLine(to: b)
            path.addLine(to: c)
        }
        return path
    }

    /// Sets a path, animating from wherever it is on screen right now (interruptible).
    private func set(_ shape: CAShapeLayer, path: CGPath, duration: CFTimeInterval) {
        let from = shape.presentation()?.path ?? shape.path
        shape.path = path
        guard duration > 0, let from else { shape.removeAnimation(forKey: "path"); return }
        let a = CABasicAnimation(keyPath: "path")
        a.fromValue = from
        a.toValue = path
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1) // quick, soft landing
        shape.add(a, forKey: "path")
    }

    private func fade(from: Float, to: Float, duration: CFTimeInterval) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: "opacity")
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return a
    }

    private func toLocal(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x - shot.rect.minX, y: p.y - shot.rect.minY)
    }
}
