#!/usr/bin/env python3
"""Resident, strictly offline MLX speech recognition over a local Unix socket."""

import os

# These must be set before importing MLX or any Hugging Face dependency.
os.environ["HF_HUB_OFFLINE"] = "1"
os.environ["TRANSFORMERS_OFFLINE"] = "1"
os.environ["HF_HUB_DISABLE_TELEMETRY"] = "1"
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"

import sys
import errno
import re
import json
import time
import socket
import signal
import threading
import hashlib
import fcntl
import multiprocessing
import queue
import stat
import importlib
import unicodedata
from concurrent.futures import Future
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from nemotron_engine import FastInferenceWorker, receive_exact

SOCKET_PATH = os.environ.get("PRESSTOWRITE_SOCKET", "/tmp/presstowrite.sock")
DEFAULT_MODEL = "mlx-community/whisper-large-v3-turbo"
FALLBACK_MODEL = "mlx-community/whisper-base.en"
PROTOCOL_VERSION = 4
MAX_REQUEST_BYTES = 65536
# One hour of 16 kHz mono PCM16. Audio arrives over the socket and stays in memory.
MAX_AUDIO_BYTES = 16000 * 2 * 60 * 60
SCRIPT_SHA256 = hashlib.sha256(b"".join(
    (Path(__file__).parent / name).read_bytes()
    for name in ("whisper_daemon.py", "nemotron_engine.py", "gguf_metadata.py")
)).hexdigest()

active_model = None
active_model_path = None
mlx_whisper = None
prompt_tokenizer = None
prompt_token_budget = 223
is_engine_ready = False
engine_load_error = None
engine_message = "Loading the local speech model…"
engine_lock = threading.Lock()
inference_lock = threading.Lock()
server_stop = threading.Event()
bound_socket_identity = None


def deny_network_access(event, args):
    """Defense in depth: this daemon permits Unix sockets, never network sockets."""
    if event == "socket.__new__" and args[1] in (socket.AF_INET, socket.AF_INET6):
        raise OSError("Press To Write speech recognition is offline; network access is disabled")
    if event in ("socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr"):
        raise OSError("Press To Write speech recognition is offline; DNS access is disabled")


def complete_model_folder(folder):
    folder = Path(folder)
    try:
        return (folder / "config.json").is_file() and any(
            (folder / name).is_file() and (folder / name).stat().st_size > 0
            for name in ("weights.safetensors", "weights.npz")
        )
    except OSError:
        return False


def local_model_candidates():
    """Find downloaded files directly; never invoke a Hub resolver or downloader."""
    explicit_path = os.environ.get("PRESSTOWRITE_MODEL_DIR")
    if explicit_path:
        folder = Path(explicit_path).expanduser().resolve()
        if not complete_model_folder(folder):
            raise RuntimeError(f"The local model folder is incomplete: {folder}")
        return [(folder.name, str(folder))]

    cache_home = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache"))).expanduser()
    hf_home = Path(os.environ.get("HF_HOME", str(cache_home / "huggingface"))).expanduser()
    hub_cache = Path(os.environ.get("HF_HUB_CACHE", os.environ.get(
        "HUGGINGFACE_HUB_CACHE", str(hf_home / "hub")
    ))).expanduser()
    candidates = []
    for model in (DEFAULT_MODEL, FALLBACK_MODEL):
        repository = hub_cache / ("models--" + model.replace("/", "--"))
        snapshots = repository / "snapshots"
        folders = []
        main_ref = repository / "refs" / "main"
        if main_ref.is_file():
            revision = main_ref.read_text().strip()
            if revision and "/" not in revision and revision not in (".", ".."):
                folders.append(snapshots / revision)
        if snapshots.is_dir():
            folders.extend(sorted(snapshots.iterdir(), key=lambda path: path.name))
        for folder in folders:
            if complete_model_folder(folder):
                candidates.append((model, str(folder.resolve())))
                break
    if not candidates:
        raise RuntimeError(
            "No downloaded speech model was found. Install a local MLX Whisper model "
            "and restart Press To Write. No model will be downloaded automatically."
        )
    return candidates


