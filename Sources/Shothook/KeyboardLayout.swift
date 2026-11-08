import Carbon.HIToolbox

enum KeyboardLayout {
    /// The virtual key that produces `character` *with ⌘ held* in the current ASCII-capable
    /// layout — what macOS matches ⌘-shortcuts against. So Dvorak's ⌘V isn't the QWERTY V key,
    /// "Dvorak – QWERTY ⌘" resolves to QWERTY, and Hebrew/Russian go through their ASCII
    /// companion layout. Falls back to `fallback`.
    static func keyCode(for character: Character, fallback: CGKeyCode) -> CGKeyCode {
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return fallback }

        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        return bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var chars = [UniChar](repeating: 0, count: 4)
            for code in 0..<128 {
                var deadKeys: UInt32 = 0 // fresh per key so a dead key can't leak into the next lookup
                var length = 0
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                            &deadKeys, chars.count, &length, &chars)
                if status == noErr, length == 1, Character(UnicodeScalar(chars[0]) ?? " ") == character {
                    return CGKeyCode(code)
                }
            }
            return fallback
        }
    }
}
