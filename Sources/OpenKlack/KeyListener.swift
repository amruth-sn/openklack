import AppKit

/// Global keyboard/mouse observer built on NSEvent monitors (requires the
/// Accessibility permission, same as Klack). Local monitors cover events while
/// our own UI is frontmost.
final class KeyListener {
    enum Event {
        case keyDown(keycode: UInt16, isRepeat: Bool, flags: NSEvent.ModifierFlags)
        case keyUp(keycode: UInt16)
        case mouseDown
        case mouseUp
    }

    var handler: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var downModifiers = Set<UInt16>()

    /// Device-dependent NX_DEVICE* modifier flag masks, keyed by keycode.
    private static let deviceMasks: [UInt16: UInt] = [
        59: 0x0001, 62: 0x2000, // control L/R
        56: 0x0002, 60: 0x0004, // shift L/R
        55: 0x0008, 54: 0x0010, // command L/R
        58: 0x0020, 61: 0x0040, // option L/R
    ]

    func start() {
        stop()
        let keyMask: NSEvent.EventTypeMask = [.keyDown, .keyUp, .flagsChanged]
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseUp,
                                                .rightMouseDown, .rightMouseUp,
                                                .otherMouseDown, .otherMouseUp]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: keyMask, handler: { [weak self] event in
            self?.process(event)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            self?.process(event)
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: keyMask, handler: { [weak self] event in
            self?.process(event)
            return event
        }) {
            monitors.append(monitor)
        }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: mouseMask, handler: { [weak self] event in
            self?.process(event)
            return event
        }) {
            monitors.append(monitor)
        }
    }

    func stop() {
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors.removeAll()
        downModifiers.removeAll()
    }

    private func process(_ event: NSEvent) {
        switch event.type {
        case .keyDown:
            handler?(.keyDown(keycode: event.keyCode, isRepeat: event.isARepeat,
                              flags: event.modifierFlags))
        case .keyUp:
            handler?(.keyUp(keycode: event.keyCode))
        case .flagsChanged:
            // NSEvent gives no press/release direction for modifiers; read it
            // from the event's flag bits (device-dependent masks distinguish
            // left/right keys) so state can't invert if an event is missed.
            let code = event.keyCode
            let down: Bool
            if code == 57 {
                // Caps Lock latches: one event per press/release cycle, so a
                // toggle would alternate press/release samples. Always press.
                down = true
            } else if code == 63 {
                down = event.modifierFlags.contains(.function)
            } else if let mask = Self.deviceMasks[code] {
                down = event.modifierFlags.rawValue & mask != 0
            } else {
                down = !downModifiers.contains(code)
            }
            if down {
                downModifiers.insert(code)
                handler?(.keyDown(keycode: code, isRepeat: false, flags: event.modifierFlags))
            } else {
                downModifiers.remove(code)
                handler?(.keyUp(keycode: code))
            }
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            handler?(.mouseDown)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            handler?(.mouseUp)
        default:
            break
        }
    }
}

enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestIfNeeded() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func openSystemSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
