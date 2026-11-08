import CoreGraphics
import Testing
@testable import ShothookCore

struct SelectionGeometryTests {
    @Test func dragRectIsNormalizedInAnyDirection() {
        let r = Geometry.rect(from: CGPoint(x: 300, y: 100), to: CGPoint(x: 100, y: 250))
        #expect(r == CGRect(x: 100, y: 100, width: 200, height: 150))
    }

    @Test func pixelRectFlipsAndScales() {
        // Primary 1512×982 pt screen captured at 2× (3024×1964 px). Cocoa selection near the top-left.
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let selection = CGRect(x: 10, y: 882, width: 200, height: 50) // top edge at y=932 → 50pt from the top
        let px = Geometry.pixelRect(of: selection, in: screen, imageWidth: 3024, imageHeight: 1964)
        #expect(px == CGRect(x: 20, y: 100, width: 400, height: 100))
    }

    @Test func pixelRectOnSecondaryScreenAndClamped() {
        // 1920×1080 @1× display to the right of the primary; selection hangs off its right edge.
        let screen = CGRect(x: 1512, y: 0, width: 1920, height: 1080)
        let selection = CGRect(x: 3300, y: 0, width: 300, height: 100)
        let px = Geometry.pixelRect(of: selection, in: screen, imageWidth: 1920, imageHeight: 1080)
        #expect(px == CGRect(x: 1788, y: 980, width: 132, height: 100))
    }

    @Test func landingPointSitsInTheComposerZone() {
        // A 1000×800 window whose top-left (CG coords) is at (100, 50) on a 982pt-tall primary.
        let p = Geometry.landingPoint(windowTopLeft: CGRect(x: 100, y: 50, width: 1000, height: 800), primaryHeight: 982)
        #expect(p.x == 600)
        #expect(p.y == CGFloat(196)) // 64pt above the window bottom (982 - 850 + 64)
    }

    @Test func landingPointInSmallWindowStaysInside() {
        let p = Geometry.landingPoint(windowTopLeft: CGRect(x: 0, y: 0, width: 300, height: 100), primaryHeight: 1000)
        #expect(p.y > 900 && p.y < 1000)
    }
}
