import CoreGraphics
import Darwin
import Foundation

/// The page as one kitty-graphics image placed over the pane.
///
/// The first frame creates the image and its placement (`a=T`); later frames
/// overwrite only the rectangle that changed (`a=f,r=1,x,y,s,v,X=1`), so the
/// placement never flashes. Rex frees an image once it has no placement, so
/// upload and placement always go in one command.
final class KittyImage {
    let term: Terminal
    let inline: Bool
    let id = 6161
    private(set) var placed = false
    private var sent: [String] = []
    private(set) var bytesSent = 0

    init(term: Terminal, inline: Bool) {
        self.term = term
        self.inline = inline
    }

    func create(_ rgb: Data, width: Int, height: Int, cols: Int, rows: Int, row: Int) {
        term.write("\u{1b}[\(row);1H")
        send("a=T,f=24,s=\(width),v=\(height),i=\(id),p=1,c=\(cols),r=\(rows),C=1,q=2", rgb)
        placed = true
    }

    func update(_ rgb: Data, x: Int, y: Int, width: Int, height: Int) {
        send("a=f,r=1,i=\(id),x=\(x),y=\(y),s=\(width),v=\(height),f=24,X=1,q=2", rgb)
    }

    func delete() {
        if placed { term.write("\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\") }
        placed = false
    }

    func resetBytes() { bytesSent = 0 }

    /// Temp files the terminal hasn't read (and so deleted) yet.
    func cleanup() {
        for path in sent { unlink(path) }
        sent = []
    }

    private func send(_ keys: String, _ data: Data) {
        bytesSent += data.count
        if inline {
            let b64 = Array(data.base64EncodedData())
            let chunk = 4096
            var start = 0
            var out = Data()
            repeat {
                let end = min(start + chunk, b64.count)
                let more = end < b64.count ? 1 : 0
                let head = start == 0 ? "\(keys),t=d,m=\(more)" : "m=\(more),q=2"
                out.append(contentsOf: Array("\u{1b}_G\(head);".utf8))
                out.append(contentsOf: b64[start..<end])
                out.append(contentsOf: Array("\u{1b}\\".utf8))
                start = end
            } while start < b64.count
            term.write(out)
            return
        }
        // A t=t file must live in a temp directory and have
        // "tty-graphics-protocol" in its name; the terminal deletes it once read.
        var template = Array((NSTemporaryDirectory() + "tty-graphics-protocol-rex-browser-XXXXXX.rgb").utf8CString)
        let fd = mkstemps(&template, 4)
        guard fd >= 0 else { return }
        data.withUnsafeBytes { (p: UnsafeRawBufferPointer) in
            var base = p.baseAddress!
            var left = p.count
            while left > 0 {
                let n = Darwin.write(fd, base, left)
                if n <= 0 { break }
                base += n
                left -= n
            }
        }
        close(fd)
        let path = String(cString: template)
        sent.append(path)
        if sent.count > 512 { sent = sent.filter { access($0, F_OK) == 0 } }
        term.write("\u{1b}_G\(keys),t=t;\(Data(path.utf8).base64EncodedString())\u{1b}\\")
    }
}

/// An RGBA buffer the snapshots are drawn into, and diffs between two of them.
final class Frame {
    let width: Int
    let height: Int
    let context: CGContext

    init?(width: Int, height: Int) {
        guard width > 0, height > 0,
              let ctx = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
              )
        else { return nil }
        self.width = width
        self.height = height
        context = ctx
    }

    var pixels: UnsafeMutablePointer<UInt8> { context.data!.assumingMemoryBound(to: UInt8.self) }

    /// Draws an image over white, scaled to fill the buffer.
    func draw(_ image: CGImage) {
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.setBlendMode(.normal)
        context.interpolationQuality = .high
        context.draw(image, in: rect)
    }

    /// The smallest rectangle (x, y, w, h) outside which this frame equals `old`.
    func changed(since old: Frame) -> (x: Int, y: Int, w: Int, h: Int)? {
        guard old.width == width, old.height == height else { return (0, 0, width, height) }
        let a = UnsafeRawPointer(pixels)
        let b = UnsafeRawPointer(old.pixels)
        let stride = width * 4
        var minY = -1, maxY = -1, minX = width, maxX = -1
        for y in 0..<height {
            let ra = a + y * stride, rb = b + y * stride
            if memcmp(ra, rb, stride) == 0 { continue }
            if minY < 0 { minY = y }
            maxY = y
            var x = 0
            while x < minX, ra.load(fromByteOffset: x * 4, as: UInt32.self) == rb.load(fromByteOffset: x * 4, as: UInt32.self) {
                x += 1
            }
            minX = min(minX, x)
            x = width - 1
            while x > maxX, ra.load(fromByteOffset: x * 4, as: UInt32.self) == rb.load(fromByteOffset: x * 4, as: UInt32.self) {
                x -= 1
            }
            maxX = max(maxX, x)
        }
        guard minY >= 0 else { return nil }
        return (minX, minY, maxX - minX + 1, maxY - minY + 1)
    }

    /// The RGB bytes of a rectangle, row by row.
    func rgb(x: Int, y: Int, w: Int, h: Int) -> Data {
        var out = Data(count: w * h * 3)
        let src = pixels
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var d = dst.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for row in y..<(y + h) {
                var s = src + (row * width + x) * 4
                for _ in 0..<w {
                    d[0] = s[0]
                    d[1] = s[1]
                    d[2] = s[2]
                    d += 3
                    s += 4
                }
            }
        }
        return out
    }
}
