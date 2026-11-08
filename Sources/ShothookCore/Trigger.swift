/// What starts a capture: a classic key combo (`opt+shift+4`, via Carbon) or a
/// modifier-only chord (`lshift+rshift`), which fires when the keys are released.
public enum Trigger: Equatable, Sendable {
    case keys(Hotkey)
    case chord(ModifierChord)

    public init(parsing input: String) throws {
        let tokens = Self.tokens(input)
        guard !tokens.isEmpty else { throw Hotkey.ParseError(description: "empty hotkey") }
        if tokens.allSatisfy({ ModifierChord.token($0) != nil }) {
            self = .chord(try ModifierChord(tokens: tokens, source: input))
        } else {
            self = .keys(try Hotkey(parsing: input))
        }
    }

    public var display: String {
        switch self {
        case .keys(let hotkey): hotkey.display
        case .chord(let chord): chord.display
        }
    }

    /// Splits `"cmd+lshift+rshift"` / `"⌘⇧⇧"` into lowercase tokens.
    static func tokens(_ input: String) -> [String] {
        var tokens: [String] = []
        for part in input.split(separator: "+") {
            var rest = Substring(part.trimmingCharacters(in: .whitespaces))
            while let first = rest.first, "⌘⇧⌥⌃".contains(first) {
                tokens.append(String(first))
                rest = rest.dropFirst()
            }
            let word = rest.trimmingCharacters(in: .whitespaces).lowercased()
            if !word.isEmpty { tokens.append(word) }
        }
        return tokens
    }
}

/// Physical modifier keys, using the device-dependent bits macOS puts in event flags.
public struct ModifierKeys: OptionSet, Hashable, Sendable {
    public let rawValue: UInt
    public init(rawValue: UInt) { self.rawValue = rawValue }

    public static let leftControl = ModifierKeys(rawValue: 0x0001)
    public static let leftShift = ModifierKeys(rawValue: 0x0002)
    public static let rightShift = ModifierKeys(rawValue: 0x0004)
    public static let leftCommand = ModifierKeys(rawValue: 0x0008)
    public static let rightCommand = ModifierKeys(rawValue: 0x0010)
    public static let leftOption = ModifierKeys(rawValue: 0x0020)
    public static let rightOption = ModifierKeys(rawValue: 0x0040)
    public static let rightControl = ModifierKeys(rawValue: 0x2000)
    public static let all: ModifierKeys = [.leftControl, .rightControl, .leftShift, .rightShift,
                                           .leftCommand, .rightCommand, .leftOption, .rightOption]
}

public struct ModifierChord: Equatable, Sendable {
    public enum Family: CaseIterable, Sendable {
        case control, option, shift, command // display order ⌃⌥⇧⌘

        var left: ModifierKeys {
            switch self {
            case .control: .leftControl
            case .option: .leftOption
            case .shift: .leftShift
            case .command: .leftCommand
            }
        }

        var right: ModifierKeys {
            switch self {
            case .control: .rightControl
            case .option: .rightOption
            case .shift: .rightShift
            case .command: .rightCommand
            }
        }

        var symbol: String {
            switch self {
            case .control: "⌃"
            case .option: "⌥"
            case .shift: "⇧"
            case .command: "⌘"
            }
        }
    }

    public enum Side: Equatable, Sendable { case either, left, right, both }

    let sides: [Family: Side]

    init(tokens: [String], source: String) throws {
        var sides: [Family: Side] = [:]
        for token in tokens {
            guard let (family, side) = Self.token(token) else {
                throw Hotkey.ParseError(description: "unknown modifier \"\(token)\" in \"\(source)\"")
            }
            switch (sides[family], side) {
            case (nil, _): sides[family] = side
            case (.either?, .either), (.left?, .right), (.right?, .left): sides[family] = .both
            default:
                throw Hotkey.ParseError(description: "\"\(source)\" names the same \(family.symbol) key twice or mixes generic and sided (use lshift+rshift)")
            }
        }
        self.sides = sides
    }

    /// True if exactly these physical keys (and no other modifiers) satisfy the chord.
    public func matches(_ held: ModifierKeys) -> Bool {
        Family.allCases.allSatisfy { family in
            let down = held.intersection([family.left, family.right])
            switch sides[family] {
            case nil: return down.isEmpty
            case .either?: return !down.isEmpty
            case .left?: return down == family.left
            case .right?: return down == family.right
            case .both?: return down == [family.left, family.right]
            }
        }
    }

    public var display: String {
        Family.allCases.compactMap { family in
            sides[family].map { side in
                switch side {
                case .either: family.symbol
                case .left: "L" + family.symbol
                case .right: "R" + family.symbol
                case .both: family.symbol + family.symbol
                }
            }
        }.joined()
    }

    static func token(_ token: String) -> (Family, Side)? {
        let sided: [String: (Family, Side)] = [
            "lshift": (.shift, .left), "rshift": (.shift, .right),
            "lcmd": (.command, .left), "rcmd": (.command, .right),
            "lcommand": (.command, .left), "rcommand": (.command, .right),
            "lopt": (.option, .left), "ropt": (.option, .right),
            "loption": (.option, .left), "roption": (.option, .right),
            "lalt": (.option, .left), "ralt": (.option, .right),
            "lctrl": (.control, .left), "rctrl": (.control, .right),
            "lcontrol": (.control, .left), "rcontrol": (.control, .right),
        ]
        if let hit = sided[token] { return hit }
        let generic: [String: Family] = [
            "shift": .shift, "⇧": .shift, "cmd": .command, "command": .command, "⌘": .command,
            "opt": .option, "option": .option, "alt": .option, "⌥": .option,
            "ctrl": .control, "control": .control, "⌃": .control,
        ]
        return generic[token].map { ($0, .either) }
    }
}

/// Turns a stream of "which modifiers are down" snapshots into chords: a chord is the set of
/// keys held at the peak, reported once everything is released. Firing on release is what makes
/// `⇧⇧` and `⌘⇧⇧` distinguishable no matter which key went down first.
public struct ChordDetector: Sendable {
    public struct Fired: Equatable, Sendable {
        public let keys: ModifierKeys
        public let began: Double
    }

    private var peak: ModifierKeys = []
    private var began: Double?

    public init() {}

    public mutating func update(_ held: ModifierKeys, at time: Double) -> Fired? {
        guard held.isEmpty else {
            if began == nil { began = time }
            peak.formUnion(held)
            return nil
        }
        defer { peak = []; began = nil }
        guard let began, !peak.isEmpty else { return nil }
        return Fired(keys: peak, began: began)
    }
}
