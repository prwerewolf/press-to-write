import Foundation
import Darwin

@main
struct LocalDaemonClientTests {
    static func main() throws {
        let client = LocalDaemonClient.shared
        let hash = String(repeating: "a", count: 64)
        let current: [String: Any] = [
            "protocol_version": client.protocolVersion, "offline": true, "script_sha256": hash,
        ]
        precondition(client.isCurrentDaemon(current, scriptHash: hash))
        precondition(!client.isCurrentDaemon(current, scriptHash: String(repeating: "b", count: 64)))
        precondition(!client.isCurrentDaemon([
            "protocol_version": 2, "offline": true, "script_sha256": hash,
        ], scriptHash: hash))
        precondition(!client.isCurrentDaemon([
            "protocol_version": 3, "offline": true, "script_sha256": hash,
        ], scriptHash: hash), "A daemon that reads recordings from files must be replaced")
        precondition(!client.isCurrentDaemon([
            "protocol_version": client.protocolVersion, "offline": false, "script_sha256": hash,
        ], scriptHash: hash))

        let repo = FileManager.default.currentDirectoryPath
        let script = repo + "/daemon/whisper_daemon.py"
        precondition(client.isKnownLegacyLaunch(
            command: ".venv/bin/python3 -u daemon/whisper_daemon.py",
            script: script, workingDirectory: repo
        ))
        precondition(!client.isKnownLegacyLaunch(
            command: ".venv/bin/python3 -u daemon/whisper_daemon.py",
            script: script, workingDirectory: "/tmp"
        ))
        precondition(!client.isKnownLegacyLaunch(
            command: "/usr/bin/python3 -u /tmp/whisper_daemon.py",
            script: script, workingDirectory: repo
        ))

        let cancelled = InFlightTranscription()
        cancelled.cancel()
        do {
            try cancelled.register(3)
            preconditionFailure("A request canceled before socket setup must not start I/O")
        } catch is CancellationError {
            // Expected.
        }

        let lockPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("presstowrite-lock-test-\(UUID().uuidString)").path
        let lockFD = open(lockPath, O_RDWR | O_CREAT, mode_t(0o600))
        precondition(lockFD >= 0)
        defer {
            close(lockFD)
            try? FileManager.default.removeItem(atPath: lockPath)
        }
        precondition(flock(lockFD, LOCK_EX | LOCK_NB) == 0)
        precondition(!client.daemonLaunchLockAvailable(at: lockPath),
                     "A new daemon must wait while the old daemon holds the launch lock")
        flock(lockFD, LOCK_UN)
        precondition(client.daemonLaunchLockAvailable(at: lockPath))

        print("Local daemon client regressions passed: script identity, verified legacy paths, early cancel, launch lock.")
    }
}
