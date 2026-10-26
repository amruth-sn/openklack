import AppKit
import Combine
import ServiceManagement
import UserNotifications

/// Central app state: user settings (persisted to UserDefaults), the audio
/// engine, the key listener, and keystroke stats.
final class AppState: ObservableObject {
    static let shared = AppState()

    let engine = SoundEngine()
    let listener = KeyListener()
    private(set) var packs: [SoundPack] = []

    // MARK: - Persisted settings

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: "enabled") }
    }
    @Published var volume: Float {
        didSet {
            defaults.set(volume, forKey: "volume")
            engine.volume = volume
            scheduleVolumePreview()
        }
    }
    @Published var selectedPackID: String {
        didSet {
            defaults.set(selectedPackID, forKey: "pack")
            applyPack(notify: oldValue != selectedPackID)
        }
    }
    @Published var toneX: Float {
        didSet {
            defaults.set(toneX, forKey: "toneX")
            engine.setTone(x: toneX, y: toneY)
        }
    }
    @Published var toneY: Float {
        didSet {
            defaults.set(toneY, forKey: "toneY")
            engine.setTone(x: toneX, y: toneY)
        }
    }
    @Published var pitchVariation: Float {
        didSet {
            defaults.set(pitchVariation, forKey: "pitchVariation")
            engine.pitchVariationCents = pitchVariation
        }
    }
    @Published var muteModifiers: Bool {
        didSet { defaults.set(muteModifiers, forKey: "muteModifiers") }
    }
    @Published var functionKeysAudible: Bool {
        didSet { defaults.set(functionKeysAudible, forKey: "functionKeysAudible") }
    }
    @Published var returnDing: Bool {
        didSet {
            defaults.set(returnDing, forKey: "returnDing")
            if returnDing && oldValue != returnDing { engine.playExtra(named: "ding") }
        }
    }
    @Published var mouseClicks: Bool {
        didSet {
            defaults.set(mouseClicks, forKey: "mouseClicks")
            if mouseClicks && oldValue != mouseClicks {
                engine.playExtra(named: "click_down", gain: 0.9)
            }
        }
    }
    @Published var hapticFeedback: Bool {
        didSet { defaults.set(hapticFeedback, forKey: "hapticFeedback") }
    }
    @Published var notifyOnSwitchChange: Bool {
        didSet { defaults.set(notifyOnSwitchChange, forKey: "notifyOnSwitchChange") }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: "launchAtLogin")
            guard !reconcilingLoginItem else { return }
            updateLoginItem()
        }
    }
    private var reconcilingLoginItem = false
    @Published var outputDeviceUID: String? {
        didSet {
            defaults.set(outputDeviceUID, forKey: "outputDeviceUID")
            applyOutputDevice()
        }
    }

    // MARK: - Stats

    @Published private(set) var totalKeystrokes: Int
    @Published private(set) var todayKeystrokes: Int
    private var todayStamp: String

    @Published private(set) var accessibilityTrusted = Permissions.isTrusted

    private let defaults = UserDefaults.standard
    private var dingBuffersLoaded = false

    private init() {
        defaults.register(defaults: [
            "enabled": true, "volume": 0.55, "pack": "cream",
            "toneX": 0.0, "toneY": 0.0, "pitchVariation": 60.0,
            "muteModifiers": false, "functionKeysAudible": true,
            "returnDing": false, "mouseClicks": false,
            "hapticFeedback": false, "notifyOnSwitchChange": false,
            "launchAtLogin": false,
            "statsTotal": 0, "statsToday": 0, "statsTodayStamp": "",
        ])
        enabled = defaults.bool(forKey: "enabled")
        volume = min(max(defaults.float(forKey: "volume"), 0), 1)
        selectedPackID = defaults.string(forKey: "pack") ?? "cream"
        toneX = min(max(defaults.float(forKey: "toneX"), -1), 1)
        toneY = min(max(defaults.float(forKey: "toneY"), -1), 1)
        pitchVariation = min(max(defaults.float(forKey: "pitchVariation"), 0), 150)
        muteModifiers = defaults.bool(forKey: "muteModifiers")
        functionKeysAudible = defaults.bool(forKey: "functionKeysAudible")
        returnDing = defaults.bool(forKey: "returnDing")
        mouseClicks = defaults.bool(forKey: "mouseClicks")
        hapticFeedback = defaults.bool(forKey: "hapticFeedback")
        notifyOnSwitchChange = defaults.bool(forKey: "notifyOnSwitchChange")
        launchAtLogin = defaults.bool(forKey: "launchAtLogin")
        outputDeviceUID = defaults.string(forKey: "outputDeviceUID")
        totalKeystrokes = defaults.integer(forKey: "statsTotal")
        todayKeystrokes = defaults.integer(forKey: "statsToday")
        todayStamp = defaults.string(forKey: "statsTodayStamp") ?? ""
    }

    // MARK: - Lifecycle

    func startUp() {
        packs = SoundPack.discover(in: Self.soundsDirectory())
        engine.volume = volume
        engine.pitchVariationCents = pitchVariation
        engine.setTone(x: toneX, y: toneY)
        applyPack(notify: false)
        engine.loadExtras(from: Self.soundsDirectory().appendingPathComponent("_extras"))
        do {
            try engine.start()
        } catch {
            klog.error("engine start failed: \(error, privacy: .public)")
        }
        // Only pin an output device when one is explicitly saved; default
        // routing follows the system output on its own.
        if outputDeviceUID != nil {
            applyOutputDevice()
        }

        // NSEvent monitor callbacks arrive on the main thread already; calling
        // straight through keeps keystroke→sound latency at one buffer.
        listener.handler = { [weak self] event in
            self?.handle(event)
        }
        accessibilityTrusted = Permissions.requestIfNeeded()
        listener.start()
        reconcileLoginItem()
        klog.notice("startup: trusted=\(self.accessibilityTrusted, privacy: .public) packs=\(self.packs.count, privacy: .public) device=\(self.outputDeviceUID ?? "default", privacy: .public)")

        // Monitors registered before the Accessibility grant never deliver
        // events, and re-registering in-process isn't enough — the app has to
        // relaunch. Poll for the grant and relaunch ourselves when it lands.
        if !accessibilityTrusted {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                guard self != nil else { return timer.invalidate() }
                if Permissions.isTrusted {
                    timer.invalidate()
                    klog.notice("accessibility granted — relaunching")
                    Self.relaunch()
                }
            }
        }
    }

    private static func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: config) { _, error in
            DispatchQueue.main.async {
                if let error {
                    klog.error("relaunch failed: \(error, privacy: .public)")
                } else {
                    NSApp.terminate(nil)
                }
            }
        }
    }

    var currentPack: SoundPack? {
        packs.first { $0.id == selectedPackID } ?? packs.first
    }

    private func applyPack(notify: Bool) {
        guard let pack = currentPack else {
            klog.error("no sound packs found")
            return
        }
        engine.load(pack: pack)
        klog.notice("loaded pack \(pack.id, privacy: .public)")
        if notify {
            playSwitchPreview()
            if notifyOnSwitchChange {
                postNotification(title: "Switch changed", body: pack.name)
            }
        }
    }

    // MARK: - Preference previews (audible feedback for settings changes)

    private var volumePreview: DispatchWorkItem?

    /// A short down/up pair so a new switch or volume can be judged instantly.
    private func playSwitchPreview() {
        engine.playKey(keyClass: .row2, up: false, x: 0.5)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.engine.playKey(keyClass: .row2, up: true, x: 0.5)
        }
    }

    /// Debounced so slider drags produce one preview, not a machine-gun burst.
    private func scheduleVolumePreview() {
        volumePreview?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.playSwitchPreview() }
        volumePreview = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    // MARK: - Event handling

    static let toggleKeycode: UInt16 = 40 // 'k'
    private var suppressNextKeyUp: UInt16?

    private var loggedFirstEvent = false

    private func handle(_ event: KeyListener.Event) {
        if !loggedFirstEvent {
            loggedFirstEvent = true
            klog.notice("first input event received — monitors are live")
        }
        switch event {
        case let .keyDown(keycode, isRepeat, flags):
            // ⌘⌃K toggles Klack-style, even while disabled. Swallow the
            // matching key-up too, or enabling would emit an orphan release.
            if keycode == Self.toggleKeycode && !isRepeat,
               flags.contains(.command), flags.contains(.control) {
                enabled.toggle()
                suppressNextKeyUp = keycode
                return
            }
            guard enabled, !isRepeat, audible(keycode) else { return }
            // Sound first; stats and haptics can trail it.
            let info = KeyMap.info(for: keycode)
            if returnDing, KeyMap.returnKeycodes.contains(keycode) {
                engine.playKey(keyClass: .enter, up: false, x: info.x)
                playDing()
            } else {
                engine.playKey(keyClass: info.keyClass, up: false, x: info.x)
            }
            if hapticFeedback {
                NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            }
            recordKeystroke()
        case let .keyUp(keycode):
            if keycode == suppressNextKeyUp {
                suppressNextKeyUp = nil
                return
            }
            guard enabled, audible(keycode) else { return }
            let info = KeyMap.info(for: keycode)
            engine.playKey(keyClass: info.keyClass, up: true, x: info.x)
        case .mouseDown:
            guard enabled, mouseClicks else { return }
            engine.playExtra(named: "click_down", gain: 0.9)
        case .mouseUp:
            guard enabled, mouseClicks else { return }
            engine.playExtra(named: "click_up", gain: 0.7)
        }
    }

    private func audible(_ keycode: UInt16) -> Bool {
        if muteModifiers && KeyMap.modifierKeycodes.contains(keycode) { return false }
        if !functionKeysAudible && KeyMap.functionKeycodes.contains(keycode) { return false }
        return true
    }

    private func playDing() {
        // The typewriter ding ships as a shared extra, outside any pack.
        engine.playExtra(named: "ding")
    }

    // MARK: - Stats

    private func recordKeystroke() {
        let stamp = Self.dayStamp()
        if stamp != todayStamp {
            todayStamp = stamp
            todayKeystrokes = 0
            defaults.set(stamp, forKey: "statsTodayStamp")
        }
        todayKeystrokes += 1
        totalKeystrokes += 1
        // UserDefaults writes hit an in-memory cache; persist every N strokes
        // to avoid two change notifications per keypress. flushStats() covers
        // the remainder at quit.
        if todayKeystrokes % 20 == 0 {
            flushStats()
        }
    }

    func flushStats() {
        defaults.set(todayKeystrokes, forKey: "statsToday")
        defaults.set(totalKeystrokes, forKey: "statsTotal")
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func dayStamp() -> String {
        dayFormatter.string(from: Date())
    }

    // MARK: - System integration

    private func updateLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("OpenKlack: login item update failed: \(error)")
            reconcileLoginItem()
        }
    }

    /// Keep the checkbox truthful: reflect the actual SMAppService status
    /// (registration can fail, or be changed in System Settings).
    func reconcileLoginItem() {
        reconcilingLoginItem = true
        launchAtLogin = SMAppService.mainApp.status == .enabled
        reconcilingLoginItem = false
    }

    private func applyOutputDevice() {
        if let uid = outputDeviceUID,
           let device = AudioDevices.outputDevices().first(where: { $0.uid == uid }) {
            engine.setOutputDevice(device.id)
        } else {
            engine.setOutputDevice(nil)
        }
    }

    private func postNotification(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            center.add(UNNotificationRequest(identifier: UUID().uuidString,
                                             content: content, trigger: nil))
        }
    }

    /// Sounds live in the app bundle's Resources/Sounds; during `swift run`
    /// development, fall back to ./Resources/Sounds in the working directory.
    static func soundsDirectory() -> URL {
        if let res = Bundle.main.resourceURL {
            let bundled = res.appendingPathComponent("Sounds")
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Sounds")
    }
}
