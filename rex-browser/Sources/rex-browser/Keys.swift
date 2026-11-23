import AppKit
import WebKit

/// Turns terminal keys into the NSEvents a Mac keyboard would produce.
enum Keys {
    /// macOS virtual key codes (kVK_ANSI_*) by the character on the key.
    private static let codes: [Character: UInt16] = {
        var m: [Character: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "1": 18, "2": 19,
            "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28,
            "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38,
            "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
            "`": 50, " ": 49,
        ]
        let shifted: [Character: Character] = [
            "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
            "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";",
            "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`",
        ]
        for (s, base) in shifted { m[s] = m[base] }
        return m
    }()

    private static func function(_ code: Int) -> String {
        String(Character(UnicodeScalar(UInt32(code))!))
    }

    @MainActor
    static func send(_ key: Key, _ mods: Mods, to web: WKWebView, window: NSWindow) {
        var flags: NSEvent.ModifierFlags = []
        if mods.contains(.shift) { flags.insert(.shift) }
        if mods.contains(.alt) { flags.insert(.option) }
        if mods.contains(.ctrl) { flags.insert(.control) }

        let chars: String
        let base: String
        let code: UInt16
        switch key {
        case .char(let c):
            chars = String(c)
            base = String(c)
            let lower = Character(String(c).lowercased())
            code = codes[lower] ?? codes[c] ?? 0
            if c.isUppercase || "!@#$%^&*()_+{}|:\"<>?~".contains(c) { flags.insert(.shift) }
        case .ctrl(let c):
            let ascii = c.asciiValue ?? 0x40
            chars = String(Character(UnicodeScalar(ascii & 0x1F)))
            base = String(c)
            code = codes[c] ?? 0
            flags.insert(.control)
        case .enter: (chars, base, code) = ("\r", "\r", 36)
        case .backspace: (chars, base, code) = ("\u{7f}", "\u{7f}", 51)
        case .tab: (chars, base, code) = ("\t", "\t", 48)
        case .backtab:
            (chars, base, code) = ("\u{19}", "\t", 48)
            flags.insert(.shift)
        case .escape: (chars, base, code) = ("\u{1b}", "\u{1b}", 53)
        case .up: (chars, base, code) = (function(NSUpArrowFunctionKey), function(NSUpArrowFunctionKey), 126)
        case .down: (chars, base, code) = (function(NSDownArrowFunctionKey), function(NSDownArrowFunctionKey), 125)
        case .left: (chars, base, code) = (function(NSLeftArrowFunctionKey), function(NSLeftArrowFunctionKey), 123)
        case .right: (chars, base, code) = (function(NSRightArrowFunctionKey), function(NSRightArrowFunctionKey), 124)
        case .home: (chars, base, code) = (function(NSHomeFunctionKey), function(NSHomeFunctionKey), 115)
        case .end: (chars, base, code) = (function(NSEndFunctionKey), function(NSEndFunctionKey), 119)
        case .pageUp: (chars, base, code) = (function(NSPageUpFunctionKey), function(NSPageUpFunctionKey), 116)
        case .pageDown: (chars, base, code) = (function(NSPageDownFunctionKey), function(NSPageDownFunctionKey), 121)
        case .delete: (chars, base, code) = (function(NSDeleteFunctionKey), function(NSDeleteFunctionKey), 117)
        }
        switch key {
        case .up, .down, .left, .right, .home, .end, .pageUp, .pageDown, .delete:
            flags.formUnion([.function, .numericPad])
        default: break
        }

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: chars, charactersIgnoringModifiers: base,
                isARepeat: false, keyCode: code
            ) else { continue }
            if type == .keyDown { web.keyDown(with: event) } else { web.keyUp(with: event) }
        }
    }
}
