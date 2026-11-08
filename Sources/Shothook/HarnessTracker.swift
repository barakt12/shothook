import AppKit
import ShothookCore

/// Remembers which configured harness you used last, purely from app-activation
/// notifications (no polling).
final class HarnessTracker {
    private var mru = MRUList()
    private var config: Config
    private var observer: (any NSObjectProtocol)?

    init(config: Config) {
        self.config = config
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { if let id { self?.activated(id) } }
        }
        if let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier { activated(front) }
    }

    func update(config: Config) {
        self.config = config
    }

    private func activated(_ bundleId: String) {
        if config.harness(for: bundleId) != nil { mru.touch(bundleId) }
    }

    /// Where the next shot goes, or nil if no configured harness is running.
    func target() -> (app: NSRunningApplication, harness: Harness)? {
        let configured = config.harnesses.map(\.bundleId)
        let running = NSWorkspace.shared.runningApplications.filter { !$0.isTerminated }
        let runningIDs = Set(running.compactMap(\.bundleIdentifier)).intersection(configured)
        guard let id = mru.resolve(running: runningIDs, fallbackOrder: configured),
              let harness = config.harness(for: id),
              let app = running.first(where: { $0.bundleIdentifier == id })
        else { return nil }
        return (app, harness)
    }
}
