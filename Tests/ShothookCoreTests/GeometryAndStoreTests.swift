import CoreGraphics
import Foundation
import Testing
@testable import ShothookCore

struct GeometryTests {
    @Test func primaryScreenMapsToOrigin() {
        let r = Geometry.topLeftRect(for: CGRect(x: 0, y: 0, width: 1512, height: 982), primaryHeight: 982)
        #expect(r == CGRect(x: 0, y: 0, width: 1512, height: 982))
        #expect(Geometry.regionArgument(r) == "0,0,1512,982")
    }

    @Test func externalScreenAboveAndLeftFlipsY() {
        // A 1920x1080 display placed above-left of a 1512x982 primary (Cocoa: y grows upward).
        let r = Geometry.topLeftRect(for: CGRect(x: -400, y: 982, width: 1920, height: 1080), primaryHeight: 982)
        #expect(r == CGRect(x: -400, y: -1080, width: 1920, height: 1080))
        #expect(Geometry.regionArgument(r) == "-400,-1080,1920,1080")
    }

    @Test func fittedSizeOnlyShrinksOversizedImages() {
        #expect(Geometry.fittedSize(width: 1000, height: 500, maxLongEdge: 2560) == nil)
        #expect(Geometry.fittedSize(width: 6048, height: 3928, maxLongEdge: 2560) == .init(2560, 1663))
        #expect(Geometry.fittedSize(width: 1000, height: 4000, maxLongEdge: 2000) == .init(500, 2000))
        #expect(Geometry.fittedSize(width: 6048, height: 3928, maxLongEdge: 0) == nil)
    }
}

struct ShotStoreTests {
    @Test func prunesOnlyOldShots() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shothook-test-\(UUID().uuidString)")
        let store = ShotStore(directory: dir)
        let now = Date()
        let fresh = try store.newShotURL(now: now)
        let stale = dir.appendingPathComponent("shot-old.png")
        let unrelated = dir.appendingPathComponent("notes.txt")
        for url in [fresh, stale, unrelated] { try Data("x".utf8).write(to: url) }
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: stale.path)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-90_000)], ofItemAtPath: unrelated.path)

        store.prune(olderThan: 86_400, now: now)

        #expect(FileManager.default.fileExists(atPath: fresh.path))
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path), "never touch files shothook didn't create")
        try? FileManager.default.removeItem(at: dir)
    }

    @Test func shotPathsAreUniqueAndShellSafe() throws {
        let store = ShotStore(directory: URL(fileURLWithPath: "/tmp/shothook-x"))
        let now = Date()
        let a = try store.newShotURL(now: now, createDirectory: false)
        let b = try store.newShotURL(now: now, createDirectory: false)
        #expect(a != b)
        #expect(!a.lastPathComponent.contains(" "))
        #expect(a.pathExtension == "png")
    }
}
