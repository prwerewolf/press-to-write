# Press To Write Project Status & Handoff

## Where We Stand

Press To Write is a local-first push-to-talk speech dictation app for Apple Silicon running macOS 14+. One-time setup installs dependencies and a model; speech recognition, text cleanup, and system integrations then run on-device. The pinned MLX runtime determines the supported macOS version.

### Recently Completed & Verified

**Two-Mac review fixes (October 28, 2026; verified locally on one Mac):**

- Rescue transcription now works on a temporary copy. The speech engine deletes
  every file it is given, even after an error, so a failed or canceled "Transcribe
  Last Recording" used to destroy the saved recording. It now survives and can be
  retried. Reproduced against the real engine code before the fix.
- An explicitly chosen microphone is the only capture attempt. If it is missing the
  existing unavailable error appears instead of recording from another input. Only
  System Default keeps the cascade (default, built-in, any input, unconfigured
  default). A paste is skipped when focus moved to a different control in the same
  app (role or frame differs); unreadable lookups keep the application-level check.
- The Permissions screen links to System Settings after microphone access was
  declined. Hotkey monitors re-arm when Accessibility is granted while the app runs.
- The pill icon is decoded once. A standalone benchmark measured 6.78 ms per draw
  when reloaded versus 0.01 ms when reused; the cost inside the running app was not
  measured. The 3-second status poll no longer republishes unchanged values.
  `build_app.sh` removes the generated key material after the identity import.
- Verified: all twelve Swift suites, all 84 Python tests (also on Python 3.11, 3.12,
  and 3.14), a debug and a release build, and the source and history privacy checks.
  New regressions cover rescue retention, microphone selection, field switches, the
  hotkey re-arm rule, and unchanged-status polling; the field-switch tests were
  mutation-checked. The key cleanup was verified with a stubbed keychain import.
- Not verified: the field-switch rule against real browsers or Electron apps, the
  Permissions screen after a real denial, the hotkey re-arm after a real grant, and
  any run on the second Mac. Needs Accessibility and microphone permission on a Mac.
- Known and unchanged: Professional style turns a spoken "period" that ends an
  utterance into punctuation, which drops the noun in "the grace period" (Natural
  and Raw keep it). Two different builds running at once could keep replacing each
  other's daemon; this was not reproduced. The 3-second poll cadence is unmeasured.

**Press To Write naming cleanup (October 13, 2026; verified locally):**

- Current app, runtime, and documentation names use **Press To Write**, with
  `presstowrite` identifiers and `PRESSTOWRITE_` environment variables. Runtime
  discovery uses the current Application Support directory. The neutral `.venv`
  fallback remains available for an existing local installation.
- Preferences move to current names while preserving configured values,
  microphone selection, and pill placement through a one-time migration.
- The GitHub repository and local checkout are named `press-to-write`; the
  local remote points to the renamed repository. Existing branch protections
  still require Privacy checks and macOS regression tests.
- All twelve Swift regression suites and all 84 Python tests passed. The release
  app built from the renamed checkout and signed with the persistent development
  identity; bundle verification and source privacy checks passed. Independent
  review found no actionable issues. Publication follows the required
  current-head CI and neutral-identity route in MAINTAINING.md.

**Correction-learning regression timing (October 12, 2026; verified locally):**

- The asynchronous regression waits for the initial paste to be observed before
  editing its simulated field, then waits for settled suggestions and focus-loss
  invalidation with bounded deadlines. This prevents scheduler delays from
  turning the fixture into an unverified paste.
- Explicit assertions require another observation after the first edit and the
  full settling window before publication. Unverified-paste rejection, focus
  loss, cancellation, and expiration remain covered.
- All eleven Swift regression suites, all 84 Python tests, and the release build
  passed locally. The correction-learning regression also passed 25 consecutive
  runs. The application uses the existing correction-monitor behavior.

**Clean local reinstall and permission recovery (October 12, 2026; verified locally):**

- Removed the active application, legacy application, legacy runtimes, and app
  preferences after preserving a private recovery backup outside the source tree.
  Reset the applications' own macOS permission records.
- Reinstalled the pinned Python runtime and rebuilt the official source with the
  persistent local signing identity. Installed a single application copy in the
  Applications folder; its bundle signature and designated requirement passed.
  Reinstalled the optional English engine with its verified assets and tokenizer.
