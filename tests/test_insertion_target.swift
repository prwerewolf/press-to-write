import Foundation
import ApplicationServices

@main
struct InsertionTargetTests {
    static func main() {
        let scenarios: [(String, pid_t?, Bool, Bool)] = [
            ("Original application and control still focused", 100, true, true),
            ("Switched to another application", 200, true, false),
            ("Switched to another field in the original application", 100, false, false),
            ("Original application lost focus and no foreground app is available", nil, true, false),
            ("Focused control is missing or cannot be read", 100, false, false),
            ("Application and focused control both changed", 200, false, false)
        ]

        for (description, currentProcessID, focusedElementMatches, expected) in scenarios {
            let actual = InsertionTarget.matches(
                originalProcessID: 100,
                currentProcessID: currentProcessID,
                focusedElementMatches: focusedElementMatches
            )
            precondition(actual == expected, description)
        }

        // Creating an AX object is local; all messaging below is replaced by fakes.
        // Model an unresponsive server that consumes its configured timeout.
        let application = AXUIElementCreateApplication(getpid())
        var configuredTimeout: Float = 6
        var elapsedMessagingTime: Float = 0
        var requestedAttributes: [String] = []
        let unavailableFocus = InsertionTarget.focus(
            in: application,
            setMessagingTimeout: { element, timeout in
                precondition(CFEqual(element, application))
                configuredTimeout = timeout
                return .success
            },
            copyAttributeValue: { element, attribute, _ in
                precondition(CFEqual(element, application))
                requestedAttributes.append(attribute as String)
                elapsedMessagingTime += configuredTimeout
                return .cannotComplete
            }
        )
        precondition(unavailableFocus == nil, "An unresponsive app must never become an insertion target")
        precondition(elapsedMessagingTime > 0 && elapsedMessagingTime <= 0.25,
                     "A stalled focus query must be bounded, rather than consuming the default multi-second timeout")
        precondition(requestedAttributes == [kAXFocusedUIElementAttribute as String],
                     "Focus protection must read only the focused element identity")

        var didQueryAfterConfigurationFailure = false
        let unboundedFocus = InsertionTarget.focus(
            in: application,
            setMessagingTimeout: { _, _ in .invalidUIElement },
            copyAttributeValue: { _, _, _ in
                didQueryAfterConfigurationFailure = true
                return .success
            }
        )
        precondition(unboundedFocus == nil && !didQueryAfterConfigurationFailure,
                     "Do not attempt an unbounded query if applying the timeout fails")

        let responsiveFocus = InsertionTarget.focus(
            in: application,
            setMessagingTimeout: { _, _ in .success },
            copyAttributeValue: { _, _, result in
                result.pointee = application
                return .success
            }
        )
        precondition(responsiveFocus.map { CFEqual($0, application) } == true,
                     "A successful bounded query must preserve its focused element")

        // Test bounded timeout and cursor context on focused element
        let targetWithElement = InsertionTarget(processID: 100, applicationElement: application, focusedElement: application)
        var cursorTimeout: Float = 0
        let timedOutContext = targetWithElement.cursorContext(
            setMessagingTimeout: { _, timeout in
                cursorTimeout = timeout
                return .cannotComplete
            }
        )
        precondition(timedOutContext == .unavailable, "Stalled cursor query must fail closed")
        precondition(cursorTimeout == 0.2, "Cursor context must enforce 0.2s messaging timeout")

        // Location 0 should return startOfText
        var zeroRange = CFRange(location: 0, length: 0)
        let zeroAxVal = AXValueCreate(.cfRange, &zeroRange)!
        let startContext = targetWithElement.cursorContext(
            setMessagingTimeout: { _, _ in .success },
            copyAttributeValue: { _, attr, result in
                if attr as String == kAXSelectedTextRangeAttribute as String {
                    result.pointee = zeroAxVal
                    return .success
                }
                return .attributeUnsupported
            }
        )
        precondition(startContext == .startOfText, "Location 0 must report startOfText")

        // Location > 0 should return character
        var midRange = CFRange(location: 5, length: 0)
        let midAxVal = AXValueCreate(.cfRange, &midRange)!
        let charContext = targetWithElement.cursorContext(
            setMessagingTimeout: { _, _ in .success },
            copyAttributeValue: { _, attr, result in
                if attr as String == kAXSelectedTextRangeAttribute as String {
                    result.pointee = midAxVal
                    return .success
                }
                return .attributeUnsupported
            },
            copyParameterizedAttributeValue: { _, attr, _, result in
                if attr as String == kAXStringForRangeParameterizedAttribute as String {
                    result.pointee = "W" as CFString
                    return .success
                }
                return .attributeUnsupported
            }
        )
        precondition(charContext == .character("W"), "Location > 0 must report preceding character")

        // Test precedingText: location 0 returns nil
        let zeroText = targetWithElement.precedingText(
            setMessagingTimeout: { _, _ in .success },
            copyAttributeValue: { _, attr, result in
                if attr as String == kAXSelectedTextRangeAttribute as String {
                    result.pointee = zeroAxVal
                    return .success
                }
                return .attributeUnsupported
            }
        )
        precondition(zeroText == nil, "Location 0 must report nil preceding text")

        // Test precedingText: location > 0 returns preceding substring
        var queriedRange = CFRange()
        let midText = targetWithElement.precedingText(
            maxCharacters: 50,
            setMessagingTimeout: { _, _ in .success },
            copyAttributeValue: { _, attr, result in
                if attr as String == kAXSelectedTextRangeAttribute as String {
                    result.pointee = midAxVal
                    return .success
                }
                return .attributeUnsupported
            },
            copyParameterizedAttributeValue: { _, attr, param, result in
                if attr as String == kAXStringForRangeParameterizedAttribute as String {
                    let axRange = param as! AXValue
                    AXValueGetValue(axRange, .cfRange, &queriedRange)
                    result.pointee = "Hello" as CFString
                    return .success
                }
                return .attributeUnsupported
            }
        )
        precondition(midText == "Hello", "Location > 0 must report preceding text")
        precondition(queriedRange.location == 0 && queriedRange.length == 5, "Queried range must cover prefix up to location 5")

        // Learning requires exact control identity and bounded non-secure text.
        var didReadCorrectionText = false
        var secure = false
        var reportedLength = "📌 Lumara".utf16.count
        var focusedControl = application
        var subroleFailure: AXError? = nil
        var currentPID: pid_t = 100
        func correctionSnapshot() -> CorrectionFieldSnapshot? {
            targetWithElement.correctionSnapshot(
                currentProcessID: { currentPID },
                setMessagingTimeout: { _, _ in .success },
                copyAttributeValue: { _, attribute, value in
                    switch attribute as String {
                    case let name where name == kAXFocusedUIElementAttribute as String: value.pointee = focusedControl
                    case let name where name == kAXRoleAttribute as String: value.pointee = "AXTextArea" as CFString
                    case let name where name == kAXSubroleAttribute as String:
                        if let subroleFailure { return subroleFailure }
                        value.pointee = (secure ? "AXSecureTextField" : "AXStandardTextArea") as CFString
                    case let name where name == kAXNumberOfCharactersAttribute as String: value.pointee = NSNumber(value: reportedLength)
                    case let name where name == kAXSelectedTextRangeAttribute as String: value.pointee = zeroAxVal
                    default: return .attributeUnsupported
                    }
                    return .success
                },
                copyParameterizedAttributeValue: { _, attribute, parameter, value in
                    precondition(attribute as String == kAXStringForRangeParameterizedAttribute as String)
                    var range = CFRange()
                    AXValueGetValue(parameter as! AXValue, .cfRange, &range)
                    precondition(range.location == 0 && range.length <= 8192)
                    didReadCorrectionText = true
                    value.pointee = "📌 Lumara" as CFString
                    return .success
                }
            )
        }
        precondition(correctionSnapshot()?.text == "📌 Lumara" && didReadCorrectionText)
        didReadCorrectionText = false
        secure = true
        precondition(correctionSnapshot() == nil && !didReadCorrectionText, "Secure fields must never be read")
        secure = false
        subroleFailure = .cannotComplete
        precondition(correctionSnapshot() == nil && !didReadCorrectionText, "Unknown security status must fail closed")
        subroleFailure = nil
        reportedLength = 8193
        precondition(correctionSnapshot() == nil && !didReadCorrectionText, "Large documents must not be read")
        reportedLength = 8
        focusedControl = AXUIElementCreateSystemWide()
        precondition(correctionSnapshot() == nil && !didReadCorrectionText, "Another field in the same app must not be read")
        focusedControl = application
        currentPID = 200
        precondition(ApplicationCategory.category(for: "com.microsoft.VSCode") == .code)
        precondition(ApplicationCategory.category(for: "com.apple.Terminal") == .code)
        precondition(ApplicationCategory.category(for: "com.todesktop.230313mzl4w4u92") == .code)
        precondition(ApplicationCategory.category(for: "com.googlecode.iterm2") == .code)
        precondition(ApplicationCategory.category(for: "com.tinyspeck.slackmacgap") == .chat)
        precondition(ApplicationCategory.category(for: "com.apple.MobileSMS") == .chat)
        precondition(ApplicationCategory.category(for: "com.hnc.Discord") == .chat)
        precondition(ApplicationCategory.category(for: "com.apple.mail") == .prose)
        precondition(ApplicationCategory.category(for: "com.apple.Notes") == .prose)
        precondition(ApplicationCategory.category(for: nil) == .prose)

        // A field switch inside one app must block the paste. Distinct AX objects
        // stand in for browser proxies; the fake table gives each a role and frame.
        let fieldA = AXUIElementCreateApplication(getpid())
        let fieldB = AXUIElementCreateSystemWide()
        struct Control { var role: String?; var origin: CGPoint?; var size: CGSize? }
        var controls: [(element: AXUIElement, control: Control)] = []
        var attributeReads = 0
        var failTimeout = false
        func axValue(_ point: CGPoint) -> CFTypeRef {
            var p = point
            return AXValueCreate(.cgPoint, &p)!
        }
        func axValue(_ size: CGSize) -> CFTypeRef {
            var s = size
            return AXValueCreate(.cgSize, &s)!
        }
        func compare(_ original: AXUIElement?, _ current: AXUIElement?) -> InsertionTarget.ControlComparison {
            attributeReads = 0
            return InsertionTarget.compareControls(
                original: original, current: current,
                setMessagingTimeout: { _, _ in failTimeout ? .cannotComplete : .success },
                copyAttributeValue: { element, attribute, result in
                    attributeReads += 1
                    guard let control = controls.first(where: { CFEqual($0.element, element) })?.control else {
                        return .cannotComplete
                    }
                    switch attribute as String {
                    case kAXRoleAttribute as String:
                        guard let role = control.role else { return .attributeUnsupported }
                        result.pointee = role as CFString
                    case kAXPositionAttribute as String:
                        guard let origin = control.origin else { return .attributeUnsupported }
                        result.pointee = axValue(origin)
                    case kAXSizeAttribute as String:
                        guard let size = control.size else { return .attributeUnsupported }
                        result.pointee = axValue(size)
                    default:
                        return .attributeUnsupported
                    }
                    return .success
                }
            )
        }
        func setControls(_ a: Control, _ b: Control) { controls = [(fieldA, a), (fieldB, b)] }
        let field = Control(role: "AXTextField", origin: CGPoint(x: 100, y: 200), size: CGSize(width: 300, height: 24))

        setControls(field, field)
        precondition(compare(fieldA, fieldA) == .same && attributeReads == 0,
                     "The identical AX object needs no attribute reads")
        precondition(compare(fieldA, fieldB) == .same,
                     "Distinct proxy objects for one role and frame are the same field")
        var nearby = field
        nearby.origin = CGPoint(x: 100.8, y: 200)
        setControls(field, nearby)
        precondition(compare(fieldA, fieldB) == .same, "Sub-point frame noise is the same field")

        var movedField = field
        movedField.origin = CGPoint(x: 100, y: 260)
        setControls(field, movedField)
        precondition(compare(fieldA, fieldB) == .different, "Another field of the same size below is a field switch")
        var widerField = field
        widerField.size = CGSize(width: 340, height: 24)
        setControls(field, widerField)
        precondition(compare(fieldA, fieldB) == .different, "A field at the same origin with another size is a field switch")
        var otherRole = field
        otherRole.role = "AXTextArea"
        setControls(field, otherRole)
        precondition(compare(fieldA, fieldB) == .different, "A different control role is a field switch")

        // Unreadable evidence never blocks; the application check still applies.
        var noRole = field
        noRole.role = nil
        setControls(field, noRole)
        precondition(compare(fieldA, fieldB) == .unknown, "An unreadable role is unknown")
        var noFrame = field
        noFrame.size = nil
        setControls(field, noFrame)
        precondition(compare(fieldA, fieldB) == .unknown, "An unreadable frame is unknown")
        setControls(field, movedField)
        failTimeout = true
        precondition(compare(fieldA, fieldB) == .unknown && attributeReads == 0,
                     "A stalled application is unknown without an unbounded read")
        failTimeout = false
        precondition(compare(nil, fieldB) == .unknown && compare(fieldA, nil) == .unknown,
                     "A missing focused element is unknown")

        print("Insertion destination tests passed, including exact control identity, field switches, secure fields, read bounds, focus loss for correction learning, and application category mapping.")
    }
}

