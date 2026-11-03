// AppState.swift — App-wide state management
//
// USB I/O runs entirely on a background queue. Only UI state updates
// dispatch to @MainActor. This prevents USB timeouts from blocking
// the main thread (which causes macOS rainbow spinner + keyboard freeze).

import AppKit
import Foundation
import Observation

extension Notification.Name {
    static let deviceStateChanged = Notification.Name("deviceStateChanged")
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {

    // Connection (UI-facing)
    var isConnected = false
    var deviceInfo: DeviceInfo?
    var statusMessage = "Disconnected"

    // Display
    // Brightness persists across launches. Size and orientation aren't settings:
    // they come from the screen's handshake (DeviceInfo).
    var brightness: Int = UserDefaults.standard.object(forKey: "brightness") as? Int ?? 5
    var refreshInterval: Double = 0.5

    // Metrics (for menu bar display)
    var frameCount = 0
    var lastFrameSize = 0

    // MARK: - Internal

    private var engine: DisplayEngine?

    // MARK: - Lifecycle

    func start() {
        let eng = DisplayEngine { [weak self] status in
            Task { @MainActor in
                guard let self else { return }
                let prev = self.isConnected
                self.isConnected = status.connected
                self.deviceInfo = status.deviceInfo ?? self.deviceInfo
                self.statusMessage = status.message
                self.frameCount = status.frameCount
                self.lastFrameSize = status.lastFrameSize

                // Log state changes + post notification for UI refresh
                if status.connected != prev {
                    log("[*] LCD \(status.connected ? "connected" : "disconnected")")
                    NotificationCenter.default.post(name: .deviceStateChanged, object: nil)
                }
            }
        }
        engine = eng
        eng.start(brightness: brightness, interval: refreshInterval)
    }

    /// Stop for good (quit): waits out the frame being sent, so the LCD is never
    /// left mid-frame.
    func stop() {
        engine?.stopAndWait()
        engine = nil
        isConnected = false
        statusMessage = "Stopped"
    }

    func connect() {
        engine?.reconnect()
    }

    func disconnect() {
        engine?.stop()
        isConnected = false
        statusMessage = "Disconnected"
        frameCount = 0
    }

    /// Called when user changes brightness or interval
    func applySettings() {
        UserDefaults.standard.set(brightness, forKey: "brightness")
        engine?.updateSettings(brightness: brightness, interval: refreshInterval)
    }

    /// Latest rendered frame for the on-Mac preview window
    func currentFrame() -> CGImage? {
        engine?.currentFrame()
    }
}

// MARK: - Engine Status

struct EngineStatus: Sendable {
    let connected: Bool
    let deviceInfo: DeviceInfo?
    let message: String
    let frameCount: Int
    let lastFrameSize: Int
}

// MARK: - Display Engine (runs entirely off main thread)

final class DisplayEngine: @unchecked Sendable {

    private let statusCallback: @Sendable (EngineStatus) -> Void
    private let usbQueue = DispatchQueue(label: "com.thermalvision.usb")
    private var device: USBDevice?
    private var hotplug: USBHotplug?
    // Stop can arrive on the main/hotplug thread while USB is opening or sending.
    private let stateLock = NSLock()
    private var _running = false
    private var _quitting = false
    private var connectionGeneration = 0
    private var running: Bool {
        get { stateLock.withLock { _running } }
        set { stateLock.withLock { _running = newValue } }
    }
    private var frameCount = 0
    private var lastFrameSize = 0
    private var fpsFrames = 0
    private var fpsSince = Date()
    private let frameWake = DispatchSemaphore(value: 0)   // the frame loop's sleep, cut short by stop()
    // The last frame encoded, and what it was encoded with (usbQueue only)
    private var lastEncoded: (image: CGImage, brightness: Int, rotate180: Bool, hardware: Bool, jpeg: Data)?

    // Settings share the lifecycle lock because the UI writes while USB reads.
    private var _brightness: Int = 5
    private var _interval: Double = 0.5
    private var brightness: Int {
        get { stateLock.withLock { _brightness } }
        set { stateLock.withLock { _brightness = newValue } }
    }
    private var interval: Double {
        get { stateLock.withLock { _interval } }
        set { stateLock.withLock { _interval = newValue } }
    }

    private let renderer = MagpieRenderer()

    init(statusCallback: @escaping @Sendable (EngineStatus) -> Void) {
        self.statusCallback = statusCallback
    }

