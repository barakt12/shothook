import Testing
@testable import ShothookCore

struct RoutingTests {
    @Test func mostRecentlyUsedRunningHarnessWins() {
        var mru = MRUList()
        mru.touch("claude")
        mru.touch("ghostty")
        mru.touch("codex")
        #expect(mru.items == ["codex", "ghostty", "claude"])
        #expect(mru.resolve(running: ["claude", "ghostty", "codex"], fallbackOrder: []) == "codex")
    }

    @Test func touchingAgainMovesToFront() {
        var mru = MRUList()
        mru.touch("a"); mru.touch("b"); mru.touch("a")
        #expect(mru.items == ["a", "b"])
    }

    @Test func skipsHarnessesThatQuit() {
        var mru = MRUList()
        mru.touch("claude"); mru.touch("codex")
        #expect(mru.resolve(running: ["claude"], fallbackOrder: []) == "claude")
    }

    @Test func fallsBackToConfigOrderWhenNothingUsedYet() {
        let mru = MRUList()
        #expect(mru.resolve(running: ["ghostty", "claude"], fallbackOrder: ["claude", "ghostty"]) == "claude")
    }

    @Test func nilWhenNoHarnessIsRunning() {
        var mru = MRUList()
        mru.touch("claude")
        #expect(mru.resolve(running: [], fallbackOrder: ["claude"]) == nil)
    }
}
