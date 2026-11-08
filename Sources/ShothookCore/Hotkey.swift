/// A global hotkey parsed from a human string like `"opt+shift+4"` or `"⌃⌥S"`.
/// Key codes are macOS virtual key codes (ANSI layout); modifiers use Carbon's bit values,
/// so this file stays free of Carbon/AppKit imports and is unit-testable.
public struct Hotkey: Equatable, Sendable {
    public let keyCode: UInt32
    public let carbonModifiers: UInt32

    public enum Modifier: UInt32, CaseIterable, Sendable {
        // Carbon values: cmdKey, shiftKey, optionKey, controlKey.
        case command = 256, shift = 512, option = 2048, control = 4096

        /// Display order follows Apple's convention: ⌃⌥⇧⌘.
        static let displayOrder: [Modifier] = [.control, .option, .shift, .command]

        var symbol: String {
            switch self {
            case .command: "⌘"
            case .shift: "⇧"
            case .option: "⌥"
            case .control: "⌃"
            }
        }
    }

    public struct ParseError: Error, CustomStringConvertible, Sendable {
        public let description: String
    }

    private let keyName: String

    public init(parsing input: String) throws {
        var modifiers: UInt32 = 0
        var tokens: [String] = []

        // Peel leading modifier symbols (⌘⌃⌥⇧) so "⌘⇧4" works without "+".
        var rest = Substring(input.trimmingCharacters(in: .whitespaces))
        while let first = rest.first, let mod = Self.symbolModifiers[first] {
            modifiers |= mod.rawValue
            rest = rest.dropFirst()
        }
        tokens = rest.split(separator: "+").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard let keyToken = tokens.popLast(), !keyToken.isEmpty else {
            throw ParseError(description: "hotkey \"\(input)\" has no key")
        }
        for token in tokens {
            guard let mod = Self.modifierNames[token] else {
                throw ParseError(description: "unknown modifier \"\(token)\" in \"\(input)\" (use cmd, ctrl, opt, shift)")
            }
            modifiers |= mod.rawValue
        }
        if Self.modifierNames[keyToken] != nil {
            throw ParseError(description: "hotkey \"\(input)\" has modifiers but no key")
        }
        guard let code = Self.keyCodes[keyToken] else {
            throw ParseError(description: "unknown key \"\(keyToken)\" in \"\(input)\"")
        }
        // A printable key with no modifier other than shift would swallow normal typing system-wide.
        let isFunctionKey = keyToken.count > 1 && keyToken.hasPrefix("f") && Int(keyToken.dropFirst()) != nil
        let typingModifiers = modifiers & ~Modifier.shift.rawValue
        if !isFunctionKey && typingModifiers == 0 {
            throw ParseError(description: "hotkey \"\(input)\" needs cmd, ctrl or opt (or use an F-key)")
        }
        self.keyCode = code
        self.carbonModifiers = modifiers
        self.keyName = keyToken
    }

    /// Human-readable form for menus, e.g. `⌥⇧4`.
    public var display: String {
        let mods = Modifier.displayOrder.filter { carbonModifiers & $0.rawValue != 0 }.map(\.symbol).joined()
        let key = keyName.count == 1 ? keyName.uppercased() : keyName.prefix(1).uppercased() + keyName.dropFirst()
        return mods + key
    }

    public static func == (a: Hotkey, b: Hotkey) -> Bool {
        a.keyCode == b.keyCode && a.carbonModifiers == b.carbonModifiers
    }

    private static let symbolModifiers: [Character: Modifier] = [
        "⌘": .command, "⇧": .shift, "⌥": .option, "⌃": .control,
    ]

    private static let modifierNames: [String: Modifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "⌃": .control,
    ]

    private static let keyCodes: [String: UInt32] = {
        var map: [String: UInt32] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
            "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
            "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
            "n": 45, "m": 46, ".": 47, "`": 50,
            "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53, "esc": 53,
        ]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113, 106, 64, 79, 80, 90]
        for (i, code) in fKeys.enumerated() { map["f\(i + 1)"] = code }
        return map
    }()
}