def engine_status():
    with engine_lock:
        return {
            "success": True,
            "protocol_version": PROTOCOL_VERSION,
            "script_sha256": SCRIPT_SHA256,
            "pid": os.getpid(),
            "offline": True,
            "status": "ready" if is_engine_ready else ("unavailable" if engine_load_error else "loading"),
            "message": engine_load_error or engine_message,
            "model": active_model,
        }


def load_engine_background():
    global mlx_whisper, active_model, active_model_path
    global prompt_tokenizer, prompt_token_budget
    global is_engine_ready, engine_load_error, engine_message
    with engine_lock:
        is_engine_ready = False
        engine_load_error = None
        engine_message = "Loading the local speech model…"
    try:
        candidates = local_model_candidates()
        import mlx_whisper as mw
        import numpy as np

        failures = []
        # All MLX work runs on the same single worker, including this warmup. Passing
        # an existing directory also prevents mlx-whisper from calling snapshot_download.
        with inference_lock:
            for model, model_path in candidates:
                try:
                    with engine_lock:
                        active_model = model
                        engine_message = "Warming up the local speech model…"
                    mw.transcribe(
                        np.zeros(16000, dtype=np.float32),
                        path_or_hf_repo=model_path,
                        fp16=True,
                        verbose=None,
                        language="en",
                        temperature=0.0,
                        sample_len=1,
                        condition_on_previous_text=False,
                    )
                    # Use the tokenizer and context size of the actual warmed model.
                    # These modules and token tables are installed locally with MLX.
                    holder = importlib.import_module("mlx_whisper.transcribe").ModelHolder
                    tokenizer_module = importlib.import_module("mlx_whisper.tokenizer")
                    loaded = holder.model
                    tokenizer = tokenizer_module.get_tokenizer(
                        loaded.is_multilingual, num_languages=loaded.num_languages
                    )
                    budget = loaded.dims.n_text_ctx // 2 - 1
                    if budget < 1:
                        raise RuntimeError("The speech model has no prompt context")
                    with engine_lock:
                        mlx_whisper = mw
                        prompt_tokenizer = tokenizer
                        prompt_token_budget = budget
                        active_model_path = model_path
                        is_engine_ready = True
                        engine_message = "Ready — speech stays on this Mac"
                    print(f"[Press To Write Daemon] Local model loaded and warmed: {model}")
                    return
                except Exception as error:
                    failures.append(f"{model}: {error}")
        raise RuntimeError("Unable to load the downloaded speech model. " + "; ".join(failures))
    except Exception as error:
        with engine_lock:
            engine_load_error = str(error)
        print(f"[Press To Write Daemon] Local model unavailable: {error}", file=sys.stderr)


def deduplicate_repetition_loops(text: str) -> str:
    if not text:
        return ""
    # 1. Deduplicate repeated sentences or clauses with ending punctuation (e.g. "Phrase. Phrase. Phrase." -> "Phrase.")
    text = re.sub(r"(?<![\w'’-])((?:[^\.\?\!\n]+?[\.\?\!]))(?:\s+\1)+", r'\1', text, flags=re.IGNORECASE)
    # 2. Deduplicate repeated multi-word phrases (2 to 8 words) (e.g. "phrase phrase phrase" -> "phrase")
    # Match whole words, including at the start of the first phrase and the end
    # of every repeat: "do you do your homework" must not become "do your homework".
    text = re.sub(r"(?<![\w'’-])((?:[a-zA-Z0-9']+[,\s]+){1,8}[a-zA-Z0-9']+)(?:[,\s]+\1(?![\w'’-]))+", r'\1', text, flags=re.IGNORECASE)
    return text.strip()

