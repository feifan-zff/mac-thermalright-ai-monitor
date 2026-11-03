// MacTRApp.swift — macOS menu bar app
//
// Uses NSStatusItem directly (not SwiftUI MenuBarExtra) for reliable
// menu bar icon that never disappears regardless of USB state.
//
// CLI mode: --cli flag for headless operation.

import AppKit
import os
import SwiftUI

private let mactrLogger = Logger(subsystem: "com.m1ngli.MacTRAI", category: "main")

func log(_ message: String) {
    mactrLogger.info("\(message, privacy: .public)")
}

// MARK: - App Entry Point

@main
struct MacTREntry {
    static func main() {
        // CLI mode
        if CommandLine.arguments.contains("--cli") {
            runCLI()
            return
        }

        // Benchmark mode: measure achievable frame rate on the real LCD.
        if CommandLine.arguments.contains("--benchmark") {
            runBenchmark()
            return
        }

        // GIF mode: render an animated demo GIF (for the README). No LCD needed.
        if CommandLine.arguments.contains("--gif") {
            runGif()
            return
        }

        // Pipeline benchmark: CPU cost per frame of render + encode, no USB.
        // Usage: --pipeline-bench [--brightness N]
        if CommandLine.arguments.contains("--pipeline-bench") {
            runPipelineBench()
            return
        }

        // Snapshot mode: render one frame and save as PNG (or the device JPEG)
        // Usage: --snapshot path.png|path.jpg [--brightness N] [--rotate]
        if CommandLine.arguments.contains("--snapshot") {
            if let image = primedRenderer().render() {
                let url = URL(fileURLWithPath: CommandLine.arguments.last == "--snapshot"
                    ? "snapshot.png" : CommandLine.arguments[CommandLine.arguments.firstIndex(of: "--snapshot")! + 1])
                if url.pathExtension == "jpg" {
                    // The exact bytes the LCD receives (device orientation, brightness applied)
                    let level = parseFlag(CommandLine.arguments, flag: "--brightness") ?? 1
                    let rotate = CommandLine.arguments.contains("--rotate")
                    try? JPEGEncoder.encode(image, brightness: level, rotate: rotate)?.write(to: url)
                    log("[Snapshot] Saved device JPEG to \(url.path)")
                } else if let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, image, nil)
                    CGImageDestinationFinalize(dest)
                    log("[Snapshot] Saved to \(url.path)")
                }
            }
            return
        }

        // Preview mode: live render in a window — no LCD hardware needed
        if CommandLine.arguments.contains("--preview") {
            let app = NSApplication.shared
            app.setActivationPolicy(.regular)
            let delegate = PreviewController()
            app.delegate = delegate
            app.run()
            return
        }

        // GUI mode — NSApplication with StatusBar
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // No dock icon
        let delegate = StatusBarController()
        app.delegate = delegate
        app.run()
    }
}

// MARK: - Preview Window (debug without LCD hardware)

@MainActor
final class PreviewController: NSObject, NSApplicationDelegate, NSWindowDelegate {

    private var window: NSWindow!
    private var imageView: NSImageView!
    private let renderer = MagpieRenderer()
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[Preview] Starting preview window (no LCD)")

        // Half-scale window keeps the 1920x480 frame readable on a laptop screen
        let contentSize = NSSize(width: Layout.width / 2, height: Layout.height / 2)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "MacTR Preview — \(Layout.width)x\(Layout.height)"
        window.contentAspectRatio = NSSize(width: Layout.width, height: Layout.height)
        window.delegate = self

        imageView = NSImageView(frame: NSRect(origin: .zero, size: contentSize))
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(imageView)

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        renderer.startMetrics()
        // 10fps, matching the LCD's animation rate (data itself is polled every 1s)
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
    }

    private func refresh() {
        guard let image = renderer.render() else { return }
        imageView.image = NSImage(cgImage: image,
                                  size: NSSize(width: Layout.width, height: Layout.height))
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        renderer.stopMetrics()
        NSApp.terminate(nil)
    }
}

// MARK: - Status Bar Controller

@MainActor
final class StatusBarController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {

    private var statusItem: NSStatusItem!
    private let appState = AppState()
    private var menu: NSMenu!

