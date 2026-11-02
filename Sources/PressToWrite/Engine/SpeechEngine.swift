import Foundation

public enum SpeechMode: String, CaseIterable, Identifiable, Sendable {
    case accuracy
    case fast

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .accuracy: return "Accuracy — Whisper"
        case .fast: return "Fast — Nemotron English"
        }
    }
}

public struct LocalEngineStatus: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        case loading
        case ready
        case unavailable
    }

    public let phase: Phase
    public let message: String
    public let model: String?

    public init(phase: Phase = .loading, message: String = "Loading the local speech model…", model: String? = nil) {
        self.phase = phase
        self.message = message
        self.model = model
    }
}

/// Audio is 16 kHz mono PCM16 held in memory. It is never written to disk.
public protocol SpeechEngineProtocol {
    func transcribe(pcm16: Data, vocabulary: [String], style: TranscriptionStyle, context: String?) async throws -> String
}

public extension SpeechEngineProtocol {
    func transcribe(pcm16: Data, vocabulary: [String], style: TranscriptionStyle) async throws -> String {
        try await transcribe(pcm16: pcm16, vocabulary: vocabulary, style: style, context: nil)
    }
}
