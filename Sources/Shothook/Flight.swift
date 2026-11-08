import AppKit
import QuartzCore

/// The throw. The captured area flashes like a shutter, lifts off the screen, and arcs into its
/// destination (the harness composer, or the menu-bar icon in clipboard mode) with a whoosh,
/// landing with a ripple and a whomp. Runs on the GPU; delivery happens in parallel.
enum Flight {
    static let duration: CFTimeInterval = 0.56
    private static let liftEnd = 0.17 // fraction of `duration` spent lifting before travel

    /// Returns at the moment of impact (so callers can sync feedback); cleans up shortly after.
    static func throwShot(_ image: CGImage, from rect: CGRect, on screen: NSScreen, to landing: CGPoint, sound: Bool) async {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let panel = NSPanel(contentRect: screen.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        configureAsOverlay(panel)
        panel.ignoresMouseEvents = true
        let host = NSView(frame: CGRect(origin: .zero, size: screen.frame.size))
        host.layer = CALayer()
        host.wantsLayer = true
        panel.contentView = host
        panel.setFrame(screen.frame, display: false)
        guard let root = host.layer else { return }

        let bounds = host.bounds
        let start = rect.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let rawEnd = CGPoint(x: landing.x - screen.frame.minX, y: landing.y - screen.frame.minY)
        let end = clamp(rawEnd, to: bounds.insetBy(dx: 18, dy: 18)) // off this display? aim for its edge

        panel.orderFrontRegardless()
        let now = CACurrentMediaTime()

        if reduceMotion {
            // No flight, no flash: a calm acknowledgement at the destination.
            ripple(in: root, at: end, beginTime: now)
            if sound { Sounds.whomp() }
            try? await Task.sleep(for: .milliseconds(150))
            close(panel, after: 0.5)
            return
        }

        let card = makeCard(image, frame: start)
        root.addSublayer(card)
        let photo = card.sublayers![0], shutter = photo.sublayers![0]

        let thumb = min(1, 96 / max(start.width, start.height)) // ~96pt on the long side, never enlarged
        let cardAnimations = CAAnimationGroup()
        cardAnimations.duration = duration
        cardAnimations.fillMode = .forwards
        cardAnimations.isRemovedOnCompletion = false
        cardAnimations.animations = [
            travel(from: CGPoint(x: start.midX, y: start.midY), to: end, within: bounds),
            keyframes("transform.scale", [1, 1.035, thumb, thumb * 0.15], [0, liftEnd, 0.88, 1]),
            keyframes("transform.rotation.z", [0, 0, -0.07, 0.03, 0], [0, liftEnd, 0.5, 0.82, 1]),
            keyframes("opacity", [1, 1, 0.94, 0.94, 0], [0, liftEnd, 0.4, 0.88, 1]), // big things travel a bit translucent
            keyframes("shadowOpacity", [0, 0.5, 0.35, 0], [0, liftEnd, 0.8, 1]),
            keyframes("shadowRadius", [0, 26, 12, 4], [0, liftEnd, 0.8, 1]),
        ]
        card.add(cardAnimations, forKey: "throw")
        // Visual corner radius ~12pt at full size, ~8pt as a thumbnail (radius scales with the card).
        photo.add(group(duration, [
            keyframes("cornerRadius", [0, 12, 8 / thumb], [0, liftEnd, 0.88]),
            keyframes("borderWidth", [0, 1.5, 2.5 / thumb], [0, liftEnd, 0.88]),
        ]), forKey: "shape")
        shutter.add(group(duration, [keyframes("opacity", [0, 0.6, 0], [0, 0.05, 0.3])]), forKey: "shutter")

        ripple(in: root, at: end, beginTime: now + duration * 0.9)
        if sound {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * liftEnd) { Sounds.whoosh() }
            DispatchQueue.main.asyncAfter(deadline: .now() + duration * 0.9) { Sounds.whomp() }
        }

        try? await Task.sleep(for: .seconds(duration * 0.9)) // impact
        close(panel, after: 0.55)
    }

    // MARK: Pieces

