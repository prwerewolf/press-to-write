import AppKit
import ApplicationServices

public enum ApplicationCategory: String, CaseIterable, Sendable {
    case code
    case chat
    case prose

    public static func category(for bundleIdentifier: String?) -> ApplicationCategory {
        InsertionTarget.category(for: bundleIdentifier)
    }
}

/// The application and focused control that owned the cursor when dictation began.
/// Checking a target never activates an application or changes keyboard focus.
public struct InsertionTarget {
    private let processID: pid_t
    private let applicationElement: AXUIElement
    private let focusedElement: AXUIElement?

    public static func capture() -> InsertionTarget? {
        guard AXIsProcessTrusted(),
              let application = NSWorkspace.shared.frontmostApplication else { return nil }

        let processID = application.processIdentifier
        if processID == ProcessInfo.processInfo.processIdentifier {
            return nil
        }
        let applicationElement = AXUIElementCreateApplication(processID)
        let focusedElement = focus(in: applicationElement)
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == processID else { return nil }

        return InsertionTarget(
            processID: processID,
            applicationElement: applicationElement,
            focusedElement: focusedElement
        )
    }

    public init(processID: pid_t, applicationElement: AXUIElement, focusedElement: AXUIElement?) {
        self.processID = processID
        self.applicationElement = applicationElement
        self.focusedElement = focusedElement
    }

    public var targetPID: pid_t { processID }

    public var targetBundleIdentifier: String? {
        NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
    }

    public var applicationCategory: ApplicationCategory {
        Self.category(for: targetBundleIdentifier)
    }

    public static func category(for bundleIdentifier: String?) -> ApplicationCategory {
        guard let bundleID = bundleIdentifier?.lowercased() else { return .prose }
        let codeBundleIDs: Set<String> = [
            "com.microsoft.vscode",
            "com.microsoft.vscodeinsiders",
            "com.todesktop.230313mzl4w4u92",
            "com.apple.dt.xcode",
            "com.apple.terminal",
            "com.googlecode.iterm2",
            "dev.warp.warp-stable",
            "dev.warp.warp",
            "com.sublimetext.4",
            "com.sublimetext.3",
            "com.jetbrains.intellij",
            "com.jetbrains.intellij.ce",
            "com.jetbrains.pycharm",
            "com.jetbrains.pycharm.ce",
            "com.jetbrains.webstorm",
            "com.jetbrains.clion",
            "com.jetbrains.rider",
            "com.jetbrains.goland",
            "com.jetbrains.rubymine",
            "com.jetbrains.datagrip",
            "com.jetbrains.fleet",
            "com.panic.nova",
            "com.mitchellh.ghostty",
            "co.zeit.hyper",
            "net.kovidgoyal.kitty",
            "io.alacritty",
            "com.github.wez.wezterm",
            "com.google.android.studio",
            "com.postmanlabs.mac",
            "com.insomnia.app",
            "com.sequel-ace.sequel-ace",
            "com.tableplus.tableplus"
        ]
        if codeBundleIDs.contains(bundleID) { return .code }

        let chatBundleIDs: Set<String> = [
            "com.tinyspeck.slackmacgap",
            "com.apple.mobilesms",
            "com.hnc.discord",
            "org.whispersystems.signal-desktop",
            "com.microsoft.teams2",
            "com.microsoft.teams",
            "ru.keepcoder.telegram",
            "com.tdesktop.telegram",
            "com.facebook.archon",
            "net.whatsapp.whatsapp",
            "com.element.desktop",
            "chat.rocket"
        ]
        if chatBundleIDs.contains(bundleID) { return .chat }

        return .prose
    }

    public func watchCorrectionFocus(_ onChange: @escaping () -> Void) -> CorrectionFocusWatch? {
        CorrectionFocusWatch(processID: processID, application: applicationElement, onChange: onChange)
    }

