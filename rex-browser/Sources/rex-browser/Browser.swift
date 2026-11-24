import AppKit
import WebKit

/// An offscreen window that always reports itself key, so WebKit treats the
/// page as focused (carets blink, keyboard input lands) while Rex has focus.
final class HostWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override var isKeyWindow: Bool { true }
    override var isMainWindow: Bool { true }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// The page view. Real pointer moves reach WebKit through tracking areas, not
/// through the view; the hidden window sits on a real screen under the real
/// cursor, so those areas are removed and only rex-browser's moves get in.
final class PageView: WKWebView {
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
    }

    override func cursorUpdate(with event: NSEvent) {}

    /// WKWebView has no `mouseMoved:` of its own (moves arrive through its
    /// tracking-area owner), so a move is handed to WebKit with its private
    /// `_simulateMouseMove:`, which is what that owner calls.
    func simulateMove(_ event: NSEvent) {
        let sel = NSSelectorFromString("_simulateMouseMove:")
        if responds(to: sel) {
            perform(sel, with: event)
        } else {
            Log.write("missing _simulateMouseMove:")
        }
    }
}

/// Calls a private WebKit setter if this WebKit has it.
@MainActor
func callSPI(_ object: NSObject, _ name: String, bool value: Bool) {
    let sel = NSSelectorFromString(name)
    guard object.responds(to: sel), let imp = object.method(for: sel) else {
        Log.write("missing SPI \(name)")
        return
    }
    typealias Fn = @convention(c) (AnyObject, Selector, Bool) -> Void
    unsafeBitCast(imp, to: Fn.self)(object, sel, value)
}

@MainActor
func callSPI(_ object: NSObject, _ name: String, float value: CGFloat) {
    let sel = NSSelectorFromString(name)
    guard object.responds(to: sel), let imp = object.method(for: sel) else {
        Log.write("missing SPI \(name)")
        return
    }
    typealias Fn = @convention(c) (AnyObject, Selector, CGFloat) -> Void
    unsafeBitCast(imp, to: Fn.self)(object, sel, value)
}

@MainActor
final class Browser: NSObject, WKNavigationDelegate, WKUIDelegate {
    let opts: Options
    let term = Terminal()
    let parser = InputParser()
    let kitty: KittyImage
    var window: HostWindow!
    var web: PageView!
    var observations: [NSKeyValueObservation] = []
    var sources: [DispatchSourceProtocol] = []
    var timer: Timer?

    // Geometry: the top row is the address bar, the image fills the rest.
    let barRows = 1
    var barHeight = 28
    var barButtons: [(Range<Int>, BarAction)] = []
    var barTimer: Timer?
    /// Blinks the caret while the address is being edited (macOS's rate).
    var blinkTimer: Timer?
    var caretVisible = true
    /// The colors last given to each row's edge cells, which Rex extends into
    /// the pane's side padding ("Fill Padding with Program Colors").
    var edgeColors: [String] = []
    var pageBackground: (UInt8, UInt8, UInt8)?
    var tsize = Terminal.Size(cols: 80, rows: 24, xpx: 0, ypx: 0)
    var cellW = 14.0
    var cellH = 28.0
    var scale: CGFloat = 2
    var generation = 0

    // Frames.
    var pxW = 0
    var pxH = 0
    var previous: Pixels?
    var lastImage: CGImage?
    var rgbBuffer: [UInt8] = []
    var frameRequested = false
    var lastSnapshot = 0.0
    var snapshotScheduled = false
    var pendingScroll: (dx: Double, dy: Double, point: CGPoint)?
    var scrollInFlight = false
    var snapshotting = false
    var idleFrames = 0
    var ticks = 0
    struct Stats {
        var frames = 0, sentFrames = 0, pixels = 0
        var rects = 0, shifts = 0, busy = 0
        var snap = 0.0, draw = 0.0, diff = 0.0, scroll = 0.0, pack = 0.0, send = 0.0
        var since = Date()
    }
    var stats = Stats()
    var loggedFormat = false

    // Address bar.
    var editing = false
    var edit: [Character] = []
    var cursor = 0
    var notice: String?
    var noticeUntil = Date.distantPast

    // Mouse.
    var leftDown = false
    var lastClick = (time: 0.0, point: CGPoint.zero, count: 0)
    var resizePending = false

