#!/usr/bin/env bash
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

TEST_DIR="$(mktemp -d "${TMPDIR:-/tmp}/presstowrite-tests.XXXXXX")"
trap 'rm -rf "$TEST_DIR"' EXIT
MODULE_CACHE="${CLANG_MODULE_CACHE_PATH:-$TEST_DIR/module-cache}"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Engine/TextCleaner.swift tests/test_cleaner.swift \
    -o "$TEST_DIR/cleaner"
"$TEST_DIR/cleaner"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Engine/SpeechEngine.swift Sources/PressToWrite/Engine/TextCleaner.swift \
    Sources/PressToWrite/Engine/LocalDaemonClient.swift Sources/PressToWrite/Engine/LocalStreamingSession.swift \
    tests/test_local_daemon_client.swift \
    -o "$TEST_DIR/local-daemon-client"
"$TEST_DIR/local-daemon-client"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Engine/SpeechEngine.swift Sources/PressToWrite/Engine/TextCleaner.swift \
    Sources/PressToWrite/Engine/LocalDaemonClient.swift Sources/PressToWrite/Engine/LocalStreamingSession.swift \
    tests/test_streaming_session.swift -o "$TEST_DIR/streaming-session"
"$TEST_DIR/streaming-session"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/HotkeyManager.swift tests/test_hotkeys.swift \
    -o "$TEST_DIR/hotkeys"
"$TEST_DIR/hotkeys"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/KeyboardShortcutResolver.swift tests/test_keyboard_shortcuts.swift \
    -o "$TEST_DIR/keyboard-shortcuts"
"$TEST_DIR/keyboard-shortcuts"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/CorrectionLearner.swift tests/test_correction_learning.swift \
    -o "$TEST_DIR/correction-learning"
"$TEST_DIR/correction-learning"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/InsertionTarget.swift Sources/PressToWrite/Core/TextInserter.swift \
    Sources/PressToWrite/Core/KeyboardShortcutResolver.swift Sources/PressToWrite/Core/CorrectionLearner.swift \
    tests/test_insertion_target.swift \
    -o "$TEST_DIR/insertion-target"
"$TEST_DIR/insertion-target"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/AudioInputDevice.swift tests/test_microphone.swift \
    -o "$TEST_DIR/microphone"
"$TEST_DIR/microphone"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/AudioInputDevice.swift Sources/PressToWrite/Core/AudioInputDeviceController.swift \
    Sources/PressToWrite/Core/PreferenceMigration.swift \
    Sources/PressToWrite/Core/AudioRecorder.swift tests/test_audio_conversion.swift \
    -o "$TEST_DIR/audio-conversion"
"$TEST_DIR/audio-conversion"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/UI/FloatingPill/PillDisplayRestoration.swift tests/test_pill_display.swift \
    -o "$TEST_DIR/pill-display"
"$TEST_DIR/pill-display"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/PreferenceMigration.swift \
    Sources/PressToWrite/Core/CorrectionLearner.swift \
    Sources/PressToWrite/App/AppState.swift Sources/PressToWrite/Engine/TextCleaner.swift \
    Sources/PressToWrite/Engine/SpeechEngine.swift tests/test_app_state.swift \
    -o "$TEST_DIR/app-state"
"$TEST_DIR/app-state"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/LegacyRecordingCleanup.swift tests/test_legacy_recording_cleanup.swift \
    -o "$TEST_DIR/legacy-recording-cleanup"
"$TEST_DIR/legacy-recording-cleanup"

swiftc -module-cache-path "$MODULE_CACHE" -parse-as-library \
    Sources/PressToWrite/Core/PreferenceMigration.swift tests/test_preference_migration.swift \
    -o "$TEST_DIR/preference-migration"
"$TEST_DIR/preference-migration"

python3 -B -m unittest discover -s tests -p 'test_*.py'
