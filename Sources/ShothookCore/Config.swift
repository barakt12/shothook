import Foundation

/// How a screenshot is handed to a harness.
public enum PasteMode: String, Codable, Sendable {
    /// PNG on the clipboard, then ⌘V. For GUI chat composers (Electron, native).
    case image
    /// File path (text only) on the clipboard, then ⌘V. For terminal CLIs
    /// (Claude Code, Codex) that turn a pasted image path into an attachment.
    case path
}

/// What a capture does with the shot.
public enum DeliveryMode: String, Codable, Sendable {
    /// Paste it into the most recently used harness.
    case harness
    /// Just put it on the clipboard, like ⌘⌃⇧4.
    case clipboard
}

public struct Harness: Codable, Equatable, Sendable {
    public var bundleId: String
    public var name: String?
    public var paste: PasteMode

    public init(_ bundleId: String, _ name: String, paste: PasteMode = .image) {
        self.bundleId = bundleId
        self.name = name
        self.paste = paste
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundleId = try c.decode(String.self, forKey: .bundleId)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        paste = try c.decodeIfPresent(PasteMode.self, forKey: .paste) ?? .image
    }
}

public struct Config: Codable, Equatable, Sendable {
    public struct Hotkeys: Codable, Equatable, Sendable {
        /// Opens the selection overlay. A key combo (`opt+shift+4`) or a modifier chord
        /// (`cmd+lshift+rshift`, fires on release). Empty string disables it.
        public var region: String
        /// Captures the whole display under the mouse pointer. Same syntax. Empty disables it.
        public var screen: String

        public init(region: String, screen: String) {
            self.region = region
            self.screen = screen
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            region = try c.decodeIfPresent(String.self, forKey: .region) ?? Config.default.hotkeys.region
            screen = try c.decodeIfPresent(String.self, forKey: .screen) ?? Config.default.hotkeys.screen
        }
    }

    public var mode: DeliveryMode
    public var hotkeys: Hotkeys
    /// Checked in order when no harness has been focused yet; MRU wins otherwise.
    public var harnesses: [Harness]
    /// The throw animation: shutter flash, the shot flying into the harness, landing ripple.
    public var effects: Bool
    /// The whoosh-and-whomp that goes with it.
    public var sound: Bool
    /// Downscale shots whose long edge exceeds this many pixels (0 = never). Models
    /// downsample large images anyway; this keeps pastes small and fast.
    public var maxLongEdge: Int

    public static let `default` = Config(
        mode: .harness,
        hotkeys: Hotkeys(region: "cmd+lshift+rshift", screen: "lshift+rshift"),
        harnesses: [
            Harness("com.anthropic.claudefordesktop", "Claude"),
            Harness("com.openai.codex", "Codex"),
            Harness("com.openai.chat", "ChatGPT"),
            Harness("com.t3tools.t3code", "T3 Code"),
            Harness("com.todesktop.230313mzl4w4u92", "Cursor"),
            Harness("com.microsoft.VSCode", "VS Code"),
            Harness("com.exafunction.windsurf", "Windsurf"),
            Harness("dev.zed.Zed", "Zed"),
            Harness("com.mitchellh.ghostty", "Ghostty", paste: .path),
            Harness("com.googlecode.iterm2", "iTerm", paste: .path),
            Harness("com.apple.Terminal", "Terminal", paste: .path),
            Harness("dev.warp.Warp-Stable", "Warp", paste: .path),
            Harness("com.github.wez.wezterm", "WezTerm", paste: .path),
            Harness("net.kovidgoyal.kitty", "kitty", paste: .path),
            Harness("org.alacritty", "Alacritty", paste: .path),
        ],
        effects: true,
        sound: true,
        maxLongEdge: 2560
    )

    public init(mode: DeliveryMode, hotkeys: Hotkeys, harnesses: [Harness], effects: Bool, sound: Bool, maxLongEdge: Int) {
        self.mode = mode
        self.hotkeys = hotkeys
        self.harnesses = harnesses
        self.effects = effects
        self.sound = sound
        self.maxLongEdge = maxLongEdge
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Config.default
        mode = try c.decodeIfPresent(DeliveryMode.self, forKey: .mode) ?? d.mode
        hotkeys = try c.decodeIfPresent(Hotkeys.self, forKey: .hotkeys) ?? d.hotkeys
        harnesses = try c.decodeIfPresent([Harness].self, forKey: .harnesses) ?? d.harnesses
        effects = try c.decodeIfPresent(Bool.self, forKey: .effects) ?? d.effects
        sound = try c.decodeIfPresent(Bool.self, forKey: .sound) ?? d.sound
        maxLongEdge = try c.decodeIfPresent(Int.self, forKey: .maxLongEdge) ?? d.maxLongEdge
    }

    public static func decode(_ data: Data) throws -> Config {
        try JSONDecoder().decode(Config.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try e.encode(self)
    }

    public func harness(for bundleId: String) -> Harness? {
        harnesses.first { $0.bundleId == bundleId }
    }

    /// `~/.config/shothook/config.json`
    public static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/shothook/config.json")
    }

    /// Loads the config file, writing defaults only if no file exists yet.
    /// An existing file that can't be read or parsed throws — it's never overwritten.
    public static func loadOrCreate(at url: URL = fileURL) throws -> Config {
        if FileManager.default.fileExists(atPath: url.path) {
            return try decode(Data(contentsOf: url))
        }
        try Config.default.save(to: url)
        return .default
    }

    public func save(to url: URL = fileURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}
