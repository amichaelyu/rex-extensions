import Accelerate
import CoreGraphics
import Darwin
import Foundation

struct Rect {
    var x: Int
    var y: Int
    var w: Int
    var h: Int
    var area: Int { w * h }
}

/// A vertical shift of rows [start, end) of the new frame, which equal rows
/// [start + by, end + by) of the old one (by > 0 when the page scrolled down).
struct Shift {
    var start: Int
    var end: Int
    var by: Int
}

/// The page as one kitty-graphics image placed over the pane.
///
/// The first frame creates the image and its placement (`a=T`). Later frames
/// overwrite only changed rectangles (`a=f,r=1,x,y,s,v,X=1`), so the placement
/// never flashes; a scroll first moves the rows already on screen inside the
/// terminal (`a=c` through a hidden scratch frame) so only the newly exposed
/// strip is sent. Rex frees an image once it has no placement, so upload and
/// placement always go in one command.
final class KittyImage {
    let term: Terminal
    let inline: Bool
    let id = 6161
    private(set) var placed = false
    /// Gray rows above the page inside the image (padding under the address
    /// bar); page coordinates are offset by this many pixels.
    var top = 0
    /// The address bar's color (xterm 236).
    static let barColor: [UInt8] = [48, 48, 48]
    private var hasScratch = false
    private var sent: [String] = []
    private var lastFile: String?
    private(set) var bytesSent = 0

    init(term: Terminal, inline: Bool) {
        self.term = term
        self.inline = inline
    }

    /// True while the terminal hasn't read the last frame file: sending more
    /// would only queue up stale frames.
    var busy: Bool {
        guard let lastFile else { return false }
        if access(lastFile, F_OK) == 0 { return true }
        self.lastFile = nil
        return false
    }

    func create(_ rgb: UnsafeRawBufferPointer, width: Int, height: Int, cols: Int, rows: Int, row: Int) {
        term.write("\u{1b}[\(row);1H")
        var image = [UInt8]()
        image.reserveCapacity((height + top) * width * 3)
        for _ in 0..<(top * width) { image += Self.barColor }
        image += rgb
        image.withUnsafeBytes { all in
            send("a=T,f=24,s=\(width),v=\(height + top),i=\(id),p=1,c=\(cols),r=\(rows),C=1,q=2", all)
        }
        placed = true
        hasScratch = false
    }

    /// Re-places the current image over a new cell area (the terminal scales it).
    func place(cols: Int, rows: Int, row: Int) {
        guard placed else { return }
        term.write("\u{1b}[\(row);1H\u{1b}_Ga=p,i=\(id),p=1,c=\(cols),r=\(rows),C=1,q=2\u{1b}\\")
    }

    func update(_ rgb: UnsafeRawBufferPointer, _ r: Rect) {
        send("a=f,r=1,i=\(id),x=\(r.x),y=\(r.y + top),s=\(r.w),v=\(r.h),f=24,X=1,q=2", rgb)
    }

    /// Moves runs of rows inside the terminal's copy of the image (frame 1).
    /// A frame can't be composed onto itself where the rectangles overlap, so
    /// every run first goes to frame 2 (a gapless frame that is never shown)
    /// and then all come back; one run's copy can't clobber another's source.
    func shift(_ runs: [Shift], width: Int) {
        guard !runs.isEmpty else { return }
        if !hasScratch {
            let pixel = Data([255, 255, 255]).base64EncodedString()
            term.write("\u{1b}_Ga=f,i=\(id),c=1,s=1,v=1,f=24,z=-1,q=2;\(pixel)\u{1b}\\\u{1b}_Ga=a,i=\(id),s=1,c=1,q=2\u{1b}\\")
            hasScratch = true
        }
        var out = ""
        for s in runs {
            out += "\u{1b}_Ga=c,i=\(id),r=1,c=2,X=0,Y=\(s.start + s.by + top),x=0,y=\(s.start + top),w=\(width),h=\(s.end - s.start),C=1,q=2\u{1b}\\"
        }
        for s in runs {
            out += "\u{1b}_Ga=c,i=\(id),r=2,c=1,X=0,Y=\(s.start + top),x=0,y=\(s.start + top),w=\(width),h=\(s.end - s.start),C=1,q=2\u{1b}\\"
        }
        term.write(out)
    }