def clean_whisper_result(result: dict) -> str:
    segments = result.get("segments", [])
    if segments:
        cleaned_segments = []
        for seg in segments:
            seg_text = seg.get("text", "").strip()
            if not seg_text:
                continue

            # Check compression ratio: Whisper flags repetitive hallucination with high ratio
            comp_ratio = seg.get("compression_ratio", 1.0)
            if comp_ratio and comp_ratio > 2.4:
                continue

            # Skip segments flagged as silence/low confidence
            no_speech = seg.get("no_speech_prob", 0.0)
            avg_logprob = seg.get("avg_logprob", 0.0)
            if no_speech and no_speech > 0.6 and avg_logprob and avg_logprob < -1.0:
                continue

            # Filter consecutive duplicate segments
            if cleaned_segments and seg_text.lower() == cleaned_segments[-1].lower():
                continue

            cleaned_segments.append(seg_text)

        raw_text = " ".join(cleaned_segments).strip() if cleaned_segments else ""
    else:
        raw_text = result.get("text", "").strip()

    return deduplicate_repetition_loops(raw_text)

def vocabulary_terms(vocabulary):
    """Normalize bounded input without splitting a vocabulary entry."""
    if not isinstance(vocabulary, list):
        raise ValueError("Vocabulary must be a list of words or phrases")
    terms = []
    seen = set()
    for value in vocabulary:
        if not isinstance(value, str):
            raise ValueError("Vocabulary terms must be text")
        term = " ".join(value.split()).strip()
        if not term or len(term) > 100 or term.casefold() in seen:
            continue
        if len(terms) >= 256:
            break
        terms.append(term)
        seen.add(term.casefold())
    return terms


def vocabulary_prompt(vocabulary):
    # Retained for small callers; inference budgets the combined prompt below.
    return ", ".join(vocabulary_terms(vocabulary)) or None


