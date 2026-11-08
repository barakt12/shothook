import Testing
@testable import ShothookCore

struct HotkeyTests {
    @Test func parsesDefaultRegionHotkey() throws {
        let hk = try Hotkey(parsing: "opt+shift+4")
        #expect(hk.keyCode == 21)
        #expect(hk.carbonModifiers == Hotkey.Modifier.option.rawValue | Hotkey.Modifier.shift.rawValue)
        #expect(hk.display == "⌥⇧4")
    }

    @Test func acceptsAliasesSymbolsAndCase() throws {
        let a = try Hotkey(parsing: "Cmd + Control + Alt + Shift + A")
        let b = try Hotkey(parsing: "⌘⌃⌥⇧a")
        #expect(a == b)
        #expect(a.keyCode == 0)
        #expect(a.display == "⌃⌥⇧⌘A")
    }

    @Test func parsesFunctionAndNamedKeys() throws {
        #expect(try Hotkey(parsing: "f13").keyCode == 105)
        #expect(try Hotkey(parsing: "ctrl+space").keyCode == 49)
        #expect(try Hotkey(parsing: "ctrl+space").display == "⌃Space")
    }

    @Test func rejectsGarbage() {
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "") }
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "hyper+4") }
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "opt+shift") }
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "opt+banana") }
    }

    @Test func rejectsPlainKeysThatWouldHijackTyping() {
        // A bare letter or digit as a global hotkey would swallow normal typing.
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "4") }
        #expect(throws: Hotkey.ParseError.self) { try Hotkey(parsing: "shift+a") }
    }
}