    private static func makeCard(_ image: CGImage, frame: CGRect) -> CALayer {
        let card = CALayer()
        card.frame = frame
        card.shadowColor = NSColor.black.cgColor
        card.shadowOffset = CGSize(width: 0, height: -10)
        card.shadowOpacity = 0
        let photo = CALayer()
        photo.frame = card.bounds
        photo.contents = image
        photo.contentsGravity = .resizeAspectFill
        photo.masksToBounds = true
        photo.borderColor = NSColor.white.withAlphaComponent(0.92).cgColor
        photo.borderWidth = 0
        let shutter = CALayer()
        shutter.frame = photo.bounds
        shutter.backgroundColor = NSColor.white.cgColor
        shutter.opacity = 0
        photo.addSublayer(shutter)
        card.addSublayer(photo)
        return card
    }

    /// Holds still while lifting, then a tossed arc that accelerates into the target.
    private static func travel(from a: CGPoint, to b: CGPoint, within bounds: CGRect) -> CAAnimation {
        let distance = hypot(b.x - a.x, b.y - a.y)
        var control = CGPoint(x: (a.x + b.x) / 2, y: max(a.y, b.y) + min(160, distance * 0.3))
        control.y = min(control.y, bounds.maxY - 40)
        let path = CGMutablePath()
        path.move(to: a)
        path.addQuadCurve(to: b, control: control)
        let move = CAKeyframeAnimation(keyPath: "position")
        move.path = path
        move.beginTime = duration * liftEnd
        move.duration = duration * (1 - liftEnd)
        move.timingFunction = CAMediaTimingFunction(controlPoints: 0.45, 0, 0.7, 0.5)
        move.fillMode = .both
        return move
    }

    /// The landing: an accent-colored ring and a soft glow bloom out from the impact point.
    private static func ripple(in root: CALayer, at p: CGPoint, beginTime: CFTimeInterval) {
        let accent = NSColor.controlAccentColor
        for (radius, stroke, fill, scale, life) in [(CGFloat(26), CGFloat(3), 0.0, CGFloat(1.9), 0.45),
                                                     (CGFloat(18), CGFloat(0), 0.35, CGFloat(1.4), 0.35)] {
            let ring = CAShapeLayer()
            ring.path = CGPath(ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
            ring.position = p
            ring.fillColor = fill > 0 ? accent.withAlphaComponent(fill).cgColor : nil
            ring.strokeColor = stroke > 0 ? accent.cgColor : nil
            ring.lineWidth = stroke
            ring.opacity = 0 // invisible until its moment
            root.addSublayer(ring)
            let bloom = group(life, [
                keyframes("transform.scale", [0.25, scale], [0, 1]),
                keyframes("opacity", [1, 0], [0, 1]),
            ])
            bloom.beginTime = beginTime
            bloom.timingFunction = CAMediaTimingFunction(name: .easeOut)
            ring.add(bloom, forKey: "ripple")
        }
    }

    private static func keyframes(_ keyPath: String, _ values: [Any], _ times: [Double]) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.calculationMode = .linear
        a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: .easeInEaseOut), count: max(1, values.count - 1))
        return a
    }

    private static func group(_ duration: CFTimeInterval, _ animations: [CAAnimation]) -> CAAnimationGroup {
        let g = CAAnimationGroup()
        g.animations = animations
        g.duration = duration
        g.fillMode = .forwards
        g.isRemovedOnCompletion = false
        return g
    }

    private static func clamp(_ p: CGPoint, to r: CGRect) -> CGPoint {
        CGPoint(x: min(max(p.x, r.minX), r.maxX), y: min(max(p.y, r.minY), r.maxY))
    }

    private static func close(_ panel: NSPanel, after seconds: Double) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { panel.close() }
    }
}

/// The whoosh (lift-off) and whomp (landing). Tiny bundled WAVs, loaded once.
enum Sounds {
    private static let whooshSound = load("whoosh")
    private static let whompSound = load("whomp")

    static func whoosh() { play(whooshSound) }
    static func whomp() { play(whompSound) }

    private static func load(_ name: String) -> NSSound? {
        Bundle.main.url(forResource: name, withExtension: "wav").flatMap { NSSound(contentsOf: $0, byReference: true) }
    }

    private static func play(_ sound: NSSound?) {
        guard let sound else { return }
        sound.stop()
        sound.play()
    }
}
