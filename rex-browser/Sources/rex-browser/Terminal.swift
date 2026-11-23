import Darwin
import Foundation

/// The pane: raw mode, its size, and writes to it.
final class Terminal {
    struct Size: Equatable {
        var cols: Int
        var rows: Int
        var xpx: Int
        var ypx: Int
    }

    private var saved = termios()
    private var raw = false

    func size() -> Size {
        var w = winsize()
        guard ioctl(1, TIOCGWINSZ, &w) == 0 else { return Size(cols: 80, rows: 24, xpx: 0, ypx: 0) }
        return Size(cols: Int(w.ws_col), rows: Int(w.ws_row), xpx: Int(w.ws_xpixel), ypx: Int(w.ws_ypixel))
    }

    func enterRaw() {
        tcgetattr(0, &saved)
        var t = saved
        cfmakeraw(&t)
        tcsetattr(0, TCSANOW, &t)
        raw = true
    }

    func restore() {
        if raw { tcsetattr(0, TCSADRAIN, &saved) }
        raw = false
    }

    func write(_ data: Data) {
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            guard var base = p.baseAddress else { return }
            var left = p.count
            while left > 0 {
                let n = Darwin.write(1, base, left)
                if n < 0 {
                    if errno == EINTR || errno == EAGAIN { continue }
                    return
                }
                base += n
                left -= n
            }
        }
    }

    func write(_ s: String) { write(Data(s.utf8)) }
}

// MARK: - Input

enum Key: Equatable {
    case char(Character)
    case ctrl(Character)
    case enter, backspace, tab, backtab, escape
    case up, down, left, right, home, end, pageUp, pageDown, delete
}

struct Mods: OptionSet {
    let rawValue: Int
    static let shift = Mods(rawValue: 1)
    static let alt = Mods(rawValue: 2)
    static let ctrl = Mods(rawValue: 4)
}

struct Mouse {
    enum Kind { case press, release, drag, move, wheel }
    var kind: Kind
    /// 0 left, 1 middle, 2 right; for wheels 0 up, 1 down, 2 left, 3 right.
    var button: Int
    /// 1-based, in pixels when SGR-pixel mode (1016) is on.
    var x: Int
    var y: Int
    var mods: Mods
}

enum InputEvent {
    case key(Key, Mods)
    case mouse(Mouse)
    case paste(String)
}

/// Turns the bytes a terminal sends into keys, mouse reports and pastes.
final class InputParser {
    private var buf: [UInt8] = []
    private var inPaste = false
    private var pasted: [UInt8] = []
    private static let pasteEnd: [UInt8] = Array("\u{1b}[201~".utf8)

    func feed(_ bytes: [UInt8]) -> [InputEvent] {
        buf += bytes
        var out: [InputEvent] = []
        var i = 0
        scan: while i < buf.count {
            if inPaste {
                if let end = find(Self.pasteEnd, from: i) {
                    pasted += buf[i..<end]
                    out.append(.paste(String(decoding: pasted, as: UTF8.self)))
                    pasted = []
                    inPaste = false
                    i = end + Self.pasteEnd.count
                    continue
                }
                let keep = min(Self.pasteEnd.count - 1, buf.count - i)
                pasted += buf[i..<(buf.count - keep)]
                i = buf.count - keep
                break
            }
            let b = buf[i]
            if b == 0x1B {
                guard i + 1 < buf.count else {
                    out.append(.key(.escape, []))
                    i += 1
                    continue
                }
                let n = buf[i + 1]
                if n == UInt8(ascii: "[") {
                    var j = i + 2
                    while j < buf.count, !(0x40...0x7E).contains(buf[j]) { j += 1 }
                    guard j < buf.count else { break scan }
                    let params = String(decoding: buf[(i + 2)..<j], as: UTF8.self)
                    let final = buf[j]
                    i = j + 1
                    if params == "200", final == UInt8(ascii: "~") {
                        inPaste = true
                        continue
                    }
                    out += csi(params, final)
                    continue
                }
                if n == UInt8(ascii: "O") {
                    guard i + 2 < buf.count else { break scan }
                    if let k = ss3(buf[i + 2]) { out.append(.key(k, [])) }
                    i += 3
                    continue
                }
                if n == 0x7F {
                    out.append(.key(.backspace, .alt))
                    i += 2
                    continue
                }
                if n == 0x1B {
                    out.append(.key(.escape, []))
                    i += 1
                    continue
                }
                let len = utf8Length(n)
                guard i + 1 + len <= buf.count else { break scan }
                if let c = String(decoding: buf[(i + 1)..<(i + 1 + len)], as: UTF8.self).first {
                    out.append(.key(n < 0x20 ? .ctrl(ctrlLetter(n)) : .char(c), .alt))
                }
                i += 1 + len
                continue
            }
            switch b {
            case 0x0D: out.append(.key(.enter, []))
            case 0x09: out.append(.key(.tab, []))
            case 0x7F, 0x08: out.append(.key(.backspace, []))
            case 0x00: break
            case 0x01...0x1A: out.append(.key(.ctrl(ctrlLetter(b)), .ctrl))
            case 0x1C...0x1F: break
            default:
                let len = utf8Length(b)
                guard i + len <= buf.count else { break scan }
                if let c = String(decoding: buf[i..<(i + len)], as: UTF8.self).first {
                    out.append(.key(.char(c), []))
                }
                i += len
                continue
            }
            i += 1
        }
        buf.removeFirst(i)
        return out
    }

