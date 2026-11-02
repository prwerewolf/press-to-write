import Foundation
import Darwin

@main
struct StreamingSessionTests {
    static func pair() -> [Int32] {
        var fds: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        for fd in fds {
            var value: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, socklen_t(MemoryLayout<Int32>.size))
            var timeout = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        }
        return fds
    }

    static func receive(_ fd: Int32, count: Int) -> Data {
        var output = Data()
        while output.count < count {
            var buffer = [UInt8](repeating: 0, count: count - output.count)
            let received = read(fd, &buffer, buffer.count)
            precondition(received > 0)
            output.append(buffer, count: received)
        }
        return output
    }

    static func main() async throws {
        let client = LocalDaemonClient.shared
        let sockets = pair()
        let peer = Task.detached {
            defer { close(sockets[1]) }
            let begin = try client.readJSON(from: sockets[1])
            precondition(begin["action"] as? String == "stream")
            precondition(begin["protocol_version"] as? Int == client.protocolVersion)
            precondition(begin["vocabulary"] as? [String] == ["Lumora", "Acmetron"])
            try client.sendJSON(["protocol_version": client.protocolVersion, "vocabulary_count": 2], to: sockets[1])
            var frames: [Data] = []
            while true {
                let header = receive(sockets[1], count: 4)
                let count = header.enumerated().reduce(0) { $0 | (Int($1.element) << ($1.offset * 8)) }
                if count == 0 { break }
                frames.append(receive(sockets[1], count: count))
            }
            precondition(frames == [Data([1, 0, 2, 0]), Data([3, 0])], "The short final buffer must arrive before finish")
            try client.sendJSON(["protocol_version": client.protocolVersion, "text": "Lumora finishes the final word"], to: sockets[1])
        }
        let session = LocalStreamingSession(client: client, vocabulary: ["Lumora", "Acmetron"],
                                            connect: { sockets[0] }, cancelRequest: { _ in })
        session.appendPCM16(Data([1, 0, 2, 0]))
        session.appendPCM16(Data([3, 0]))
        let result = try await session.finish()
        precondition(result == "Lumora finishes the final word")
        try await peer.value

        // Cancel before connect/handshake: finishing must throw, never return text.
        let canceledSockets = pair()
        let canceled = LocalStreamingSession(client: client, vocabulary: [],
                                             connect: { canceledSockets[0] }, cancelRequest: { _ in })
        canceled.cancel()
        do {
            _ = try await canceled.finish()
            preconditionFailure("Canceled audio must never produce a transcript")
        } catch is CancellationError {}
        close(canceledSockets[1])

        // A stalled local worker cannot grow the capture queue without bound.
        let stalledSockets = pair()
        let stalled = LocalStreamingSession(client: client, vocabulary: [],
                                            connect: { stalledSockets[0] }, cancelRequest: { _ in })
        for _ in 0..<6 { stalled.appendPCM16(Data(repeating: 0, count: 32000)) }
        do {
            _ = try await stalled.finish()
            preconditionFailure("A buffer overrun must fail instead of returning partial text")
        } catch {
            precondition(error.localizedDescription.contains("dictate again"))
        }
        close(stalledSockets[1])
        print("Streaming session passed: vocabulary delivery, ordered final frames, finish, early cancel, bounded audio.")
    }
}
