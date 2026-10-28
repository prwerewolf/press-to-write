import Foundation
import Combine

// Compile with AppState, PreferenceMigration, SpeechEngine, and TextCleaner.
// These doubles keep tests away from the microphone, system preferences,
// clipboard, and running daemon.
public final class UserDefaults {
    public static let standard = UserDefaults()
    private var values: [String: Any] = [:]
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
    public func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    public func string(forKey key: String) -> String? { values[key] as? String }
    public func object(forKey key: String) -> Any? { values[key] }
    public func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
}

public final class NSPasteboard {
    public static let general = NSPasteboard()
    public enum PasteboardType { case string }
    public private(set) var writes: [String] = []
    public func clearContents() {}
    public func setString(_ text: String, forType: PasteboardType) { writes.append(text) }
}

public enum HotkeyChoice: String { case fnHold }
public enum DictationMode: String { case pushToTalk }
public final class HotkeyManager {
    public static let shared = HotkeyManager()
    public static var granted = true
    public var activeHotkey = HotkeyChoice.fnHold
    public var activeMode = DictationMode.pushToTalk
    public var onHotkeyDown: (() -> Void)?
    public var onHotkeyUp: (() -> Void)?
    public var onToggle: (() -> Void)?
    public var onCancel: (() -> Void)?
    public private(set) var resetModifierStatesCount = 0
    public func resetModifierStates() { resetModifierStatesCount += 1 }
    public static func isAccessibilityGranted() -> Bool { granted }
    public static func requestAccessibilityPermission() {}
}

public final class AudioRecorder {
    public static let shared = AudioRecorder()
    public var onAudioLevel: ((Float) -> Void)?
    public var onRecordingError: ((Error, URL?) -> Void)?
    public private(set) var recordings: [URL] = []
    public var removeOnStop = false
    public var pcmCallback: ((Data) -> Void)?
    public func startRecording(onPCM16: ((Data) -> Void)? = nil) throws -> URL {
        pcmCallback = onPCM16
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("presstowrite-state-test-\(UUID().uuidString)")
        try Data([0]).write(to: url)
        recordings.append(url)
        return url
    }
    public func stopRecording() -> URL? {
        if removeOnStop, let url = recordings.last {
            try? FileManager.default.removeItem(at: url)
        }
        return recordings.last
    }
}

public final class SoundEffects {
    public static let shared = SoundEffects()
    public var isSoundEnabled = false
    public func playStart() {}
    public func playStop() {}
    public func playSuccess() {}
    public func playError() {}
}

@MainActor
public final class LocalDaemonClient: SpeechEngineProtocol {
    public static let shared = LocalDaemonClient()
    public var result: Result<String, Error> = .success("Test dictation")
    public var status = LocalEngineStatus(phase: .ready, message: "Ready", model: "test-local-model")
    public var suspend = false
    public var pending: [CheckedContinuation<String, Error>] = []
    public private(set) var requests: [(vocabulary: [String], style: TranscriptionStyle, context: String?)] = []
    public private(set) var audioURLs: [URL] = []
    public func engineStatus(mode: SpeechMode = .accuracy) async -> LocalEngineStatus { status }
    public private(set) var streams: [LocalStreamingSession] = []
    public func startStreaming(vocabulary: [String]) -> LocalStreamingSession {
        let session = LocalStreamingSession(vocabulary: vocabulary, result: result)
        streams.append(session)
        return session
    }
    public func transcribe(audioFileURL: URL, vocabulary: [String], style: TranscriptionStyle, context: String? = nil) async throws -> String {
        requests.append((vocabulary, style, context))
        audioURLs.append(audioFileURL)
        // The real daemon removes every file it is asked to transcribe, including
        // after an engine error or cancellation. The app must hand it a copy.
        defer { try? FileManager.default.removeItem(at: audioFileURL) }
        if suspend {
            return try await withCheckedThrowingContinuation { pending.append($0) }
        }
        return try result.get()
    }
}

public final class LocalStreamingSession {
    public let vocabulary: [String]
    public let result: Result<String, Error>
    public private(set) var frames: [Data] = []
    public private(set) var cancelled = false
    public private(set) var finished = false
    init(vocabulary: [String], result: Result<String, Error>) {
        self.vocabulary = vocabulary
        self.result = result
    }
    public func appendPCM16(_ pcm: Data) { frames.append(pcm) }
    public func cancel() { if !finished { cancelled = true } }
    public func finish() async throws -> String {
        try Task.checkCancellation()
        if cancelled { throw CancellationError() }
        finished = true
        return try result.get()
    }
}

