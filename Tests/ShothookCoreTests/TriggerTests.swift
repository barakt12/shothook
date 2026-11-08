import Testing
@testable import ShothookCore

struct TriggerTests {
    @Test func bothShiftsIsAChord() throws {
        let t = try Trigger(parsing: "lshift+rshift")
        guard case .chord(let chord) = t else { Issue.record("expected chord"); return }
        #expect(chord.matches([.leftShift, .rightShift]))
        #expect(!chord.matches([.leftShift]))
        #expect(!chord.matches([.leftShift, .rightShift, .leftCommand]), "extra modifiers don't match")
        #expect(t.display == "⇧⇧")
    }

    @Test func commandPlusBothShifts() throws {
        guard case .chord(let chord) = try Trigger(parsing: "cmd+lshift+rshift") else { Issue.record("expected chord"); return }
        #expect(chord.matches([.leftCommand, .leftShift, .rightShift]))
        #expect(chord.matches([.rightCommand, .leftShift, .rightShift]), "generic cmd accepts either side")
        #expect(!chord.matches([.leftShift, .rightShift]))
        #expect(try Trigger(parsing: "cmd+lshift+rshift").display == "⇧⇧⌘")
    }

    @Test func genericTwiceMeansBothSides() throws {
        #expect(try Trigger(parsing: "shift+shift") == Trigger(parsing: "lshift+rshift"))
        #expect(try Trigger(parsing: "⇧⇧") == Trigger(parsing: "lshift+rshift"))
    }

    @Test func singleSidedChord() throws {
        guard case .chord(let chord) = try Trigger(parsing: "rcmd") else { Issue.record("expected chord"); return }
        #expect(chord.matches([.rightCommand]))
        #expect(!chord.matches([.leftCommand]))
        #expect(try Trigger(parsing: "rcmd").display == "R⌘")
    }

    @Test func keyCombosStillWork() throws {
        #expect(try Trigger(parsing: "opt+shift+4") == .keys(try Hotkey(parsing: "opt+shift+4")))
        #expect(try Trigger(parsing: "⌥⇧4").display == "⌥⇧4")
    }

    @Test func rejectsAmbiguousOrBrokenChords() {
        #expect(throws: (any Error).self) { try Trigger(parsing: "shift+rshift") } // generic + sided: ambiguous
        #expect(throws: (any Error).self) { try Trigger(parsing: "lshift+lshift") }
        #expect(throws: (any Error).self) { try Trigger(parsing: "shift+shift+shift") }
        #expect(throws: (any Error).self) { try Trigger(parsing: "") }
        #expect(throws: (any Error).self) { try Trigger(parsing: "lshift+4") } // sides only for chords
    }
}

struct ChordDetectorTests {
    @Test func firesOnFullReleaseWithPeakSet() {
        var d = ChordDetector()
        #expect(d.update([.leftShift], at: 0) == nil)
        #expect(d.update([.leftShift, .rightShift], at: 0.05) == nil)
        #expect(d.update([.rightShift], at: 0.15) == nil) // partial release keeps the peak
        let fired = d.update([], at: 0.2)
        #expect(fired?.keys == [.leftShift, .rightShift])
        #expect(fired?.began == 0)
    }

    @Test func orderDoesNotMatterForSupersets() {
        var d = ChordDetector()
        _ = d.update([.leftShift], at: 0)
        _ = d.update([.leftShift, .rightShift], at: 0.05)
        _ = d.update([.leftShift, .rightShift, .leftCommand], at: 0.1) // ⌘ added last
        #expect(d.update([], at: 0.3)?.keys == [.leftShift, .rightShift, .leftCommand])
    }

    @Test func resetsBetweenChords() {
        var d = ChordDetector()
        _ = d.update([.leftCommand], at: 0)
        _ = d.update([], at: 0.1)
        _ = d.update([.rightShift], at: 1)
        #expect(d.update([], at: 1.1)?.keys == [.rightShift])
    }

    @Test func releaseWithoutPressIsIgnored() {
        var d = ChordDetector()
        #expect(d.update([], at: 0) == nil)
    }
}
