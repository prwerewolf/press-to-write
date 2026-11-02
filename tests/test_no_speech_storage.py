"""Nothing the user says may be written to disk; guard the source against regressions."""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
# The only source allowed to name old recording files is the code that deletes them.
CLEANUP = ROOT / "Sources" / "PressToWrite" / "Core" / "LegacyRecordingCleanup.swift"

SWIFT_STORAGE = re.compile(
    r"AVAudioFile|AVAudioRecorder|ExtAudioFile|AudioFileCreate|temporaryDirectory|NSTemporaryDirectory"
    r"|\.wav\b|last_recording|rescue_metadata"
)
PYTHON_STORAGE = re.compile(
    r"^\s*(?:import|from)\s+(?:wave|tempfile|soundfile|scipy\.io)\b|\.wav\b|NamedTemporaryFile|mkstemp",
    re.MULTILINE,
)


class NoSpeechStorageTests(unittest.TestCase):
    def offenders(self, paths, pattern):
        found = []
        for path in paths:
            for number, line in enumerate(path.read_text().splitlines(), 1):
                if pattern.search(line):
                    found.append(f"{path.relative_to(ROOT)}:{number}: {line.strip()}")
        return found

    def test_app_never_writes_recordings_or_dictation_history(self):
        sources = [path for path in (ROOT / "Sources").rglob("*.swift") if path != CLEANUP]
        self.assertTrue(sources)
        self.assertEqual(self.offenders(sources, SWIFT_STORAGE), [])

    def test_speech_engine_never_creates_audio_or_temporary_files(self):
        daemon = sorted((ROOT / "daemon").glob("*.py"))
        self.assertTrue(daemon)
        self.assertEqual(self.offenders(daemon, PYTHON_STORAGE), [])

    def test_cleanup_only_deletes(self):
        text = CLEANUP.read_text()
        for write in (r"write\(to:", r"createFile", r"copyItem", r"\bmoveItem", r"FileHandle\(forWriting"):
            self.assertIsNone(re.search(write, text), write)


if __name__ == "__main__":
    unittest.main()