- After a full quit and relaunch, the app showed Microphone and Accessibility as
  Granted, All Permissions Active, and Whisper Ready. The permission window did
  not reopen automatically. Settings use fresh defaults; former preferences and
  recovery recordings remain in the private backup. Physical hotkey dictation
  remains a manual verification step. This reinstall was performed locally.

**Application-Aware Contextual Dictation & Strict Em Dash Prohibition (October 12, 2026; verified locally):**

- Added Application-Aware Contextual Dictation that automatically detects the frontmost application category (Code/Terminal, Chat/Messaging, or Prose/Documents) using native macOS bundle IDs and dynamically adapts formatting.
- Introduced a dedicated `.code` transcription style supporting spoken technical symbols (such as `--`, `-`, `_`, `/`, `\`, backticks, `==`, `!=`, `->`, `=>`, `..`, `.`, `::`, `;`, `:`, `@`, `#`, `$`, `%`, `&`, `&&`, `|`, `||`, `++`, `*`, brackets, braces, parentheses, newlines, and tabs), spoken casing macros (camelCase, snake_case, kebab-case, CONSTANT_CASE, PascalCase), lowercase command-name preservation, and trailing period suppression.
- Added casual chat punctuation formatting for messaging apps, omitting formal single trailing periods in conversational chat while preserving exclamation marks and question marks.
- Implemented strict em dash and en dash prohibition across all transcription styles (including Raw mode), unconditionally sanitizing Unicode em and en dash variants into standard ASCII hyphens.
- Added an "Auto-Adapt Style to Target App" toggle in Settings -> Writing, persisted across app sessions via UserDefaults.
- Verified all 20 TextCleaner unit tests (including symbol conversions, casing macros, command preservation, chat punctuation, and em dash sanitization), all AppState regression tests, all InsertionTarget category tests, and all 84 Python daemon tests. Release build and bundle signing succeeded.

**Optional local English streaming (October 10, 2026; verified locally):**

- Fixed the Nemotron Q8 export's missing SentencePiece tokenizer. Setup embeds
  the exact tokenizer from the pinned public checkpoint while preserving tensor
  bytes. All 1,024 token IDs match the original vocabulary. The three synthetic
  names missed without hints were all recovered with actual RNNT boosting.
- Added Accuracy — Whisper (default) and Fast — Nemotron English in Engine
  settings. Fast streams mono PCM16 during capture into a separate warm Metal
  child; release flushes queued frames before finalizing. Vocabulary merges
  manual terms and remembered corrections. Existing cleanup, focus protection,
  clipboard behavior, learning, and rescue recording still apply. Rescue uses
  Whisper; switching modes is disabled during recording or processing.
- Optional `make setup-fast` installs pinned, checksum-verified public assets.
  Normal dictation never downloads; a missing or mismatched tokenizer cannot
  silently disable boosting. Runtime files, models, and local benchmark outputs
  remain outside public source. No HTTP endpoint or cloud transcription is used.
- All 11 Swift regression suites and 84 Python tests passed, including ordered
  streaming frames, the final short buffer, bounded buffering, cancellation,
  invalid audio, optional setup, vocabulary delivery, and remembered words.
  Production socket/Metal tests recovered all three synthetic names, retained
  the long dictation's ending, returned empty text for silence and noise, and
  reloaded after cancellation. Two paced speech clips finalized in approximately
  54–67 ms over the Unix socket; capture, cleanup, and paste are outside that
  measurement. Whisper's existing accuracy/vocabulary path also passed offline.
  The production Swift streaming client also passed against the running app's
  Metal worker with synthetic audio, finalizing in approximately 68 ms.
- Debug and release builds, bundle signature, complete bundled-module identity,
  and source privacy checks passed. Both modes were visibly Ready in the running
  app's Engine settings; Accuracy was restored after verification. The release
  bundle now uses the persistent local development signing identity. The app
  showed its permission setup screen; live microphone/Accessibility dictation
  needs permissions on this Mac and has not been exercised for fast mode.
- README, privacy/storage, and third-party notices document optional setup and
  local behavior. New GGUF/checkpoint/tokenizer formats are ignored and rejected
  by publication checks, even when force-staged. Only source, documentation, and
  synthetic tests belong in the release; models and local benchmark data stay
  private. Maintainers land this source update through the required GitHub privacy
  and macOS checks using the neutral-identity route in MAINTAINING.md.

**Local dictation improvements (October 10, 2026):**

- Paste and voice undo resolve Command shortcuts from the active keyboard layout.
  Unsupported mappings fail without sending a guessed physical key; manual paste
  remains available and failed undo no longer reports success.
- The warmed MLX model supplies the tokenizer and prompt-window size. Recent
  context and whole vocabulary entries share one token budget, reserving context
  instead of allowing a large dictionary to crowd it out.
- Prompt-shaped vocabulary echoes receive at most one decode of the same samples
  without hints. Real speech containing vocabulary words, intentional lists, Raw
  output, and temporary recording cleanup are covered by regressions.
- Added opt-in correction suggestions after a verified paste. Learning uses only
  a bounded non-secure control with exact focus checks and native focus-change
  notifications when available. Stable spelling edits offer Remember/Dismiss.
  Only accepted words persist locally; management lives in Writing settings.
  Incognito, cancellation, a new dictation, and focus loss stop observation.
- Verified all Swift regression suites and 70 Python tests. The installed local
  tokenizer was exercised with English, dense Unicode, and long technical terms
  under the daemon's network guard. The actual cached model warmed to Ready with
  a 223-token prompt window. Debug compilation, release packaging, bundle-signature
  verification, bundled-daemon identity, and the source privacy check passed.
  Synthetic settings and suggestion states were inspected in light and dark mode.
- The release bundle uses ad-hoc local signing; macOS may require granting
  Accessibility again. Reopen the rebuilt app to load this update. Learning is
  off by default; enable Suggest spelling corrections below Voice Snippets in
  Settings → Writing. An older settings window belongs to the older app;
  use the rebuilt Press To Write app to access the new controls.
- Release through a reviewed branch with the required current-head privacy and
  macOS checks, then the neutral-identity fast-forward route in MAINTAINING.md.
  Application bundles, preferences, local spelling lists, and recordings remain
  outside the source release. Live dictation with alternative physical keyboard
  layouts has not been exercised.

**Community sharing preparation (October 7, 2026):**

- Replaced personal fixtures and machine-specific examples with synthetic values.
- Added the Unmodified Use License: free use of official unmodified versions,
  including internal business use; modification, resale, and redistribution
  require written permission. Third-party dependencies retain their own licenses.
- Added exclusions for private data, models, signing material, local editor and
  agent settings, and distribution artifacts. Added staged-file and full-history
  privacy checks, local commit/push hooks, a neutral commit wrapper, and CI.
- Added pinned direct runtime dependencies and first-run instructions. Setup
  creates the Python environment directly in Application Support, supports cache
  environment variables, and has an explicit offline mode. MLX requires macOS 14+.
- Building packages the daemon without replacing a user's running runtime.
- Isolated audio recovery tests from real Application Support data.
- Verified all Swift regression suites, 59 Python tests, the source privacy
  check, and a signed release build. Fresh online dependency/model installation
  has not been exercised on a second Mac; model setup is covered with mocked
  downloads and temporary caches.
- Before changing a previously private repository to public, separately verify
  retained pull-request refs and cached old commits. A branch rewrite alone does
  not remove those GitHub copies. See PRIVACY.md and MAINTAINING.md.

1. **Launch at Login (`SMAppService`)**:
   - Native macOS 13+ ServiceManagement integration via `LaunchAtLogin.swift`.
   - General Settings toggle seamlessly registers/unregisters `Press To Write.app` in macOS Login Items.

2. **Custom Text Replacements / Voice Snippet Macros**:
   - Expansion engine in `TextCleaner.swift` supporting `phrase -> replacement` or `phrase = replacement`.
   - Applied in Natural and Professional styles with word-boundary matching and case-insensitive recognition.
   - User-configurable via dedicated editor in Style Settings tab with live `UserDefaults` persistence.

3. **Smart Prefix Spacing**:
   - Caret inspection via `InsertionTarget.precedingCharacter()` using macOS Accessibility API.
   - Fallback consecutive dictation heuristic: automatically prepends space if dictating into the same app/PID within 45 seconds without trailing whitespace.
   - Punctuation guard ensures spaces are never prepended before punctuation, quotes, brackets, or newlines.

4. **"Scratch That" Voice Corrections & Standalone Undo**:
   - Mid-utterance phrase correction in `TextCleaner.swift` automatically cuts abandoned words/clauses before `"scratch that"` / `"cancel that"`.
   - Standalone voice undo: Speaking *"scratch that"*, *"cancel that"*, or *"undo that"* alone synthesizes a native `Cmd+Z` keystroke via `TextInserter.sendUndoKeystroke()`, displays `"Undone!"` on the pill, and avoids inserting text.

5. **Accidental Click Guard**:
   - Silently drops recordings under 0.25 seconds in `AppState.stopRecordingAndTranscribe()`.
   - Cleans up temporary audio files and resets state to `"Ready"` without error chimes.

6. **Portable Daemon Path Resolution**:
   - Removed all hardcoded personal paths in `LocalDaemonClient.swift` and tests.
   - Dynamically discovers daemon and script locations relative to the app bundle or repository root for multi-Mac compatibility.

7. **Speech Transcription Without `ffmpeg`**:
   - Fixed Fn dictation failing after release when the GUI-launched daemon could not find Homebrew's `ffmpeg`.
   - The daemon validates and decodes Press To Write's 16 kHz mono PCM16 WAV using Python `wave` and NumPy, then passes float32 samples to MLX Whisper.
   - Added a regression test for sample scaling, array input to MLX, and temporary recording cleanup.

8. **Comprehensive Codebase Hardening & Bug Fixes**:
   - **Bounded Accessibility IPC**: Added a 200ms timeout (`AXUIElementSetMessagingTimeout(element, 0.2)`) on cursor context queries in `InsertionTarget.swift` to prevent main-thread beachballs on sluggish target applications.
   - **Empty Field Leading Space Suppression**: Introduced typed `CursorContext` (`.character`, `.startOfText`, `.unavailable`) in `InsertionTarget.swift` and `AppState.swift` to prevent erroneous leading spaces when dictating at cursor position 0 in empty fields.
   - **Sticky Modifier Key Recovery**: Added `resetModifierStates()` in `HotkeyManager.swift` and invoked it on cancellation, click-guard drops, audio recording errors, and `stopListening()` to eliminate latched modifier states.
   - **Socket `EINTR` Interruption Safety**: Guarded `write()` and `read()` loops in `LocalDaemonClient.swift` against POSIX signal interruptions (`EINTR`).
   - **Dynamic Excision & Chained Undo Correction**: Replaced static match iteration with dynamic live-string re-matching in `TextCleaner.swift` and added support for chained undo phrases (`"meeting at four, scratch that, cancel that, five"` -> `"meeting at five"`), while preserving noun phrases (`"a scratch that hurts"`).
   - **Multi-Display Topology Auto-Recovery**: Added an observer for `NSApplication.didChangeScreenParametersNotification` in `FloatingPillWindow.swift` to automatically re-anchor the floating pill to the main screen if an external display is disconnected.

9. **Multi-Device Fallback Cascade (`AudioInputSelection.captureAttempts`)**:
   - System Default only: `default -> built-in -> any input -> AUHAL default`. An explicit selection is exact and never falls back.
   - Prevents capture failures and freezes when an input device (e.g., iPhone Continuity Camera mic) enters an invalid or non-responsive AUHAL state (`Input:No | Output:No`, error `1852797029`).

10. **Unconditional Hotkey Modifier Unlatching (`HotkeyManager.swift`)**:
   - Modifier releases and unexpected `flagsChanged` events unconditionally reset `isFnDown`, `isRightOptionDown`, and `isRightCommandDown`.
   - `startRecording()` and `onRecordingError` explicitly call `resetModifierStates()` to guarantee modifier flags can never stay latched after an error.

11. **Persistent Audio Rescue System & Menu Bar Recovery (`RescueAudioController.swift`)**:
   - Raw recorded audio is persisted to `~/Library/Application Support/Press To Write/last_recording.wav` with a JSON metadata manifest.
   - Speech audio is never discarded on device errors or transcription timeouts.
   - Added **"Transcribe Last Recording"** menu bar status item with duration readout (`AppDelegate.swift`), enabling instant one-click recovery to the clipboard at any time.

12. **Zero-Orphan Process Watchdog (`whisper_daemon.py` & `LocalDaemonClient.swift`)**:
   - `PRESSTOWRITE_PARENT_PID` environment propagation to spawned daemons.
   - Background POSIX watchdog thread in Python terminates the daemon within 1 second if the parent app exits or is force-quit.
   - Explicit `terminateLaunchedDaemon()` hook in `AppDelegate.applicationWillTerminate`.

13. **macOS TCC Sandbox Immunity via Application Support Runtime**:
   - Resolved GUI-launch access failures when a checkout under `~/Documents` was used as the speech runtime.
   - Current setup creates the runtime directly at `~/Library/Application Support/Press To Write/venv`. It does not copy or relocate an existing virtual environment. An existing checkout `.venv` remains a fallback for older installations.
   - Updated `LocalDaemonClient.swift` to automatically sync `whisper_daemon.py` to Application Support and prioritize the Application Support Python environment in `candidatePythonPaths`.
   - Setup maintains dependencies in Application Support; building only packages the daemon in the app. The app stages its bundled daemon when launched, leaving user preferences and recovery recordings outside the source checkout.
   - Added `NSDocumentsFolderUsageDescription` in `Resources/Info.plist` for defense-in-depth.

14. **Full Rebrand to Press To Write (`Press To Write.app`)**:
   - Standardized **Press To Write** across native Swift sources, app bundle (`Press To Write.app`), bundle identifier (`com.presstowrite.mac`), Swift package target (`PressToWrite`), and local codesigning identity (`Press To Write Development`).
   - Cleaned up legacy prototype processes, reset TCC permissions for `com.presstowrite.mac`, and unhooked legacy Fn key interceptors.
   - Updated all user-facing UI: Menu Bar ("Press To Write"), Floating Pill ("Press To Write", adjusted horizontal pill width to 126pt), Settings, History, and Permissions windows.
   - Modernized offline model downloader in `scripts/setup_mac.sh` to use `huggingface_hub.snapshot_download` instead of deprecated `huggingface_hub.cli.core`.
   - Updated local IPC socket path to `/tmp/presstowrite.sock`; current environment overrides use `PRESSTOWRITE_MODEL_DIR` and `PRESSTOWRITE_PYTHON`.
   - Re-verified full test suite and clean release build.

15. **Context-Aware Prompt Biasing, Hallucination Guard & Output Formatting (October 9, 2026)**:
   - **Context Extraction (`InsertionTarget.precedingText`)**: Queries the focused control via macOS Accessibility (`kAXSelectedTextRangeAttribute` / `kAXStringForRangeParameterizedAttribute`) with a bounded 200ms IPC timeout, with a 45-second fallback to recent utterance text in the same target application.
   - **Whisper Prompt Biasing (`whisper_daemon.py`)**: Combines up to 250 characters of preceding document context with custom vocabulary hints into Whisper's `initial_prompt`, giving the decoder instant awareness of sentence flow, casing, and document terminology with zero added latency.
   - **Mid-Sentence Continuation Casing (`TextCleaner.swift` & `AppState.swift`)**: Detects mid-sentence continuations from preceding context and suppresses start-of-utterance capitalization in Professional style, ensuring seamless multi-turn speech flow.
   - **Hallucination & Audio Artifact Guard (`TextCleaner.removeAudioArtifacts`)**: Strips phantom Whisper audio descriptors (`[Music]`, `[Applause]`, `(laughter)`, `[Silence]`, etc.) on silence or background noise, allowing quiet audio to reset to "No Speech Detected" rather than inserting ghost text.
   - **Professional Style by Default**: New installs and unconfigured sessions default to Professional style, enabling spoken punctuation (`comma`, `period`, `new paragraph`), list formatting, and proper capitalization out of the box while preserving Natural and Raw styles.
   - **Build Script Signing Hardening (`build_app.sh`)**: Added graceful ad-hoc signing fallback if persistent developer identity signing cannot access the keychain or is run non-interactively.

### Verification Status
- All twelve Swift regression suites passed locally: cleaner, local-daemon-client, streaming-session, hotkeys, keyboard shortcuts, correction learning, insertion-target, microphone, audio conversion/config, pill-display, app-state, and preference-migration.
- All 84 Python tests passed: 47 daemon tests, 7 setup tests, 13 fast-engine/setup tests, and 17 privacy tests.
- App bundle cleanly compiles, packages, and signs (`make build`).
- Source and published-history privacy checks passed. The actual staged tree and
  outgoing history must pass again before each commit/push; personal identity
  terms remain only in the ignored local deny-list.
- Public branch histories, repository descriptions, PR text, and source icon
  metadata were audited for personal and machine identifiers. Retained private
  local snapshot objects are unavailable through the replacement GitHub repo's
  object API. Keep those snapshots local; never include them in a push.
- The real cached offline model warmed to Ready with its actual 223-token prompt window. Synthetic light/dark UI checks covered correction suggestions, long spellings, the vocabulary limit, and learned-word management.
- Physical Fn/microphone dictation and a fresh online install on a second Mac remain manual onboarding checks. Automated tests use synthetic audio and temporary model caches.
- Whisper and Nemotron English warmed to Ready offline. The production Swift
  streaming client, Metal vocabulary boosting, silence/noise, cancellation and
  reload, and final-word flush were tested with synthetic audio. Optional fast
  assets must be installed separately on another Mac with `make setup-fast`;
  they are never copied into Git.

### Publication and handoff

- The official branch is `main`. Source-sharing changes and license are committed and pushed; privacy hooks are installed in the working checkout.
- The old repository was deleted and recreated at the original URL on October 7, 2026. The replacement is public and contains the verified clean source. Legacy PRs and PR refs are absent; tested original identifying Git commit objects return 404 in the replacement.
- Source, commit identities, and normal uploads are guarded by the privacy checks. Private app preferences and shared local configuration stay outside published files. Repository ownership still identifies the GitHub hosting account.
- Repository-level secret scanning and secret push protection are enabled. `main` requires the GitHub Actions privacy and macOS checks, including for administrators, with linear history and force pushes/deletions disabled. These controls are active; normal updates must satisfy them.
- Normal setup now enables privacy hooks automatically in its own Git checkout, preserving existing hook preferences and avoiding changes to an enclosing repository for ZIP installs. AGENTS.md gives future coding sessions standing privacy instructions. No custom Codex skill is required. Fresh-checkout setup, existing hooks, source archives, and common system account labels have regression coverage.
- PR CI checks the combined file tree and macOS behavior, and checks commit identities on the actual proposed branch history. Maintainers land validated PRs with a local fast-forward or a validated neutral-identity integration commit, preserving neutral commit attribution.
- Publication is a GitHub source release. There is no binary-distribution, notarization, website-hosting, or deployment pipeline to run. The installer builds the app on the recipient's Mac.
- Follow MAINTAINING.md for subsequent updates. After a history rewrite, other machines must start from a clean clone and keep their local preferences outside Git.

---

## What's Left & Future Roadmap

- Additional specialized punctuation / code snippet modes if requested.
- Extended multi-monitor edge-docking customization for unconventional display layouts.
- Performance profiling on M-series chips for larger vocabulary lists (>1,000 terms).

---

## Architectural Context & Gotchas

- **Strict Offline Enforcement**: The Python daemon sets `sys.addaudithook(deny_network_access)` to block socket connections and DNS lookups at the interpreter level. Any feature or dependency that introduces network calls will be blocked and will fail tests.
- **Audio Rescue Invariant**: Speech audio is saved to `RescueAudioController` whenever recording finishes or encounters an error after >= 1.0s of speech. The temporary file in `/tmp` is removed to prevent disk leaks while preserving user voice data in Application Support.
- **Standalone Undo vs. Mid-Utterance**: `TextCleaner.isStandaloneUndoCommand` preserves bare undo commands so `AppState` can inspect them before text insertion and trigger `Cmd+Z`. Mid-utterance commands are handled separately in `cleanScratchThatPhrases`.
- **Accessibility Permissions**: Virtual keystroke insertion (`Cmd+V`, `Cmd+Z`) and focused element inspection require macOS Accessibility permissions. If ungranted, clipboard fallback is used.
- **GUI Process `PATH`**: Apps launched by Finder may not inherit Homebrew paths. Pass decoded NumPy audio to MLX Whisper, rather than a WAV filename that would make the dependency call `ffmpeg`. Press To Write's PCM16 WAV format is validated before inference.
