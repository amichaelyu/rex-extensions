import AppKit

let usage = """
rex-browser [URL] [--inline] [--scale N] [--log FILE]

A WebKit browser drawn into the terminal pane with the kitty graphics protocol.
The top row is the address bar; the page fills the rest.

  URL          page to open (a URL, host:port, path, or search words);
               without one, the address bar opens for typing
  --inline     send frames as base64 through the tty instead of temp files,
               for a terminal on another machine
  --scale N    device pixels per point (default: 2 when cells are >= 20 px tall)
  --log FILE   write timings and errors to FILE

Keys: ctrl+L address bar, ctrl+R reload, alt+←/→ back/forward,
alt+= / alt+- / alt+0 zoom, ctrl+C or ctrl+Q quit. Click the bar's ← → ↻.
"""

struct Options {
    var url: String?
    var inline = false
    var scale: CGFloat?
    var log: String?
}

enum Log {
    static var enabled = false

    static func write(_ message: String) {
        guard enabled else { return }
        let stamp = String(format: "%.3f", Date().timeIntervalSince1970)
        FileHandle.standardError.write(Data("\(stamp) \(message)\n".utf8))
    }
}

func parseOptions() -> Options {
    var o = Options()
    var args = Array(CommandLine.arguments.dropFirst())
    while !args.isEmpty {
        let a = args.removeFirst()
        switch a {
        case "-h", "--help":
            print(usage)
            exit(0)
        case "--inline":
            o.inline = true
        case "--scale":
            guard let v = args.first, let d = Double(v), d > 0 else { fail("--scale needs a number") }
            o.scale = CGFloat(d)
            args.removeFirst()
        case "--log":
            guard let v = args.first else { fail("--log needs a file") }
            o.log = v
            args.removeFirst()
        default:
            if a.hasPrefix("--") { fail("unknown option \(a)") }
            o.url = o.url.map { $0 + " " + a } ?? a
        }
    }
    return o
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("rex-browser: \(message)\n\n\(usage)\n".utf8))
    exit(2)
}

let options = parseOptions()
guard isatty(0) == 1, isatty(1) == 1 else { fail("run it in a terminal pane") }

// stderr would draw over the pane: send it (and WebKit's own logging) to the
// log file or nowhere.
let errFD = open(options.log ?? "/dev/null", O_WRONLY | O_CREAT | O_APPEND, 0o644)
if errFD >= 0 { dup2(errFD, 2) }
Log.enabled = options.log != nil

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
MainActor.assumeIsolated {
    let browser = Browser(options: options)
    browser.start()
    objc_setAssociatedObject(app, "rex-browser", browser, .OBJC_ASSOCIATION_RETAIN)
}
app.run()
