import Foundation
import Testing
@testable import ShothookCore

struct ConfigTests {
    @Test func emptyObjectYieldsDefaults() throws {
        let c = try Config.decode(Data("{}".utf8))
        #expect(c == Config.default)
    }

    @Test func partialConfigKeepsOtherDefaults() throws {
        let json = #"{ "hotkeys": { "region": "ctrl+opt+s" }, "sound": false }"#
        let c = try Config.decode(Data(json.utf8))
        #expect(c.hotkeys.region == "ctrl+opt+s")
        #expect(c.hotkeys.screen == Config.default.hotkeys.screen)
        #expect(c.sound == false)
        #expect(c.effects == true)
        #expect(c.harnesses == Config.default.harnesses)
    }

    @Test func modeDefaultsToHarnessAndAcceptsClipboard() throws {
        #expect(Config.default.mode == .harness)
        #expect(try Config.decode(Data(#"{ "mode": "clipboard" }"#.utf8)).mode == .clipboard)
        #expect(throws: (any Error).self) { try Config.decode(Data(#"{ "mode": "fax" }"#.utf8)) }
    }

    @Test func savingRoundTripsAndCreatesTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shothook-save-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/config.json")
        var c = Config.default
        c.mode = .clipboard
        try c.save(to: url)
        #expect(try Config.loadOrCreate(at: url).mode == .clipboard)
    }

    @Test func harnessPasteModeDefaultsToImage() throws {
        let json = #"{ "harnesses": [ { "bundleId": "com.example.a" }, { "bundleId": "com.example.t", "paste": "path" } ] }"#
        let c = try Config.decode(Data(json.utf8))
        #expect(c.harnesses.map(\.paste) == [.image, .path])
    }

    @Test func unknownPasteModeIsAnError() {
        let json = #"{ "harnesses": [ { "bundleId": "x", "paste": "telepathy" } ] }"#
        #expect(throws: (any Error).self) { try Config.decode(Data(json.utf8)) }
    }

    @Test func defaultsRoundTripThroughJSON() throws {
        let data = try Config.default.encoded()
        #expect(try Config.decode(data) == Config.default)
    }

    @Test func defaultsCoverTerminalsWithPathMode() {
        let ghostty = Config.default.harnesses.first { $0.bundleId == "com.mitchellh.ghostty" }
        #expect(ghostty?.paste == .path)
        let claude = Config.default.harnesses.first { $0.bundleId == "com.anthropic.claudefordesktop" }
        #expect(claude?.paste == .image)
    }

    @Test func loadOrCreateWritesDefaultsOnlyWhenMissing() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shothook-cfg-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        #expect(try Config.loadOrCreate(at: url) == .default)
        #expect(FileManager.default.fileExists(atPath: url.path))

        // A broken file must surface an error and stay untouched — never be "repaired" with defaults.
        try Data("{ not json".utf8).write(to: url)
        #expect(throws: (any Error).self) { try Config.loadOrCreate(at: url) }
        #expect(try String(contentsOf: url, encoding: .utf8) == "{ not json")

        // Same for a file we can't read at all (e.g. bad permissions).
        try Data(#"{ "sound": false }"#.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        #expect(throws: (any Error).self) { try Config.loadOrCreate(at: url) }
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        #expect(try Config.decode(Data(contentsOf: url)).sound == false)
    }

    @Test func defaultHotkeysParse() throws {
        #expect(try Trigger(parsing: Config.default.hotkeys.region).display == "⇧⇧⌘")
        #expect(try Trigger(parsing: Config.default.hotkeys.screen).display == "⇧⇧")
    }
}