public enum LaunchAtLogin {
    public static var isEnabled = false
}

public final class CorrectionFocusWatch {}

public enum ApplicationCategory: String, CaseIterable, Sendable {
    case code
    case chat
    case prose
}

public struct InsertionTarget {
    public enum CursorContext: Equatable {
        case character(Character)
        case startOfText
        case unavailable
    }
    public static var current = true
    public static var mockCategory: ApplicationCategory = .prose
    public static var mockPrecedingChar: Character? = nil
    public static var mockCursorContext: CursorContext? = nil
    public static var mockPrecedingText: String? = nil
    public static var mockSnapshot: CorrectionFieldSnapshot? = nil
    public static var snapshotReads = 0
    public static var focusChanged: (() -> Void)?
    public static func capture() -> InsertionTarget? { InsertionTarget() }
    public var isCurrent: Bool { Self.current }
    public var targetPID: pid_t { 123 }
    public var applicationCategory: ApplicationCategory { Self.mockCategory }
    public func cursorContext() -> CursorContext {
        if let mock = Self.mockCursorContext { return mock }
        if let char = Self.mockPrecedingChar { return .character(char) }
        return .unavailable
    }
    public func precedingCharacter() -> Character? {
        if case .character(let char) = cursorContext() { return char }
        return nil
    }
    public func precedingText(maxCharacters: Int = 200) -> String? {
        Self.mockPrecedingText
    }
    public func correctionSnapshot() -> CorrectionFieldSnapshot? {
        Self.snapshotReads += 1
        return Self.current ? Self.mockSnapshot : nil
    }
    public func watchCorrectionFocus(_ onChange: @escaping () -> Void) -> CorrectionFocusWatch? {
        Self.focusChanged = onChange
        return CorrectionFocusWatch()
    }
}

public final class TextInserter {
    public static let shared = TextInserter()
    public var pendingCompletion: (() -> Void)?
    public private(set) var undoCount = 0
    public var undoSucceeds = true
    public func insertText(_ text: String, keepOnClipboard: Bool, target: InsertionTarget?, shouldInsert: (() -> Bool)? = nil, completion: ((Bool) -> Void)? = nil) {
        pendingCompletion = {
            let inserted = target?.isCurrent == true && shouldInsert?() != false
            if inserted, let before = InsertionTarget.mockSnapshot,
               let capture = CorrectionCapture(before: before, insertedText: text) {
                InsertionTarget.mockSnapshot = CorrectionFieldSnapshot(
                    text: capture.expectedText, selection: NSRange(location: capture.expectedText.utf16.count, length: 0)
                )
            }
            completion?(inserted)
        }
    }
    public func sendUndoKeystroke() -> Bool {
        guard undoSucceeds else { return false }
        undoCount += 1
        return true
    }
}

@main
struct AppStateTests {
    @MainActor
    static func waitUntil(line: Int = #line, _ condition: () -> Bool) async throws {
        for _ in 0..<2000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        preconditionFailure("Timed out waiting for state transition at test line \(line)")
    }