    /// Correction learning has a stricter policy than automatic paste: a known
    /// control must still be focused, and secure/unsupported controls are excluded.
    /// Never copy a selection or read an unbounded document to obtain this value.
    public func correctionSnapshot(
        currentProcessID: () -> pid_t? = { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue,
        copyParameterizedAttributeValue: (AXUIElement, CFString, CFTypeRef, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyParameterizedAttributeValue
    ) -> CorrectionFieldSnapshot? {
        guard currentProcessID() == processID, let element = focusedElement,
              let focus = Self.focus(in: applicationElement, setMessagingTimeout: setMessagingTimeout,
                                     copyAttributeValue: copyAttributeValue), CFEqual(element, focus),
              setMessagingTimeout(element, 0.05) == .success else { return nil }
        func attribute(_ name: String) -> CFTypeRef? {
            var value: CFTypeRef?
            guard copyAttributeValue(element, name as CFString, &value) == .success else { return nil }
            return value
        }
        var subrole: CFTypeRef?
        let subroleResult = copyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleResult == .success || subroleResult == .attributeUnsupported || subroleResult == .noValue,
              subrole as? String != "AXSecureTextField",
              let role = attribute(kAXRoleAttribute as String) as? String,
              ["AXTextField", "AXTextArea", "AXComboBox"].contains(role),
              let count = attribute(kAXNumberOfCharactersAttribute as String) as? NSNumber,
              count.intValue >= 0, count.intValue <= 8192,
              let selected = attribute(kAXSelectedTextRangeAttribute as String),
              CFGetTypeID(selected) == AXValueGetTypeID() else { return nil }
        let selectedValue = selected as! AXValue
        var selection = CFRange()
        guard AXValueGetType(selectedValue) == .cfRange,
              AXValueGetValue(selectedValue, .cfRange, &selection),
              selection.location >= 0, selection.length >= 0,
              selection.location <= count.intValue,
              selection.length <= count.intValue - selection.location else { return nil }
        var range = CFRange(location: 0, length: count.intValue)
        guard let rangeValue = AXValueCreate(.cfRange, &range) else { return nil }
        var value: CFTypeRef?
        if count.intValue == 0 { value = "" as CFString }
        else if copyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                rangeValue, &value) != .success { return nil }
        guard let text = value as? String, text.utf16.count == count.intValue,
              currentProcessID() == processID,
              let finalFocus = Self.focus(in: applicationElement, setMessagingTimeout: setMessagingTimeout,
                                          copyAttributeValue: copyAttributeValue), CFEqual(element, finalFocus)
        else { return nil }
        return CorrectionFieldSnapshot(text: text, selection: NSRange(location: selection.location, length: selection.length))
    }

    public enum CursorContext: Equatable {
        case character(Character)
        case startOfText
        case unavailable
    }

    /// Reads the cursor context in the focused control with bounded IPC timeout.
    /// Differentiates start-of-field (location == 0) from unsupported accessibility.
    public func cursorContext(
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue,
        copyParameterizedAttributeValue: (AXUIElement, CFString, CFTypeRef, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyParameterizedAttributeValue
    ) -> CursorContext {
        guard let element = focusedElement ?? Self.focus(in: applicationElement) else { return .unavailable }
        guard setMessagingTimeout(element, 0.2) == .success else { return .unavailable }
        var rangeValue: CFTypeRef?
        guard copyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unavailable }

        let axValue = rangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return .unavailable }
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return .unavailable }
        if cfRange.location == 0 {
            return .startOfText
        }

