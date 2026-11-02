import Foundation

/// Earlier builds kept the latest recording and its metadata in Application
/// Support, and a crash could leave a temporary WAV behind. Nothing the user
/// says is written to disk any more, so remove those leftovers at launch.
public enum LegacyRecordingCleanup {
    static let savedRecordingNames = ["last_recording.wav", "rescue_metadata.json"]
    static let temporaryRecordingPrefixes = ["presstowrite_", "metatron_"]

    public static func run(
        applicationSupport: URL? = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory
    ) {
        let fileManager = FileManager.default
        if let applicationSupport {
            for folder in ["Press To Write", "Metatron"] {
                let directory = applicationSupport.appendingPathComponent(folder, isDirectory: true)
                for name in savedRecordingNames {
                    try? fileManager.removeItem(at: directory.appendingPathComponent(name))
                }
            }
        }
        let leftovers = (try? fileManager.contentsOfDirectory(
            at: temporaryDirectory, includingPropertiesForKeys: nil
        )) ?? []
        for url in leftovers where isTemporaryRecording(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    static func isTemporaryRecording(_ name: String) -> Bool {
        name.lowercased().hasSuffix(".wav") && temporaryRecordingPrefixes.contains { name.hasPrefix($0) }
    }
}