    init(options: Options) {
        opts = options
        kitty = KittyImage(term: term, inline: options.inline)
        super.init()
    }

    var lastVideoFrame = 0.0
    var capture: WindowCapture?
    var captured: CGImage?

    /// Window capture: the window server streams the hidden window's
    /// composited frames (with video, about 0 ms each, versus a software
    /// repaint of the whole page per snapshot). Falls back to snapshots if it
    /// can't start; REX_BROWSER_SNAPSHOT=1 forces snapshots.
    func startCapture() {
        guard ProcessInfo.processInfo.environment["REX_BROWSER_SNAPSHOT"] != "1" else { return }
        let c = WindowCapture()
        c.onFrame = { [weak self] image, _ in
            MainActor.assumeIsolated {
                self?.captured = image
                self?.flushCaptured()
            }
        }
        c.onFailure = { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.capture != nil else { return }
                self.capture = nil
                Log.write("capture: falling back to snapshots")
                self.requestFrame()
            }
        }
        c.start(windowNumber: window.windowNumber, width: pxW, height: pxH)
        capture = c
    }

    /// Sends the latest captured frame once the terminal has read the last
    /// one. Capture only delivers changes, so a frame that had to wait is
    /// kept, never dropped.
    func flushCaptured() {
        guard let image = captured else { return }
        if kitty.busy {
            stats.busy += 1
            return
        }
        captured = nil
        present(image, snapMs: 0)
    }

    func videoFrame() {
        lastVideoFrame = CACurrentMediaTime()
        requestFrame()
    }

    // MARK: Lifecycle

    func start() {
        term.enterRaw()
        // Hide the cursor, clear, and turn on any-motion SGR mouse reports in
        // pixels (1003, 1006, 1016) and bracketed paste (2004). Normal screen:
        // Rex doesn't draw kitty images on the alternate one.
        term.write("\u{1b}[?7l\u{1b}[?25l\u{1b}[H\u{1b}[2J\u{1b}[3J\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016h\u{1b}[?2004h")

        let config = WKWebViewConfiguration()
        config.preferences.inactiveSchedulingPolicy = .none
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        // Nothing outlives the pane: cookies, storage and cache stay in memory.
        config.websiteDataStore = .nonPersistent()
        // Each presented video frame asks for a snapshot, so video is sampled
        // in step with its own frames instead of beating against the timer.
        config.userContentController.add(VideoFrames(self), name: "rexFrame")
        config.userContentController.addUserScript(WKUserScript(
            source: VideoFrames.script, injectionTime: .atDocumentStart, forMainFrameOnly: false
        ))
        web = PageView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        // The window is offscreen, so keep WebKit from treating the page as
        // hidden (which throttles timers and stops rendering).
        callSPI(web, "_setWindowOcclusionDetectionEnabled:", bool: false)

        window = HostWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        // On a real screen (so it composites at its Retina scale) but below
        // the desktop wallpaper, where nothing can show it.
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        // Not a window anyone should see: keep it out of Mission Control,
        // window cycling and the Window menu.
        window.collectionBehavior = [.transient, .ignoresCycle, .fullScreenNone]
        window.isExcludedFromWindowsMenu = true
        window.contentView = web
        window.orderFrontRegardless()
        window.makeFirstResponder(web)

        layout()
        observe()
        listen()
        startCapture()

        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t

        if let url = opts.url, let resolved = resolve(url) {
            open(resolved)
        } else {
            startEditing(prefill: "")
        }
        renderBar()
    }

    func quit() {
        timer?.invalidate()
        capture?.stop()
        kitty.delete()
        term.write("\u{1b}[?7h\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?2004l\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25h")
        term.restore()
        kitty.cleanup()
        exit(0)
    }

    private func listen() {
        let input = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        input.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                var buf = [UInt8](repeating: 0, count: 65536)
                let n = read(0, &buf, buf.count)
                if n <= 0 { self.quit() }
                let events = self.parser.feed(Array(buf[0..<n]))
                for (i, event) in events.enumerated() {
                    // Only the last of a run of pointer moves matters.
                    if case .mouse(let m) = event, m.kind == .move, i + 1 < events.count,
                       case .mouse(let next) = events[i + 1], next.kind == .move { continue }
                    self.handle(event)
                }
                if !events.isEmpty { self.requestFrame() }
            }
        }
        input.resume()
        sources.append(input)

        for sig in [SIGWINCH, SIGTERM, SIGHUP, SIGINT, SIGUSR1] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch sig {
                    case SIGWINCH: self.scheduleLayout()
                    case SIGUSR1: self.dumpFrame()
                    default: self.quit()
                    }
                }
            }
            s.resume()
            sources.append(s)
        }
    }

    /// Writes the last frame sent to the pane as a PNG (on SIGUSR1), for debugging.
    /// On SIGUSR1: writes the last snapshot as a PNG and its RGB bytes, for debugging.
    private func dumpFrame() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
        if let image = lastImage,
           let dest = CGImageDestinationCreateWithURL(dir.appendingPathComponent("rex-browser-frame.png") as CFURL,
                                                      "public.png" as CFString, 1, nil) {
            CGImageDestinationAddImage(dest, image, nil)
            CGImageDestinationFinalize(dest)
        }
        if let frame = previous {
            frame.rgb(Rect(x: 0, y: 0, w: frame.width, h: frame.height), into: &rgbBuffer)
            let data = Data(rgbBuffer[0..<(frame.width * frame.height * 3)])
            try? data.write(to: dir.appendingPathComponent("rex-browser-frame.rgb"))
        }
        Log.write("frame written to \(dir.path)/rex-browser-frame.{png,rgb}")
    }

    private func observe() {
        let refresh: () -> Void = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.wake()
                    self?.renderBar()
                }
            }
        }
        observations = [
            web.observe(\.title) { _, _ in refresh() },
            web.observe(\.url) { _, _ in refresh() },
            web.observe(\.estimatedProgress) { _, _ in refresh() },
            web.observe(\.isLoading) { _, _ in refresh() },
            web.observe(\.canGoBack) { _, _ in refresh() },
            web.observe(\.canGoForward) { _, _ in refresh() },
        ]
    }

    // MARK: Layout

    private func scheduleLayout() {
        guard !resizePending else { return }
        resizePending = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.resizePending = false
                self?.layout()
            }
        }
    }

    func layout() {
        tsize = term.size()
        let cols = max(tsize.cols, 1)
        let rows = max(tsize.rows, barRows + 1)
        if tsize.xpx > 0, tsize.ypx > 0 {
            cellW = Double(tsize.xpx) / Double(cols)
            cellH = Double(tsize.ypx) / Double(rows)
        }
        // Rex reports device pixels; cells taller than 20 px mean a 2x screen.
        scale = opts.scale ?? (cellH >= 20 ? 2 : 1)
        callSPI(web, "_setOverrideDeviceScaleFactor:", float: scale)

        let width = Int((Double(cols) * cellW).rounded())
        // The image covers every row; its top row is the drawn address bar.
        barHeight = Int(cellH.rounded())
        kitty.top = barHeight
        let height = Int((Double(rows) * cellH).rounded()) - barHeight
        window.setContentSize(NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        window.setFrameOrigin(NSScreen.main?.frame.origin ?? .zero)

        pxW = width
        pxH = height
        capture?.resize(width: width, height: height)
        previous = nil
        generation += 1
        // A narrower pane rewraps the old address bar onto the rows below,
        // whose gray then shows beside the image: blank every row (line by
        // line, since clearing the screen would delete the image), then
        // stretch the old frame over the new size until the sharp one lands.
        var blank = "\u{1b}[0m"
        for r in 1...rows { blank += "\u{1b}[\(r);1H\u{1b}[2K" }
        term.write(blank)
        edgeColors = []
        kitty.place(cols: cols, rows: rows, row: 1)
        renderBar()
        requestFrame()
        Log.write("layout \(cols)x\(rows) cells, \(width)x\(height) px, cell \(cellW)x\(cellH), scale \(scale)")
    }

    // MARK: Frames

    func wake() { idleFrames = 0 }

    private func tick() {
        ticks += 1
        if Date() > noticeUntil, notice != nil {
            notice = nil
            renderBar()
        }
        // A resize can land before the SIGWINCH handler exists; check 4 times a second.
        if ticks % 15 == 0, !resizePending, term.size() != tsize { scheduleLayout() }
        // Still pages are checked 10 times a second, then 4 after 5 s.
        if capture != nil {
            flushCaptured()
            return
        }
        if !frameRequested {
            // While a video drives frames, the timer only looks for other changes.
            if CACurrentMediaTime() - lastVideoFrame < 0.2, ticks % 4 != 0 { return }
            if idleFrames > 80, ticks % 15 != 0 { return }
            if idleFrames > 30, ticks % 6 != 0 { return }
        }
        snapshot()
    }

    /// Takes a snapshot now (or right after the one in flight), for input.
    func requestFrame() {
        frameRequested = true
        idleFrames = 0
        snapshot()
    }

    private func snapshot() {
        // With window capture running, frames come from it, not snapshots.
        if capture != nil {
            flushCaptured()
            return
        }
        guard !snapshotting, pxW > 0, pxH > 0 else { return }
        // At most 120 snapshots a second; a request that comes sooner waits.
        let wait = lastSnapshot + 1.0 / 120 - CACurrentMediaTime()
        if wait > 0 {
            if !snapshotScheduled {
                snapshotScheduled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                    MainActor.assumeIsolated {
                        self?.snapshotScheduled = false
                        self?.snapshot()
                    }
                }
            }
            return
        }
        // Don't queue frames the terminal hasn't caught up with; the timer retries.
        if kitty.busy {
            stats.busy += 1
            return
        }
        frameRequested = false
        snapshotting = true
        let gen = generation
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        let started = CACurrentMediaTime()
        lastSnapshot = started
        web.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotting = false
            if gen == self.generation, let image,
               let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.present(cg, snapMs: (CACurrentMediaTime() - started) * 1000)
            }
            if self.frameRequested { self.snapshot() }
        }
    }

    private func present(_ image: CGImage, snapMs: Double) {
        if !loggedFormat, Log.enabled {
            loggedFormat = true
            Log.write("snapshot \(image.width)x\(image.height) \(image.colorSpace?.name as String? ?? "?") bpp \(image.bitsPerPixel) info \(image.bitmapInfo.rawValue) alpha \(image.alphaInfo.rawValue)")
        }
        var t = CACurrentMediaTime()
        func lap() -> Double { let n = CACurrentMediaTime(); defer { t = n }; return (n - t) * 1000 }
        guard let frame = Pixels.from(image, width: pxW, height: pxH) else { return }
        lastImage = image
        stats.frames += 1
        stats.snap += snapMs
        stats.draw += lap()

        guard let old = previous, kitty.placed else {
            let full = Rect(x: 0, y: 0, w: frame.width, h: frame.height)
            frame.rgb(full, into: &rgbBuffer)
            stats.pack += lap()
            let rows = max(tsize.rows, barRows + 1)
            rgbBuffer.withUnsafeBytes { buf in
                kitty.create(UnsafeRawBufferPointer(rebasing: buf[0..<(full.area * 3)]), width: full.w, height: full.h,
                             cols: max(tsize.cols, 1), rows: rows, row: 1)
            }
            stats.send += lap()
            stats.pixels += full.area
            stats.sentFrames += 1
            previous = frame
            idleFrames = 0
            paintEdges(frame)
            renderBar()
            logStats()
            return
        }

        var rects = frame.changes(since: old)
        stats.diff += lap()
        guard !rects.isEmpty else {
            idleFrames += 1
            logStats()
            return
        }
        // A big change is usually a scroll: move what's already on screen and
        // send only what's new, when that's at most half as many pixels.
        var shifts: [Shift] = []
        let area = rects.reduce(0) { $0 + $1.area }
        if area > frame.width * frame.height / 4 {
            let runs = frame.scroll(from: old)
            if !runs.isEmpty {
                let shifted = frame.changes(since: old, shifts: runs)
                if shifted.reduce(0, { $0 + $1.area }) * 2 < area {
                    shifts = runs
                    rects = shifted
                }
            }
        }
        stats.scroll += lap()
        kitty.shift(shifts, width: frame.width)
        if !shifts.isEmpty { stats.shifts += 1 }
        for r in rects {
            frame.rgb(r, into: &rgbBuffer)
            stats.pack += lap()
            rgbBuffer.withUnsafeBytes { buf in
                kitty.update(UnsafeRawBufferPointer(rebasing: buf[0..<(r.area * 3)]), r)
            }
            stats.send += lap()
            stats.pixels += r.area
            stats.rects += 1
        }
        stats.sentFrames += 1
        previous = frame
        idleFrames = 0
        paintEdges(frame)
        logStats()
    }

    private func logStats() {
        guard Log.enabled else { return }
        let elapsed = Date().timeIntervalSince(stats.since)
        guard elapsed >= 2 else { return }
        let n = Double(max(stats.frames, 1)), m = Double(max(stats.sentFrames, 1))
        Log.write(String(
            format: "%.0f snap/s %.0f sent/s | per snapshot: snap %.1f read %.1f diff %.1f ms | per sent: scroll %.1f pack %.1f send %.1f ms, %.0f kpx, %.1f rects, %d shifts | %.1f MB/s | %d waits for the terminal",
            n / elapsed, Double(stats.sentFrames) / elapsed, stats.snap / n, stats.draw / n, stats.diff / n,
            stats.scroll / m, stats.pack / m, stats.send / m, Double(stats.pixels) / m / 1000,
            Double(stats.rects) / m, stats.shifts, Double(kitty.bytesSent) / elapsed / 1e6, stats.busy
        ))
        stats = Stats()
        kitty.resetBytes()
    }

    // MARK: Address bar

    /// Colors each row's first and last cell so Rex's side padding, which
    /// takes its color from those cells, blends into the page: the bar's gray
    /// beside the bar, and one color for every page row: the page's own
    /// background (read from its CSS), else its most common solid edge color.
    /// Per-row edge sampling would turn into blocks beside images and video.
    /// The cells sit under the image, so only the padding shows them.
    private func paintEdges(_ frame: Pixels) {
        let rows = max(tsize.rows, 1), cols = max(tsize.cols, 1)
        if edgeColors.count != rows { edgeColors = Array(repeating: "", count: rows) }
        let page = pageBackground ?? commonEdgeColor(frame)
        var out = ""
        for r in 0..<rows {
            let c = r < barRows ? (UInt8(48), UInt8(48), UInt8(48)) : page
            let key = "\(c)"
            guard edgeColors[r] != key else { continue }
            edgeColors[r] = key
            let sgr = "\u{1b}[48;2;\(c.0);\(c.1);\(c.2)m "
            out += "\u{1b}[\(r + 1);1H" + sgr + "\u{1b}[\(r + 1);\(cols)H" + sgr
        }
        if !out.isEmpty { term.write(out + "\u{1b}[0m") }
    }

    /// The color most rows' edges are, counting only rows where the edge is
    /// one solid color for the whole row.
    private func commonEdgeColor(_ frame: Pixels) -> (UInt8, UInt8, UInt8) {
        var counts: [String: ((UInt8, UInt8, UInt8), Int)] = [:]
        let rows = max(tsize.rows, 1)
        for r in barRows..<rows {
            let y0 = max(Int(Double(r) * cellH) - barHeight, 0)
            let y1 = min(Int(Double(r + 1) * cellH) - barHeight, frame.height)
            guard y1 > y0 else { continue }
            for x in [0, frame.width - 1] {
                let c = frame.color(x: x, y: y0)
                if (y0..<y1).allSatisfy({ frame.color(x: x, y: $0) == c }) {
                    let k = "\(c)"
                    counts[k] = (c, (counts[k]?.1 ?? 0) + 1)
                }
            }
        }
        return counts.values.max(by: { $0.1 < $1.1 })?.0 ?? frame.color(x: 0, y: 0)
    }

    /// Reads the page's background color (html, else body) after loads.
    func refreshBackground() {
        let js = """
        (() => {
          for (const e of [document.documentElement, document.body]) {
            if (!e) continue;
            const c = getComputedStyle(e).backgroundColor;
            if (c && c !== 'transparent' && !/rgba\\(.*,\\s*0\\)$/.test(c)) return c;
          }
          return '';
        })()
        """
        web.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let numbers = ((result as? String) ?? "").split(whereSeparator: { !"0123456789.".contains($0) }).compactMap { Double($0) }
                let color = numbers.count >= 3 ? (UInt8(min(numbers[0], 255)), UInt8(min(numbers[1], 255)), UInt8(min(numbers[2], 255))) : nil
                guard "\(String(describing: color))" != "\(String(describing: self.pageBackground))" else { return }
                self.pageBackground = color
                if let frame = self.previous { self.paintEdges(frame) }
            }
        }
    }

    /// Redraws the address bar into the top of the image. Calls within one
    /// run-loop pass (KVO bursts while loading) draw once.
    func renderBar() {
        updateBlink()
        guard barTimer == nil else { return }
        barTimer = Timer.scheduledTimer(withTimeInterval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.barTimer = nil
                self?.drawBar()
            }
        }
    }

    /// Starts or stops the caret blink with editing; any redraw (a key, a
    /// click) shows the caret again and restarts the blink.
    private func updateBlink() {
        caretVisible = true
        blinkTimer?.invalidate()
        blinkTimer = nil
        guard editing else { return }
        let t = Timer(timeInterval: 0.53, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.editing else { return }
                self.caretVisible.toggle()
                self.drawBar()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        blinkTimer = t
    }

    private func drawBar() {
        guard web != nil else { return }
        var state = BarState()
        state.canGoBack = web.canGoBack
        state.canGoForward = web.canGoForward
        state.loading = web.isLoading
        state.progress = web.estimatedProgress
        state.title = web.title ?? ""
        state.url = web.url?.absoluteString ?? ""
        state.notice = notice
        state.editing = editing
        state.edit = String(edit)
        state.cursor = cursor
        state.caretVisible = caretVisible
        let width = Int((Double(max(tsize.cols, 1)) * cellW).rounded())
        let (rgb, buttons) = BarRenderer.render(state, width: width, height: barHeight, scale: scale)
        barButtons = buttons
        kitty.updateBar(rgb, width: width)
    }

    func show(notice text: String) {
        notice = text
        noticeUntil = Date().addingTimeInterval(4)
        renderBar()
    }

    func startEditing(prefill: String) {
        editing = true
        edit = Array(prefill)
        cursor = edit.count
        renderBar()
    }

    func stopEditing() {
        editing = false
        renderBar()
    }

    private func editKey(_ key: Key, _ mods: Mods) {
        switch key {
        case .char(let c):
            edit.insert(c, at: cursor)
            cursor += 1
        case .backspace:
            if mods.contains(.alt) {
                while cursor > 0, edit[cursor - 1] == " " { edit.remove(at: cursor - 1); cursor -= 1 }
                while cursor > 0, edit[cursor - 1] != " " { edit.remove(at: cursor - 1); cursor -= 1 }
            } else if cursor > 0 {
                edit.remove(at: cursor - 1)
                cursor -= 1
            }
        case .delete:
            if cursor < edit.count { edit.remove(at: cursor) }
        case .left: cursor = max(0, cursor - 1)
        case .right: cursor = min(edit.count, cursor + 1)
        case .home, .ctrl("a"): cursor = 0
        case .end, .ctrl("e"): cursor = edit.count
        case .ctrl("u"):
            edit.removeFirst(cursor)
            cursor = 0
        case .ctrl("k"): edit.removeLast(edit.count - cursor)
        case .ctrl("c"), .ctrl("q"): quit()
        case .enter:
            let text = String(edit)
            stopEditing()
            if let url = resolve(text) { open(url) }
            return
        case .escape:
            stopEditing()
            return
        default: break
        }
        renderBar()
    }

    /// A URL for what was typed: a URL, a path, a host[:port], or a search.
    func resolve(_ input: String) -> URL? {
        let t = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let u = URL(string: t), let scheme = u.scheme?.lowercased(),
           ["http", "https", "file", "about", "data"].contains(scheme) {
            return u
        }
        if t.hasPrefix("/") || t.hasPrefix("~") {
            return URL(fileURLWithPath: (t as NSString).expandingTildeInPath)
        }
        if t.range(of: #"^(localhost|127\.\d+\.\d+\.\d+|0\.0\.0\.0|\[::1\])(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
            || t.range(of: #"^[\w.-]+:\d+(/.*)?$"#, options: .regularExpression) != nil {
            return URL(string: "http://" + t)
        }
        if !t.contains(" "), t.contains(".") {
            return URL(string: "https://" + t)
        }
        var c = URLComponents(string: "https://duckduckgo.com/")!
        c.queryItems = [URLQueryItem(name: "q", value: t)]
        return c.url
    }

    func open(_ url: URL) {
        if url.isFileURL {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            web.load(URLRequest(url: url))
        }
        wake()
    }

    // MARK: Input

    private func handle(_ event: InputEvent) {
        wake()
        Log.write("input \(event)")
        switch event {
        case .paste(let text):
            if editing {
                let clean = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
                edit.insert(contentsOf: clean, at: cursor)
                cursor += clean.count
                renderBar()
            } else {
                web.callAsyncJavaScript(
                    "document.execCommand('insertText', false, text)", arguments: ["text": text],
                    in: nil, in: .page, completionHandler: nil
                )
            }
        case .mouse(let m):
            mouse(m)
        case .key(let key, let mods):
            if editing {
                editKey(key, mods)
            } else {
                pageKey(key, mods)
            }
        }
    }

    private func pageKey(_ key: Key, _ mods: Mods) {
        switch key {
        case .ctrl("c"), .ctrl("q"): quit()
        case .ctrl("l"): startEditing(prefill: web.url?.absoluteString ?? "")
        case .ctrl("r"): web.reload()
        case .left where mods.contains(.alt): web.goBack()
        case .right where mods.contains(.alt): web.goForward()
        case .char("=") where mods.contains(.alt), .char("+") where mods.contains(.alt):
            web.pageZoom = min(web.pageZoom * 1.1, 5)
        case .char("-") where mods.contains(.alt):
            web.pageZoom = max(web.pageZoom / 1.1, 0.25)
        case .char("0") where mods.contains(.alt):
            web.pageZoom = 1
        default:
            Keys.send(key, mods, to: web, window: window)
        }
    }

    private func mouse(_ m: Mouse) {
        // Pixel position in the pane (1016 reports 1-based pixels).
        let px = Double(m.x - 1)
        let py = Double(m.y - 1)
        let pageY = py - Double(barHeight)
        if pageY < 0, !leftDown {
            if m.kind == .press, m.button == 0 { barClick(Int(px)) }
            return
        }
        let point = CGPoint(x: px / scale, y: max(pageY, 0) / scale)
        var flags: NSEvent.ModifierFlags = []
        if m.mods.contains(.shift) { flags.insert(.shift) }
        if m.mods.contains(.alt) { flags.insert(.option) }
        if m.mods.contains(.ctrl) { flags.insert(.control) }

        switch m.kind {
        case .press where m.button == 0:
            if editing { stopEditing() }
            let now = ProcessInfo.processInfo.systemUptime
            let near = abs(point.x - lastClick.point.x) < 5 && abs(point.y - lastClick.point.y) < 5
            let count = (now - lastClick.time < NSEvent.doubleClickInterval && near) ? min(lastClick.count + 1, 3) : 1
            lastClick = (now, point, count)
            leftDown = true
            mouseEvent(.leftMouseDown, at: point, flags: flags, clicks: count)
        case .release where m.button == 0 || leftDown:
            guard leftDown else { return }
            leftDown = false
            mouseEvent(.leftMouseUp, at: point, flags: flags, clicks: lastClick.count)
        case .drag where m.button == 0:
            mouseEvent(.leftMouseDragged, at: point, flags: flags, clicks: 0)
        case .move:
            mouseEvent(leftDown ? .leftMouseDragged : .mouseMoved, at: point, flags: flags, clicks: 0)
        case .wheel:
            let step = 48.0
            let (dx, dy): (Double, Double)
            switch m.button {
            case 0: (dx, dy) = (0, step)
            case 1: (dx, dy) = (0, -step)
            case 2: (dx, dy) = (step, 0)
            default: (dx, dy) = (-step, 0)
            }
            m.mods.contains(.shift) ? scroll(dx: dy, dy: dx, at: point) : scroll(dx: dx, dy: dy, at: point)
        default:
            break
        }
    }

    private func barClick(_ x: Int) {
        switch barButtons.first(where: { $0.0.contains(x) })?.1 ?? .edit {
        case .back: web.goBack()
        case .forward: web.goForward()
        case .reload: if web.isLoading { web.stopLoading() } else { web.reload() }
        case .edit: startEditing(prefill: web.url?.absoluteString ?? "")
        }
    }

    /// `point` is in the page's points, from its top-left corner.
    private func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint, flags: NSEvent.ModifierFlags, clicks: Int) {
        let location = NSPoint(x: point.x, y: web.bounds.height - point.y)
        guard let event = NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: flags,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .leftMouseDown ? 1 : 0
        ) else { return }
        switch type {
        case .leftMouseDown: web.mouseDown(with: event)
        case .leftMouseUp: web.mouseUp(with: event)
        case .leftMouseDragged: web.mouseDragged(with: event)
        default: web.simulateMove(event)
        }
    }

    /// Scrolls the scrollable element under `point` by (dx, dy) points, as a
    /// wheel does: page wheel listeners see it first and may cancel it.
    private func scroll(dx: Double, dy: Double, at point: CGPoint) {
        if let p = pendingScroll {
            pendingScroll = (p.dx + dx, p.dy + dy, point)
        } else {
            pendingScroll = (dx, dy, point)
        }
        flushScroll()
    }

    /// Scrolls the scrollable element under the pointer by every wheel tick
    /// that arrived since the last scroll, as a wheel does: page wheel
    /// listeners see it first and may cancel it. One scroll runs at a time.
    private func flushScroll() {
        guard !scrollInFlight, let p = pendingScroll else { return }
        pendingScroll = nil
        scrollInFlight = true
        let js = """
        let el = document.elementFromPoint(x, y);
        const wheel = new WheelEvent('wheel', {deltaX: -dx, deltaY: -dy, clientX: x, clientY: y,
          bubbles: true, cancelable: true, deltaMode: 0});
        if (el && !el.dispatchEvent(wheel)) return;
        const can = (e, d, axis) => {
          if (!d) return false;
          const s = getComputedStyle(e);
          const o = axis === 'y' ? s.overflowY : s.overflowX;
          if (!/(auto|scroll|overlay)/.test(o)) return false;
          if (axis === 'y') return d < 0 ? e.scrollTop + e.clientHeight < e.scrollHeight - 1 : e.scrollTop > 0;
          return d < 0 ? e.scrollLeft + e.clientWidth < e.scrollWidth - 1 : e.scrollLeft > 0;
        };
        while (el && el !== document.body && el !== document.documentElement) {
          if (can(el, dy, 'y') || can(el, dx, 'x')) { el.scrollBy({left: -dx, top: -dy, behavior: 'instant'}); return; }
          el = el.parentElement;
        }
        (document.scrollingElement || document.documentElement).scrollBy({left: -dx, top: -dy, behavior: 'instant'});
        """
        web.callAsyncJavaScript(
            js, arguments: ["x": p.point.x, "y": p.point.y, "dx": p.dx, "dy": p.dy],
            in: nil, in: .page
        ) { [weak self] _ in
            guard let self else { return }
            self.scrollInFlight = false
            self.requestFrame()
            self.flushScroll()
        }
    }

    // MARK: WebKit delegates

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // One page per pane: links that open a new window load here instead.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        show(notice: "alert: " + message)
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        show(notice: "confirmed: " + message)
        completionHandler(true)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?, initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        show(notice: "prompt skipped: " + prompt)
        completionHandler(defaultText)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        refreshBackground()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        pageBackground = nil
        refreshBackground()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        failed(error)
    }

    private func failed(_ error: Error) {
        let e = error as NSError
        if e.domain == NSURLErrorDomain, e.code == NSURLErrorCancelled { return }
        show(notice: e.localizedDescription)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        show(notice: "page crashed; reloading")
        webView.reload()
    }
}

/// Relays `requestVideoFrameCallback` from pages (a weak hop, since the
/// content controller retains its handlers).
final class VideoFrames: NSObject, WKScriptMessageHandler {
    weak var browser: Browser?

    init(_ browser: Browser) { self.browser = browser }

    static let script = """
    (() => {
      const seen = new WeakSet();
      const watch = v => {
        if (seen.has(v) || !v.requestVideoFrameCallback) return;
        seen.add(v);
        const frame = () => {
          try { webkit.messageHandlers.rexFrame.postMessage(0); } catch (e) {}
          v.requestVideoFrameCallback(frame);
        };
        v.requestVideoFrameCallback(frame);
      };
      document.addEventListener('play', e => { if (e.target instanceof HTMLVideoElement) watch(e.target); }, true);
    })();
    """

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated { browser?.videoFrame() }
    }
}