def build_prompt_plan(vocabulary, context=None, tokenizer=None, max_tokens=None):
    """Reserve recent context, then admit whole terms inside one token budget.

    Count the leading space too: Whisper's decoder may re-encode string prompts
    with that prefix. Character counts cannot bound rare names or Unicode text.
    Return the terms actually sent so echo detection uses the same vocabulary.
    """
    terms = vocabulary_terms([] if vocabulary is None else vocabulary)
    tokenizer = tokenizer if tokenizer is not None else prompt_tokenizer
    budget = max_tokens if max_tokens is not None else prompt_token_budget
    if tokenizer is None or budget < 1:
        raise ValueError("The local speech tokenizer is unavailable. Restart Press To Write.")

    def fits(text, limit):
        return len(tokenizer.encode(" " + text)) <= limit

    ctx = ""
    if isinstance(context, str):
        ctx = " ".join(context.split())[-250:].strip()
        # Leave room for names even when recent document text is token-dense.
        context_budget = min(64, max(1, budget // 3)) if terms else budget
        while ctx and not fits(ctx, context_budget):
            _, separator, tail = ctx.partition(" ")
            ctx = tail if separator else ctx[1:]

    accepted = []
    prompt = ctx
    for term in terms:
        candidate_vocab = ", ".join([*accepted, term])
        candidate = f"{ctx} {candidate_vocab}" if ctx else candidate_vocab
        if fits(candidate, budget):
            accepted.append(term)
            prompt = candidate
    return prompt or None, accepted


def build_initial_prompt(vocabulary, context=None, tokenizer=None, max_tokens=None):
    return build_prompt_plan(vocabulary, context, tokenizer, max_tokens)[0]


def normalized_words(text):
    return re.findall(r"[^\W_]+(?:['’\-][^\W_]+)*", unicodedata.normalize("NFKC", text).casefold())


def is_vocabulary_echo(text, terms):
    """Recognize prompt-shaped output, never mere overlap with a saved word."""
    words = normalized_words(text)
    sequences = [normalized_words(term) for term in terms]
    sequences = [sequence for sequence in sequences if sequence]
    if not words or not sequences:
        return False
    vocabulary_words = {word for sequence in sequences for word in sequence}
    if any(word not in vocabulary_words for word in words):
        return False

    # A single name repeated three or more times is a decoder loop. An ordinary
    # short dictation such as "Lumora" or "Lumora, Lumora" must survive.
    for sequence in sequences:
        if len(words) >= 3 * len(sequence) and len(words) % len(sequence) == 0:
            if words == sequence * (len(words) // len(sequence)):
                return True

    # Three consecutive entries in the transmitted list are a likely prompt
    # continuation. A prompt-free retry also preserves intentional spoken lists.
    for start in range(len(sequences)):
        run = []
        for end in range(start, len(sequences)):
            run.extend(sequences[end])
            if len(run) > len(words):
                break
            if end - start >= 2 and run == words:
                return True
    return False


def pcm16_samples(pcm):
    """Scale the app's in-memory 16 kHz mono PCM16 audio for MLX Whisper."""
    if not isinstance(pcm, (bytes, bytearray)) or not pcm:
        raise ValueError("The recording contains no audio samples")
    if len(pcm) % 2:
        raise ValueError("Unsupported recording format; expected 16 kHz mono PCM16")

    import numpy as np
    # PCM16 is little-endian. astype makes a writable float32 copy before scaling.
    return np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768.0


def transcribe_pcm(pcm, vocabulary=None, style="natural", context=None) -> dict:
    """Recognize audio held in memory. No recording or transcript touches disk."""
    if style not in ("natural", "professional", "raw", "code"):
        return {"error": "Unknown writing style"}
    status = engine_status()
    if status["status"] != "ready":
        return {"error": status["message"]}

    start_time = time.monotonic()
    try:
        with inference_lock:
            # Recheck that files still exist. Even a removed cache must never turn
            # into a Hub lookup. Offline flags + the network guard enforce this too.
            if not active_model_path or not complete_model_folder(active_model_path):
                raise RuntimeError("The downloaded speech model is missing. Restart Press To Write after restoring it.")
            prompt, sent_terms = build_prompt_plan(vocabulary, context=context)
            audio = pcm16_samples(pcm)
            options = dict(
                path_or_hf_repo=active_model_path, fp16=True, verbose=None,
                condition_on_previous_text=False, compression_ratio_threshold=2.4,
                logprob_threshold=-1.0, no_speech_threshold=0.6,
            )
            result = mlx_whisper.transcribe(audio, initial_prompt=prompt, **options)
            recovered = is_vocabulary_echo(result.get("text", ""), sent_terms)
            if recovered:
                # Reuse the samples once, without any prompt. The worker still
                # owns cancellation of this in-memory request.
                # Never discard speech just because it uses dictionary words:
                # an independent decode can confirm an intentional spoken list.
                result = mlx_whisper.transcribe(audio, initial_prompt=None, **options)
        # Return the recognizer's text exactly. Swift owns style-specific cleanup
        # in one place; Raw bypasses that cleanup completely.
        text = result.get("text", "")
        return {
            "success": True,
            "text": text,
            "duration": round(time.monotonic() - start_time, 3),
            "model": active_model,
            "vocabulary_recovery": recovered,
        }
    except Exception as error:
        return {"error": str(error)}


def inference_process(pipe):
    """MLX lives only in this child so an abandoned decode can be stopped safely."""
    sys.addaudithook(deny_network_access)
    try:
        load_engine_background()
        pipe.send({"kind": "status", "status": engine_status()})
        while True:
            message = pipe.recv()
            if message.get("action") != "transcribe":
                continue
            result = transcribe_pcm(
                message["pcm"], message.get("vocabulary", []), message.get("style", "natural"),
                context=message.get("context")
            )
            pipe.send({"kind": "result", "request_id": message["request_id"], "result": result})
            # Release this dictation's audio, context and text before waiting for the next.
            message = result = None
    except (EOFError, BrokenPipeError):
        pass
    finally:
        pipe.close()


class IsolatedInferenceWorker:
    """One warm MLX child. Cancellation terminates only that owned child."""

    def __init__(self, context=None):
        self.context = context or multiprocessing.get_context("spawn")
        self.pending = queue.Queue()
        self.jobs = {}
        self.cancelled_ids = {}
        self.lock = threading.Lock()
        self.stopping = threading.Event()
        self.process = None
        self.thread = threading.Thread(target=self._run, name="presstowrite-inference-supervisor", daemon=True)
        self.thread.start()

    def submit(self, request_id, pcm, vocabulary, style, context=None):
        future = Future()
        job = {"request_id": request_id, "pcm": pcm, "vocabulary": vocabulary,
               "style": style, "context": context, "future": future, "cancelled": threading.Event()}
        with self.lock:
            if request_id in self.jobs:
                raise ValueError("A transcription with that request ID is already running")
            if request_id in self.cancelled_ids:
                self.cancelled_ids.pop(request_id)
                future.set_result({"error": "Dictation canceled"})
                return future
            self.jobs[request_id] = job
        self.pending.put(job)
        return future

    def cancel(self, request_id):
        with self.lock:
            job = self.jobs.get(request_id)
            if job is None:
                # Cancellation can overtake request delivery on a second socket.
                # Keep a small, short-lived tombstone for that race.
                now = time.monotonic()
                self.cancelled_ids = {key: expiry for key, expiry in self.cancelled_ids.items() if expiry > now}
                if len(self.cancelled_ids) >= 128:
                    self.cancelled_ids.pop(next(iter(self.cancelled_ids)))
                self.cancelled_ids[request_id] = now + 10
                return True
            job["cancelled"].set()
            if not job["future"].done():
                job["future"].set_result({"error": "Dictation canceled"})
        return True

    def shutdown(self):
        self.stopping.set()
        with self.lock:
            process = self.process
        if process is not None and process.is_alive():
            process.terminate()
        self.thread.join(timeout=2)

    def _finish(self, job, result):
        # Release the audio as soon as its request is settled.
        job["pcm"] = None
        with self.lock:
            self.jobs.pop(job["request_id"], None)
            if not job["future"].done():
                job["future"].set_result(result)

    def _run(self):
        global is_engine_ready, engine_load_error, engine_message, active_model
        while not self.stopping.is_set():
            with engine_lock:
                is_engine_ready = False
                engine_load_error = None
                engine_message = "Loading the local speech model…"
                active_model = None
            parent_pipe, child_pipe = self.context.Pipe()
            process = self.context.Process(target=inference_process, args=(child_pipe,), daemon=True)
            try:
                process.start()
            except Exception as error:
                with engine_lock:
                    engine_load_error = f"Could not start the local speech worker: {error}"
                parent_pipe.close()
                child_pipe.close()
                if self.stopping.wait(1):
                    break
                continue
            child_pipe.close()
            with self.lock:
                self.process = process
            active_job = None
            try:
                while not self.stopping.is_set() and process.is_alive():
                    if active_job is not None and active_job["cancelled"].is_set():
                        # The inference call is synchronous and cannot be interrupted in
                        # its thread. Reap the owned child and warm a fresh one.
                        break
                    try:
                        if parent_pipe.poll(0.05):
                            message = parent_pipe.recv()
                            if message.get("kind") == "status":
                                status = message["status"]
                                with engine_lock:
                                    is_engine_ready = status["status"] == "ready"
                                    engine_load_error = status["message"] if status["status"] == "unavailable" else None
                                    engine_message = status["message"]
                                    active_model = status["model"]
                            elif message.get("kind") == "result" and active_job is not None:
                                self._finish(active_job, message["result"])
                                active_job = None
                            message = None
                    except (EOFError, BrokenPipeError, OSError):
                        break
                    if active_job is None:
                        try:
                            job = self.pending.get_nowait()
                        except queue.Empty:
                            continue
                        if job["cancelled"].is_set():
                            self._finish(job, {"error": "Dictation canceled"})
                            continue
                        with engine_lock:
                            ready = is_engine_ready
                            unavailable = engine_load_error
                        if unavailable:
                            self._finish(job, {"error": unavailable})
                        elif not ready:
                            self.pending.put(job)
                        else:
                            try:
                                parent_pipe.send({
                                    "action": "transcribe", "request_id": job["request_id"],
                                    "pcm": job["pcm"], "vocabulary": job["vocabulary"], "style": job["style"],
                                    "context": job.get("context"),
                                })
                                active_job, job = job, None
                            except (BrokenPipeError, OSError):
                                self.pending.put(job)
                                break
            finally:
                if process.is_alive():
                    process.terminate()
                process.join(timeout=2)
                if process.is_alive():
                    process.kill()
                    process.join(timeout=2)
                parent_pipe.close()
                with self.lock:
                    if self.process is process:
                        self.process = None
                if active_job is not None:
                    self._finish(active_job, {"error": "Dictation canceled" if active_job["cancelled"].is_set()
                                             else "The local speech worker stopped unexpectedly"})
            if not self.stopping.is_set():
                self.stopping.wait(0.1)


def cleanup_socket():
    """Never unlink a replacement server's socket during this daemon's exit."""
    global bound_socket_identity
    if bound_socket_identity is None:
        return
    try:
        current = os.lstat(SOCKET_PATH)
        if (current.st_dev, current.st_ino) == bound_socket_identity:
            os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass
    bound_socket_identity = None


def remove_stale_socket():
    """Called only while holding the launch lock; reject a live listener."""
    try:
        before = os.lstat(SOCKET_PATH)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(before.st_mode):
        raise RuntimeError("The local speech socket path is occupied by another file")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(0.2)
        probe.connect(SOCKET_PATH)
        raise RuntimeError("Another local speech daemon is already running")
    except (ConnectionRefusedError, FileNotFoundError):
        pass
    finally:
        probe.close()
    try:
        current = os.lstat(SOCKET_PATH)
        if (current.st_dev, current.st_ino) == (before.st_dev, before.st_ino):
            os.unlink(SOCKET_PATH)
    except FileNotFoundError:
        pass


def read_request_audio(conn, req, already_read):
    """Read the PCM16 body that follows a transcription header, into memory only."""
    size = req.get("audio_bytes")
    if (not isinstance(size, int) or isinstance(size, bool) or size <= 0
            or size > MAX_AUDIO_BYTES or size % 2):
        raise ValueError("A transcription needs 16 kHz mono PCM16 audio of at most one hour")
    if len(already_read) > size:
        raise ValueError("The transcription request has more audio than it declared")
    return already_read + receive_exact(conn, size - len(already_read))


def handle_connection(conn, worker, fast_worker=None):
    try:
        conn.settimeout(5)
        data = b""
        while b"\n" not in data:
            # Streaming clients wait for the begin acknowledgement before sending
            # PCM. A transcription body may follow its header at once; any bytes
            # read past the newline belong to that body.
            chunk = conn.recv(4096)
            if not chunk:
                break
            data += chunk
            if b"\n" not in data and len(data) > MAX_REQUEST_BYTES:
                raise ValueError("Daemon request is too large")
        if not data.strip():
            return
        header, _, body = data.partition(b"\n")
        req = json.loads(header)
        action = req.get("action", "")
        if action == "ping":
            response = engine_status()
            if req.get("engine") == "fast" and fast_worker is not None:
                fast_worker.prepare()
                response.update(fast_worker.status())
        elif req.get("protocol_version") != PROTOCOL_VERSION:
            response = {"error": "Restart Press To Write to update the local speech connection"}
        elif action == "transcribe":
            request_id = req.get("request_id")
            if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", request_id):
                raise ValueError("A valid transcription request ID is required")
            pcm = read_request_audio(conn, req, body)
            # Ping and cancel never wait behind the single MLX worker.
            response = worker.submit(
                request_id, pcm, req.get("vocabulary", []), req.get("style", "natural"),
                context=req.get("context")
            ).result()
        elif action == "cancel":
            response = {"success": True, "cancelled": worker.cancel(req.get("request_id"))}
            if fast_worker is not None:
                fast_worker.cancel(req.get("request_id"))
        elif action == "stream" and fast_worker is not None:
            request_id = req.get("request_id")
            if not isinstance(request_id, str) or not re.fullmatch(r"[0-9a-fA-F-]{36}", request_id):
                raise ValueError("A valid streaming request ID is required")
            def acknowledge(result):
                result["protocol_version"] = PROTOCOL_VERSION
                conn.sendall((json.dumps(result) + "\n").encode("utf-8"))
            response = fast_worker.stream(conn, request_id, req.get("vocabulary", []), acknowledge)
        elif action == "shutdown":
            if req.get("expected_sha256") != SCRIPT_SHA256:
                response = {"error": "The speech daemon changed; shutdown was refused"}
            else:
                response = {"success": True}
                server_stop.set()
        else:
            response = {"error": f"Unknown action: {action}"}
        response["protocol_version"] = PROTOCOL_VERSION
        conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
    except (BrokenPipeError, ConnectionResetError, TimeoutError):
        pass
    except Exception as error:
        try:
            conn.sendall((json.dumps({"error": str(error), "protocol_version": PROTOCOL_VERSION}) + "\n").encode("utf-8"))
        except OSError:
            pass
    finally:
        conn.close()


def start_parent_watchdog():
    parent_pid_str = os.environ.get("PRESSTOWRITE_PARENT_PID")
    if not parent_pid_str:
        return
    try:
        parent_pid = int(parent_pid_str)
        if parent_pid <= 1:
            return
    except ValueError:
        return

    def _watch():
        while not server_stop.is_set():
            time.sleep(1.0)
            try:
                os.kill(parent_pid, 0)
            except OSError as err:
                if err.errno == errno.ESRCH:
                    print(f"[Press To Write Daemon] Parent process {parent_pid} exited. Stopping daemon.")
                    server_stop.set()
                    time.sleep(0.5)
                    os._exit(0)

    t = threading.Thread(target=_watch, daemon=True, name="ParentWatchdog")
    t.start()


def run_server():
    global bound_socket_identity
    lock_file = open(SOCKET_PATH + ".lock", "a+b")
    fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    remove_stale_socket()
    server_stop.clear()
    start_parent_watchdog()
    signal.signal(signal.SIGINT, lambda s, f: sys.exit(0))
    signal.signal(signal.SIGTERM, lambda s, f: sys.exit(0))
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(SOCKET_PATH)
    bound = os.lstat(SOCKET_PATH)
    bound_socket_identity = (bound.st_dev, bound.st_ino)
    server.listen(16)
    server.settimeout(0.5)
    os.chmod(SOCKET_PATH, 0o600)
    print(f"[Press To Write Daemon] Offline socket initialized at {SOCKET_PATH}")
    worker = IsolatedInferenceWorker()
    fast_worker = FastInferenceWorker()
    try:
        while not server_stop.is_set():
            try:
                conn, _ = server.accept()
            except socket.timeout:
                continue
            threading.Thread(target=handle_connection, args=(conn, worker, fast_worker), daemon=True).start()
    finally:
        server.close()
        cleanup_socket()
        worker.shutdown()
        fast_worker.shutdown()
        lock_file.close()


if __name__ == "__main__":
    sys.addaudithook(deny_network_access)
    run_server()
