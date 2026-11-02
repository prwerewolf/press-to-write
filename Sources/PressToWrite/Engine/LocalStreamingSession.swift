import Foundation
import Darwin

/// One recording owns one connection. Capture only copies into this bounded
/// buffer; socket writes and inference never run on the audio tap or main thread.
public final class LocalStreamingSession: @unchecked Sendable {
    private let client: LocalDaemonClient
    private let requestID = UUID().uuidString
    private let condition = NSCondition()
    private let inFlight = InFlightTranscription()
    private let connect: () throws -> Int32
    private let cancelRequest: (String) -> Void
    private var pending: [Data] = []
    private var pendingBytes = 0
    private var finishing = false
    private var cancelled = false
    private var failure: Error?
    private var result: Result<String, Error>?
    private var continuation: CheckedContinuation<String, Error>?
    private let maxBufferedBytes = 160000 // five seconds, including an in-flight frame

    init(client: LocalDaemonClient, vocabulary: [String],
         connect: (() throws -> Int32)? = nil, cancelRequest: ((String) -> Void)? = nil) {
        self.client = client
        self.connect = connect ?? { try client.connectedSocket(timeout: 30) }
        self.cancelRequest = cancelRequest ?? { client.cancelStreaming(requestID: $0) }
        DispatchQueue.global(qos: .userInitiated).async { self.run(vocabulary: vocabulary) }
    }

    public func appendPCM16(_ pcm: Data) {
        guard !pcm.isEmpty else { return }
        condition.lock()
        guard !finishing, !cancelled, failure == nil, result == nil else {
            condition.unlock()
            return
        }
        if pcm.count % 2 != 0 || pcm.count > 32000 || pendingBytes + pcm.count > maxBufferedBytes {
            failure = client.engineError("Fast mode could not keep up with audio. Please dictate again.")
            condition.broadcast()
            condition.unlock()
            inFlight.cancel()
            cancelRequest(requestID)
            return
        }
        pending.append(pcm)
        pendingBytes += pcm.count
        condition.signal()
        condition.unlock()
    }

    /// Call after capture stops, so every accepted PCM frame precedes the finish
    /// marker and the recognizer can flush the final words.
    public func finish() async throws -> String {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { next in
                condition.lock()
                if let result {
                    condition.unlock()
                    next.resume(with: result)
                } else if continuation != nil {
                    condition.unlock()
                    next.resume(throwing: client.engineError("This dictation is already finishing."))
                } else {
                    continuation = next
                    finishing = true
                    condition.broadcast()
                    condition.unlock()
                }
            }
        } onCancel: { self.cancel() }
    }

    public func cancel() {
        condition.lock()
        guard !cancelled, result == nil else { condition.unlock(); return }
        cancelled = true
        pending.removeAll()
        pendingBytes = 0
        condition.broadcast()
        condition.unlock()
        inFlight.cancel()
        cancelRequest(requestID)
    }

    private func checkState() throws {
        condition.lock()
        defer { condition.unlock() }
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
    }

    private func validated(_ response: [String: Any]) throws {
        guard response["protocol_version"] as? Int == client.protocolVersion else {
            throw client.engineError("Restart Press To Write to update the local speech connection.")
        }
        if let error = response["error"] as? String { throw client.engineError(error) }
    }

    private func run(vocabulary: [String]) {
        do {
            try checkState()
            let fd = try connect()
            defer { inFlight.clear(fd); close(fd) }
            try inFlight.register(fd)
            try client.sendJSON([
                "action": "stream", "protocol_version": client.protocolVersion,
                "request_id": requestID, "vocabulary": vocabulary,
            ], to: fd)
            try validated(client.readJSON(from: fd))
            while true {
                condition.lock()
                while pending.isEmpty, !finishing, !cancelled, failure == nil { condition.wait() }
                if cancelled || failure != nil {
                    condition.unlock()
                    try checkState()
                }
                let pcm = pending.isEmpty ? nil : pending.removeFirst()
                let shouldFinish = pcm == nil && finishing
                condition.unlock()
                if let pcm {
                    var size = UInt32(pcm.count).littleEndian
                    var frame = withUnsafeBytes(of: &size) { Data($0) }
                    frame.append(pcm)
                    try client.sendData(frame, to: fd)
                    condition.lock()
                    pendingBytes = max(0, pendingBytes - pcm.count)
                    condition.unlock()
                } else if shouldFinish {
                    try client.sendData(Data(repeating: 0, count: 4), to: fd)
                    let response = try client.readJSON(from: fd)
                    try validated(response)
                    guard let text = response["text"] as? String else {
                        throw client.engineError("The local fast engine returned no text.")
                    }
                    try checkState()
                    complete(.success(text))
                    return
                }
            }
        } catch {
            condition.lock()
            let finalError: Error = cancelled ? CancellationError() : (failure ?? error)
            condition.unlock()
            complete(.failure(finalError))
        }
    }

    private func complete(_ outcome: Result<String, Error>) {
        condition.lock()
        result = outcome
        pending.removeAll()
        pendingBytes = 0
        let next = continuation
        continuation = nil
        condition.unlock()
        next?.resume(with: outcome)
    }
}
