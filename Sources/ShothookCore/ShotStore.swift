import Foundation

/// Where shots live: `$TMPDIR/shothook/shot-*.png`. Terminal harnesses read the file by
/// path when the path is pasted, so files must outlive the paste; they're pruned after a day.
public struct ShotStore: Sendable {
    public let directory: URL

    public init(directory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("shothook", isDirectory: true)) {
        self.directory = directory
    }

    public func newShotURL(now: Date = Date(), createDirectory: Bool = true) throws -> URL {
        if createDirectory {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let stamp = Self.stamp(from: now)
        let suffix = UUID().uuidString.prefix(6).lowercased()
        return directory.appendingPathComponent("shot-\(stamp)-\(suffix).png")
    }

    /// Deletes `shot-*.png` files older than `age` seconds. Never touches anything else.
    public func prune(olderThan age: TimeInterval = 86_400, now: Date = Date()) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for url in urls where url.lastPathComponent.hasPrefix("shot-") && url.pathExtension == "png" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? now
            if now.timeIntervalSince(modified) > age {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// A fresh formatter per call: DateFormatter is a mutable class, and this type is Sendable.
    private static func stamp(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }
}
