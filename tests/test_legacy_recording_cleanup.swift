import Foundation

@main
struct LegacyRecordingCleanupTests {
    static func main() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("presstowrite-cleanup-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        let support = root.appendingPathComponent("Application Support", isDirectory: true)
        let temporary = root.appendingPathComponent("T", isDirectory: true)
        let current = support.appendingPathComponent("Press To Write", isDirectory: true)
        let legacy = support.appendingPathComponent("Metatron", isDirectory: true)
        for directory in [current.appendingPathComponent("venv"), legacy, temporary] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        func file(_ url: URL) throws -> URL {
            try Data([1, 0]).write(to: url)
            return url
        }
        let removed = [
            try file(current.appendingPathComponent("last_recording.wav")),
            try file(current.appendingPathComponent("rescue_metadata.json")),
            try file(legacy.appendingPathComponent("last_recording.wav")),
            try file(legacy.appendingPathComponent("rescue_metadata.json")),
            try file(temporary.appendingPathComponent("presstowrite_\(UUID().uuidString).wav")),
            try file(temporary.appendingPathComponent("presstowrite_rescue_\(UUID().uuidString).wav")),
            try file(temporary.appendingPathComponent("metatron_\(UUID().uuidString).wav")),
        ]
        let kept = [
            try file(current.appendingPathComponent("whisper_daemon.py")),
            try file(current.appendingPathComponent("venv/pyvenv.cfg")),
            try file(temporary.appendingPathComponent("presstowrite_daemon.log")),
            try file(temporary.appendingPathComponent("someone-elses-recording.wav")),
            try file(support.appendingPathComponent("last_recording.wav")),
        ]

        LegacyRecordingCleanup.run(applicationSupport: support, temporaryDirectory: temporary)
        for url in removed {
            precondition(!fileManager.fileExists(atPath: url.path), "A saved recording must be removed: \(url.lastPathComponent)")
        }
        for url in kept {
            precondition(fileManager.fileExists(atPath: url.path), "Unrelated files must be kept: \(url.lastPathComponent)")
        }

        // Running again, or against folders that do not exist, is harmless.
        LegacyRecordingCleanup.run(applicationSupport: support, temporaryDirectory: temporary)
        LegacyRecordingCleanup.run(applicationSupport: root.appendingPathComponent("missing"),
                                   temporaryDirectory: root.appendingPathComponent("missing-tmp"))
        print("Legacy recording cleanup passed: saved and temporary recordings removed, other files kept.")
    }
}
