import Foundation
import CryptoKit
import Darwin

final class InFlightTranscription: @unchecked Sendable {
    private let lock = NSLock()
    private var socketFD: Int32?
    private var cancelled = false

    func register(_ fd: Int32) throws {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { throw CancellationError() }
        socketFD = fd
    }

    func clear(_ fd: Int32) {
        lock.lock()
        if socketFD == fd { socketFD = nil }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        if let socketFD { shutdown(socketFD, SHUT_RDWR) }
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

public final class LocalDaemonClient: SpeechEngineProtocol, @unchecked Sendable {
    public static let shared = LocalDaemonClient()

    private let socketPath = "/tmp/presstowrite.sock"
    let protocolVersion = 4
    private let lifecycleQueue = DispatchQueue(label: "com.presstowrite.local-engine", qos: .utility)
    // Only accessed on lifecycleQueue, which also serializes launch attempts.
    private var launchedProcess: Process?
    private var lastLaunchAttempt: Date = .distantPast

    private init() {}

    private var appSupportURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Press To Write", isDirectory: true)
    }

    private func syncDaemonScriptToApplicationSupport() -> String? {
        guard let dirURL = appSupportURL else { return nil }
        try? FileManager.default.createDirectory(at: dirURL, withIntermediateDirectories: true)
        let targetScript = dirURL.appendingPathComponent("whisper_daemon.py")

        let inAppScript = Bundle.main.bundlePath + "/Contents/Resources/whisper_daemon.py"
        let repoScript = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("daemon/whisper_daemon.py").path
        let cwdScript = FileManager.default.currentDirectoryPath + "/daemon/whisper_daemon.py"

        let sourcePath: String?
        if FileManager.default.fileExists(atPath: inAppScript) {
            sourcePath = inAppScript
        } else if FileManager.default.fileExists(atPath: repoScript) {
            sourcePath = repoScript
        } else if FileManager.default.fileExists(atPath: cwdScript) {
            sourcePath = cwdScript
        } else {
            sourcePath = nil
        }

        if let sourcePath {
            let sourceDirectory = URL(fileURLWithPath: sourcePath).deletingLastPathComponent()
            do {
                // Read the complete revision before staging any file. The hash
                // covers every module, so a helper-only update restarts the worker.
                let files = try daemonFileNames.map { name in
                    (name, try Data(contentsOf: sourceDirectory.appendingPathComponent(name)))
                }
                for (name, data) in files {
                    let target = dirURL.appendingPathComponent(name)
                    if (try? Data(contentsOf: target)) != data {
                        try data.write(to: target, options: .atomic)
                    }
                }
                return targetScript.path
            } catch { return nil }
        }

        if FileManager.default.fileExists(atPath: targetScript.path) {
            return targetScript.path
        }
        return nil
    }

    private func defaultDaemonScriptPath() -> String {
        if let appSupportScript = syncDaemonScriptToApplicationSupport() {
            return appSupportScript
        }
        let inAppScript = Bundle.main.bundlePath + "/Contents/Resources/whisper_daemon.py"
        if FileManager.default.fileExists(atPath: inAppScript) {
            return inAppScript
        }
        let repoScript = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("daemon/whisper_daemon.py").path
        if FileManager.default.fileExists(atPath: repoScript) {
            return repoScript
        }
        return FileManager.default.currentDirectoryPath + "/daemon/whisper_daemon.py"
    }

    private func scriptSHA256(at path: String) throws -> String {
        let directory = URL(fileURLWithPath: path).deletingLastPathComponent()
        var data = Data()
        for name in daemonFileNames {
            data.append(try Data(contentsOf: directory.appendingPathComponent(name)))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private let daemonFileNames = ["whisper_daemon.py", "nemotron_engine.py", "gguf_metadata.py"]

    func isCurrentDaemon(_ response: [String: Any], scriptHash: String) -> Bool {
        response["protocol_version"] as? Int == protocolVersion &&
            response["offline"] as? Bool == true &&
            response["script_sha256"] as? String == scriptHash
    }

    /// A quick compatibility check. Readiness must be obtained through engineStatus().
    public func isDaemonRunning() -> Bool {
        let script = defaultDaemonScriptPath()
        guard let hash = try? scriptSHA256(at: script),
              let response = try? request(["action": "ping"], timeout: 1) else { return false }
        return isCurrentDaemon(response, scriptHash: hash)
    }

    /// Retained for callers that only want to initiate startup; never blocks the main thread.
    public func ensureDaemonRunning(daemonScriptPath: String? = nil) {
        lifecycleQueue.async {
            try? self.launchIfNeeded(daemonScriptPath: daemonScriptPath)
        }
    }

    /// Terminates any daemon process launched by this client instance.
    public func terminateLaunchedDaemon() {
        lifecycleQueue.sync {
            if let process = self.launchedProcess, process.isRunning {
                process.terminate()
                self.launchedProcess = nil
            }
        }
    }

    /// Launch and socket I/O run off the main thread. The daemon answers pings during warmup
    /// and inference, so "Ready" always means the actual model has finished loading.
    public func engineStatus(mode: SpeechMode = .accuracy) async -> LocalEngineStatus {
        await withCheckedContinuation { continuation in
            lifecycleQueue.async {
                do {
                    try self.launchIfNeeded()
                    let response = try self.request(["action": "ping", "engine": mode.rawValue], timeout: 1)
                    continuation.resume(returning: self.status(from: response))
                } catch {
                    continuation.resume(returning: LocalEngineStatus(
                        phase: .unavailable,
                        message: "Local speech engine unavailable: \(error.localizedDescription)"
                    ))
                }
            }
        }
    }

    private func status(from response: [String: Any]) -> LocalEngineStatus {
        guard response["protocol_version"] as? Int == protocolVersion,
              response["offline"] as? Bool == true,
              let expectedHash = try? scriptSHA256(at: defaultDaemonScriptPath()),
              response["script_sha256"] as? String == expectedHash else {
            return LocalEngineStatus(
                phase: .unavailable,
                message: "The local speech engine is outdated. Reopen Press To Write to restart it."
            )
        }
        let phase: LocalEngineStatus.Phase
        switch response["status"] as? String {
        case "ready": phase = .ready
        case "loading": phase = .loading
        default: phase = .unavailable
        }
        return LocalEngineStatus(
            phase: phase,
            message: response["message"] as? String ?? "The local speech engine is unavailable",
            model: response["model"] as? String
        )
    }

    private func launchIfNeeded(daemonScriptPath: String? = nil) throws {
        let script = daemonScriptPath ?? defaultDaemonScriptPath()
        guard FileManager.default.fileExists(atPath: script) else {
            throw engineError("The local speech engine script is missing.")
        }
        let expectedHash = try scriptSHA256(at: script)
        if let response = try? request(["action": "ping"], timeout: 1) {
            if isCurrentDaemon(response, scriptHash: expectedHash) { return }
            try replaceOutdatedDaemon(response, script: script)
        }
        // Polls can arrive while the Python process is still creating its socket.
        if launchedProcess?.isRunning != true {
            guard Date().timeIntervalSince(lastLaunchAttempt) >= 5 else {
                throw engineError("The speech engine could not start. Check the local Python installation.")
            }
            lastLaunchAttempt = Date()
            let appSupportPython: String? = appSupportURL?.appendingPathComponent("venv/bin/python3").path
            let candidatePythonPaths: [String] = [
                ProcessInfo.processInfo.environment["PRESSTOWRITE_PYTHON"],
                appSupportPython,
                NSHomeDirectory() + "/Library/Application Support/Press To Write/venv/bin/python3",
                NSHomeDirectory() + "/.presstowrite/venv/bin/python3",
                NSHomeDirectory() + "/.venv/bin/python3",
                Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent(".venv/bin/python3").path,
                FileManager.default.currentDirectoryPath + "/.venv/bin/python3",
                "/opt/homebrew/bin/python3",
                "/usr/local/bin/python3",
                "/usr/bin/python3"
            ].compactMap { $0 }
            let pythonPath = candidatePythonPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? "/usr/bin/python3"
            let logURL = URL(fileURLWithPath: "/tmp/presstowrite_daemon.log")
            if !FileManager.default.fileExists(atPath: logURL.path) {
                FileManager.default.createFile(atPath: logURL.path, contents: nil)
            }
            let log = try FileHandle(forWritingTo: logURL)
            defer { try? log.close() }
            try log.seekToEnd()
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            process.arguments = [pythonPath, "-u", script]
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = log
            process.standardError = log
            var environment = ProcessInfo.processInfo.environment
            environment["HF_HUB_OFFLINE"] = "1"
            environment["TRANSFORMERS_OFFLINE"] = "1"
            environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
            environment["PYTHONDONTWRITEBYTECODE"] = "1"
            environment["PRESSTOWRITE_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
            process.environment = environment
            try process.run()
            launchedProcess = process
        }
        // Only this background queue waits for socket startup; GPU warmup is polled separately.
        for _ in 0..<15 {
            if let response = try? request(["action": "ping"], timeout: 1),
               isCurrentDaemon(response, scriptHash: expectedHash) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw engineError("The local speech engine is still starting. Try again in a moment.")
    }

    private func replaceOutdatedDaemon(_ response: [String: Any], script: String) throws {
        guard response["offline"] as? Bool == true else {
            throw engineError("Another process is using Press To Write's local speech socket.")
        }
        var legacyPID: pid_t?
        // Version 3 has the same verified shutdown command as the current version.
        if let oldVersion = response["protocol_version"] as? Int,
           (3...protocolVersion).contains(oldVersion),
           let oldHash = response["script_sha256"] as? String,
           oldHash.count == 64 {
            let shutdownResponse = try request([
                "action": "shutdown", "protocol_version": oldVersion,
                "expected_sha256": oldHash,
            ], timeout: 2)
            guard shutdownResponse["success"] as? Bool == true else {
                throw engineError("The outdated local speech engine refused to stop.")
            }
        } else if response["protocol_version"] as? Int == 2 {
            // Version 2 has no shutdown command. Identify the actual Unix peer and
            // its exact daemon script arguments before sending it SIGTERM.
            guard let pid = verifiedLegacyDaemonPID(script: script), kill(pid, SIGTERM) == 0 else {
                throw engineError("The old local speech engine could not be safely replaced. Quit it and reopen Press To Write.")
            }
            legacyPID = pid
        } else {
            throw engineError("An unrecognized local speech engine is using the socket.")
        }
        for _ in 0..<50 {
            if let fd = try? connectedSocket(timeout: 1) {
                close(fd)
            } else if daemonLaunchLockAvailable(at: socketPath + ".lock"),
                      legacyPID.map({ kill($0, 0) != 0 }) ?? true {
                launchedProcess = nil
                lastLaunchAttempt = .distantPast
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw engineError("The old local speech engine is still stopping. Try again in a moment.")
    }

    func daemonLaunchLockAvailable(at path: String) -> Bool {
        let fd = open(path, O_RDWR | O_CREAT, mode_t(0o600))
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
        flock(fd, LOCK_UN)
        return true
    }

    private func verifiedLegacyDaemonPID(script: String) -> pid_t? {
        guard let fd = try? connectedSocket(timeout: 1) else { return nil }
        defer { close(fd) }
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(fd, &peerUID, &peerGID) == 0, peerUID == getuid() else { return nil }
        var peerPID: pid_t = 0
        var pidLength = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &peerPID, &pidLength) == 0,
              peerPID > 1, peerPID != getpid() else { return nil }
        guard let freshPing = try? request(["action": "ping"], timeout: 1, connectedFD: fd),
              freshPing["protocol_version"] as? Int == 2,
              freshPing["offline"] as? Bool == true else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(peerPID), "-o", "args="]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let command = String(data: data, encoding: .utf8) else { return nil }
        guard isKnownLegacyLaunch(
            command: command, script: script,
            workingDirectory: processWorkingDirectory(of: peerPID)
        ) else { return nil }
        return peerPID
    }

    func isKnownLegacyLaunch(command: String, script: String, workingDirectory: String?) -> Bool {
        let arguments = command.split(whereSeparator: \.isWhitespace).map(String.init)
        guard arguments.count == 3, arguments[1] == "-u" else { return false }
        let bundleParent = Bundle.main.bundleURL.deletingLastPathComponent().standardizedFileURL.path
        let repository = workingDirectory ?? bundleParent
        let hasRelativeArgument = !arguments[0].hasPrefix("/") || !arguments[2].hasPrefix("/")
        let scriptRepo = URL(fileURLWithPath: script).deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL.path
        let validWorkingDirs = Set([
            bundleParent,
            scriptRepo,
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).standardizedFileURL.path
        ])
        if hasRelativeArgument && (workingDirectory == nil || !validWorkingDirs.contains(URL(fileURLWithPath: workingDirectory!).standardizedFileURL.path)) { return false }
        func absolutePath(_ argument: String) -> String {
            argument.hasPrefix("/") ? argument : URL(fileURLWithPath: workingDirectory ?? repository)
                .appendingPathComponent(argument).standardizedFileURL.path
        }
        let appSupportScript: String? = appSupportURL?.appendingPathComponent("whisper_daemon.py").path
        let knownScripts: [String] = [script, defaultDaemonScriptPath(), appSupportScript, repository + "/daemon/whisper_daemon.py"].compactMap { $0 }
        let appSupportPython: String? = appSupportURL?.appendingPathComponent("venv/bin/python3").path
        let knownPython: [String] = [
            appSupportPython,
            NSHomeDirectory() + "/Library/Application Support/Press To Write/venv/bin/python3",
            NSHomeDirectory() + "/.presstowrite/venv/bin/python3",
            repository + "/.venv/bin/python3",
            "/usr/bin/python3"
        ].compactMap { $0 }
        return knownPython.contains(absolutePath(arguments[0])) &&
            knownScripts.contains(absolutePath(arguments[2]))
    }

    private func processWorkingDirectory(of pid: pid_t) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-p", String(pid), "-d", "cwd", "-Fn"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let listing = String(data: data, encoding: .utf8) else { return nil }
        return listing.split(separator: "\n").first(where: { $0.hasPrefix("n/") }).map { String($0.dropFirst()) }
    }

    /// Sends the recording over the private Unix socket. Audio stays in memory in
    /// both processes; neither side writes it to a file.
    public func transcribe(pcm16: Data, vocabulary: [String], style: TranscriptionStyle, context: String? = nil) async throws -> String {
        try Task.checkCancellation()
        var currentStatus = await engineStatus()
        // A canceled decode restarts the isolated MLX child. A recording released
        // during that short warmup should wait for Ready instead of being discarded.
        for _ in 0..<100 where currentStatus.phase == .loading {
            try await Task.sleep(nanoseconds: 200_000_000)
            currentStatus = await engineStatus()
        }
        guard currentStatus.phase == .ready else { throw engineError(currentStatus.message) }
        try Task.checkCancellation()
        let styleID: String
        switch style {
        case .natural: styleID = "natural"
        case .professional: styleID = "professional"
        case .code: styleID = "code"
        case .raw: styleID = "raw"
        }
        let requestID = UUID().uuidString
        let inFlight = InFlightTranscription()
        var requestPayload: [String: Any] = [
            "action": "transcribe",
            "protocol_version": self.protocolVersion,
            "request_id": requestID,
            "audio_bytes": pcm16.count,
            "vocabulary": vocabulary,
            "style": styleID,
        ]
        if let context = context, !context.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            requestPayload["context"] = context
        }
        let text: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        if inFlight.isCancelled { throw CancellationError() }
                        let response = try self.request(requestPayload, timeout: 120, inFlight: inFlight, body: pcm16)
                        if inFlight.isCancelled { throw CancellationError() }
                        guard response["protocol_version"] as? Int == self.protocolVersion else {
                            throw self.engineError("Restart Press To Write to update the local speech engine.")
                        }
                        if let error = response["error"] as? String { throw self.engineError(error) }
                        guard let text = response["text"] as? String else {
                            throw self.engineError("The local speech engine returned no text.")
                        }
                        continuation.resume(returning: text)
                    } catch {
                        continuation.resume(throwing: inFlight.isCancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            inFlight.cancel()
            DispatchQueue.global(qos: .userInitiated).async {
                _ = try? self.request([
                    "action": "cancel", "protocol_version": self.protocolVersion,
                    "request_id": requestID,
                ], timeout: 2)
            }
        }
        try Task.checkCancellation()
        return text
    }

    public func startStreaming(vocabulary: [String]) -> LocalStreamingSession {
        LocalStreamingSession(client: self, vocabulary: vocabulary)
    }

    func cancelStreaming(requestID: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            _ = try? self.request([
                "action": "cancel", "protocol_version": self.protocolVersion,
                "request_id": requestID,
            ], timeout: 2)
        }
    }

    func connectedSocket(timeout: Int) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw engineError("Could not create a local speech connection.") }
        var socketTimeout = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &socketTimeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        withUnsafeMutablePointer(to: &address.sun_path) { destination in
            pathBytes.withUnsafeBytes { source in
                UnsafeMutableRawPointer(destination).copyMemory(from: source.baseAddress!, byteCount: source.count)
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw engineError("The local speech engine is not responding.")
        }
        return fd
    }

