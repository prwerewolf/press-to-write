import SwiftUI
import AppKit

struct CorrectionLearningSettings: View {
    @ObservedObject var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Suggest spelling corrections", isOn: $appState.correctionLearningEnabled)
            Text("After you fix dictated text, choose Remember to save its spelling on this Mac. Learning stops when you leave the field. Only words you remember are saved, never what you said.")
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.8))

            HStack {
                Text("Learned Vocabulary").fontWeight(.medium)
                Spacer()
                if !appState.learnedVocabulary.isEmpty {
                    Button("Clear Learned Words", role: .destructive) { appState.clearLearnedVocabulary() }
                        .controlSize(.small)
                }
            }
            .padding(.top, 4)
            if appState.learnedVocabulary.isEmpty {
                Text("No learned words yet. Enable suggestions, dictate, then correct a spelling in the same field.")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.8))
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(appState.learnedVocabulary, id: \.self) { word in
                            LearnedWordEditor(word: word, appState: appState)
                        }
                    }
                }
                .frame(height: min(160, CGFloat(appState.learnedVocabulary.count) * 38 + 24))
                Text("\(appState.learnedVocabulary.count) of 256 words saved locally. Only spellings you remember are saved.")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.8))
            }
        }
    }
}

private struct LearnedWordEditor: View {
    let word: String
    @ObservedObject var appState: AppState
    @State private var value: String
    @State private var error: String?

    init(word: String, appState: AppState) {
        self.word = word
        self.appState = appState
        _value = State(initialValue: word)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                TextField("Learned spelling", text: $value)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                    .accessibilityLabel("Learned spelling: \(word)")
                Button(action: save) { Image(systemName: "checkmark") }
                    .disabled(value == word)
                    .help("Save spelling")
                    .accessibilityLabel("Save spelling")
                Button(role: .destructive) { appState.removeLearnedWord(word) } label: {
                    Image(systemName: "trash")
                }
                .help("Forget this spelling")
                .accessibilityLabel("Forget \(word)")
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }

    private func save() {
        guard value != word else { return }
        if appState.updateLearnedWord(word, to: value) { error = nil }
        else { error = "Enter a unique word or phrase, up to 64 characters." }
    }
}

struct CorrectionSuggestionView: View {
    let suggestion: VocabularySuggestion
    let canRemember: Bool
    let remember: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Remember this spelling?").font(.headline)
            HStack(alignment: .top, spacing: 10) {
                Text(verbatim: suggestion.original).foregroundStyle(Color.primary.opacity(0.8))
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                Text(verbatim: suggestion.word).fontWeight(.semibold)
            }
            .lineLimit(2)
            .truncationMode(.middle)
            Text(canRemember ? "Saved words guide future dictations on this Mac." : "Vocabulary is full. Remove a word in Writing settings.")
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.8))
            HStack {
                Spacer()
                Button("Dismiss", action: dismiss)
                Button("Remember", action: remember)
                    .buttonStyle(.bordered)
                    .disabled(!canRemember)
            }
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 352, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Appears without activating the app or taking the user's text cursor.
final class CorrectionSuggestionPanel: NSPanel {
    init(suggestion: VocabularySuggestion) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 352, height: 160),
                   styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        update(suggestion)
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    func update(_ suggestion: VocabularySuggestion) {
        let hosting = NSHostingView(rootView: CorrectionSuggestionView(
            suggestion: suggestion, canRemember: AppState.shared.learnedVocabulary.count < 256,
            remember: { AppState.shared.rememberCorrection(suggestion) },
            dismiss: { AppState.shared.dismissCorrection(suggestion) }
        ))
        contentView = hosting
        setContentSize(hosting.fittingSize)
    }

    func show(near frame: NSRect) {
        let screen = NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let x = min(max(visible.minX + 8, frame.midX - self.frame.width / 2), visible.maxX - self.frame.width - 8)
        let above = frame.maxY + 8
        let y = above + self.frame.height <= visible.maxY ? above : frame.minY - self.frame.height - 8
        setFrameOrigin(NSPoint(x: x, y: min(max(visible.minY + 8, y), visible.maxY - self.frame.height - 8)))
        orderFront(nil)
    }
}