    func start(brightness: Int, interval: Double) {
        self.brightness = brightness
        self.interval = interval

        usbQueue.async { [weak self] in
            guard let self else { return }
            self.renderer.startMetrics()
            self.setupHotplug()
            self.connectAndRun()
        }
    }

    /// Invalidate a pending handshake/retry as well as the active frame loop.
    @discardableResult
    private func interruptConnection() -> Int {
        let generation = stateLock.withLock {
            _running = false
            connectionGeneration += 1
            return connectionGeneration
        }
        frameWake.signal()
        return generation
    }

    func stop() {
        interruptConnection()
        renderer.stopMetrics()
        usbQueue.async { [weak self] in
            self?.hotplug?.stop()
            self?.hotplug = nil
            self?.device?.close()
            self?.device = nil
        }
    }

    /// Stop, and return only once the frame loop has let go of the device. A
    /// process killed mid-transfer leaves the LCD waiting for the rest of that
    /// frame: it ignores everything after (even a handshake) until it is
    /// unplugged, so quitting must never cut a frame short.
    func stopAndWait() {
        stateLock.withLock { _quitting = true }
        stop()
        usbQueue.sync {}
    }

    func reconnect(after delay: TimeInterval = 0) {
        let generation = interruptConnection()
        scheduleConnection(after: delay, generation: generation)
    }

    private func scheduleConnection(after delay: TimeInterval, generation: Int) {
        usbQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.connectAndRun(expectedGeneration: generation)
        }
    }

    /// Latest rendered frame for the on-Mac preview window (used while the LCD
    /// is disconnected). Thread-safe: render() serializes internally.
    func currentFrame() -> CGImage? {
        renderer.render()
    }

    func updateSettings(brightness: Int, interval: Double) {
        log("[Engine] Settings updated: brightness=\(brightness), interval=\(interval)")
        self.brightness = brightness
        self.interval = interval
    }

    // MARK: - Private (all on usbQueue)

    private func connectAndRun(expectedGeneration: Int? = nil) {
        let generation: Int? = stateLock.withLock {
            guard !_running, !_quitting,
                  expectedGeneration == nil || expectedGeneration == connectionGeneration else { return nil }
            return connectionGeneration
        }
        guard let generation else { return }

        // Ensure gateway polling is running (may have been stopped on disconnect/sleep)
        renderer.startMetrics()

        // Close existing connection
        device?.close()
        device = nil
        frameCount = 0

        postStatus(connected: false, message: "Connecting...")

        let dev = USBDevice()
        do {
            try dev.open()
        } catch USBError.deviceNotFound {
            postStatus(connected: false, message: "Device not found")
            return
        } catch USBError.deviceBusy {
            postStatus(connected: false, message: "Device busy (Chrome?)")
            return
        } catch {
            postStatus(connected: false, message: "Error: \(error)")
            return
        }

        do {
            let info = try LYProtocol.handshake(device: dev)
            let mayRun = stateLock.withLock {
                guard !_quitting, connectionGeneration == generation else { return false }
                _running = true
                return true
            }
            guard mayRun else { dev.close(); return }
            DisplayShape.update(pm: info.pm)
            renderer.adaptCanvas(width: info.width, height: info.height)
            log("[*] Device PM=\(info.pm) SUB=\(info.sub) FBL=\(info.fbl) → \(info.width)x\(info.height), "
                + "rotate 180°: \(info.needsRotation), corner radius \(Int(DisplayShape.cornerRadius))px")
            device = dev
            postStatus(connected: true, deviceInfo: info,
                       message: "Connected (\(info.width)x\(info.height))")
            runFrameLoop(device: dev, info: info, generation: generation)
        } catch {
            dev.close()
            postStatus(connected: false, message: "Handshake failed")
        }
    }

