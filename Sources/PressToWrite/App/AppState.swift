import Foundation
import SwiftUI
import Combine

public enum PillOrientation: String, CaseIterable, Identifiable, Codable {
    case horizontal
    case vertical

    public var id: String { rawValue }
}

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    // MARK: - Live States
    @Published public var isRecording: Bool = false
    @Published public var isProcessing: Bool = false
    @Published public var showSuccess: Bool = false
    @Published public var currentAudioLevel: Float = 0.0
    @Published public var statusMessage: String = "Ready"
    @Published public var hasPendingInsertion: Bool = false
    @Published public var engineStatus = LocalEngineStatus(phase: .loading, message: "Loading local speech model…")

    // MARK: - Correction Learning
    // Nothing the user says is stored: no recordings, transcripts, or history.
    // Audio and text live in memory only while a single dictation needs them.
    @Published public var correctionLearningEnabled: Bool = false {
        didSet {
            UserDefaults.standard.set(correctionLearningEnabled, forKey: "presstowrite_correction_learning")
            if !correctionLearningEnabled { stopCorrectionLearning() }
        }
    }
    @Published public private(set) var learnedVocabulary: [String] = []
    @Published public private(set) var correctionSuggestions: [VocabularySuggestion] = []
    private let correctionMonitor = CorrectionMonitor()
    private var correctionFocusWatch: CorrectionFocusWatch?
    private var dismissedCorrections = Set<String>()

    // MARK: - Privacy & Clipboard Controls
    @Published public var autoCopyToClipboard: Bool = false {
        didSet {
            UserDefaults.standard.set(autoCopyToClipboard, forKey: "presstowrite_auto_copy")
        }
    }

    @Published public var autoInsertText: Bool = true {
        didSet {
            UserDefaults.standard.set(autoInsertText, forKey: "presstowrite_auto_insert")
        }
    }

    // MARK: - Floating Pill State
    @Published public var pillOrientation: PillOrientation = .horizontal {
        didSet {
            UserDefaults.standard.set(pillOrientation.rawValue, forKey: "presstowrite_pill_orientation")
        }
    }

    // MARK: - Settings
    @Published public var speechMode: SpeechMode = .accuracy {
        didSet {
            UserDefaults.standard.set(speechMode.rawValue, forKey: "presstowrite_speech_mode")
            engineStatus = LocalEngineStatus(phase: .loading, message: "Loading \(speechMode.title)…")
            Task { await self.refreshEngineStatus() }
        }
    }

    @Published public var hotkeyChoice: HotkeyChoice = .fnHold {
        didSet {
            UserDefaults.standard.set(hotkeyChoice.rawValue, forKey: "presstowrite_hotkey")
            HotkeyManager.shared.activeHotkey = hotkeyChoice
        }
    }

    @Published public var dictationMode: DictationMode = .pushToTalk {
        didSet {
            UserDefaults.standard.set(dictationMode.rawValue, forKey: "presstowrite_mode")
            HotkeyManager.shared.activeMode = dictationMode
        }
    }

    @Published public var transcriptionStyle: TranscriptionStyle = .professional {
        didSet {
            UserDefaults.standard.set(transcriptionStyle.rawValue, forKey: "presstowrite_style")
        }
    }

    @Published public var autoAdaptiveFormatting: Bool = true {
        didSet {
            UserDefaults.standard.set(autoAdaptiveFormatting, forKey: "presstowrite_auto_adaptive")
        }
    }

    @Published public var isSoundEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(isSoundEnabled, forKey: "presstowrite_sound")
            SoundEffects.shared.isSoundEnabled = isSoundEnabled
        }
    }

    @Published public var customVocabularyText: String = "" {
        didSet {
            UserDefaults.standard.set(customVocabularyText, forKey: "presstowrite_vocab")
            updateCustomVocabulary()
        }
    }

    @Published public var textReplacementsText: String = "" {
        didSet {
            UserDefaults.standard.set(textReplacementsText, forKey: "presstowrite_replacements")
            updateTextReplacements()
        }
    }

    @Published public var launchAtLogin: Bool = false {
        didSet {
            LaunchAtLogin.isEnabled = launchAtLogin
        }
    }

    /// Recordings shorter than this threshold are discarded quietly as accidental clicks.
    public var minRecordingDuration: Double = 0.25

    private var recordingStartTime: Date?
    private var feedbackResetTask: Task<Void, Never>?
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionID: UUID?
    private var insertionTarget: InsertionTarget?
    private var streamingSession: LocalStreamingSession?
    private var isRefreshingEngine = false
    private var lastInsertionTime: Date?
    private var lastInsertionPID: pid_t?
    private var lastInsertedEndsWithWhitespace: Bool = false
    /// The end of the latest insertion, used as recognition context for a quick
    /// follow-up dictation. Memory only; forgotten when the window closes.
    private var recentInsertionContext: String?
    private var contextExpiryTask: Task<Void, Never>?
    var continuationContextLifetime: TimeInterval = 45

    private init() {
        loadSettings()
        setupAudioLevelCallback()
        setupHotkeys()
    }

    private func loadSettings() {
        PreferenceMigration.migrate()
        if let saved = UserDefaults.standard.string(forKey: "presstowrite_speech_mode"),
           let mode = SpeechMode(rawValue: saved) {
            speechMode = mode
        }
        if UserDefaults.standard.object(forKey: "presstowrite_auto_copy") != nil {
            self.autoCopyToClipboard = UserDefaults.standard.bool(forKey: "presstowrite_auto_copy")
        } else {
            self.autoCopyToClipboard = false // Default to false for privacy
        }

        if UserDefaults.standard.object(forKey: "presstowrite_auto_insert") != nil {
            self.autoInsertText = UserDefaults.standard.bool(forKey: "presstowrite_auto_insert")
        } else {
            self.autoInsertText = true
        }

        if let rawOrientation = UserDefaults.standard.string(forKey: "presstowrite_pill_orientation"),
           let orientation = PillOrientation(rawValue: rawOrientation) {
            self.pillOrientation = orientation
        }

        if let rawHotkey = UserDefaults.standard.string(forKey: "presstowrite_hotkey"),
           let hotkey = HotkeyChoice(rawValue: rawHotkey) {
            self.hotkeyChoice = hotkey
        }

        if let rawMode = UserDefaults.standard.string(forKey: "presstowrite_mode"),
           let mode = DictationMode(rawValue: rawMode) {
            self.dictationMode = mode
        }

        if let rawStyle = UserDefaults.standard.string(forKey: "presstowrite_style"),
           let style = TranscriptionStyle(rawValue: rawStyle) {
            self.transcriptionStyle = style
        } else {
            self.transcriptionStyle = .professional
        }

        if UserDefaults.standard.object(forKey: "presstowrite_auto_adaptive") != nil {
            self.autoAdaptiveFormatting = UserDefaults.standard.bool(forKey: "presstowrite_auto_adaptive")
        } else {
            self.autoAdaptiveFormatting = true
        }

        if UserDefaults.standard.object(forKey: "presstowrite_sound") != nil {
            self.isSoundEnabled = UserDefaults.standard.bool(forKey: "presstowrite_sound")
        }

        self.launchAtLogin = LaunchAtLogin.isEnabled
        self.customVocabularyText = UserDefaults.standard.string(forKey: "presstowrite_vocab") ?? ""
        self.textReplacementsText = UserDefaults.standard.string(forKey: "presstowrite_replacements") ?? ""
        self.correctionLearningEnabled = UserDefaults.standard.bool(forKey: "presstowrite_correction_learning")
        let savedWords = UserDefaults.standard.object(forKey: "presstowrite_learned_vocabulary") as? [String] ?? []
        var seenWords = Set<String>()
        self.learnedVocabulary = savedWords.compactMap(Self.validLearnedWord)
            .filter { seenWords.insert($0.lowercased()).inserted }.prefix(256).map { $0 }

        updateCustomVocabulary()
        updateTextReplacements()
    }

    private func setupAudioLevelCallback() {
        AudioRecorder.shared.onAudioLevel = { [weak self] level in
            guard let self = self, self.isRecording else { return }
            self.currentAudioLevel = level
        }
        AudioRecorder.shared.onRecordingError = { [weak self] error in
            guard let self = self else { return }
            // The recorder already discarded the partial audio; nothing is kept.
            self.cancelDictation(showFeedback: false)
            HotkeyManager.shared.resetModifierStates()
            self.statusMessage = error.localizedDescription
            SoundEffects.shared.playError()
        }
    }

    private func setupHotkeys() {
        HotkeyManager.shared.activeHotkey = hotkeyChoice
        HotkeyManager.shared.activeMode = dictationMode

        HotkeyManager.shared.onHotkeyDown = { [weak self] in
            Task { @MainActor in
                self?.startRecording()
            }
        }

        HotkeyManager.shared.onHotkeyUp = { [weak self] in
            Task { @MainActor in
                self?.stopRecordingAndTranscribe()
            }
        }

        HotkeyManager.shared.onToggle = { [weak self] in
            Task { @MainActor in
                self?.toggleRecording()
            }
        }
        HotkeyManager.shared.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelDictation()
            }
        }
    }

    private func updateCustomVocabulary() {
        let terms = customVocabularyText
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        TextCleaner.shared.customVocabulary = (terms + learnedVocabulary)
            .filter { seen.insert($0.lowercased()).inserted }
    }

    public func stopCorrectionLearning() {
        correctionFocusWatch = nil
        correctionMonitor.stop()
        correctionSuggestions.removeAll()
        dismissedCorrections.removeAll()
    }

    private func beginCorrectionLearning(capture: CorrectionCapture, target: InsertionTarget) {
        guard correctionLearningEnabled else { return }
        correctionFocusWatch = target.watchCorrectionFocus { [weak self] in
            Task { @MainActor in self?.stopCorrectionLearning() }
        }
        correctionMonitor.start(
            capture: capture, knownWords: TextCleaner.shared.customVocabulary,
            read: { target.correctionSnapshot() },
            onSuggestions: { [weak self] suggestions in
                guard let self, self.correctionLearningEnabled else { return }
                let known = Set(TextCleaner.shared.customVocabulary.map { $0.lowercased() })
                self.correctionSuggestions = suggestions.filter {
                    !self.dismissedCorrections.contains($0.id) && !known.contains($0.word.lowercased())
                }
            },
            onInvalidated: { [weak self] in self?.stopCorrectionLearning() }
        )
    }

    public func dismissCorrection(_ suggestion: VocabularySuggestion) {
        dismissedCorrections.insert(suggestion.id)
        correctionSuggestions.removeAll { $0.id == suggestion.id }
    }

    public func rememberCorrection(_ suggestion: VocabularySuggestion) {
        guard correctionLearningEnabled,
              correctionSuggestions.contains(suggestion), let word = Self.validLearnedWord(suggestion.word),
              learnedVocabulary.count < 256 else { return }
        if !TextCleaner.shared.customVocabulary.contains(where: { $0.caseInsensitiveCompare(word) == .orderedSame }) {
            learnedVocabulary.append(word)
            saveLearnedVocabulary()
        }
        dismissCorrection(suggestion)
    }

    @discardableResult
    public func updateLearnedWord(_ oldWord: String, to replacement: String) -> Bool {
        guard let index = learnedVocabulary.firstIndex(of: oldWord),
              let word = Self.validLearnedWord(replacement),
              !learnedVocabulary.enumerated().contains(where: {
                  $0.offset != index && $0.element.caseInsensitiveCompare(word) == .orderedSame
              }),
              !TextCleaner.shared.customVocabulary.contains(where: {
                  $0.caseInsensitiveCompare(oldWord) != .orderedSame && $0.caseInsensitiveCompare(word) == .orderedSame
              }) else { return false }
        learnedVocabulary[index] = word
        saveLearnedVocabulary()
        return true
    }

    public func removeLearnedWord(_ word: String) {
        learnedVocabulary.removeAll { $0 == word }
        saveLearnedVocabulary()
    }

    public func clearLearnedVocabulary() {
        learnedVocabulary.removeAll()
        saveLearnedVocabulary()
    }

    private static func validLearnedWord(_ value: String) -> String? {
        let word = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-'’ "))
        guard !word.isEmpty, word.count <= 64, word.unicodeScalars.allSatisfy(allowed.contains),
              word.unicodeScalars.contains(where: CharacterSet.letters.contains) else { return nil }
        return word
    }

    private func saveLearnedVocabulary() {
        UserDefaults.standard.set(learnedVocabulary, forKey: "presstowrite_learned_vocabulary")
        updateCustomVocabulary()
    }

    private func updateTextReplacements() {
        TextCleaner.shared.customReplacements = TextCleaner.parseReplacements(from: textReplacementsText)
    }

    public func resolveEffectiveStyle(baseStyle: TranscriptionStyle, target: InsertionTarget?) -> TranscriptionStyle {
        guard autoAdaptiveFormatting, let target else { return baseStyle }
        switch target.applicationCategory {
        case .code:
            return .code
        case .chat:
            return .natural
        case .prose:
            return baseStyle
        }
    }

    public static func isUndoCommand(_ text: String) -> Bool {
        return TextCleaner.isStandaloneUndoCommand(text)
    }

    public static func shouldPrependSpace(
        to newText: String,
        target: InsertionTarget?,
        lastInsertionTime: Date?,
        lastInsertionPID: pid_t?,
        lastInsertedEndsWithWhitespace: Bool,
        now: Date = Date()
    ) -> Bool {
        let trimmed = newText.trimmingCharacters(in: .whitespaces)
        guard let firstChar = trimmed.first else { return false }

        // Never prepend a space before punctuation, quotes, brackets, or newlines
        let noLeadingSpaceCharacters = CharacterSet(charactersIn: ".,!?;:)]}'\"”\n•-")
        if let scalar = firstChar.unicodeScalars.first, noLeadingSpaceCharacters.contains(scalar) {
            return false
        }

        // 1. If AX can inspect the cursor context in the focused control:
        if let target {
            switch target.cursorContext() {
            case .startOfText:
                // Cursor is at the beginning of the text field (location == 0). Never prepend space.
                return false
            case .character(let preceding):
                let whitespaceOrOpening = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "([{“\"'\n\t"))
                if let scalar = preceding.unicodeScalars.first, whitespaceOrOpening.contains(scalar) {
                    return false
                }
                return true
            case .unavailable:
                break
            }
        }

        // 2. Fallback: Consecutive dictation in the same app within 45 seconds
        if let lastTime = lastInsertionTime,
           let lastPID = lastInsertionPID,
           let currentPID = target?.targetPID,
           lastPID == currentPID,
           now.timeIntervalSince(lastTime) < 45.0,
           !lastInsertedEndsWithWhitespace {
            return true
        }

        return false
    }

    // MARK: - Actions

    public func refreshEngineStatus() async {
        guard !isRefreshingEngine else { return }
        isRefreshingEngine = true
        defer { isRefreshingEngine = false }
        let previous = engineStatus
        let mode = speechMode
        let status = await LocalDaemonClient.shared.engineStatus(mode: mode)
        // A late poll from the old mode must not label the selected mode Ready.
        guard mode == speechMode else {
            isRefreshingEngine = false
            Task { await self.refreshEngineStatus() }
            return
        }
        // Assigning a @Published property always notifies observers, even with an
        // equal value, so skip no-op writes from this periodic poll.
        if engineStatus != status { engineStatus = status }
        if !isRecording, !isProcessing, !showSuccess,
           statusMessage == previous.message, statusMessage != "Ready" {
            statusMessage = "Ready"
        }
    }

    public func toggleRecording() {
        if isRecording {
            stopRecordingAndTranscribe()
        } else {
            startRecording()
        }
    }

    public func startRecording() {
        guard !isRecording, !isProcessing else { return }
        stopCorrectionLearning()
        clearFeedback()
        guard engineStatus.phase == .ready else {
            statusMessage = engineStatus.message
            HotkeyManager.shared.resetModifierStates()
            return
        }

        do {
            let captureStartedAt = ProcessInfo.processInfo.systemUptime
            let target = InsertionTarget.capture()
            NSLog("[Press To Write Timing] capture_focus=%.3fs", ProcessInfo.processInfo.systemUptime - captureStartedAt)
            let audioStartedAt = ProcessInfo.processInfo.systemUptime
            let session = speechMode == .fast
                ? LocalDaemonClient.shared.startStreaming(vocabulary: TextCleaner.shared.customVocabulary) : nil
            streamingSession = session
            // Fast mode consumes every frame as it streams, so the recorder keeps none.
            try AudioRecorder.shared.startRecording(retainPCM: session == nil, onPCM16: session.map { session in
                { pcm in session.appendPCM16(pcm) }
            })
            NSLog("[Press To Write Timing] start_audio=%.3fs", ProcessInfo.processInfo.systemUptime - audioStartedAt)
            self.insertionTarget = target
            self.isRecording = true
            self.recordingStartTime = Date()
            self.statusMessage = "Listening..."
            SoundEffects.shared.playStart()
        } catch {
            NSLog("[Press To Write] Failed to start audio recording: \(error)")
            streamingSession?.cancel()
            streamingSession = nil
            self.statusMessage = error.localizedDescription
            HotkeyManager.shared.resetModifierStates()
            SoundEffects.shared.playError()
            self.scheduleFeedbackReset(after: 3_000_000_000)
        }
    }

    public func stopRecordingAndTranscribe() {
        guard isRecording else { return }
        let pipelineStartedAt = ProcessInfo.processInfo.systemUptime
        let duration = Date().timeIntervalSince(recordingStartTime ?? Date())

        // Accidental Click Guard: Silently discard clicks shorter than minRecordingDuration (default 0.25s)
        if minRecordingDuration > 0 && duration < minRecordingDuration {
            _ = AudioRecorder.shared.stopRecording()
            streamingSession?.cancel()
            streamingSession = nil
            recordingStartTime = nil
            insertionTarget = nil
            self.isRecording = false
            self.isProcessing = false
            self.currentAudioLevel = 0.0
            HotkeyManager.shared.resetModifierStates()
            clearFeedback()
            self.statusMessage = "Ready"
            return
        }

        clearFeedback()
        self.isRecording = false
        self.isProcessing = true
        self.statusMessage = "Transcribing..."
        self.currentAudioLevel = 0.0
        SoundEffects.shared.playStop()

        // This dictation's task owns the only copy of the audio and releases it when done.
        let pcm = AudioRecorder.shared.stopRecording() ?? Data()
        NSLog("[Press To Write Timing] stop_audio=%.3fs", ProcessInfo.processInfo.systemUptime - pipelineStartedAt)
        let session = streamingSession
        streamingSession = nil
        let target = insertionTarget
        let vocabulary = TextCleaner.shared.customVocabulary
        let replacements = TextCleaner.shared.customReplacements
        let effectiveStyle = resolveEffectiveStyle(baseStyle: transcriptionStyle, target: target)
        let isChat = target?.applicationCategory == .chat
        var contextText = target?.precedingText()
        if contextText == nil || contextText?.isEmpty == true {
            if let lastTime = self.lastInsertionTime,
               let lastPID = self.lastInsertionPID,
               let currentPID = target?.targetPID,
               lastPID == currentPID,
               Date().timeIntervalSince(lastTime) < 45.0,
               let recentContext = self.recentInsertionContext {
                contextText = recentContext
            }
        }
        let requestID = UUID()
        transcriptionID = requestID
        recordingStartTime = nil
        insertionTarget = nil

        transcriptionTask = Task {
            defer {
                session?.cancel()
                NSLog("[Press To Write Timing] release_to_completion=%.3fs cancelled=%d", ProcessInfo.processInfo.systemUptime - pipelineStartedAt, Task.isCancelled ? 1 : 0)
                if self.transcriptionID == requestID {
                    self.isProcessing = false
                    self.transcriptionID = nil
                    self.transcriptionTask = nil
                }
            }

            guard self.transcriptionID == requestID, !Task.isCancelled else { return }
            if session == nil && pcm.isEmpty {
                self.statusMessage = "No Audio"
                self.scheduleFeedbackReset(after: 1_200_000_000)
                return
            }

            do {
                let recognitionStartedAt = ProcessInfo.processInfo.systemUptime
                let rawText: String
                if let session {
                    rawText = try await session.finish()
                } else {
                    rawText = try await LocalDaemonClient.shared.transcribe(pcm16: pcm, vocabulary: vocabulary, style: effectiveStyle, context: contextText)
                }
                NSLog("[Press To Write Timing] recognition=%.3fs", ProcessInfo.processInfo.systemUptime - recognitionStartedAt)
                try Task.checkCancellation()
                guard self.transcriptionID == requestID else { return }
                let cleanupStartedAt = ProcessInfo.processInfo.systemUptime
                let isContinuation: Bool
                if let ctx = contextText?.trimmingCharacters(in: .whitespacesAndNewlines), !ctx.isEmpty {
                    isContinuation = !".!?\n".contains(ctx.last!)
                } else {
                    isContinuation = false
                }
                let cleanedText = TextCleaner.shared.clean(
                    text: rawText,
                    style: effectiveStyle,
                    vocabulary: vocabulary,
                    replacements: replacements,
                    isContinuation: isContinuation,
                    isChat: isChat
                )
                NSLog("[Press To Write Timing] text_cleanup=%.3fs", ProcessInfo.processInfo.systemUptime - cleanupStartedAt)

                // Standalone Voice Undo: "scratch that", "cancel that", "undo that"
                if Self.isUndoCommand(cleanedText) {
                    let undone = HotkeyManager.isAccessibilityGranted() && target?.isCurrent == true
                        && TextInserter.shared.sendUndoKeystroke()
                    self.statusMessage = undone ? "Undone!" : "Undo unavailable: use Edit -> Undo"
                    self.showSuccess = undone
                    if undone { SoundEffects.shared.playSuccess() } else { SoundEffects.shared.playError() }
                    self.scheduleFeedbackReset(after: 1_800_000_000)
                    return
                }

                if !cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    var needsManualInsertion = false

                    // Smart Prefix Spacing: prepend space if following a prior insertion in same target
                    var textToInsert = cleanedText
                    let effectiveTarget = target ?? InsertionTarget.capture()
                    if self.autoInsertText && Self.shouldPrependSpace(
                        to: textToInsert,
                        target: effectiveTarget,
                        lastInsertionTime: self.lastInsertionTime,
                        lastInsertionPID: self.lastInsertionPID,
                        lastInsertedEndsWithWhitespace: self.lastInsertedEndsWithWhitespace
                    ) {
                        textToInsert = " " + textToInsert
                    }

                    if self.autoInsertText {
                        let hasAccessibility = HotkeyManager.isAccessibilityGranted()
                        if hasAccessibility {
                            let capture = self.correctionLearningEnabled
                                ? effectiveTarget?.correctionSnapshot().flatMap {
                                    CorrectionCapture(before: $0, insertedText: textToInsert)
                                } : nil
                            let inserted: Bool = await withCheckedContinuation { continuation in
                                TextInserter.shared.insertText(textToInsert, keepOnClipboard: self.autoCopyToClipboard, target: effectiveTarget, shouldInsert: { [weak self] in
                                    self?.transcriptionID == requestID
                                }) { inserted in
                                    continuation.resume(returning: inserted)
                                }
                            }
                            try Task.checkCancellation()
                            guard self.transcriptionID == requestID else { return }
                            if inserted {
                                self.statusMessage = self.autoCopyToClipboard ? "Inserted & Copied!" : "Inserted!"
                                self.lastInsertionTime = Date()
                                self.lastInsertionPID = effectiveTarget?.targetPID
                                self.lastInsertedEndsWithWhitespace = textToInsert.hasSuffix(" ") || textToInsert.hasSuffix("\n")
                                self.rememberInsertionContext(cleanedText)
                                if let capture, let effectiveTarget {
                                    self.beginCorrectionLearning(capture: capture, target: effectiveTarget)
                                }
                            } else {
                                // Always place speech on clipboard if auto-insertion could not complete
                                TextInserter.shared.copyForManualPaste(cleanedText, keepInHistory: self.autoCopyToClipboard)
                                needsManualInsertion = true
                                self.statusMessage = "Text ready: copied for manual paste"
                            }
                        } else {
                            HotkeyManager.requestAccessibilityPermission()
                            TextInserter.shared.copyForManualPaste(cleanedText, keepInHistory: self.autoCopyToClipboard)
                            self.statusMessage = "Copied! (Grant Accessibility to auto-insert)"
                        }
                    } else {
                        // Nothing is kept for later, so without insertion the
                        // clipboard is where this dictation's text is delivered.
                        TextInserter.shared.copyForManualPaste(cleanedText, keepInHistory: self.autoCopyToClipboard)
                        self.statusMessage = "Copied to Clipboard!"
                    }

                    self.hasPendingInsertion = needsManualInsertion
                    // Visual and audio feedback
                    self.showSuccess = !self.hasPendingInsertion
                    if !self.hasPendingInsertion {
                        SoundEffects.shared.playSuccess()
                    } else {
                        SoundEffects.shared.playError()
                    }

                    if !self.hasPendingInsertion {
                        self.scheduleFeedbackReset(after: 2_200_000_000)
                    } else {
                        self.scheduleFeedbackReset(after: 3_500_000_000)
                    }
                } else {
                    self.statusMessage = "No Speech Detected"
                    self.scheduleFeedbackReset(after: 1_200_000_000)
                }
            } catch is CancellationError {
                // A canceled request must never insert text or overwrite a newer recording.
            } catch {
                guard self.transcriptionID == requestID, !Task.isCancelled else { return }
                NSLog("[Press To Write] Transcription error: \(error)")
                let msg = error.localizedDescription
                self.statusMessage = msg.count > 40 ? String(msg.prefix(37)) + "..." : msg
                SoundEffects.shared.playError()
                self.scheduleFeedbackReset(after: 3_000_000_000)
            }
        }
    }

    public func cancelDictation(showFeedback: Bool = true) {
        stopCorrectionLearning()
        guard isRecording || isProcessing else { return }
        clearFeedback()
        // Stopping discards the captured audio; a canceled task releases its copy.
        if isRecording { _ = AudioRecorder.shared.stopRecording() }
        streamingSession?.cancel()
        streamingSession = nil
        transcriptionID = nil
        transcriptionTask?.cancel()
        transcriptionTask = nil
        insertionTarget = nil
        recordingStartTime = nil
        isRecording = false
        isProcessing = false
        currentAudioLevel = 0
        HotkeyManager.shared.resetModifierStates()
        if showFeedback {
            statusMessage = "Canceled"
            scheduleFeedbackReset(after: 1_200_000_000)
        }
    }

    private func clearFeedback() {
        feedbackResetTask?.cancel()
        feedbackResetTask = nil
        showSuccess = false
    }

    private func scheduleFeedbackReset(after nanoseconds: UInt64) {
        feedbackResetTask?.cancel()
        feedbackResetTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                return
            }
            guard let self = self, !self.isRecording, !self.isProcessing else { return }
            self.showSuccess = false
            self.statusMessage = "Ready"
            self.feedbackResetTask = nil
        }
    }

    /// Keeps the end of the latest insertion in memory for the continuation
    /// window only, then forgets it. It is never shown, logged, or saved.
    private func rememberInsertionContext(_ text: String) {
        recentInsertionContext = String(text.suffix(200))
        contextExpiryTask?.cancel()
        let lifetime = UInt64(max(0, continuationContextLifetime) * 1_000_000_000)
        contextExpiryTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: lifetime)
            } catch {
                return
            }
            // A newer insertion may have replaced this timer after its sleep ended.
            guard !Task.isCancelled else { return }
            self?.recentInsertionContext = nil
            self?.contextExpiryTask = nil
        }
    }
}
