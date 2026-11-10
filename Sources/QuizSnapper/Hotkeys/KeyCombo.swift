import AppKit
import Carbon

/// A global keyboard shortcut (Carbon key code + Carbon modifier mask).
struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        modifiers = KeyCombo.carbonModifiers(from: event.modifierFlags)
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        if flags.contains(.shift) { m |= UInt32(shiftKey) }
        if flags.contains(.option) { m |= UInt32(optionKey) }
        if flags.contains(.control) { m |= UInt32(controlKey) }
        return m
    }

    var hasCommand: Bool { modifiers & UInt32(cmdKey) != 0 }
    var hasShift: Bool { modifiers & UInt32(shiftKey) != 0 }
    var hasOption: Bool { modifiers & UInt32(optionKey) != 0 }
    var hasControl: Bool { modifiers & UInt32(controlKey) != 0 }

    var modifierSymbols: String {
        var s = ""
        if hasControl { s += "⌃" }
        if hasOption { s += "⌥" }
        if hasShift { s += "⇧" }
        if hasCommand { s += "⌘" }
        return s
    }

    var keySymbol: String { KeyCombo.keyName(for: UInt16(keyCode)) }

    var displayString: String { modifierSymbols + keySymbol }

    /// Individual key caps for nicer rendering (["⌃", "⌥", "⌘", "X"]).
    var keyCaps: [String] { modifierSymbols.map { String($0) } + [keySymbol] }

    var isFunctionKey: Bool { KeyCombo.functionKeys.contains(UInt16(keyCode)) }

    /// Returns an error message if this shortcut is not usable as a global hotkey.
    var validationError: String? {
        if !hasCommand && !hasControl && !hasOption && !isFunctionKey {
            return "Use at least one of ⌘, ⌃ or ⌥ (or a function key)."
        }
        // macOS 15+ refuses hotkeys whose only modifiers are ⌥ or ⌥⇧.
        if hasOption && !hasCommand && !hasControl && !isFunctionKey {
            return "macOS doesn't allow shortcuts that only use ⌥ / ⌥⇧. Add ⌘ or ⌃."
        }
        return nil
    }

    // MARK: Key names

    private static let functionKeys: Set<UInt16> = [
        UInt16(kVK_F1), UInt16(kVK_F2), UInt16(kVK_F3), UInt16(kVK_F4), UInt16(kVK_F5), UInt16(kVK_F6),
        UInt16(kVK_F7), UInt16(kVK_F8), UInt16(kVK_F9), UInt16(kVK_F10), UInt16(kVK_F11), UInt16(kVK_F12),
        UInt16(kVK_F13), UInt16(kVK_F14), UInt16(kVK_F15), UInt16(kVK_F16), UInt16(kVK_F17), UInt16(kVK_F18),
        UInt16(kVK_F19), UInt16(kVK_F20),
    ]

    private static let specialKeys: [UInt16: String] = [
        UInt16(kVK_Return): "↩", UInt16(kVK_ANSI_KeypadEnter): "⌤", UInt16(kVK_Tab): "⇥",
        UInt16(kVK_Space): "Space", UInt16(kVK_Delete): "⌫", UInt16(kVK_ForwardDelete): "⌦",
        UInt16(kVK_Escape): "⎋", UInt16(kVK_LeftArrow): "←", UInt16(kVK_RightArrow): "→",
        UInt16(kVK_UpArrow): "↑", UInt16(kVK_DownArrow): "↓", UInt16(kVK_Home): "↖", UInt16(kVK_End): "↘",
        UInt16(kVK_PageUp): "⇞", UInt16(kVK_PageDown): "⇟", UInt16(kVK_Help): "Help",
        UInt16(kVK_F1): "F1", UInt16(kVK_F2): "F2", UInt16(kVK_F3): "F3", UInt16(kVK_F4): "F4",
        UInt16(kVK_F5): "F5", UInt16(kVK_F6): "F6", UInt16(kVK_F7): "F7", UInt16(kVK_F8): "F8",
        UInt16(kVK_F9): "F9", UInt16(kVK_F10): "F10", UInt16(kVK_F11): "F11", UInt16(kVK_F12): "F12",
        UInt16(kVK_F13): "F13", UInt16(kVK_F14): "F14", UInt16(kVK_F15): "F15", UInt16(kVK_F16): "F16",
        UInt16(kVK_F17): "F17", UInt16(kVK_F18): "F18", UInt16(kVK_F19): "F19", UInt16(kVK_F20): "F20",
    ]

    static func keyName(for keyCode: UInt16) -> String {
        if let special = specialKeys[keyCode] { return special }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return "#\(keyCode)" }
        let layoutData = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = layoutData.withUnsafeBytes { raw -> OSStatus in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return -1 }
            return UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeyState, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return "#\(keyCode)" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

extension KeyCombo {
    static let cmd = UInt32(cmdKey)
    static let shift = UInt32(shiftKey)
    static let opt = UInt32(optionKey)
    static let ctrl = UInt32(controlKey)
    static let hyper = ctrl | opt | cmd

    static let defaults: [ShortcutAction: KeyCombo] = [
        .snapAndAsk: KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: cmd | shift),
        .regionAndAsk: KeyCombo(keyCode: UInt32(kVK_ANSI_X), modifiers: hyper),
        .addScreen: KeyCombo(keyCode: UInt32(kVK_ANSI_A), modifiers: hyper),
        .addRegion: KeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: hyper),
        .sendStack: KeyCombo(keyCode: UInt32(kVK_Return), modifiers: hyper),
        .clearStack: KeyCombo(keyCode: UInt32(kVK_Delete), modifiers: hyper),
        .togglePanel: KeyCombo(keyCode: UInt32(kVK_ANSI_P), modifiers: hyper),
        .nextProfile: KeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: hyper),
        .dismissAnswer: KeyCombo(keyCode: UInt32(kVK_ANSI_H), modifiers: hyper),
    ]
}