    // On-Mac preview — shown automatically while the LCD is disconnected OR during
    // the nightly window (18:30–09:00, when the LCD is blanked). `previewShown`
    // tracks our intent so the timer doesn't re-open / re-focus it every tick.
    private var previewWindow: NSWindow?
    private var previewImageView: NSImageView?
    private var previewTimer: Timer?
    private var previewShown = false

    // Menu items that need updating
    private var statusMenuItem: NSMenuItem!
    private var versionMenuItem: NSMenuItem!
    private var reconnectItem: NSMenuItem!
    private var updateTimer: Timer?
    private var quitSignals: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("[*] MacTR starting...")

        // pkill / logout / ⌃C quit like the menu's Quit does — through
        // applicationWillTerminate, which lets the frame being sent finish
        // (a frame cut short leaves the LCD deaf until it is unplugged)
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            quitSignals.append(source)
        }

        // Accessory apps show no menu bar, but AppKit still routes ⌘X/⌘C/⌘V/⌘A/⌘Z
        // through NSApp.mainMenu — without one, Settings' text fields can't paste.
        NSApp.mainMenu = Self.makeEditMenu()

        // Create status bar item — this NEVER gets removed
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateIcon()

        // Build menu
        buildMenu()
        menu.delegate = self
        statusItem.menu = menu

        // Watch for device state changes — close menu so it refreshes
        // Update icon immediately on device state change
        NotificationCenter.default.addObserver(
            forName: .deviceStateChanged, object: nil, queue: .main
        ) { [weak self] _ in
            // `queue: .main` already guarantees this body runs on the main thread,
            // but the observer closure's type is nonisolated, so the compiler has
            // no way to see that. Assert it rather than hopping through
            // `Task { @MainActor }` — the point of this observer is to repaint the
            // icon the instant the device state flips, and a hop would let a frame
            // render against the stale state first.
            MainActor.assumeIsolated {
                self?.updateIcon()
                self?.updateMenuItems()
                self?.updateDisplayTarget()
            }
        }

        // Start engine
        appState.start()

        // No LCD after the initial connect attempt → fall back to on-Mac preview.
        // Delayed so a present device can connect first without a window flash.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.updateDisplayTarget()
        }

        // Timer to refresh menu + icon, and to react to the night-window schedule
        updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateIcon()
                self?.updateMenuItems()
                self?.updateDisplayTarget()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        updateTimer?.invalidate()
        appState.stop()
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        updateIcon()
        updateMenuItems()
    }

    // MARK: - Icon

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        button.image = makeIcon(disconnected: !appState.isConnected)
    }

    /// Draw menu bar icon manually. Connected = white display. Disconnected = display + red badge.
    private func makeIcon(disconnected: Bool) -> NSImage {
        let w: CGFloat = disconnected ? 22 : 18
        let h: CGFloat = 16

        let image = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            let menuBarColor: NSColor = .labelColor  // adapts to dark/light mode

            // Draw monitor shape
            let screenRect = NSRect(x: 0, y: 4, width: 18, height: 11)
            let screenPath = NSBezierPath(roundedRect: screenRect, xRadius: 2, yRadius: 2)
            menuBarColor.setStroke()
            screenPath.lineWidth = 1.5
            screenPath.stroke()

            // Stand
            let standTop = NSPoint(x: 9, y: 4)
            let standBot = NSPoint(x: 9, y: 1.5)
            let stand = NSBezierPath()
            stand.move(to: standTop)
            stand.line(to: standBot)
            stand.lineWidth = 1.5
            menuBarColor.setStroke()
            stand.stroke()

            // Base
            let basePath = NSBezierPath()
            basePath.move(to: NSPoint(x: 5, y: 1.5))
            basePath.line(to: NSPoint(x: 13, y: 1.5))
            basePath.lineWidth = 1.5
            basePath.stroke()

            // Red badge (only when disconnected)
            if disconnected {
                let badgeD: CGFloat = 9
                let badgeRect = NSRect(
                    x: rect.width - badgeD + 0.5,
                    y: rect.height - badgeD + 0.5,
                    width: badgeD, height: badgeD)

                // Red circle
                NSColor.red.setFill()
                NSBezierPath(ovalIn: badgeRect).fill()

                // White "!"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 7, weight: .black),
                    .foregroundColor: NSColor.white,
                ]
                let mark = "!" as NSString
                let markSize = mark.size(withAttributes: attrs)
                mark.draw(at: NSPoint(
                    x: badgeRect.midX - markSize.width / 2,
                    y: badgeRect.midY - markSize.height / 2),
                    withAttributes: attrs)
            }

            return true
        }

        // Template only when connected (so it adapts to dark/light mode)
        // Non-template when disconnected (to keep red badge color)
        image.isTemplate = !disconnected
        return image
    }

    private static func makeEditMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
            .keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        let main = NSMenu()
        main.addItem(editItem)
        return main
    }

    // MARK: - Menu

    private func buildMenu() {
        menu = NSMenu()

        // App title + version
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.3.0"
        versionMenuItem = NSMenuItem(title: "MacTR v\(version)", action: nil, keyEquivalent: "")
        versionMenuItem.isEnabled = false
        menu.addItem(versionMenuItem)

        // Status
        statusMenuItem = NSMenuItem(title: "Disconnected", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)

        menu.addItem(.separator())

        // Reconnect
        reconnectItem = NSMenuItem(title: "Reconnect", action: #selector(reconnect), keyEquivalent: "r")
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        // Settings
        let settingsItem = NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        // Preview window (manual reopen after closing it)
        let previewItem = NSMenuItem(title: "Preview Window", action: #selector(showPreviewManually), keyEquivalent: "p")
        previewItem.target = self
        menu.addItem(previewItem)

        // Night blanking (18:30–09:00) on/off
        let nightItem = NSMenuItem(title: "Blank LCD at Night", action: #selector(toggleNightBlank(_:)), keyEquivalent: "")
        nightItem.target = self
        nightItem.state = NightSchedule.isEnabled ? .on : .off
        menu.addItem(nightItem)

        menu.addItem(.separator())

        // About
        let aboutItem = NSMenuItem(title: "About MacTR AI", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        // Quit
        let quitItem = NSMenuItem(title: "Quit MacTR", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        updateMenuItems()
    }

    private func updateMenuItems() {
        // Status
        let dot = appState.isConnected ? "🟢" : "🔴"
        statusMenuItem.title = "\(dot) \(appState.statusMessage)"

        // Reconnect visibility
        reconnectItem.isHidden = appState.isConnected
    }

    // MARK: - Preview Window (auto-fallback when LCD is disconnected)

    /// Show the dashboard on the Mac when the LCD isn't the right target:
    /// either it's disconnected, or we're inside the night window (LCD blanked).
    /// Transition-based so we don't grab focus every second.
    private func updateDisplayTarget() {
        let wantPreview = !appState.isConnected || NightSchedule.isNight
        if wantPreview && !previewShown {
            showPreview(); previewShown = true
        } else if !wantPreview && previewShown {
            hidePreview(); previewShown = false
        }
    }

    private func showPreview() {
        if previewWindow == nil {
            let contentSize = NSSize(width: Layout.width / 2, height: Layout.height / 2)
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: contentSize),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered, defer: false)
            window.title = "MacTR — 本机预览"
            window.contentAspectRatio = NSSize(width: Layout.width, height: Layout.height)
            window.isReleasedWhenClosed = false
            window.delegate = self

            let imageView = NSImageView(frame: NSRect(origin: .zero, size: contentSize))
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.autoresizingMask = [.width, .height]
            window.contentView?.addSubview(imageView)
            window.center()

            previewWindow = window
            previewImageView = imageView
        }
        // orderFrontRegardless shows it without stealing focus from your work
        previewWindow?.orderFrontRegardless()

        if previewTimer == nil {
            // 10fps for smooth breathing/blink (metrics are cached, recomputed ~2s)
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.refreshPreview() }
            }
            refreshPreview()
        }
    }

    private func hidePreview() {
        previewTimer?.invalidate()
        previewTimer = nil
        previewWindow?.orderOut(nil)
    }

    private func refreshPreview() {
        guard let image = appState.currentFrame() else { return }
        previewImageView?.image = NSImage(
            cgImage: image, size: NSSize(width: Layout.width, height: Layout.height))
    }

    @objc private func showPreviewManually() {
        showPreview(); previewShown = true
    }

    @objc private func toggleNightBlank(_ sender: NSMenuItem) {
        NightSchedule.isEnabled.toggle()
        sender.state = NightSchedule.isEnabled ? .on : .off
        updateDisplayTarget()
    }

    // User closed the preview window — stop rendering to it. previewShown stays true
    // so we don't immediately reopen it; it comes back on the next display-target
    // transition (LCD unplug, or entering/leaving the night window).
    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window == previewWindow else { return }
        previewTimer?.invalidate()
        previewTimer = nil
    }

    // MARK: - Actions

    @objc private func reconnect() {
        appState.connect()
    }

    @objc private func openSettings() {
        // Open settings window
        let settingsView = SettingsView(state: appState)
        let hostingController = NSHostingController(rootView: settingsView)
        let window = NSWindow(contentViewController: hostingController)
        window.title = "MacTR Settings"
        window.styleMask = [.titled, .closable]
        window.setContentSize(NSSize(width: 450, height: 350))
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func showAbout() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"

        let alert = NSAlert()
        alert.messageText = "MacTR AI"
        alert.informativeText = """
            Version \(version) (Build \(build))

            magpie routing + subscription usage on the
            Thermalright Trofeo Vision 9.16 LCD.

            Built with Swift + libusb
            github.com/m1ng-li/mac-thermalright-ai-monitor

            Based on beret21/MacTR
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        if let icon = NSImage(named: "AppIcon") {
            alert.icon = icon
        }

        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    @objc private func quit() {
        appState.stop()
        NSApp.terminate(nil)
    }
}

// MARK: - CLI Mode

// MARK: - Benchmark Mode

/// Measure achievable frame rate on the connected LCD. Breaks timing into render,
/// JPEG encode, and USB send so we know which stage bounds the fps.
private func runBenchmark() {
    let args = CommandLine.arguments
    let frames = parseFlag(args, flag: "--benchmark") ?? 120
    let brightness = parseFlag(args, flag: "-b") ?? 5
    let rotate = args.contains("--rotate")

    print("[Bench] Frame-rate benchmark — \(frames) frames")
    let device = USBDevice()
    do { try device.open() } catch {
        print("[Bench][ERROR] open failed: \(error) — is MacTR still running and holding the device?")
        return
    }
    defer { device.close() }

    do { _ = try LYProtocol.handshake(device: device) }
    catch { print("[Bench][ERROR] handshake failed: \(error)"); return }

    // --static: re-send one pre-encoded frame — isolates device + USB throughput
    let renderer = primedRenderer()
    var staticJPEG: Data?
    if args.contains("--static"), let img = renderer.render() {
        staticJPEG = JPEGEncoder.encode(img, brightness: brightness, rotate: rotate)
    }

    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }  // ms

    // Warm up: first render + JPEG/rotation contexts allocate; discard 5 frames
    for _ in 0..<5 {
        if let img = renderer.render(),
           let j = JPEGEncoder.encode(img, brightness: brightness, rotate: rotate) {
            try? LYProtocol.sendFrame(device: device, jpegData: j)
        }
    }

    var renderMs = [Double](), encodeMs = [Double](), sendMs = [Double]()
    var jpegBytes = [Int]()
    var sent = 0
    let t0 = now()

    for _ in 0..<frames {
        let r0 = now()
        let image = staticJPEG == nil ? renderer.render() : nil
        guard staticJPEG != nil || image != nil else { continue }
        let r1 = now()
        guard let jpeg = staticJPEG ?? image.flatMap({ JPEGEncoder.encode($0, brightness: brightness, rotate: rotate) })
        else { continue }
        let r2 = now()
        do { try LYProtocol.sendFrame(device: device, jpegData: jpeg) }
        catch { print("[Bench][ERROR] send failed at frame \(sent): \(error)"); break }
        let r3 = now()

        renderMs.append(r1 - r0)
        encodeMs.append(r2 - r1)
        sendMs.append(r3 - r2)
        jpegBytes.append(jpeg.count)
        sent += 1
    }

    let elapsed = (now() - t0) / 1000  // seconds
    renderer.stopMetrics()

    guard sent > 0 else { print("[Bench] No frames sent"); return }
    func avg(_ a: [Double]) -> Double { a.reduce(0, +) / Double(a.count) }
    func pctl(_ a: [Double], _ p: Double) -> Double {
        let s = a.sorted(); return s[min(s.count - 1, Int(Double(s.count) * p))]
    }
    let perFrame = avg(renderMs) + avg(encodeMs) + avg(sendMs)
    let avgKB = jpegBytes.reduce(0, +) / jpegBytes.count / 1024

    print("========== Benchmark Result ==========")
    print(String(format: "Sent %d frames in %.2fs → %.1f fps (back-to-back, no delay)", sent, elapsed, Double(sent) / elapsed))
    print(String(format: "Per-frame avg: %.1f ms  → theoretical max %.1f fps", perFrame, 1000 / perFrame))
    print(String(format: "  render  : avg %.1f ms  p95 %.1f ms", avg(renderMs), pctl(renderMs, 0.95)))
    print(String(format: "  encode  : avg %.1f ms  p95 %.1f ms", avg(encodeMs), pctl(encodeMs, 0.95)))
    print(String(format: "  USB send: avg %.1f ms  p95 %.1f ms  (%d KB/frame avg)", avg(sendMs), pctl(sendMs, 0.95), avgKB))
    print("======================================")
}

// MARK: - GIF Mode (animated demo for the README)

/// Render an animated GIF of the dashboard. No LCD required — pure rendering.
/// For a showcase, point it at canned data: `-magpieURL file:///path/to/dir`.
/// Usage: --gif out.gif [--frames N] [--fps F] [--scale S]
private func runGif() {
    let args = CommandLine.arguments
    guard let gi = args.firstIndex(of: "--gif"), gi + 1 < args.count else {
        print("[GIF] usage: --gif out.gif [--frames N] [--fps F] [--scale S]"); return
    }
    let path = args[gi + 1]
    let frames = parseFlag(args, flag: "--frames") ?? 40
    let fps = parseFlag(args, flag: "--fps") ?? 12
    let scale = max(1, parseFlag(args, flag: "--scale") ?? 2)
    let outW = Layout.width / scale, outH = Layout.height / scale
    let delay = 1.0 / Double(fps)

    let renderer = primedRenderer()

    let url = URL(fileURLWithPath: path) as CFURL
    guard let dest = CGImageDestinationCreateWithURL(url, "com.compuserve.gif" as CFString,
                                                     frames, nil) else {
        print("[GIF][ERROR] cannot create \(path)"); return
    }
    CGImageDestinationSetProperties(dest, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
    ] as CFDictionary)
    let frameProps = [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]
    ] as CFDictionary

    print("[GIF] rendering \(frames) frames at \(outW)x\(outH), \(fps)fps → \(path)")
    for _ in 0..<frames {
        autoreleasepool {
            if let img = renderer.render(), let small = downscaleImage(img, outW, outH) {
                CGImageDestinationAddImage(dest, small, frameProps)
            }
        }
        Thread.sleep(forTimeInterval: delay)   // advance the Date()-based animations
    }
    if CGImageDestinationFinalize(dest) {
        print("[GIF] wrote \(path)")
    } else {
        print("[GIF][ERROR] finalize failed")
    }
}

private func downscaleImage(_ image: CGImage, _ w: Int, _ h: Int) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return ctx.makeImage()
}

private func runCLI() {
    let args = CommandLine.arguments
    let isTest = args.contains("--test")
    let brightness = parseFlag(args, flag: "-b") ?? 5
    let rotate = args.contains("--rotate")

    log("[*] MacTR CLI — \(isTest ? "USB Test" : "magpie dashboard")")
    log("[*] Brightness: level \(brightness) (\(Brightness.factor(for: brightness))x), Rotate: \(rotate)")
    log("[*] Searching for Thermalright LCD...")

    let device = USBDevice()

    do {
        try device.open()
    } catch {
        log("[ERROR] \(error)")
        return
    }

    defer { device.close() }

    let info: DeviceInfo
    do {
        info = try LYProtocol.handshake(device: device)
    } catch {
        log("[ERROR] Handshake failed: \(error)")
        return
    }

    if isTest {
        guard let jpeg = makeTestJPEG(width: info.width, height: info.height) else {
            log("[ERROR] Failed to create test image")
            return
        }
        log("[*] JPEG size: \(jpeg.count) bytes")
        cliFrameLoop(device: device, staticJPEG: jpeg)
    } else {
        let renderer = primedRenderer()

        log("[*] Sending frames (press Ctrl+C to stop)...")
        signal(SIGINT, SIG_DFL)

        var count = 0
        while true {
            guard let image = renderer.render(),
                  let jpeg = JPEGEncoder.encode(image, brightness: brightness, rotate: rotate)
            else {
                Thread.sleep(forTimeInterval: 1)
                continue
            }

            do {
                try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                count += 1
                if count == 1 {
                    log("[OK] Monitor active! ~\(jpeg.count / 1024)KB/frame (Ctrl+C to stop)")
                }
            } catch {
                log("[ERROR] Frame send failed: \(error)")
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }
}

private func cliFrameLoop(device: USBDevice, staticJPEG: Data) {
    log("[*] Sending frames (press Ctrl+C to stop)...")
    signal(SIGINT, SIG_DFL)
    var count = 0
    while true {
        do {
            try LYProtocol.sendFrame(device: device, jpegData: staticJPEG)
            count += 1
            if count == 1 { log("[OK] Display active! Looping...") }
        } catch {
            log("[ERROR] Frame send failed: \(error)")
            break
        }
        Thread.sleep(forTimeInterval: 0.5)
    }
}

/// A renderer whose first gateway poll has landed, so render() returns frames.
private func primedRenderer() -> MagpieRenderer {
    let renderer = MagpieRenderer()
    renderer.startMetrics()
    for _ in 0..<50 where renderer.render() == nil { Thread.sleep(forTimeInterval: 0.1) }
    return renderer
}

private func parseFlag(_ args: [String], flag: String) -> Int? {
    guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
    return Int(args[idx + 1])
}

// MARK: - Test Image

func makeTestJPEG(width: Int, height: Int) -> Data? {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }

    let colors = [
        CGColor(red: 0.04, green: 0.05, blue: 0.08, alpha: 1),
        CGColor(red: 0.06, green: 0.07, blue: 0.11, alpha: 1),
    ] as CFArray
    if let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1]) {
        ctx.drawLinearGradient(gradient,
                               start: CGPoint(x: 0, y: CGFloat(height)),
                               end: CGPoint(x: 0, y: 0), options: [])
    }

    let text = "MacTR — Swift USB Test" as NSString
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 48, weight: .medium),
        .foregroundColor: NSColor.white,
    ]
    let textSize = text.size(withAttributes: attrs)
    let x = (CGFloat(width) - textSize.width) / 2

    ctx.saveGState()
    ctx.translateBy(x: 0, y: CGFloat(height))
    ctx.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
    text.draw(at: NSPoint(x: x, y: CGFloat(height) / 2 - textSize.height / 2), withAttributes: attrs)

    let sub = "macOS 26 \u{2022} Swift 6.3 \u{2022} libusb" as NSString
    let subAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 24),
        .foregroundColor: NSColor(white: 0.6, alpha: 1),
    ]
    let subSize = sub.size(withAttributes: subAttrs)
    sub.draw(at: NSPoint(x: (CGFloat(width) - subSize.width) / 2,
                         y: CGFloat(height) / 2 + textSize.height / 2 + 10),
             withAttributes: subAttrs)
    NSGraphicsContext.restoreGraphicsState()
    ctx.restoreGState()

    guard let image = ctx.makeImage() else { return nil }
    return JPEGEncoder.encode(image)
}

// MARK: - Pipeline benchmark

private func runPipelineBench() {
    let args = CommandLine.arguments
    let level = parseFlag(args, flag: "--brightness") ?? 5
    let renderer = primedRenderer()
    func cpu() -> (user: Double, sys: Double) {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return (Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6,
                Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6)
    }
    let frames = 150
    var renderT = 0.0, encodeT = 0.0
    let c0 = cpu()
    for _ in 0..<frames {
        autoreleasepool {
            let t0 = DispatchTime.now().uptimeNanoseconds
            guard let img = renderer.render() else { return }
            let t1 = DispatchTime.now().uptimeNanoseconds
            _ = JPEGEncoder.encode(img, brightness: level, rotate: false)
            let t2 = DispatchTime.now().uptimeNanoseconds
            renderT += Double(t1 - t0) / 1e6
            encodeT += Double(t2 - t1) / 1e6
        }
        Thread.sleep(forTimeInterval: 1.0 / 15)
    }
    let c1 = cpu()
    let n = Double(frames)
    print(String(format: "wall: render %.2f ms  encode %.2f ms per frame", renderT / n, encodeT / n))
    print(String(format: "cpu:  user %.2f ms  sys %.2f ms per frame (incl. collector threads)",
                 (c1.user - c0.user) * 1000 / n, (c1.sys - c0.sys) * 1000 / n))
}
