# Press To Write — Local Dictation for macOS

Native push-to-talk dictation for Apple Silicon. Speech recognition, vocabulary hints, and text cleanup run on your Mac. After one-time installation, the speech engine operates offline and cannot download models or contact a cloud transcription service.

Free to run unmodified for personal or internal business use. Selling, modifying, rebranding, and redistribution are restricted by the [Unmodified Use License](LICENSE). This is a source-available project.

## Install on your Mac

Requirements: an **Apple Silicon Mac (M-series), macOS 14 or later**, Xcode Command Line Tools (Swift 5.9 or later), and a native arm64 **Python 3.10–3.13**. The pinned runtime has been verified with Python 3.10. Intel Macs, Windows, and Linux are unsupported.

1. Install Xcode Command Line Tools with `xcode-select --install` if needed.
2. Install a supported arm64 Python if needed. Check `python3 --version`; a Python installed by a version manager also works. You can select its executable with the setup script's `--python` option.
3. Download the `press-to-write` repository's source ZIP from GitHub and extract it, or copy the repository's HTTPS clone URL into `git clone`. Open Terminal in the extracted or cloned folder.
4. Run:

```bash
make setup
```

Setup creates a Python environment directly in `~/Library/Application Support/Press To Write/venv`, installs the versions in `requirements.txt`, downloads a speech model if none is already cached, builds the app, and launches it. In a Git clone, setup also enables the local commit and push privacy guards. ZIP installs are supported without initializing Git or changing another repository's hooks. Existing custom hooks are preserved and must include the privacy checks before a maintainer publishes updates.

Initial setup needs internet access and enough disk space for Python dependencies and the model. No API key, account, paid transcription service, or existing virtual environment is required. `ffmpeg` is not needed for dictation.

For a particular Python executable, use:

```bash
./scripts/setup_mac.sh --python python3.12
```

Once dependencies and the model are installed, `./scripts/setup_mac.sh --offline --no-launch` verifies the local runtime and rebuilds without allowing setup downloads. The app bundle uses local signing; it is not a notarized installer. If macOS blocks a source build, review the warning in System Settings → Privacy & Security and open the app there.

For optional English streaming, run `make setup-fast` after normal setup. This
downloads the pinned NeMo-Speech 0.2.0 Metal runtime and Nemotron English Q8 model,
then embeds the model's original matching tokenizer for vocabulary boosting.
Checksums cover the runtime, original weights, tokenizer, and repaired export;
all tensor bytes remain unchanged. Allow about 1.4 GB of additional disk space
for the model and its setup cache. Select **Fast — Nemotron English** in
Settings → Engine and wait for Ready. **Accuracy — Whisper** remains the default.
`python3 -B scripts/setup_fast.py --offline` verifies or repairs from cached
assets without downloading. Optional setup does not change your selected mode.

## First launch

Grant **Microphone** and **Accessibility** permission to Press To Write when prompted. Each Mac needs its own permissions. In System Settings → Keyboard, set **“Press 🌐 key to:” → “Do Nothing”** if using Fn / Globe. Open Settings → Microphone, select an available input, and test its levels. Wait for Settings → Speech Engine to show **Ready**, then try a short dictation in a text editor.

Your microphone choice, vocabulary, text replacements, history, and recordings are created on your own Mac. They are not bundled with the source download.

## Daily use

1. Wait for the local speech engine to show **Ready** in Settings → Speech Engine.
2. Hold **Fn / Globe**, speak, and release to transcribe. Alternative hotkeys and toggle mode are available in Settings.
3. Press **Escape** to discard a recording or cancel a pending dictation.
4. Text is inserted only if the original app and focused control still own the cursor. If focus changes, your result remains available through **Copy Last Dictation** in the menu bar or the pill's Copy button. An app that exposes too little accessibility detail to tell two controls apart is checked at the application level only.

The compact pill can be dragged to screen edges and remembers its monitor across restarts. Its waveform shows recording activity; loading and error states have explanatory tooltips.

## Settings

- **Transcription mode:** Settings → Engine offers **Accuracy — Whisper** for
  accuracy and multiple languages, and optional **Fast — Nemotron English** for
  English streaming on Metal. Fast mode decodes during recording and flushes the
  final words on release. Mode changes are disabled during dictation. Both modes
  use custom and remembered vocabulary; Whisper also uses document context and
  its token-budgeted prompt. Fast output can have less punctuation. Rescued audio
  always uses Whisper for accuracy. Missing fast files produce an installation
  message; dictation never downloads files or selects a cloud fallback.
