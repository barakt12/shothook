import CoreGraphics

public enum Geometry {
    /// Converts a Cocoa screen frame (origin bottom-left of the primary display, y up)
    /// into the global top-left coordinate space `screencapture -R` expects.
    public static func topLeftRect(for cocoaFrame: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cocoaFrame.minX, y: primaryHeight - cocoaFrame.maxY,
               width: cocoaFrame.width, height: cocoaFrame.height)
    }

    /// `x,y,w,h` argument for `screencapture -R`.
    public static func regionArgument(_ r: CGRect) -> String {
        [r.minX, r.minY, r.width, r.height].map { String(Int($0.rounded())) }.joined(separator: ",")
    }

    /// The rectangle spanned by a drag, whichever direction it went.
    public static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    /// Pixel rect (top-left origin) inside a screen's captured image for a Cocoa-space selection.
    /// Clamped to the screen; integral so cropping never lands between pixels.
    public static func pixelRect(of selection: CGRect, in screen: CGRect, imageWidth: Int, imageHeight: Int) -> CGRect {
        let clipped = selection.intersection(screen)
        guard !clipped.isNull, screen.width > 0, screen.height > 0 else { return .zero }
        let sx = CGFloat(imageWidth) / screen.width, sy = CGFloat(imageHeight) / screen.height
        let r = CGRect(x: (clipped.minX - screen.minX) * sx, y: (screen.maxY - clipped.maxY) * sy,
                       width: clipped.width * sx, height: clipped.height * sy)
        return r.integral.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    }

    /// Where a thrown shot should land in a harness window (CG/top-left frame): bottom-center,
    /// where chat composers and terminal prompts live. Returned in Cocoa coordinates.
    public static func landingPoint(windowTopLeft w: CGRect, primaryHeight: CGFloat) -> CGPoint {
        let bottom = primaryHeight - w.maxY
        return CGPoint(x: w.midX, y: bottom + min(64, w.height * 0.3))
    }

    /// Target pixel size when an image's long edge exceeds `maxLongEdge`; nil if it fits.
    public struct PixelSize: Equatable, Sendable {
        public let width: Int, height: Int
        public init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
    }

    public static func fittedSize(width: Int, height: Int, maxLongEdge: Int) -> PixelSize? {
        let long = max(width, height)
        guard maxLongEdge > 0, long > maxLongEdge else { return nil }
        let scale = Double(maxLongEdge) / Double(long)
        return PixelSize(Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded()))
    }
}