        var charRange = CFRange(location: cfRange.location - 1, length: 1)
        guard let charRangeVal = AXValueCreate(.cfRange, &charRange) else { return .unavailable }
        var stringVal: CFTypeRef?
        guard copyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            charRangeVal,
            &stringVal
        ) == .success,
              let string = stringVal as? String,
              let char = string.first else { return .unavailable }
        return .character(char)
    }

    /// Attempts to read the character immediately before the current selection/cursor in the focused element.
    /// Returns nil if accessibility attributes are unsupported or cursor is at start of text.
    public func precedingCharacter() -> Character? {
        if case .character(let char) = cursorContext() {
            return char
        }
        return nil
    }

    /// Attempts to read up to `maxCharacters` immediately preceding the current selection/cursor in the focused element.
    /// Returns nil if accessibility attributes are unsupported, cursor is at start of text, or text is empty.
    public func precedingText(
        maxCharacters: Int = 200,
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue,
        copyParameterizedAttributeValue: (AXUIElement, CFString, CFTypeRef, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyParameterizedAttributeValue
    ) -> String? {
        guard maxCharacters > 0 else { return nil }
        guard let element = focusedElement ?? Self.focus(in: applicationElement) else { return nil }
        guard setMessagingTimeout(element, 0.2) == .success else { return nil }
        var rangeValue: CFTypeRef?
        guard copyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue,
              CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }

        let axValue = rangeValue as! AXValue
        guard AXValueGetType(axValue) == .cfRange else { return nil }
        var cfRange = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &cfRange) else { return nil }
        if cfRange.location <= 0 { return nil }

        let startLocation = max(0, cfRange.location - maxCharacters)
        let length = cfRange.location - startLocation
        var textRange = CFRange(location: startLocation, length: length)
        guard let textRangeVal = AXValueCreate(.cfRange, &textRange) else { return nil }
        var stringVal: CFTypeRef?
        guard copyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            textRangeVal,
            &stringVal
        ) == .success,
              let string = stringVal as? String,
              !string.isEmpty else { return nil }
        return string
    }

    public var isCurrent: Bool {
        guard let currentPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              currentPID == processID else { return false }

        // Applications that don't expose control-level accessibility (e.g. some
        // terminals), or that hand out proxy objects, leave the comparison unknown.
        // Then verifying that the user is still in the same application is the
        // best available check. Only positive evidence of another control blocks.
        let comparison = Self.compareControls(original: focusedElement, current: Self.focus(in: applicationElement))
        if comparison == .different {
            NSLog("[Press To Write] Insertion skipped: focus moved to a different control")
        }
        return Self.matches(
            originalProcessID: processID,
            currentProcessID: currentPID,
            focusedElementMatches: comparison != .different
        )
    }

    enum ControlComparison: Equatable {
        case same
        case different
        case unknown
    }

    /// Browsers and Electron apps can return a new proxy object for the same field,
    /// so CFEqual alone cannot prove a field switch. Compare what a person would
    /// call "the same field": its role and on-screen frame. Report `.different`
    /// only when both are readable and disagree; anything unreadable is `.unknown`.
    static func compareControls(
        original: AXUIElement?,
        current: AXUIElement?,
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue
    ) -> ControlComparison {
        guard let original, let current else { return .unknown }
        if CFEqual(original, current) { return .same }

        func read(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
            guard setMessagingTimeout(element, 0.2) == .success else { return nil }
            var value: CFTypeRef?
            guard copyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
            return value
        }
        func frame(_ element: AXUIElement) -> CGRect? {
            guard let position = read(element, kAXPositionAttribute as String),
                  CFGetTypeID(position) == AXValueGetTypeID(),
                  AXValueGetType(position as! AXValue) == .cgPoint,
                  let size = read(element, kAXSizeAttribute as String),
                  CFGetTypeID(size) == AXValueGetTypeID(),
                  AXValueGetType(size as! AXValue) == .cgSize else { return nil }
            var origin = CGPoint.zero
            var extent = CGSize.zero
            guard AXValueGetValue(position as! AXValue, .cgPoint, &origin),
                  AXValueGetValue(size as! AXValue, .cgSize, &extent) else { return nil }
            return CGRect(origin: origin, size: extent)
        }

        guard let originalRole = read(original, kAXRoleAttribute as String) as? String,
              let currentRole = read(current, kAXRoleAttribute as String) as? String else { return .unknown }
        if originalRole != currentRole { return .different }
        guard let originalFrame = frame(original), let currentFrame = frame(current) else { return .unknown }
        let tolerance: CGFloat = 1
        let sameFrame = abs(originalFrame.minX - currentFrame.minX) <= tolerance
            && abs(originalFrame.minY - currentFrame.minY) <= tolerance
            && abs(originalFrame.width - currentFrame.width) <= tolerance
            && abs(originalFrame.height - currentFrame.height) <= tolerance
        return sameFrame ? .same : .different
    }

    // Kept separate from the system queries so focus policy can be tested without
    // accessibility permission, posting keyboard events, or touching the clipboard.
    static func matches(
        originalProcessID: pid_t,
        currentProcessID: pid_t?,
        focusedElementMatches: Bool
    ) -> Bool {
        currentProcessID == originalProcessID && focusedElementMatches
    }

    // AX attribute reads synchronously message the destination app. Apply the
    // timeout to this exact object before every query; equal AX objects do not
    // inherit per-object timeouts. An unresponsive destination fails closed.
    // Injectable functions let tests simulate stalled AX messaging without UI reads.
    static func focus(
        in application: AXUIElement,
        setMessagingTimeout: (AXUIElement, Float) -> AXError = AXUIElementSetMessagingTimeout,
        copyAttributeValue: (AXUIElement, CFString, UnsafeMutablePointer<CFTypeRef?>) -> AXError = AXUIElementCopyAttributeValue
    ) -> AXUIElement? {
        guard setMessagingTimeout(application, 0.2) == .success else { return nil }
        var value: CFTypeRef?
        let result = copyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )
        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return (value as! AXUIElement)
    }
}

/// Native focus notifications stop learning even if the user briefly leaves
/// and returns between polls. Unsupported apps retain the strict polling check.
public final class CorrectionFocusWatch {
    private var observer: AXObserver?
    private let application: AXUIElement
    private let onChange: () -> Void

    init?(processID: pid_t, application: AXUIElement, onChange: @escaping () -> Void) {
        self.application = application
        self.onChange = onChange
        var observer: AXObserver?
        let result = AXObserverCreate(processID, { _, _, _, context in
            guard let context else { return }
            let watcher = Unmanaged<CorrectionFocusWatch>.fromOpaque(context).takeUnretainedValue()
            watcher.onChange()
        }, &observer)
        guard result == .success, let observer else { return nil }
        guard AXUIElementSetMessagingTimeout(application, 0.05) == .success,
              AXObserverAddNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString,
                                        Unmanaged.passUnretained(self).toOpaque()) == .success else { return nil }
        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
    }

    deinit {
        if let observer {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            AXObserverRemoveNotification(observer, application, kAXFocusedUIElementChangedNotification as CFString)
        }
    }
}