    @MainActor
    static func main() async throws {
        let state = AppState.shared
        let recorder = AudioRecorder.shared
        let engine = LocalDaemonClient.shared
        precondition(state.speechMode == .accuracy, "Whisper must remain the default")
        defer {
            for url in recorder.recordings { try? FileManager.default.removeItem(at: url) }
        }
        precondition(state.historyRetention == .clearOnQuit)
        precondition(!state.autoCopyToClipboard && state.autoInsertText)
        precondition(state.pillOrientation == .horizontal)
        precondition(state.transcriptionStyle == .professional)
        precondition(state.autoAdaptiveFormatting && state.isSoundEnabled)
        precondition(!state.correctionLearningEnabled && state.learnedVocabulary.isEmpty)
        precondition(state.customVocabularyText.isEmpty && state.textReplacementsText.isEmpty)

        state.minRecordingDuration = 0
        state.autoInsertText = false
        state.autoCopyToClipboard = false
        state.startRecording()
        precondition(!state.isRecording, "Loading model must not appear ready")
        await state.refreshEngineStatus()

        // The watchdog polls for the app's whole life. A poll that finds nothing new
        // must not invalidate every view observing the state.
        var publishes = 0
        let observer = state.objectWillChange.sink { publishes += 1 }
        await state.refreshEngineStatus()
        await state.refreshEngineStatus()
        precondition(publishes == 0, "An unchanged engine status must not be republished (\(publishes) publishes)")
        engine.status = LocalEngineStatus(phase: .loading, message: "Warming up", model: nil)
        await state.refreshEngineStatus()
        precondition(publishes > 0 && state.engineStatus.message == "Warming up", "A changed status is still published")
        engine.status = LocalEngineStatus(phase: .ready, message: "Ready", model: "test-local-model")
        await state.refreshEngineStatus()
        precondition(state.engineStatus.phase == .ready && state.statusMessage == "Ready")
        observer.cancel()

        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(state.showSuccess && state.lastTranscribedText == "Test dictation")
        precondition(!FileManager.default.fileExists(atPath: recorder.recordings[0].path))

        // Feedback must not delay the next recording or reset its listening state.
        state.startRecording()
        precondition(state.isRecording && !state.showSuccess)
        try await Task.sleep(nanoseconds: 2_300_000_000)
        precondition(state.isRecording && state.statusMessage == "Listening...")
        precondition(FileManager.default.fileExists(atPath: recorder.recordings[1].path))

        LocalDaemonClient.shared.result = .failure(NSError(
            domain: "Test", code: 1, userInfo: [NSLocalizedDescriptionKey: "Test failure"]
        ))
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(state.statusMessage == "Test failure" && !state.showSuccess)
        precondition(!FileManager.default.fileExists(atPath: recorder.recordings[1].path))

        LocalDaemonClient.shared.result = .success("")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(state.statusMessage == "No Speech Detected")
        try await Task.sleep(nanoseconds: 1_300_000_000)
        precondition(state.statusMessage == "Ready")

        recorder.removeOnStop = true
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(state.statusMessage == "No Audio")
        recorder.removeOnStop = false

        // Preserve the user-requested clipboard fallback when permission is absent.
        LocalDaemonClient.shared.result = .success("Test dictation")
        HotkeyManager.granted = false
        state.autoInsertText = true
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(!state.autoCopyToClipboard)
        precondition(NSPasteboard.general.writes == ["Test dictation"])
        precondition(state.statusMessage == "Copied! (Grant Accessibility to auto-insert)")

        // Actual insertion still finishes before another recording can begin.
        HotkeyManager.granted = true
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        precondition(state.isProcessing)
        state.startRecording()
        precondition(!state.isRecording)
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await waitUntil { !state.isProcessing }
        precondition(state.showSuccess && state.statusMessage == "Inserted!")
        precondition(!FileManager.default.fileExists(atPath: recorder.recordings.last!.path))

        // A changed destination retains the result for explicit copy, without a false success.
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        InsertionTarget.current = false
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await waitUntil { !state.isProcessing }
        precondition(state.hasPendingInsertion && !state.showSuccess)
        precondition(state.lastTranscribedText == "Test dictation")
        precondition(state.statusMessage.contains("manual paste"))
        InsertionTarget.current = true

        // Escape stops capture, deletes its file, and never calls the recognizer.
        let callsBeforeCancel = engine.requests.count
        state.startRecording()
        let canceledFile = recorder.recordings.last!
        HotkeyManager.shared.onCancel?()
        try await waitUntil { !state.isRecording }
        precondition(state.statusMessage == "Canceled")
        precondition(engine.requests.count == callsBeforeCancel)
        precondition(!FileManager.default.fileExists(atPath: canceledFile.path))

        // Cancel before the queued task starts: its missing-file path must not affect new capture.
        state.startRecording()
        state.stopRecordingAndTranscribe()
        state.cancelDictation()
        state.startRecording()
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(state.isRecording && state.statusMessage == "Listening...")
        state.cancelDictation()

        // Canceled recognition can finish later without inserting or resetting newer work.
        state.autoInsertText = false
        engine.suspend = true
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { engine.pending.count == 1 }
        state.cancelDictation()
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { engine.pending.count == 2 }
        let historyCount = state.history.count
        engine.pending.removeFirst().resume(returning: "Canceled result")
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(state.isProcessing && state.history.count == historyCount)
        precondition(state.lastTranscribedText != "Canceled result")
        engine.pending.removeFirst().resume(returning: "Current result")
        try await waitUntil { !state.isProcessing }
        precondition(state.lastTranscribedText == "Current result")
        engine.suspend = false

        // Cancellation during the paste delay invalidates the insertion guard too.
        state.autoInsertText = true
        let lastTextBeforeCanceledPaste = state.lastTranscribedText
        let historyBeforeCanceledPaste = state.history.count
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        state.cancelDictation()
        state.startRecording()
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await Task.sleep(nanoseconds: 20_000_000)
        precondition(state.isRecording && !state.isProcessing && !state.showSuccess && state.statusMessage == "Listening...")
        precondition(state.lastTranscribedText == lastTextBeforeCanceledPaste && state.history.count == historyBeforeCanceledPaste)
        precondition(FileManager.default.fileExists(atPath: recorder.recordings.last!.path))
        state.cancelDictation()

        // Vocabulary and style are captured per utterance, including unchanged Raw output.
        state.autoInsertText = false
        state.customVocabularyText = "Sample User, Asteria"
        state.transcriptionStyle = .raw
        engine.result = .success("  um, asteria period  ")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        state.transcriptionStyle = .professional
        try await waitUntil { !state.isProcessing }
        precondition(engine.requests.last!.vocabulary == ["Sample User", "Asteria"])
        precondition(engine.requests.last!.style == .raw)
        precondition(state.lastTranscribedText == "  um, asteria period  ")

        // Purge must also remove the copyable last result and pending insertion.
        precondition(!state.history.isEmpty)
        state.clearHistory()
        precondition(state.history.isEmpty && state.lastTranscribedText.isEmpty)
        precondition(!state.hasPendingInsertion && !state.showSuccess)
        let clipboardWritesBeforeCopy = NSPasteboard.general.writes.count
        state.copyLastDictation()
        precondition(NSPasteboard.general.writes.count == clipboardWritesBeforeCopy,
                     "Copy Last Dictation must not recover purged speech")

        state.historyRetention = .clearOnQuit
        engine.result = .success("Before incognito")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(!state.history.isEmpty && state.lastTranscribedText == "Before incognito")
        state.historyRetention = .off
        precondition(state.history.isEmpty && state.lastTranscribedText.isEmpty,
                     "Entering Incognito must clear prior session dictations")
        state.historyRetention = .clearOnQuit

        // A microphone disconnect discards capture and provides actionable feedback.
        state.startRecording()
        let failedFile = recorder.recordings.last!
        AudioRecorder.shared.onRecordingError?(NSError(domain: "Test", code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Microphone disconnected"]), failedFile)
        precondition(!state.isRecording && !state.isProcessing)
        precondition(state.statusMessage == "Microphone disconnected")
        precondition(!FileManager.default.fileExists(atPath: failedFile.path))

        // Accidental Click Guard: Stop immediately (< 0.25s) should quietly discard capture without transcribing
        state.minRecordingDuration = 0.25
        state.startRecording()
        precondition(state.isRecording)
        state.stopRecordingAndTranscribe()
        precondition(!state.isRecording && !state.isProcessing)
        precondition(state.statusMessage == "Ready")
        state.minRecordingDuration = 0

        // Fast mode streams merged manual/remembered vocabulary and still uses
        // the same cleanup/paste pipeline. Release must finish the owned stream.
        state.autoInsertText = false
        state.autoCopyToClipboard = false
        let previousVocabulary = state.customVocabularyText
        state.customVocabularyText = "Lumora, Acmetron"
        state.speechMode = .fast
        await state.refreshEngineStatus()
        try await waitUntil { state.engineStatus.phase == .ready }
        engine.result = .success("lumora has the latest project plan")
        let whisperRequests = engine.requests.count
        state.startRecording()
        let fastSession = engine.streams.last!
        precondition(fastSession.vocabulary.contains("Lumora"))
        recorder.pcmCallback?(Data([1, 0, 2, 0]))
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(fastSession.finished && fastSession.frames.count == 1)
        precondition(engine.requests.count == whisperRequests, "Fast release must not invoke batch Whisper")
        precondition(state.lastTranscribedText.contains("Lumora"))
        state.startRecording()
        let cancelledStream = engine.streams.last!
        state.cancelDictation(showFeedback: false)
        precondition(cancelledStream.cancelled)
        state.minRecordingDuration = 0.25
        state.startRecording()
        let shortStream = engine.streams.last!
        state.stopRecordingAndTranscribe()
        precondition(shortStream.cancelled && !shortStream.finished)
        state.minRecordingDuration = 0
        state.customVocabularyText = previousVocabulary
        state.speechMode = .accuracy
        await state.refreshEngineStatus()
        try await waitUntil { state.engineStatus.phase == .ready }

        // Smart Prefix Spacing tests
        let testTarget = InsertionTarget()
        InsertionTarget.mockPrecedingChar = nil
        let now = Date()
        precondition(AppState.shouldPrependSpace(to: "world", target: testTarget, lastInsertionTime: now, lastInsertionPID: 123, lastInsertedEndsWithWhitespace: false, now: now))
        precondition(!AppState.shouldPrependSpace(to: ", world", target: testTarget, lastInsertionTime: now, lastInsertionPID: 123, lastInsertedEndsWithWhitespace: false, now: now))
        precondition(!AppState.shouldPrependSpace(to: "world", target: testTarget, lastInsertionTime: now, lastInsertionPID: 123, lastInsertedEndsWithWhitespace: true, now: now))
        precondition(!AppState.shouldPrependSpace(to: "world", target: testTarget, lastInsertionTime: now.addingTimeInterval(-60), lastInsertionPID: 123, lastInsertedEndsWithWhitespace: false, now: now))

        // Preceding character via AX
        InsertionTarget.mockPrecedingChar = "x"
        precondition(AppState.shouldPrependSpace(to: "hello", target: testTarget, lastInsertionTime: nil, lastInsertionPID: nil, lastInsertedEndsWithWhitespace: false, now: now))
        InsertionTarget.mockPrecedingChar = " "
        precondition(!AppState.shouldPrependSpace(to: "hello", target: testTarget, lastInsertionTime: nil, lastInsertionPID: nil, lastInsertedEndsWithWhitespace: false, now: now))
        InsertionTarget.mockPrecedingChar = nil

        // Start of text via AX (location == 0) must never prepend space even within 45s window
        InsertionTarget.mockCursorContext = .startOfText
        precondition(!AppState.shouldPrependSpace(to: "hello", target: testTarget, lastInsertionTime: now, lastInsertionPID: 123, lastInsertedEndsWithWhitespace: false, now: now),
                     "Start of text must never prepend space")
        InsertionTarget.mockCursorContext = nil

        precondition(HotkeyManager.shared.resetModifierStatesCount > 0,
                     "Cancellation and error recovery must unstick modifier states")

        // Voice Undo Command detection
        precondition(AppState.isUndoCommand("scratch that"))
        precondition(AppState.isUndoCommand("cancel that."))
        precondition(AppState.isUndoCommand("undo that"))
        precondition(AppState.isUndoCommand("actually scratch that"))
        precondition(!AppState.isUndoCommand("the cat has a scratch that hurts"))

        // Standalone voice undo execution
        let priorUndos = TextInserter.shared.undoCount
        engine.result = .success("scratch that")
        state.startRecording()
        try await Task.sleep(nanoseconds: 260_000_000) // Sleep past click guard
        state.stopRecordingAndTranscribe()
        try await waitUntil { state.statusMessage == "Undone!" }
        precondition(TextInserter.shared.undoCount == priorUndos + 1)
        precondition(state.showSuccess)

        // Rescue audio persistence and recovery test
        let testRescueAudio = FileManager.default.temporaryDirectory
            .appendingPathComponent("rescue-test-\(UUID().uuidString).wav")
        try Data(repeating: 1, count: 2000).write(to: testRescueAudio)
        RescueAudioController.shared.saveRescueAudio(from: testRescueAudio, duration: 3.5)
        precondition(RescueAudioController.shared.hasRescueAudio, "Rescue audio must exist")
        precondition(RescueAudioController.shared.pendingMetadata?.duration == 3.5, "Rescue duration matches")
        precondition(RescueAudioController.shared.pendingMetadata?.status == "pending", "Status is pending")

        engine.result = .success("Rescued speech content")
        state.transcribeRescueAudio()
        try await waitUntil { !state.isProcessing }
        precondition(RescueAudioController.shared.pendingMetadata?.status == "transcribed", "Status marked transcribed")
        precondition(state.lastTranscribedText == "Rescued speech content")
        precondition(NSPasteboard.general.writes.contains("Rescued speech content"))
        let rescueURL = RescueAudioController.shared.rescueAudioURL
        let rescueCopy = engine.audioURLs.last!
        precondition(rescueCopy != rescueURL, "The engine must receive a disposable copy, never the saved recording")
        precondition(!FileManager.default.fileExists(atPath: rescueCopy.path), "The disposable copy must not be left behind")
        precondition(RescueAudioController.shared.hasRescueAudio,
                     "A completed rescue keeps the saved recording, as a normal dictation does")

        // The saved recording must survive a failed attempt so it can be retried.
        engine.result = .failure(NSError(domain: "Test", code: 2, userInfo: [NSLocalizedDescriptionKey: "Engine failure"]))
        state.transcribeRescueAudio()
        try await waitUntil { !state.isProcessing }
        precondition(RescueAudioController.shared.pendingMetadata?.status == "failed", "Failure is recorded")
        precondition(RescueAudioController.shared.hasRescueAudio, "A failed rescue must not delete the saved recording")
        precondition(!FileManager.default.fileExists(atPath: engine.audioURLs.last!.path))

        // Escape during a rescue must not delete it, and a late result is ignored.
        engine.suspend = true
        let writesBeforeCancel = NSPasteboard.general.writes.count
        state.transcribeRescueAudio()
        try await waitUntil { engine.pending.count == 1 }
        state.cancelDictation()
        precondition(RescueAudioController.shared.hasRescueAudio, "Canceling a rescue must not delete the saved recording")
        engine.pending.removeFirst().resume(returning: "Late rescued text")
        let canceledCopy = engine.audioURLs.last!
        try await waitUntil { !FileManager.default.fileExists(atPath: canceledCopy.path) }
        precondition(RescueAudioController.shared.hasRescueAudio, "A late engine result must not delete the saved recording")
        precondition(NSPasteboard.general.writes.count == writesBeforeCancel, "A canceled rescue must not reach the clipboard")
        engine.suspend = false

        // The same recording remains usable for a retry.
        engine.result = .success("Retried rescue")
        state.transcribeRescueAudio()
        try await waitUntil { !state.isProcessing }
        precondition(state.lastTranscribedText == "Retried rescue", "A rescue can be retried after a failure or cancel")
        RescueAudioController.shared.clearRescueAudio()
        try? FileManager.default.removeItem(at: testRescueAudio)

        // Context-aware prompt biasing & continuation test
        InsertionTarget.mockPrecedingText = "We are continuing this sentence and "
        engine.result = .success("reaching the conclusion period")
        state.startRecording()
        try await Task.sleep(nanoseconds: 260_000_000)
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        precondition(engine.requests.last!.context == "We are continuing this sentence and ",
                     "Engine must receive preceding text context")
        precondition(state.lastTranscribedText == "reaching the conclusion.",
                     "Continuation must preserve lowercase first letter")
        InsertionTarget.mockPrecedingText = nil

        // Correction learning needs a verified paste, then an explicit Remember.
        state.correctionLearningEnabled = true
        state.autoInsertText = true
        InsertionTarget.mockCursorContext = .startOfText
        InsertionTarget.mockSnapshot = CorrectionFieldSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        engine.result = .success("Send this to Lumara.")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await waitUntil { !state.isProcessing }
        try await Task.sleep(nanoseconds: 600_000_000)
        InsertionTarget.mockSnapshot = CorrectionFieldSnapshot(text: "Send this to Lumora.", selection: NSRange(location: 20, length: 0))
        try await waitUntil { !state.correctionSuggestions.isEmpty }
        precondition(state.learnedVocabulary.isEmpty, "Suggestions must never save themselves")
        precondition(UserDefaults.standard.object(forKey: "presstowrite_learned_vocabulary") == nil)
        state.rememberCorrection(state.correctionSuggestions[0])
        precondition(state.learnedVocabulary == ["Lumora"] && state.correctionSuggestions.isEmpty)
        precondition(UserDefaults.standard.object(forKey: "presstowrite_learned_vocabulary") as? [String] == ["Lumora"])
        precondition(state.customVocabularyText == "Sample User, Asteria", "Learning must preserve manual vocabulary")

        // Remembered corrections also reach the fast recognizer as real hints.
        state.speechMode = .fast
        await state.refreshEngineStatus()
        try await waitUntil { state.engineStatus.phase == .ready }
        state.startRecording()
        precondition(engine.streams.last!.vocabulary.contains("Lumora"))
        precondition(engine.streams.last!.vocabulary.contains("Asteria"))
        state.cancelDictation(showFeedback: false)
        state.speechMode = .accuracy
        await state.refreshEngineStatus()
        try await waitUntil { state.engineStatus.phase == .ready }

        // Learned terms guide the next utterance; dismissing never reopens the same suggestion.
        InsertionTarget.mockSnapshot = CorrectionFieldSnapshot(text: "", selection: NSRange(location: 0, length: 0))
        engine.result = .success("Call Zephara.")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await waitUntil { !state.isProcessing }
        precondition(engine.requests.last!.vocabulary.contains("Lumora"))
        try await Task.sleep(nanoseconds: 600_000_000)
        InsertionTarget.mockSnapshot = CorrectionFieldSnapshot(text: "Call Zephira.", selection: NSRange(location: 13, length: 0))
        try await waitUntil { !state.correctionSuggestions.isEmpty }
        state.dismissCorrection(state.correctionSuggestions[0])
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(state.correctionSuggestions.isEmpty && state.learnedVocabulary == ["Lumora"])

        let readsBeforeFocusChange = InsertionTarget.snapshotReads
        InsertionTarget.focusChanged?()
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(InsertionTarget.snapshotReads == readsBeforeFocusChange,
                     "A native focus-change notification must stop observation between polls")

        // Incognito cancels observation and performs no further field reads.
        state.historyRetention = .off
        let readsBeforeIncognito = InsertionTarget.snapshotReads
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { TextInserter.shared.pendingCompletion != nil }
        TextInserter.shared.pendingCompletion?()
        TextInserter.shared.pendingCompletion = nil
        try await waitUntil { !state.isProcessing }
        try await Task.sleep(nanoseconds: 600_000_000)
        precondition(InsertionTarget.snapshotReads == readsBeforeIncognito && state.correctionSuggestions.isEmpty)
        state.clearHistory()
        precondition(state.learnedVocabulary == ["Lumora"], "Purging speech must preserve explicitly remembered vocabulary")
        precondition(state.updateLearnedWord("Lumora", to: "LumoTech"))
        precondition(TextCleaner.shared.customVocabulary.contains("LumoTech"))
        precondition(!state.updateLearnedWord("LumoTech", to: "invalid,entry"))
        state.removeLearnedWord("LumoTech")
        precondition(state.learnedVocabulary.isEmpty && !TextCleaner.shared.customVocabulary.contains("LumoTech"))
        precondition(UserDefaults.standard.object(forKey: "presstowrite_learned_vocabulary") as? [String] == [])
        state.correctionLearningEnabled = false
        state.historyRetention = .clearOnQuit
        InsertionTarget.mockSnapshot = nil
        InsertionTarget.mockCursorContext = nil

        // An unresolved layout shortcut must never claim a successful undo.
        TextInserter.shared.undoSucceeds = false
        engine.result = .success("scratch that")
        state.startRecording()
        state.stopRecordingAndTranscribe()
        try await waitUntil { !state.isProcessing }
        // Test auto-adaptive effective style resolution
        state.autoAdaptiveFormatting = true
        let mockTarget = InsertionTarget()
        InsertionTarget.mockCategory = .code
        precondition(state.resolveEffectiveStyle(baseStyle: .professional, target: mockTarget) == .code, "Code target must resolve to .code style")
        InsertionTarget.mockCategory = .chat
        precondition(state.resolveEffectiveStyle(baseStyle: .professional, target: mockTarget) == .natural, "Chat target must resolve to .natural style")
        InsertionTarget.mockCategory = .prose
        precondition(state.resolveEffectiveStyle(baseStyle: .professional, target: mockTarget) == .professional, "Prose target must resolve to base style")

        // Disabled auto-adaptive must preserve base style
        state.autoAdaptiveFormatting = false
        InsertionTarget.mockCategory = .code
        precondition(state.resolveEffectiveStyle(baseStyle: .professional, target: mockTarget) == .professional, "Disabled auto-adaptive must preserve base style")
        state.autoAdaptiveFormatting = true

        print("AppState regressions passed: dictation, clipboard fallback, corrections, remembered vocabulary, native focus changes, Incognito, cancellation, undo failure, and auto-adaptive writing styles.")
    }
}