    func delete() {
        if placed { term.write("\u{1b}_Ga=d,d=I,i=\(id),q=2\u{1b}\\") }
        placed = false
        hasScratch = false
    }

    func resetBytes() { bytesSent = 0 }

    /// Temp files the terminal hasn't read (and so deleted) yet.
    func cleanup() {
        for path in sent { unlink(path) }
        sent = []
    }

    private func send(_ keys: String, _ data: UnsafeRawBufferPointer) {
        bytesSent += data.count
        if inline {
            let b64 = Array(Data(data).base64EncodedData())
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
        var base = data.baseAddress!
        var left = data.count
        while left > 0 {
            let n = Darwin.write(fd, base, left)
            if n <= 0 { break }
            base += n
            left -= n
        }
        close(fd)
        let path = String(cString: template)
        sent.append(path)
        lastFile = path
        if sent.count > 512 { sent = sent.filter { access($0, F_OK) == 0 } }
        term.write("\u{1b}_G\(keys),t=t;\(Data(path.utf8).base64EncodedString())\u{1b}\\")
    }
}

/// A frame's pixels: 32 bits each, BGRA or RGBA in memory.
final class Pixels {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let bgra: Bool
    let base: UnsafeRawPointer
    private let owner: AnyObject
    private var hashes: [UInt64]?

    private init(width: Int, height: Int, bytesPerRow: Int, bgra: Bool, base: UnsafeRawPointer, owner: AnyObject) {
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.bgra = bgra
        self.base = base
        self.owner = owner
    }

