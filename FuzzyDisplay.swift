import Cocoa
import CoreGraphics

// DeskPad-derived display owner. Fuzzy supplies a private command/status directory.
final class DisplayHelper: NSObject, NSApplicationDelegate {
    let directory: URL
    let parent: pid_t
    let physical: NSScreen
    var display: CGVirtualDisplay?
    var stream: CGDisplayStream?
    var preview: NSWindow?
    var timer: Timer?
    var height = 0
    var titleHeight: CGFloat
    var crop = CGRect.zero
    var lastCommand = ""
    var error = ""
    var windowID: CGWindowID = 0
    var windowPID: pid_t = 0
    var previous: (CGPoint, CGSize, Bool)?
    var showPreview = true
    var ready = false
    var settlingUntil = Date.distantPast

    init(directory: URL, parent: pid_t) {
        self.directory = directory
        self.parent = parent
        physical = NSScreen.main!
        let frame = NSWindow.frameRect(forContentRect: CGRect(x: 0, y: 0, width: 1920, height: 1080), styleMask: [.titled, .closable, .miniaturizable, .resizable])
        titleHeight = frame.height - 1080
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        do { try createDisplay() } catch { self.error = error.localizedDescription }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.tick() }
        tick()
    }

    func fail(_ message: String) -> NSError { NSError(domain: "FuzzyDisplay", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    func value(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, attribute as CFString, &result) == .success ? result : nil
    }
    func set(_ element: AXUIElement, _ attribute: String, _ value: CFTypeRef) throws {
        guard AXUIElementSetAttributeValue(element, attribute as CFString, value) == .success else { throw fail("Cannot set Roblox \(attribute). Check Accessibility permission.") }
    }
    func screen() -> NSScreen? {
        guard let id = display?.displayID else { return nil }
        return NSScreen.screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
    }
    func createDisplay() throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(.main)
        descriptor.name = "Fuzzy Display"
        descriptor.vendorID = 0x4675
        descriptor.productID = 0x7A79
        descriptor.serialNum = 1
        descriptor.maxPixelsWide = 1920
        descriptor.maxPixelsHigh = 4096
        descriptor.sizeInMillimeters = CGSize(width: 508, height: 286)
        guard let created = CGVirtualDisplay(descriptor: descriptor) else { throw fail("macOS could not create Fuzzy Display.") }
        display = created
        let insets = physical.frame.height - physical.visibleFrame.height
        try configure(height: Int(ceil(1080 + titleHeight + insets)))
    }
    func configure(height: Int) throws {
        guard let display = display, height >= 1080, height <= 4096 else { throw fail("Invalid display geometry.") }
        stream?.stop()
        stream = nil
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [CGVirtualDisplayMode(width: 1920, height: UInt(height), refreshRate: 60)]
        guard display.apply(settings) else { throw fail("macOS rejected the non-Retina display mode.") }
        self.height = height
        settlingUntil = Date().addingTimeInterval(1)
        ready = false
    }
    func validateDisplay() throws {
        guard let display = display, CGDisplayIsActive(display.displayID) != 0,
              let mode = CGDisplayCopyDisplayMode(display.displayID),
              mode.width == 1920, mode.height == height,
              mode.pixelWidth == 1920, mode.pixelHeight == height,
              let screen = screen(), screen.backingScaleFactor == 1 else {
            throw fail("Fuzzy Display is unavailable or is not running at 1x scale.")
        }
    }
    func window() throws -> (NSRunningApplication, AXUIElement)? {
        let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.roblox.RobloxPlayer" }
        guard apps.count <= 1 else { throw fail("1080p display mode supports one Roblox client. Close the extra clients.") }
        guard let app = apps.first else { return nil }
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        guard let raw = value(ax, kAXMainWindowAttribute) else { return nil }
        return (app, unsafeBitCast(raw, to: AXUIElement.self))
    }
    func frame(_ window: AXUIElement) throws -> (CGPoint, CGSize) {
        guard let p = value(window, kAXPositionAttribute), let s = value(window, kAXSizeAttribute) else { throw fail("Cannot read the Roblox window. Check Accessibility permission.") }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(unsafeBitCast(p, to: AXValue.self), .cgPoint, &point), AXValueGetValue(unsafeBitCast(s, to: AXValue.self), .cgSize, &size) else { throw fail("Cannot read Roblox window geometry.") }
        return (point, size)
    }
    func prepare() throws {
        if Date() < settlingUntil { return }
        try validateDisplay()
        guard AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) else { throw fail("Enable Accessibility permission for Fuzzy Display, then start the macro again.") }
        guard let (app, ax) = try window() else { ready = false; windowID = 0; windowPID = 0; return }
        let pid = app.processIdentifier
        windowPID = pid
        if previous == nil {
            let (point, size) = try frame(ax)
            previous = (point, size, (value(ax, "AXFullScreen") as? Bool) == true)
        }
        if (value(ax, "AXFullScreen") as? Bool) == true {
            try set(ax, "AXFullScreen", kCFBooleanFalse)
            ready = false
            return // Space transitions settle on a later prepare request.
        }
        guard let targetScreen = screen() else { throw fail("Virtual screen disappeared.") }
        let insets = targetScreen.frame.height - targetScreen.visibleFrame.height
        let requiredHeight = Int(ceil(1080 + titleHeight + insets))
        if height != requiredHeight { try configure(height: requiredHeight); return }
        let bounds = CGDisplayBounds(display!.displayID)
        let topInset = targetScreen.frame.maxY - targetScreen.visibleFrame.maxY
        crop = CGRect(x: bounds.minX, y: bounds.minY + topInset + titleHeight, width: 1920, height: 1080)
        var point = CGPoint(x: crop.minX, y: crop.minY - titleHeight)
        var size = CGSize(width: 1920, height: 1080 + titleHeight)
        try set(ax, kAXMinimizedAttribute, kCFBooleanFalse)
        try set(ax, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
        try set(ax, kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
        try set(ax, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
        app.activate(options: [.activateIgnoringOtherApps])
        let (actualPoint, actualSize) = try frame(ax)
        guard abs(actualPoint.x - point.x) < 1, abs(actualPoint.y - point.y) < 1,
              abs(actualSize.width - size.width) < 1, abs(actualSize.height - size.height) < 1 else { throw fail("macOS constrained the Roblox window; the 1920x1080 game area cannot be established.") }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let info = windows.first(where: {
            ($0[kCGWindowOwnerPID as String] as? Int) == Int(pid) &&
            ($0[kCGWindowLayer as String] as? Int) == 0 &&
            (($0[kCGWindowBounds as String] as? [String: CGFloat])?["Width"] ?? 0) >= 1920
        }), let number = info[kCGWindowNumber as String] as? UInt32 else { throw fail("Roblox has no capturable window on Fuzzy Display.") }
        windowPID = pid
        windowID = number
        ready = true
        try startPreview()
    }
    func startPreview() throws {
        guard stream == nil, let display = display else { return }
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else { throw fail("Enable Screen Recording permission for Fuzzy Display, then start the macro again.") }
        if preview == nil {
            let window = NSWindow(contentRect: physical.frame, styleMask: .borderless, backing: .buffered, defer: false)
            window.backgroundColor = .black
            window.ignoresMouseEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
            let view = NSView(frame: window.contentView!.bounds)
            view.wantsLayer = true
            view.layer?.contentsGravity = .resizeAspect
            window.contentView = view
            preview = window
        }
        let bounds = CGDisplayBounds(display.displayID)
        let source = CGRect(x: crop.minX - bounds.minX, y: crop.minY - bounds.minY, width: 1920, height: 1080)
        let properties: [CFString: Any] = [CGDisplayStream.sourceRect: source.dictionaryRepresentation, CGDisplayStream.showCursor: true, CGDisplayStream.preserveAspectRatio: true]
        guard let created = CGDisplayStream(dispatchQueueDisplay: display.displayID, outputWidth: 1920, outputHeight: 1080, pixelFormat: 1_111_970_369, properties: properties as CFDictionary, queue: .main, handler: { [weak self] status, _, surface, _ in
            if status == .frameComplete, let surface = surface { self?.preview?.contentView?.layer?.contents = surface }
        }), created.start() == .success else { throw fail("Cannot stream the Roblox preview. Check Screen Recording permission for Fuzzy Display.") }
        stream = created
        if showPreview { preview?.orderFront(nil) }
    }
    func restore() {
        guard let saved = previous, let pair = try? window() else { return }
        let ax = pair.1
        var point = saved.0
        var size = saved.1
        try? set(ax, kAXPositionAttribute, AXValueCreate(.cgPoint, &point)!)
        try? set(ax, kAXSizeAttribute, AXValueCreate(.cgSize, &size)!)
        if saved.2 { try? set(ax, "AXFullScreen", kCFBooleanTrue) }
    }
    func tick() {
        if kill(parent, 0) != 0 && errno == ESRCH { NSApp.terminate(nil); return }
        do {
            if let data = try? Data(contentsOf: directory.appendingPathComponent("command.json")),
               let command = try JSONSerialization.jsonObject(with: data) as? [String: Any],
               let id = command["id"] as? String, id != lastCommand {
                error = ""
                lastCommand = id
                switch command["action"] as? String {
                case "prepare":
                    if let measured = command["title_height"] as? Double { titleHeight = CGFloat(measured); stream?.stop(); stream = nil }
                    try prepare()
                case "hide": showPreview = false; preview?.orderOut(nil)
                case "show": showPreview = true; preview?.orderFront(nil)
                case "quit": NSApp.terminate(nil); return
                default: throw fail("Unknown helper command.")
                }
            }
            if Date() < settlingUntil { publish(); return }
            try validateDisplay()
            if ready {
                let covering = CGWindowListCopyWindowInfo([.optionOnScreenAboveWindow, .excludeDesktopElements], windowID) as? [[String: Any]] ?? []
                for info in covering where (info[kCGWindowAlpha as String] as? Double ?? 1) > 0 {
                    if let raw = info[kCGWindowBounds as String] as? [String: Any],
                       let frame = CGRect(dictionaryRepresentation: raw as CFDictionary), frame.intersects(crop),
                       (info[kCGWindowOwnerPID as String] as? Int) != Int(windowPID) {
                        throw fail("Another window covers Roblox on Fuzzy Display. Move it away, then restart the macro.")
                    }
                }
                guard let (app, ax) = try window(), app.processIdentifier == windowPID else { ready = false; windowID = 0; publish(); return }
                let (point, size) = try frame(ax)
                if abs(point.x - crop.minX) >= 1 || abs(point.y + titleHeight - crop.minY) >= 1 || size.width != 1920 || abs(size.height - titleHeight - 1080) >= 1 || (value(ax, "AXFullScreen") as? Bool) == true {
                    ready = false
                    throw fail("Roblox moved or changed size. Restart the macro to restore its 1080p game area.")
                }
            }
        } catch { self.error = error.localizedDescription; ready = false }
        publish()
    }
    func publish() {
        var state: [String: Any] = ["protocol": 1, "pid": ProcessInfo.processInfo.processIdentifier, "updated": Date().timeIntervalSince1970, "command": lastCommand, "error": error, "settling": Date() < settlingUntil, "window_ready": ready, "window_id": windowID, "window_pid": windowPID, "title_height": titleHeight]
        if let display = display {
            let bounds = CGDisplayBounds(display.displayID)
            state["display_id"] = display.displayID
            state["display"] = [bounds.minX, bounds.minY, bounds.width, bounds.height]
            state["content"] = [crop.minX, crop.minY, 1920, 1080]
        }
        do { try JSONSerialization.data(withJSONObject: state).write(to: directory.appendingPathComponent("status.json"), options: .atomic) }
        catch { fputs("Cannot write Fuzzy Display status: \(error)\n", stderr); NSApp.terminate(nil) }
    }
    func applicationWillTerminate(_ notification: Notification) { restore(); stream?.stop(); preview?.orderOut(nil); display = nil }
}

if CommandLine.arguments.contains("--version") { print("Fuzzy Display 1.0.0 protocol 1"); exit(0) }
guard CommandLine.arguments.count == 3, let parent = Int32(CommandLine.arguments[2]), parent > 0 else {
    fputs("Usage: FuzzyDisplay SESSION_DIRECTORY PARENT_PID\n", stderr)
    exit(64)
}
let app = NSApplication.shared
let helper = DisplayHelper(directory: URL(fileURLWithPath: CommandLine.arguments[1]), parent: parent)
app.delegate = helper
app.run()