    private func ctrlLetter(_ b: UInt8) -> Character {
        Character(UnicodeScalar(b + 0x60))
    }

    private func utf8Length(_ b: UInt8) -> Int {
        switch b {
        case 0xF0...0xF7: return 4
        case 0xE0...0xEF: return 3
        case 0xC0...0xDF: return 2
        default: return 1
        }
    }

    private func find(_ needle: [UInt8], from: Int) -> Int? {
        guard buf.count - from >= needle.count else { return nil }
        var i = from
        while i + needle.count <= buf.count {
            if buf[i] == needle[0], Array(buf[i..<(i + needle.count)]) == needle { return i }
            i += 1
        }
        return nil
    }

    private func ss3(_ b: UInt8) -> Key? {
        switch b {
        case UInt8(ascii: "A"): return .up
        case UInt8(ascii: "B"): return .down
        case UInt8(ascii: "C"): return .right
        case UInt8(ascii: "D"): return .left
        case UInt8(ascii: "H"): return .home
        case UInt8(ascii: "F"): return .end
        default: return nil
        }
    }

    private func csi(_ p: String, _ final: UInt8) -> [InputEvent] {
        let f = Character(UnicodeScalar(final))
        if f == "M" || f == "m", p.hasPrefix("<") {
            let parts = p.dropFirst().split(separator: ";").compactMap { Int($0) }
            guard parts.count == 3 else { return [] }
            let b = parts[0]
            var mods: Mods = []
            if b & 4 != 0 { mods.insert(.shift) }
            if b & 8 != 0 { mods.insert(.alt) }
            if b & 16 != 0 { mods.insert(.ctrl) }
            let low = b & 3
            let kind: Mouse.Kind
            if b & 64 != 0 {
                kind = .wheel
            } else if b & 32 != 0 {
                kind = low == 3 ? .move : .drag
            } else {
                kind = f == "M" ? .press : .release
            }
            return [.mouse(Mouse(kind: kind, button: low, x: parts[1], y: parts[2], mods: mods))]
        }
        if p.hasPrefix("?") || p.hasPrefix(">") || p.hasPrefix("<") { return [] }
        let nums = p.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var mods: Mods = []
        if nums.count >= 2, nums[1] > 1 {
            let m = nums[1] - 1
            if m & 1 != 0 { mods.insert(.shift) }
            if m & 2 != 0 { mods.insert(.alt) }
            if m & 4 != 0 { mods.insert(.ctrl) }
        }
        let key: Key?
        switch f {
        case "A": key = .up
        case "B": key = .down
        case "C": key = .right
        case "D": key = .left
        case "H": key = .home
        case "F": key = .end
        case "Z": key = .backtab
        case "~":
            switch nums.first ?? 0 {
            case 1, 7: key = .home
            case 4, 8: key = .end
            case 3: key = .delete
            case 5: key = .pageUp
            case 6: key = .pageDown
            default: key = nil
            }
        default: key = nil
        }
        return key.map { [.key($0, mods)] } ?? []
    }
}