    /// The snapshot's own bytes when they're already sRGB at the pane's size
    /// (one copy out of the image); otherwise a redraw into an RGBA buffer.
    static func from(_ image: CGImage, width: Int, height: Int) -> Pixels? {
        if image.width == width, image.height == height, image.bitsPerPixel == 32, image.bitsPerComponent == 8,
           image.colorSpace?.name == CGColorSpace.sRGB, let data = image.dataProvider?.data,
           let ptr = CFDataGetBytePtr(data) {
            let order = image.bitmapInfo.intersection(.byteOrderMask)
            let alpha = image.alphaInfo
            let first: [CGImageAlphaInfo] = [.premultipliedFirst, .first, .noneSkipFirst]
            let last: [CGImageAlphaInfo] = [.premultipliedLast, .last, .noneSkipLast]
            if order == .byteOrder32Little, first.contains(alpha) {
                return Pixels(width: width, height: height, bytesPerRow: image.bytesPerRow, bgra: true,
                              base: UnsafeRawPointer(ptr), owner: data)
            }
            if order == .byteOrder32Big || order.rawValue == 0, last.contains(alpha) {
                return Pixels(width: width, height: height, bytesPerRow: image.bytesPerRow, bgra: false,
                              base: UnsafeRawPointer(ptr), owner: data)
            }
        }
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        ), let data = ctx.data else { return nil }
        let rect = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(rect)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: rect)
        return Pixels(width: width, height: height, bytesPerRow: width * 4, bgra: false,
                      base: UnsafeRawPointer(data), owner: ctx)
    }

    func row(_ y: Int) -> UnsafeRawPointer { base + y * bytesPerRow }

    /// The rectangles that differ from `old`, as bands of rows (a band ends
    /// after 16 unchanged rows), each as narrow as its changed columns.
    /// Rows inside a shift's range are compared with the old rows it moved.
    func changes(since old: Pixels, shifts: [Shift] = []) -> [Rect] {
        guard old.width == width, old.height == height else { return [Rect(x: 0, y: 0, w: width, h: height)] }
        let rowBytes = width * 4
        var out: [Rect] = []
        var band: (y: Int, last: Int, x0: Int, x1: Int)?
        var run = 0
        for y in 0..<height {
            var oy = y
            while run < shifts.count, y >= shifts[run].end { run += 1 }
            if run < shifts.count, y >= shifts[run].start { oy = y + shifts[run].by }
            let a = row(y), b = old.row(oy)
            if memcmp(a, b, rowBytes) == 0 {
                if let open = band, y - open.last > 16 {
                    out.append(Rect(x: open.x0, y: open.y, w: open.x1 - open.x0 + 1, h: open.last - open.y + 1))
                    band = nil
                }
                continue
            }
            var x0 = 0
            while x0 < width, a.loadUnaligned(fromByteOffset: x0 * 4, as: UInt32.self)
                == b.loadUnaligned(fromByteOffset: x0 * 4, as: UInt32.self) { x0 += 1 }
            var x1 = width - 1
            while x1 > x0, a.loadUnaligned(fromByteOffset: x1 * 4, as: UInt32.self)
                == b.loadUnaligned(fromByteOffset: x1 * 4, as: UInt32.self) { x1 -= 1 }
            if var open = band {
                open.last = y
                open.x0 = min(open.x0, x0)
                open.x1 = max(open.x1, x1)
                band = open
            } else {
                band = (y, y, x0, x1)
            }
        }
        if let open = band {
            out.append(Rect(x: open.x0, y: open.y, w: open.x1 - open.x0 + 1, h: open.last - open.y + 1))
        }
        return out
    }

    /// One hash per row, to find scrolls.
    func rowHashes() -> [UInt64] {
        if let hashes { return hashes }
        var out = [UInt64](repeating: 0, count: height)
        let words = width * 4 / 8
        for y in 0..<height {
            let r = row(y)
            var h0: UInt64 = 0xCBF2_9CE4_8422_2325, h1: UInt64 = 0x8422_2325_CBF2_9CE4
            var i = 0
            while i + 1 < words {
                h0 = (h0 ^ r.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100_0000_01B3
                h1 = (h1 ^ r.loadUnaligned(fromByteOffset: (i + 1) * 8, as: UInt64.self)) &* 0x100_0000_01B3
                i += 2
            }
            if i < words { h0 = (h0 ^ r.loadUnaligned(fromByteOffset: i * 8, as: UInt64.self)) &* 0x100_0000_01B3 }
            if width % 2 == 1 { h1 ^= UInt64(r.loadUnaligned(fromByteOffset: (width - 1) * 4, as: UInt32.self)) }
            out[y] = h0 ^ (h1 &* 31)
        }
        hashes = out
        return out
    }

    /// The vertical shift that explains most of the change from `old`: rows
    /// that appear once in the old frame vote for how far they moved. Returns
    /// every run of at least 16 rows that matches it (sorted, disjoint), so a
    /// sticky header or a lazily loaded image only breaks the run, not the scroll.
    func scroll(from old: Pixels) -> [Shift] {
        guard old.width == width, old.height == height else { return [] }
        let new = rowHashes(), prev = old.rowHashes()
        var index: [UInt64: Int] = [:]
        var repeated = Set<UInt64>()
        for (y, h) in prev.enumerated() {
            if index.updateValue(y, forKey: h) != nil { repeated.insert(h) }
        }
        var votes: [Int: Int] = [:]
        for (y, h) in new.enumerated() where !repeated.contains(h) {
            if let oy = index[h], oy != y { votes[oy - y, default: 0] += 1 }
        }
        guard let (by, count) = votes.max(by: { $0.value < $1.value }), count >= 4 else { return [] }
        var runs: [Shift] = []
        var start = -1
        for y in 0...height {
            let oy = y + by
            let same = y < height && oy >= 0 && oy < height && new[y] == prev[oy]
            if same {
                if start < 0 { start = y }
            } else if start >= 0 {
                if y - start >= 16 { runs.append(Shift(start: start, end: y, by: by)) }
                start = -1
            }
        }
        return runs
    }

    /// The RGB bytes of a rectangle, row by row, into `out` (resized as needed).
    func rgb(_ r: Rect, into out: inout [UInt8]) {
        let needed = r.w * r.h * 3
        if out.count < needed { out = [UInt8](repeating: 0, count: needed) }
        out.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) in
            var src = vImage_Buffer(
                data: UnsafeMutableRawPointer(mutating: base + r.y * bytesPerRow + r.x * 4),
                height: vImagePixelCount(r.h), width: vImagePixelCount(r.w), rowBytes: bytesPerRow
            )
            var dest = vImage_Buffer(
                data: dst.baseAddress!, height: vImagePixelCount(r.h), width: vImagePixelCount(r.w), rowBytes: r.w * 3
            )
            if bgra {
                vImageConvert_BGRA8888toRGB888(&src, &dest, vImage_Flags(kvImageNoFlags))
            } else {
                vImageConvert_RGBA8888toRGB888(&src, &dest, vImage_Flags(kvImageNoFlags))
            }
        }
    }
}
