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
    var web: WKWebView!
    var observations: [NSKeyValueObservation] = []
    var sources: [DispatchSourceProtocol] = []
    var timer: Timer?

    // Geometry: the top row is the address bar, the image fills the rest.
    let barRows = 1
    var tsize = Terminal.Size(cols: 80, rows: 24, xpx: 0, ypx: 0)
    var cellW = 14.0
    var cellH = 28.0
    var scale: CGFloat = 2
    var generation = 0

    // Frames.
    var current: Frame?
    var previous: Frame?
    var snapshotting = false
    var idleFrames = 0
    var ticks = 0
    var stats = (frames: 0, sentFrames: 0, snapMs: 0.0, since: Date())

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

    // MARK: Lifecycle

    func start() {
        term.enterRaw()
        // Hide the cursor, clear, and turn on any-motion SGR mouse reports in
        // pixels (1003, 1006, 1016) and bracketed paste (2004). Normal screen:
        // Rex doesn't draw kitty images on the alternate one.
        term.write("\u{1b}[?25l\u{1b}[2J\u{1b}[?1003h\u{1b}[?1006h\u{1b}[?1016h\u{1b}[?2004h")

        let config = WKWebViewConfiguration()
        config.preferences.inactiveSchedulingPolicy = .none
        config.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        config.websiteDataStore = .default()
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        web.navigationDelegate = self
        web.uiDelegate = self
        // The window is offscreen, so keep WebKit from treating the page as
        // hidden (which throttles timers and stops rendering).
        callSPI(web, "_setWindowOcclusionDetectionEnabled:", bool: false)

        window = HostWindow(
            contentRect: NSRect(x: -30000, y: -30000, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = web
        window.orderFrontRegardless()
        window.makeFirstResponder(web)

        layout()
        observe()
        listen()

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
        kitty.delete()
        term.write("\u{1b}[?1016l\u{1b}[?1006l\u{1b}[?1003l\u{1b}[?2004l\u{1b}[0m\u{1b}[2J\u{1b}[H\u{1b}[?25h")
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
                for event in self.parser.feed(Array(buf[0..<n])) { self.handle(event) }
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
    private func dumpFrame() {
        guard let frame = previous, let image = frame.context.makeImage() else { return }
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("rex-browser-frame.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        Log.write("frame written to \(url.path)")
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
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
        let height = Int((Double(rows - barRows) * cellH).rounded())
        window.setContentSize(NSSize(width: CGFloat(width) / scale, height: CGFloat(height) / scale))
        window.setFrameOrigin(NSPoint(x: -30000, y: -30000))

        current = Frame(width: width, height: height)
        previous = nil
        generation += 1
        kitty.delete()
        term.write("\u{1b}[2J")
        renderBar()
        wake()
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
        guard !snapshotting, current != nil else { return }
        // Idle pages are checked 10 times a second instead of 60.
        if idleFrames > 30, ticks % 6 != 0 { return }
        snapshotting = true
        let gen = generation
        let config = WKSnapshotConfiguration()
        config.rect = web.bounds
        config.snapshotWidth = NSNumber(value: Double(web.bounds.width))
        let started = CACurrentMediaTime()
        web.takeSnapshot(with: config) { [weak self] image, _ in
            guard let self else { return }
            self.snapshotting = false
            guard gen == self.generation, let image,
                  let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
            else { return }
            self.present(cg, snapMs: (CACurrentMediaTime() - started) * 1000)
        }
    }

    private func present(_ image: CGImage, snapMs: Double) {
        guard let frame = current else { return }
        frame.draw(image)
        stats.frames += 1
        stats.snapMs += snapMs

        let rows = max(tsize.rows, barRows + 1) - barRows
        if let old = previous, kitty.placed {
            guard let r = frame.changed(since: old) else {
                idleFrames += 1
                logStats(image)
                return
            }
            kitty.update(frame.rgb(x: r.x, y: r.y, w: r.w, h: r.h), x: r.x, y: r.y, width: r.w, height: r.h)
        } else {
            let rgb = frame.rgb(x: 0, y: 0, w: frame.width, h: frame.height)
            kitty.create(rgb, width: frame.width, height: frame.height, cols: max(tsize.cols, 1), rows: rows, row: barRows + 1)
            renderBar()
        }
        idleFrames = 0
        stats.sentFrames += 1
        // The frame just sent becomes the reference; the old one is redrawn next.
        current = previous ?? Frame(width: frame.width, height: frame.height)
        previous = frame
        logStats(image)
    }

    private func logStats(_ image: CGImage) {
        guard Log.enabled else { return }
        let elapsed = Date().timeIntervalSince(stats.since)
        guard elapsed >= 2 else { return }
        Log.write(String(
            format: "%.0f snapshots/s, %.0f sent/s, %.1f ms/snapshot, %.1f MB/s, image %dx%d",
            Double(stats.frames) / elapsed, Double(stats.sentFrames) / elapsed,
            stats.snapMs / Double(max(stats.frames, 1)), Double(kitty.bytesSent) / elapsed / 1e6,
            image.width, image.height
        ))
        stats = (0, 0, 0, Date())
        kitty.resetBytes()
    }

    // MARK: Address bar

    func renderBar() {
        let cols = max(tsize.cols, 1)
        let bg = "\u{1b}[0m\u{1b}[48;5;236m\u{1b}[38;5;252m"
        let dim = "\u{1b}[38;5;243m"
        let normal = "\u{1b}[38;5;252m"
        var s = "\u{1b}[1;1H" + bg
        if editing {
            let prefix = " › "
            let room = max(cols - prefix.count - 1, 1)
            let first = max(0, cursor - room + 1)
            let shown = String(edit[first..<min(edit.count, first + room)])
            s += prefix + shown + String(repeating: " ", count: max(0, cols - prefix.count - shown.count))
            s += "\u{1b}[1;\(prefix.count + cursor - first + 1)H\u{1b}[?25h"
            term.write(s)
            return
        }
        let back = web.canGoBack ? "←" : dim + "←" + normal
        let forward = web.canGoForward ? "→" : dim + "→" + normal
        let reload = web.isLoading ? "×" : "↻"
        s += " \(back) \(forward) \(reload) " + dim + "│" + normal + " "
        let used = 9
        var text: String
        var detail = ""
        if let notice {
            text = notice
        } else {
            text = web.title ?? ""
            let url = web.url?.absoluteString ?? ""
            if text.isEmpty { text = url } else { detail = url }
        }
        let right = web.isLoading ? " \(Int(web.estimatedProgress * 100))% " : ""
        let room = max(cols - used - right.count, 0)
        let main = truncate(text, room)
        var rest = room - main.count
        s += main
        if !detail.isEmpty, rest > 4 {
            let extra = truncate(detail, rest - 2)
            s += dim + "  " + extra + normal
            rest -= 2 + extra.count
        }
        s += String(repeating: " ", count: max(0, rest)) + dim + right
        s += "\u{1b}[0m\u{1b}[?25l"
        term.write(s)
    }

    private func truncate(_ s: String, _ n: Int) -> String {
        guard n > 0 else { return "" }
        let flat = s.replacingOccurrences(of: "\n", with: " ")
        return flat.count <= n ? flat : String(flat.prefix(n - 1)) + "…"
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
        let row = Int(py / cellH)
        let col = Int(px / cellW)

        if row < barRows, !leftDown {
            if m.kind == .press, m.button == 0 { barClick(col) }
            return
        }
        let point = CGPoint(x: px / scale, y: (py - Double(barRows) * cellH) / scale)
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

    private func barClick(_ col: Int) {
        switch col {
        case 0...2: web.goBack()
        case 3...4: web.goForward()
        case 5...6: if web.isLoading { web.stopLoading() } else { web.reload() }
        default: startEditing(prefill: web.url?.absoluteString ?? "")
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
        default: web.mouseMoved(with: event)
        }
    }

    /// Scrolls the scrollable element under `point` by (dx, dy) points, as a
    /// wheel does: page wheel listeners see it first and may cancel it.
    private func scroll(dx: Double, dy: Double, at point: CGPoint) {
        if ProcessInfo.processInfo.environment["REX_BROWSER_NATIVE_SCROLL"] == "1",
           let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                            wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) {
            let local = NSPoint(x: point.x, y: web.bounds.height - point.y)
            let primary = NSScreen.screens.first?.frame.height ?? 0
            cg.location = CGPoint(x: local.x, y: primary - local.y)
            if let event = NSEvent(cgEvent: cg) {
                web.scrollWheel(with: event)
                return
            }
        }
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
            js, arguments: ["x": point.x, "y": point.y, "dx": dx, "dy": dy],
            in: nil, in: .page, completionHandler: nil
        )
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