- **Launch at Login:** Option in Settings → General to start Press To Write automatically on macOS login via `SMAppService`.
- **Microphone:** Choose the system default or a specific input. The level-meter test runs only while enabled, saves no recording, and stops when Settings closes or dictation begins. An unavailable saved microphone produces a clear error instead of silently switching inputs. Only System Default falls back, to the built-in microphone and then any other input, when the default input cannot start.
- **Custom vocabulary & Text Replacements:** Comma-separated vocabulary terms guide local recognition. The Text Replacements editor in Settings → Writing allows defining voice snippet macros (`phrase -> replacement` or `phrase = replacement`, e.g., `my email -> name@example.com`).
- **Correction Learning:** Enable **Suggest spelling corrections** in Settings → Writing. After a successful paste, the app briefly checks that same accessible, non-secure field for spelling edits. A **Remember this spelling?** panel offers Remember and Dismiss without activating the app. Only words you explicitly remember are saved locally; edit, forget, or clear them under Learned Vocabulary. Learning is off by default and pauses in Incognito. Unsupported controls and large documents are skipped; the feature does not retrain the model.
- **Prompt Budgeting & Vocabulary Recovery:** In Whisper, recent document context and complete vocabulary entries share the loaded model's actual token budget. Suspicious vocabulary-list echoes get one local retry without context or vocabulary hints. Short dictations containing saved names remain valid; an intentional spoken list can be confirmed by the retry.
- **Keyboard Layout Support:** Paste and voice undo resolve the Command shortcut through the current keyboard layout, including input-method fallback to an available ASCII layout. An unresolved shortcut leaves the transcript available for manual paste, and unavailable undo reports how to use the app's Edit menu.
- **Voice Correction & Undo ("Scratch That"):** Mid-sentence corrections like *"meeting at four, scratch that, five"* replace the abandoned phrase. Speaking *"scratch that"*, *"cancel that"*, or *"undo that"* as a standalone utterance triggers a native `Cmd+Z` undo keystroke with visual feedback on the pill.
- **Context-Aware Prompt Biasing:** Preceding text from the active document/focused control is automatically read via Accessibility and passed into Whisper's initial prompt, ensuring correct mid-sentence casing, sentence continuation, and document context without manual configuration.
- **Smart Prefix Spacing:** Consecutive dictations into the same app/control automatically prepend a space, using accessibility cursor inspection with a 45-second fallback for smooth multi-sentence dictation.
- **Hallucination & Sound Artifact Guard:** Filters hallucinated Whisper audio annotations (such as `[Music]`, `[Applause]`, `(laughter)`) on non-speech audio, quietly resetting to "No Speech Detected" rather than inserting ghost tokens.
- **Audio Rescue & Recovery:** If an audio device disconnects mid-speech or an unexpected engine error occurs, Press To Write preserves the raw audio recording in `~/Library/Application Support/Press To Write/last_recording.wav`. The **Transcribe Last Recording** menu item in the macOS status bar allows immediate one-click recovery of the dictated speech directly to your clipboard.
- **Accidental Click Guard:** Hotkey presses shorter than 0.25 seconds are silently discarded without transcription or error chimes.
- **Auto-Adapt Style to Target App:** When enabled in Settings -> Writing, Press To Write automatically detects the frontmost application category using native macOS bundle IDs (Code for IDEs and terminals, casual punctuation for chat apps, and Prose for documents and notes).
- **Code (Technical & Symbols):** Technical symbol formatting (such as `--`, `-`, `_`, `/`, backticks, `==`, `!=`, `->`, `=>`, `..`, `.`, `::`, `;`, `:`, `@`, `#`, `$`, `%`, `&`, `&&`, `|`, `||`, `++`, `*`, brackets, braces, parentheses), spoken casing macros (camelCase, snake_case, kebab-case, CONSTANT_CASE, PascalCase), lowercase command-name preservation, and trailing period suppression.
- **Professional (Default):** Natural cleanup plus spoken punctuation (`comma`, `period`, `new line`, `new paragraph`), bullet commands, and sentence capitalization with context-aware continuation casing.
- **Natural:** Conservative removal of clear hesitations and obvious repetition loops, preserving wording, casing, and literal punctuation words.
- **Raw:** The recognizer's output without text cleanup, vocabulary replacements, or formatting. Vocabulary still guides recognition itself.
- **Punctuation Hygiene:** All transcription styles strictly convert Unicode em and en dashes to standard ASCII hyphens.
- **Clipboard:** Existing transient clipboard markers and automatic restoration are used for insertion. “Keep Speech on System Clipboard” retains copied speech when enabled. If Accessibility is unavailable, the existing copy-to-clipboard fallback remains available.
- **History:** Session Only is the default. Incognito disables history; rolling limits keep the last 10 or 50 entries in memory. History is not persisted across app restarts.

Temporary recording files in `/tmp` are removed after processing, while the most recent recording is securely archived in Application Support for recovery. Audio tests only compute levels in memory. Text deliberately copied or inserted into another application follows that application's own storage/sync behavior.

## Offline model setup

Press To Write uses the Python environment created in `~/Library/Application Support/Press To Write/venv` and already-downloaded MLX Whisper files. Older installations can still use an existing `.venv` as a fallback. Setup preserves app preferences and does not copy your checkout’s virtual environment. The engine loads and warms the actual model before reporting Ready.

