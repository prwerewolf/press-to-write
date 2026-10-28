import Foundation
import AppKit
import IOKit.hidsystem

public enum HotkeyChoice: String, CaseIterable, Identifiable, Codable {
    case fnHold = "Function (Fn / Globe) Key [Hold]"
    case rightOption = "Right Option Key [Hold]"
    case rightCommand = "Right Command Key [Hold]"
    case doubleTapFn = "Double Tap Fn [Toggle]"
    case controlSpace = "Control + Space [Toggle]"

    public var id: String { rawValue }
}

public enum DictationMode: String, CaseIterable, Identifiable, Codable {
    case pushToTalk = "Push to Talk (Hold to speak)"
    case toggle = "Toggle (Press to start, press to stop)"

    public var id: String { rawValue }
}

public final class HotkeyManager {
    public static let shared = HotkeyManager()

    public var onHotkeyDown: (() -> Void)?
    public var onHotkeyUp: (() -> Void)?
    public var onToggle: (() -> Void)?
    public var onCancel: (() -> Void)?

    private var globalFlagsMonitor: Any?
    private var localFlagsMonitor: Any?
    private var globalKeyMonitor: Any?
    private var localKeyMonitor: Any?

    private var isFnDown = false
    private var isRightOptionDown = false
    private var isRightCommandDown = false
    private var lastFnTapTime: TimeInterval = 0

    public var activeHotkey: HotkeyChoice = .fnHold
    public var activeMode: DictationMode = .pushToTalk

    private init() {}

    public static func isAccessibilityGranted() -> Bool {
        return AXIsProcessTrusted()
    }

    public static func requestAccessibilityPermission() {
        let options: NSDictionary = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options)
    }

    private var lastKnownTrust: Bool?

    /// Event monitors installed before Accessibility was granted may never receive
    /// events. Re-arm them the moment trust appears, wherever it was granted from.
    static func shouldRearm(lastKnownTrust: Bool?, isTrusted: Bool) -> Bool {
        isTrusted && lastKnownTrust == false
    }

    /// Call periodically. Returns true when the monitors were re-armed.
    @discardableResult
    public func rearmIfAccessibilityBecameTrusted(isTrusted: Bool = HotkeyManager.isAccessibilityGranted()) -> Bool {
        let rearm = Self.shouldRearm(lastKnownTrust: lastKnownTrust, isTrusted: isTrusted)
        lastKnownTrust = isTrusted
        if rearm { startListening() }
        return rearm
    }

    public func startListening() {
        stopListening()
        lastKnownTrust = Self.isAccessibilityGranted()

        // Global flag changes (Fn, Option, Command, etc.)
        globalFlagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
        }

        localFlagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handleFlagsChanged(event: event)
            return event
        }

        // Global key down for combo hotkeys like Ctrl+Space
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event: event)
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKeyDown(event: event)
            return event
        }
    }

    public func stopListening() {
        if let monitor = globalFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            globalFlagsMonitor = nil
        }
        if let monitor = localFlagsMonitor {
            NSEvent.removeMonitor(monitor)
            localFlagsMonitor = nil
        }
        if let monitor = globalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            globalKeyMonitor = nil
        }
        if let monitor = localKeyMonitor {
            NSEvent.removeMonitor(monitor)
            localKeyMonitor = nil
        }
        resetModifierStates()
    }

    /// Clears any latched key states so an interrupted recording does not ignore subsequent presses.
    public func resetModifierStates() {
        isFnDown = false
        isRightOptionDown = false
        isRightCommandDown = false
    }

    func handleFlagsChanged(event: NSEvent) {
        let flags = event.modifierFlags
        let keyCode = event.keyCode

        // Fn / Globe key (keyCode 63 on macOS keyboards)
        if keyCode == 63 || flags.contains(.function) {
            let fnPressedNow = flags.contains(.function)

            if activeHotkey == .fnHold {
                if fnPressedNow && !isFnDown {
                    isFnDown = true
                    if activeMode == .pushToTalk {
                        onHotkeyDown?()
                    } else {
                        onToggle?()
                    }
                } else if !fnPressedNow {
                    let wasDown = isFnDown
                    isFnDown = false
                    if wasDown && activeMode == .pushToTalk {
                        onHotkeyUp?()
                    }
                }
            } else if activeHotkey == .doubleTapFn {
                if fnPressedNow && !isFnDown {
                    isFnDown = true
                    let now = Date().timeIntervalSince1970
                    if now - lastFnTapTime < 0.35 {
                        onToggle?()
                        lastFnTapTime = 0
                    } else {
                        lastFnTapTime = now
                    }
                } else if !fnPressedNow {
                    isFnDown = false
                }
            }
        } else if !flags.contains(.function) && isFnDown {
            isFnDown = false
            if activeHotkey == .fnHold && activeMode == .pushToTalk {
                onHotkeyUp?()
            }
        }

        // Right Option key (keyCode 61)
        if keyCode == 61 && activeHotkey == .rightOption {
            // The aggregate Option flag stays set if the left key is still held.
            let optPressed = flags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0
            if optPressed && !isRightOptionDown {
                isRightOptionDown = true
                if activeMode == .pushToTalk {
                    onHotkeyDown?()
                } else {
                    onToggle?()
                }
            } else if !optPressed {
                let wasDown = isRightOptionDown
                isRightOptionDown = false
                if wasDown && activeMode == .pushToTalk {
                    onHotkeyUp?()
                }
            }
        } else if activeHotkey == .rightOption && (flags.rawValue & UInt(NX_DEVICERALTKEYMASK) == 0) && isRightOptionDown {
            isRightOptionDown = false
            if activeMode == .pushToTalk {
                onHotkeyUp?()
            }
        }

        // Right Command key (keyCode 54)
        if keyCode == 54 && activeHotkey == .rightCommand {
            let cmdPressed = flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
            if cmdPressed && !isRightCommandDown {
                isRightCommandDown = true
                if activeMode == .pushToTalk {
                    onHotkeyDown?()
                } else {
                    onToggle?()
                }
            } else if !cmdPressed {
                let wasDown = isRightCommandDown
                isRightCommandDown = false
                if wasDown && activeMode == .pushToTalk {
                    onHotkeyUp?()
                }
            }
        } else if activeHotkey == .rightCommand && (flags.rawValue & UInt(NX_DEVICERCMDKEYMASK) == 0) && isRightCommandDown {
            isRightCommandDown = false
            if activeMode == .pushToTalk {
                onHotkeyUp?()
            }
        }
    }

    func handleKeyDown(event: NSEvent) {
        guard !event.isARepeat else { return }

        // Observe Escape for every hotkey configuration. The local monitor still
        // returns the original event, so other applications keep their Escape action.
        if event.keyCode == 53 {
            onCancel?()
            return
        }

        // Control + Space (keyCode 49 is Space)
        if activeHotkey == .controlSpace && event.keyCode == 49 && event.modifierFlags.contains(.control) {
            onToggle?()
        }
    }
}
