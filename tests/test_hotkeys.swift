import AppKit
import IOKit.hidsystem

@main
struct HotkeyTests {
    static func event(
        _ keyCode: UInt16,
        flags: NSEvent.ModifierFlags,
        type: NSEvent.EventType = .flagsChanged,
        isRepeat: Bool = false
    ) -> NSEvent {
        // Construct events for the handlers without posting input or installing monitors.
        NSEvent.keyEvent(
            with: type,
            location: .zero,
            modifierFlags: flags,
            timestamp: 1,
            windowNumber: 0,
            context: nil,
            characters: type == .keyDown ? " " : "",
            charactersIgnoringModifiers: type == .keyDown ? " " : "",
            isARepeat: isRepeat,
            keyCode: keyCode
        )!
    }

    static func main() {
        let manager = HotkeyManager.shared
        var callbacks: [String] = []
        manager.onHotkeyDown = { callbacks.append("down") }
        manager.onHotkeyUp = { callbacks.append("up") }
        manager.onToggle = { callbacks.append("toggle") }
        manager.onCancel = { callbacks.append("cancel") }
        var checked = 0

        func expect(_ expected: [String], _ description: String) {
            precondition(callbacks == expected, "\(description): expected \(expected), got \(callbacks)")
            callbacks.removeAll()
            checked += 1
        }

        let modifiers: [(HotkeyChoice, UInt16, UInt16, NSEvent.ModifierFlags, Int, Int)] = [
            (.rightOption, 61, 58, .option, Int(NX_DEVICERALTKEYMASK), Int(NX_DEVICELALTKEYMASK)),
            (.rightCommand, 54, 55, .command, Int(NX_DEVICERCMDKEYMASK), Int(NX_DEVICELCMDKEYMASK))
        ]

        for (choice, rightCode, leftCode, aggregate, rightMask, leftMask) in modifiers {
            let rightFlags = aggregate.union(NSEvent.ModifierFlags(rawValue: UInt(rightMask)))
            let leftFlags = aggregate.union(NSEvent.ModifierFlags(rawValue: UInt(leftMask)))
            let bothFlags = rightFlags.union(leftFlags)
            manager.activeHotkey = choice

            for mode in [DictationMode.pushToTalk, .toggle] {
                manager.activeMode = mode
                let expected = mode == .pushToTalk ? ["down", "up"] : ["toggle"]

                manager.handleFlagsChanged(event: event(leftCode, flags: leftFlags))
                manager.handleFlagsChanged(event: event(leftCode, flags: []))
                expect([], "Left key alone must not trigger \(choice)")

                manager.handleFlagsChanged(event: event(leftCode, flags: leftFlags))
                manager.handleFlagsChanged(event: event(rightCode, flags: bothFlags))
                manager.handleFlagsChanged(event: event(rightCode, flags: leftFlags))
                manager.handleFlagsChanged(event: event(leftCode, flags: []))
                expect(expected, "Release right \(choice) while left is still held (\(mode))")

                manager.handleFlagsChanged(event: event(rightCode, flags: rightFlags))
                manager.handleFlagsChanged(event: event(leftCode, flags: bothFlags))
                manager.handleFlagsChanged(event: event(leftCode, flags: rightFlags))
                manager.handleFlagsChanged(event: event(rightCode, flags: []))
                expect(expected, "Release left before right \(choice) (\(mode))")

                manager.handleFlagsChanged(event: event(rightCode, flags: rightFlags))
                manager.handleFlagsChanged(event: event(rightCode, flags: []))
                expect(expected, "Next right-only press still works (\(choice), \(mode))")
            }
        }

        manager.activeHotkey = .controlSpace
        manager.handleKeyDown(event: event(49, flags: .control, type: .keyDown))
        for _ in 0..<5 {
            manager.handleKeyDown(event: event(49, flags: .control, type: .keyDown, isRepeat: true))
        }
        expect(["toggle"], "Holding Control+Space must toggle exactly once")

        manager.handleKeyDown(event: event(49, flags: .control, type: .keyDown))
        expect(["toggle"], "A second physical Control+Space press must toggle again")

        manager.handleKeyDown(event: event(49, flags: [], type: .keyDown))
        manager.handleKeyDown(event: event(48, flags: .control, type: .keyDown))
        expect([], "Other keys must not trigger Control+Space")

        for choice in HotkeyChoice.allCases {
            manager.activeHotkey = choice
            manager.handleKeyDown(event: event(53, flags: [], type: .keyDown))
            for _ in 0..<5 {
                manager.handleKeyDown(event: event(53, flags: [], type: .keyDown, isRepeat: true))
            }
            expect(["cancel"], "Escape cancels once regardless of selected hotkey (\(choice))")

            manager.handleKeyDown(event: event(53, flags: .control, type: .keyDown))
            expect(["cancel"], "Escape works while a dictation modifier is still held (\(choice))")
        }

        // Test resetModifierStates unsticking latched keys
        manager.activeHotkey = .fnHold
        manager.activeMode = .pushToTalk
        manager.handleFlagsChanged(event: event(63, flags: .function))
        expect(["down"], "Fn press down")
        manager.resetModifierStates()
        manager.handleFlagsChanged(event: event(63, flags: .function))
        expect(["down"], "Fn press down again after resetModifierStates must trigger down")
        manager.resetModifierStates()

        // Test that flagsChanged without .function unlatches isFnDown even if keyCode is not 63
        manager.handleFlagsChanged(event: event(63, flags: .function))
        expect(["down"], "Fn press down")
        manager.handleFlagsChanged(event: event(0, flags: []))
        expect(["up"], "Unrelated flagsChanged without function flag must unlatch Fn and trigger up")

        // Test that flagsChanged without right option unlatches isRightOptionDown
        manager.activeHotkey = .rightOption
        manager.handleFlagsChanged(event: event(61, flags: .option.union(NSEvent.ModifierFlags(rawValue: UInt(NX_DEVICERALTKEYMASK)))))
        expect(["down"], "Right option press down")
        manager.handleFlagsChanged(event: event(0, flags: []))
        expect(["up"], "FlagsChanged without right option mask must unlatch Option and trigger up")

        // Monitors installed before Accessibility was granted are re-armed once, on the grant.
        let rearmCases: [(Bool?, Bool, Bool, String)] = [
            (false, true, true, "Granting Accessibility after launch re-arms the hotkey monitors"),
            (true, true, false, "Staying trusted never re-arms, so a held hotkey is not disturbed"),
            (false, false, false, "Staying untrusted does nothing"),
            (true, false, false, "Revoking access does not re-arm"),
            (nil, true, false, "A first observation is recorded without re-arming"),
            (nil, false, false, "A first untrusted observation is recorded without re-arming")
        ]
        for (last, trusted, expected, description) in rearmCases {
            precondition(HotkeyManager.shouldRearm(lastKnownTrust: last, isTrusted: trusted) == expected, description)
            checked += 1
        }

        print("All Press To Write hotkey tests passed (\(checked) scenarios).")
    }
}