Press To Write records 16 kHz mono PCM16 WAV. The local daemon decodes that format directly with Python and NumPy before recognition, so `ffmpeg` is not needed at runtime. This also works when a Finder-launched app does not inherit Homebrew's `PATH`.

Fast mode sends the same converted PCM over a private Unix socket to a separate,
resident Metal worker. The audio tap only fills a bounded queue; socket writes
and inference run off the audio and main threads. Release sends all accepted
frames before flushing, including a short final frame. Escape, device failure,
an interrupted connection, or an audio backlog discard the stream, and the
usual recovery recording remains available after a transcription failure.
Workers accept installed local paths only; no HTTP service is started. The
optional runtime and model live under Application Support's `fast` directory.
`PRESSTOWRITE_FAST_DIR` can select an existing installation when launching the
app/daemon. A model without the exact matching tokenizer is rejected instead of
silently disabling vocabulary boosting.

For an installation in a different directory or an existing asset cache, the
optional installer accepts `--destination` and `--cache`; use `--help` for their
syntax. Set `PRESSTOWRITE_FAST_DIR` to that installation when launching. Isolated
daemon tests can override `PRESSTOWRITE_SOCKET`; the app client uses the standard
Unix socket, so leave this unset for normal dictation.

The daemon looks in the local Hugging Face cache for `mlx-community/whisper-large-v3-turbo`; an already-cached `mlx-community/whisper-base.en` can serve as a startup fallback. It reads cache directories directly and never calls an online model resolver. Standard `HF_HOME`, `HF_HUB_CACHE`, `HUGGINGFACE_HUB_CACHE`, and `XDG_CACHE_HOME` cache locations are supported by both setup and the daemon. If using a custom cache or model path, launch the app’s executable from that same configured terminal; Finder does not necessarily inherit terminal environment variables.

You can instead set `PRESSTOWRITE_MODEL_DIR` to an existing local model directory containing `config.json` and `weights.safetensors` or `weights.npz` when launching the app/daemon. Missing model files produce an unavailable message; they are never downloaded automatically. Python network sockets and DNS lookups are blocked in the daemon in addition to offline dependency flags.

## Build, test, and launch

```bash
make test   # Synthetic/mocked regression tests; no microphone or network access
make build  # Build and sign Press To Write.app
make run    # Restart the app and local daemon
```

`make run` uses the existing app bundle; run `make build` first after changing source. Restart both the app and daemon after an update so they use the same offline protocol.

## macOS permissions

- **Microphone:** Needed for dictation and the explicitly started input test.
- **Accessibility:** Needed for global hotkeys, checking the insertion destination, and pasting into the focused application.
- In **System Settings → Keyboard**, set **“Press 🌐 key to:” → “Do Nothing”** to prevent the system emoji window from opening when using Fn.

## Update an official installation

Quit the app. For a clean clone tracking the official branch, run `git pull --ff-only`, then `make setup` and reopen it. Setup reuses an existing model and updates dependencies to the declared versions. If you downloaded a ZIP, download the newer official source instead and run setup from that folder. Settings and the local runtime live outside the source folder and remain on your Mac. Local signing can require granting Accessibility permission again after a rebuild.

Quit any older app copy and open the newly built **Press To Write.app**. Update
existing shortcuts to open the current bundle. In Writing settings, scroll below
Voice Snippets to find Correction Learning. macOS permissions are granted
separately to the updated application. Existing settings are migrated to the
current preference names on launch, preserving configured values.

If an older clone predates a published history cleanup, download or clone the cleaned repository again. Do not merge or push its old branches into the official repository. See [Maintainer updates and privacy](MAINTAINING.md).

## Privacy and troubleshooting

The last audio recording and its recovery metadata stay in `~/Library/Application Support/Press To Write/`. Dictation history is in memory and clears on exit; vocabulary and settings are stored in the app’s macOS preferences. The daemon writes a local diagnostic log to `/tmp/presstowrite_daemon.log`. Do not upload these files, your preferences, or real dictated text in an issue. See [PRIVACY.md](PRIVACY.md).

- **Speech engine unavailable:** Run setup again, confirm Python is native arm64, and check that the local model has `config.json` and nonempty weight files. The app will never download a missing model itself.
- **Microphone unavailable:** Choose an input currently connected to this Mac; devices and permissions differ between machines.
- **Text appears only in the clipboard:** Grant Accessibility permission and retry in the intended text control.
- **Fn opens emoji:** Change the macOS keyboard setting described above, or choose an alternative hotkey in the app.

Report bugs with your macOS version, chip family, Python version, and steps to reproduce using synthetic text. Code modifications and redistribution require the copyright holder’s written permission; the license permits configuration through the app and documented environment variables. Third-party dependencies retain their [own licenses](THIRD_PARTY.md).