    private func request(
        _ request: [String: Any], timeout: Int,
        inFlight: InFlightTranscription? = nil, connectedFD: Int32? = nil, body: Data? = nil
    ) throws -> [String: Any] {
        let fd = try connectedFD ?? connectedSocket(timeout: timeout)
        defer {
            inFlight?.clear(fd)
            if connectedFD == nil { close(fd) }
        }
        try inFlight?.register(fd)
        try sendJSON(request, to: fd)
        if let body {
            do {
                try sendData(body, to: fd)
            } catch {
                // The daemon can refuse audio mid-upload; report its reason when it sent one.
                if let reply = try? readJSON(from: fd) { return reply }
                throw error
            }
        }
        return try readJSON(from: fd)
    }

    func sendJSON(_ request: [String: Any], to fd: Int32) throws {
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        try sendData(payload, to: fd)
    }

    func sendData(_ payload: Data, to fd: Int32) throws {
        try payload.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let sent = write(fd, base.advanced(by: offset), bytes.count - offset)
                if sent < 0 && errno == EINTR { continue }
                guard sent > 0 else { throw engineError("The speech connection was interrupted.") }
                offset += sent
            }
        }
    }

    func readJSON(from fd: Int32) throws -> [String: Any] {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !response.contains(0x0A) {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw engineError("The local speech engine timed out or disconnected.") }
            response.append(buffer, count: count)
            guard response.count <= 4 * 1024 * 1024 else {
                throw engineError("The local speech engine returned too much data.")
            }
        }
        guard let newline = response.firstIndex(of: 0x0A),
              let decoded = try JSONSerialization.jsonObject(with: response.prefix(upTo: newline)) as? [String: Any] else {
            throw engineError("Invalid response from the local speech engine.")
        }
        return decoded
    }

    func engineError(_ message: String) -> NSError {
        NSError(domain: "PressToWriteLocal", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
