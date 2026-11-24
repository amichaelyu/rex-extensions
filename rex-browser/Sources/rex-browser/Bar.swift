import Accelerate
import AppKit

/// What the address bar shows.
struct BarState {
    var canGoBack = false
    var canGoForward = false
    var loading = false
    var progress = 0.0
    var title = ""
    var url = ""
    var notice: String?
    var editing = false
    var edit = ""
    var cursor = 0
    var caretVisible = true
}

enum BarAction {
    case back, forward, reload, edit
}

/// Draws the address bar as pixels for the top of the page image. Drawn
/// rather than written as a terminal text row, so its gray stops at the same
/// edges as the page (Rex pads a text row with its edge cells' color) and its
/// icons and text are centered exactly.
@MainActor
enum BarRenderer {
    static let background = NSColor(srgbRed: 48 / 255, green: 48 / 255, blue: 48 / 255, alpha: 1)
    static let text = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.86, alpha: 1)
    static let dim = NSColor(srgbRed: 0.50, green: 0.50, blue: 0.50, alpha: 1)

    /// The bar's RGB pixels, and which horizontal pixel ranges are buttons.
    static func render(_ state: BarState, width: Int, height: Int, scale s: CGFloat) -> (rgb: [UInt8], buttons: [(Range<Int>, BarAction)]) {
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return ([], []) }
        // Flip so y grows downward, like the page.
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        defer { NSGraphicsContext.current = previous }

        let w = CGFloat(width), h = CGFloat(height)
        background.setFill()
        NSRect(x: 0, y: 0, width: w, height: h).fill()

        var buttons: [(Range<Int>, BarAction)] = []
        let button = 26 * s
        var x = 6 * s
        let icons: [(String, Bool, BarAction)] = [
            ("chevron.left", state.canGoBack, .back),
            ("chevron.right", state.canGoForward, .forward),
            (state.loading ? "xmark" : "arrow.clockwise", true, .reload),
        ]
        for (name, enabled, action) in icons {
            drawSymbol(name, color: enabled ? text : dim, in: NSRect(x: x, y: 0, width: button, height: h), size: 11 * s)
            buttons.append((Int(x)..<Int(x + button), action))
            x += button
        }
        x += 6 * s
        dim.withAlphaComponent(0.5).setFill()
        NSRect(x: x, y: h * 0.25, width: max(1, s * 0.5), height: h * 0.5).fill()
        x += 10 * s

        let titleFont = NSFont.systemFont(ofSize: 12 * s, weight: .medium)
        let urlFont = NSFont.systemFont(ofSize: 11.5 * s)
        let right = w - 10 * s
        if state.editing {
            let attrs: [NSAttributedString.Key: Any] = [.font: urlFont, .foregroundColor: text]
            let full = NSAttributedString(string: state.edit, attributes: attrs)
            let before = NSAttributedString(string: String(state.edit.prefix(state.cursor)), attributes: attrs)
            let room = right - x - 4 * s
            let caret = before.size().width
            let shift = max(0, caret - room)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: NSRect(x: x, y: 0, width: room + 4 * s, height: h)).addClip()
            draw(full, at: x - shift, height: h, font: urlFont)
            if state.caretVisible {
                text.setFill()
                NSRect(x: x - shift + caret, y: h * 0.15, width: max(1, s), height: h * 0.7).fill()
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let line = NSMutableAttributedString()
            if let notice = state.notice {
                line.append(NSAttributedString(string: notice, attributes: [.font: titleFont, .foregroundColor: text]))
            } else {
                let title = state.title.isEmpty ? state.url : state.title
                line.append(NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: text]))
                if !state.title.isEmpty, !state.url.isEmpty {
                    line.append(NSAttributedString(string: "   " + state.url, attributes: [.font: urlFont, .foregroundColor: dim]))
                }
            }
            let style = NSMutableParagraphStyle()
            style.lineBreakMode = .byTruncatingTail
            line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
            let lineHeight = titleFont.ascender - titleFont.descender
            line.draw(with: NSRect(x: x, y: (h - lineHeight) / 2, width: max(0, right - x), height: lineHeight + 2 * s),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        if state.loading {
            NSColor.systemBlue.setFill()
            NSRect(x: 0, y: h - 2 * s, width: w * min(max(state.progress, 0.05), 1), height: 2 * s).fill()
        }
        NSGraphicsContext.current?.flushGraphics()

        // RGBA -> RGB.
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBytes { dst in
            var src = vImage_Buffer(data: ctx.data, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 4)
            var out = vImage_Buffer(data: dst.baseAddress, height: vImagePixelCount(height), width: vImagePixelCount(width), rowBytes: width * 3)
            vImageConvert_RGBA8888toRGB888(&src, &out, vImage_Flags(kvImageNoFlags))
        }
        return (rgb, buttons)
    }

    private static func draw(_ string: NSAttributedString, at x: CGFloat, height h: CGFloat, font: NSFont) {
        let lineHeight = font.ascender - font.descender
        string.draw(at: NSPoint(x: x, y: (h - lineHeight) / 2))
    }

    private static func drawSymbol(_ name: String, color: NSColor, in rect: NSRect, size: CGFloat) {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return }
        let size = image.size
        image.draw(in: NSRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2,
                              width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}