    private func runFrameLoop(device: USBDevice, info: DeviceInfo, generation: Int) {
        // Metrics already collecting in background via startMetrics()

        var nextDeadline = DispatchTime.now()

        while running {
            // Adaptive frame rate: the device sustains ~26fps (~19 on the original
            // revision), but the routing panel only moves while a request is
            // played. 20fps while a magpie flies (a wing beat is .42s), 10fps
            // while a request only waits — every frame is a full JPEG encode +
            // USB transfer — otherwise idle at the configured interval to save
            // CPU/power on this always-on app.
            let fps = renderer.preferredFrameRate()
            let frameInterval = fps.map { 1.0 / $0 } ?? interval
            nextDeadline = nextDeadline + .milliseconds(Int(frameInterval * 1000))

            // autoreleasepool forces CG raster data / CGImage release each frame
            // Without this, Core Graphics caches hundreds of 3.6MB images → GB leak
            autoreleasepool {
                let bright = brightness
                let rotate180 = info.needsRotation   // how this screen is mounted

                let jpeg: Data?

                if let image = renderer.render() {
                    // Idle, the renderer hands back the same image until something
                    // changes: send the JPEG already made of it (an encode is most
                    // of a frame's cost)
                    let hardware = JPEGEncoder.useHardware
                    if let last = lastEncoded, last.image === image, last.brightness == bright,
                       last.rotate180 == rotate180, last.hardware == hardware {
                        jpeg = last.jpeg
                    } else {
                        jpeg = JPEGEncoder.encode(image, brightness: bright, rotate180: rotate180)
                        lastEncoded = jpeg.map { (image, bright, rotate180, hardware, $0) }
                    }
                } else {
                    jpeg = nil
                }

                if let jpeg {
                    do {
                        try LYProtocol.sendFrame(device: device, jpegData: jpeg)
                        frameCount += 1
                        lastFrameSize = jpeg.count
                        fpsFrames += 1
                        let elapsed = Date().timeIntervalSince(fpsSince)
                        if elapsed >= 30 {
                            log(String(format: "[Engine] %.1f fps over %.0fs, ~%dKB/frame",
                                       Double(fpsFrames) / elapsed, elapsed, jpeg.count / 1024))
                            fpsFrames = 0
                            fpsSince = Date()
                        }
                        if frameCount == 1 {
                            log("[OK] Active! ~\(jpeg.count / 1024)KB/frame")
                        }
                        postStatus(connected: true, deviceInfo: nil,
                                   message: "Active")
                    } catch {
                        log("[ERROR] Frame send failed: \(error)")
                        running = false
                        self.device?.close()
                        self.device = nil
                        postStatus(connected: false, message: "Disconnected (send error)")

                        log("[Engine] Will retry connection in 5s...")
                        // Unwind this frame and its autoreleasepool before retrying.
                        scheduleConnection(after: 5, generation: generation)
                        return
                    }
                }
            }  // autoreleasepool

            // Sleep only the remaining time until next deadline
            // If work took longer than interval, send next frame immediately
            let now = DispatchTime.now()
            if nextDeadline > now {
                _ = frameWake.wait(timeout: nextDeadline)
            } else {
                // Work exceeded interval — reset deadline to avoid cascading catch-up
                nextDeadline = now
            }
        }
    }

    private func setupHotplug() {
        let hp = USBHotplug()

        hp.onConnect = { [weak self] in
            guard let self else { return }
            let generation = self.stateLock.withLock { self.connectionGeneration }
            self.scheduleConnection(after: 1, generation: generation)
        }

        hp.onDisconnect = { [weak self] in
            guard let self else { return }
            log("[Hotplug] Device removed")
            self.interruptConnection()
            // Metrics keep collecting — the on-Mac preview window takes over
            // rendering while the LCD is away
            self.usbQueue.async { [weak self] in
                self?.device?.close()
                self?.device = nil
                self?.postStatus(connected: false, message: "Disconnected (unplugged)")
            }
        }

        hp.start()
        hotplug = hp

        // Watch for macOS wake from sleep — USB needs reconnect after sleep
        // MUST register on main thread for NSWorkspace notifications to fire
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let center = NSWorkspace.shared.notificationCenter

            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                log("[Wake] macOS woke from sleep — reconnecting in 3s...")
                // Interrupt before enqueueing: the active loop owns usbQueue.
                self.reconnect(after: 3)
            }

            center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                if !self.running {
                    log("[Wake] Screens woke — reconnecting in 2s...")
                    let generation = self.stateLock.withLock { self.connectionGeneration }
                    self.scheduleConnection(after: 2, generation: generation)
                }
            }
        }
    }

    private func postStatus(
        connected: Bool, deviceInfo: DeviceInfo? = nil, message: String
    ) {
        let status = EngineStatus(
            connected: connected,
            deviceInfo: deviceInfo,
            message: message,
            frameCount: frameCount,
            lastFrameSize: lastFrameSize)
        statusCallback(status)
    }
}
