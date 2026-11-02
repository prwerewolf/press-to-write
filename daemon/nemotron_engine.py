"""Optional offline Nemotron English/Metal worker, using NeMo-Speech's C ABI.

The supervisor holds no model. Its owned child keeps Metal and the model warm;
canceling a stream can terminate that child without blocking ping or Whisper.
"""

import ctypes as C
import hashlib
import multiprocessing
import os
from pathlib import Path
import socket
import struct
import sys
import threading
import time
import unicodedata

from gguf_metadata import embedded_tokenizer

SDK_VERSION = "0.2.0"
SDK_FOLDER = "nemo-speech-0.2.0-macos-aarch64-metal"
SDK_SHA256 = "5cb02ba7c04f0b5585ce5cde9c830be5f0b7dfb4c83083c500109c381b4f2da9"
MODEL_REVISION = "ebe59e5a817142986528bbbee5dba8db7b38ed50"
MODEL_FILENAME = "nemotron-speech-streaming-en-0.6b.q8_0.gguf"
MODEL_SHA256 = "d9a01898d2a611c8764e23a1c2f45e70bbd5a425dc4de93692ac951dd603812d"
TOKENIZER_SHA256 = "07d4e5a63840a53ab2d4d106d2874768143fb3fbdd47938b3910d2da05bfb0a9"
REPAIRED_SHA256 = "926495522ccd2626d8665283b4c9225f704ed2b45e82158984d1823f7e528b52"
MODEL_LABEL = "Nemotron English · Metal"
MAX_PCM_BYTES = 32000  # one second of mono 16 kHz PCM16 per frame


def install_root():
    return Path(os.environ.get("PRESSTOWRITE_FAST_DIR", str(
        Path.home() / "Library/Application Support/Press To Write/fast"
    ))).expanduser()


def local_files(root=None):
    root = install_root() if root is None else Path(root)
    library = root / SDK_FOLDER / "lib/libnemo_speech_asr_c.dylib"
    model = root / "nemotron-en-boosted.gguf"
    if not library.is_file() or not model.is_file():
        raise RuntimeError("Fast mode is not installed. Run make setup-fast, then select Fast again.")
    tokenizer = embedded_tokenizer(model)
    if hashlib.sha256(tokenizer).hexdigest() != TOKENIZER_SHA256:
        raise RuntimeError("Fast mode's tokenizer does not match Nemotron English. Run make setup-fast.")
    return library, model


def boost_terms(vocabulary):
    if not isinstance(vocabulary, list):
        raise ValueError("Vocabulary must be a list of phrases")
    terms, seen, size = [], set(), 0
    for term in vocabulary:
        if not isinstance(term, str):
            continue
        term = unicodedata.normalize("NFKC", " ".join(term.split()))
        if not term or len(term) > 128 or "\0" in term or term.casefold() in seen:
            continue
        length = len(term.encode("utf-8"))
        if len(terms) == 256 or size + length > 8192:
            break
        terms.append(term)
        seen.add(term.casefold())
        size += length
    return terms


def deny_network(event, args):
    if event == "socket.__new__" and args[1] in (socket.AF_INET, socket.AF_INET6):
        raise OSError("Local speech recognition does not use network sockets")
    if event in ("socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr"):
        raise OSError("Local speech recognition does not use DNS")


class Backend(C.Structure):
    _fields_ = [("size", C.c_size_t), ("gpu", C.c_int32)]


class Model(C.Structure):
    _fields_ = [("size", C.c_size_t), ("path", C.c_char_p), ("name", C.c_char_p)]


class Streaming(C.Structure):
    _fields_ = [("size", C.c_size_t), ("chunk_size", C.c_float), ("left", C.c_float),
                ("right", C.c_float), ("rnnt_right_context", C.c_int32)]


class Endpointing(C.Structure):
    _fields_ = [("size", C.c_size_t), ("enable", C.c_bool), ("vad_based", C.c_bool), ("history", C.c_int32)]


class Config(C.Structure):
    _fields_ = [("size", C.c_size_t)] + [(name, C.c_void_p) for name in (
        "backend", "model", "streaming", "decoder", "vad", "endpointing", "postproc", "diar", "batching"
    )]


class SpeechContext(C.Structure):
    _fields_ = [("size", C.c_size_t), ("phrases", C.POINTER(C.c_char_p)),
                ("count", C.c_size_t), ("boost", C.c_float)]


class Options(C.Structure):
    _fields_ = [("size", C.c_size_t), ("request_id", C.c_char_p), ("language_code", C.c_char_p),
                ("interim_results", C.c_bool), ("word_offsets", C.c_bool), ("punctuation", C.c_bool),
                ("verbatim", C.c_bool), ("profanity", C.c_bool), ("history", C.c_int32),
                ("speech_contexts", C.c_void_p), ("context_count", C.c_size_t),
                ("max_alternatives", C.c_int32), ("diarization", C.c_bool), ("max_speakers", C.c_int32)]


class NemotronRecognizer:
    def __init__(self):
        import numpy as np
        self.np = np
        library, model = local_files()
        self.lib = C.CDLL(str(library))
        signatures = {
            "last_error": ([], C.c_char_p), "version": ([], C.c_char_p),
            "recognition_options_default": ([], Options),
            "create": ([C.POINTER(Config), C.POINTER(C.c_void_p)], C.c_int),
            "destroy": ([C.c_void_p], None),
            "streaming_recognize": ([C.c_void_p, C.POINTER(Options), C.POINTER(C.c_void_p)], C.c_int),
            "stream_push_f32": ([C.c_void_p, C.POINTER(C.c_float), C.c_size_t, C.c_int32], C.c_int),
            "stream_finish": ([C.c_void_p], C.c_int),
            "stream_next": ([C.c_void_p, C.POINTER(C.c_void_p)], C.c_int),
            "stream_close": ([C.c_void_p], None),
            "result_transcript": ([C.c_void_p, C.c_size_t], C.c_char_p),
            "result_destroy": ([C.c_void_p], None),
        }
        for name, (args, result) in signatures.items():
            function = getattr(self.lib, "nemo_speech_asr_" + name)
            function.argtypes, function.restype = args, result
        version = self.lib.nemo_speech_asr_version().decode()
        if version != "nemo-speech-asr " + SDK_VERSION:
            raise RuntimeError("Fast mode runtime version mismatch. Run make setup-fast.")
        backend = Backend(C.sizeof(Backend), 0)  # GPU 0 is Metal; no CPU substitution.
        model_config = Model(C.sizeof(Model), str(model).encode(), None)
        streaming = Streaming(C.sizeof(Streaming), 0.56, 0, 0, 6)
        endpoint = Endpointing(C.sizeof(Endpointing), False, False, 0)
        config = Config()
        config.size = C.sizeof(Config)
        for name, obj in (("backend", backend), ("model", model_config),
                          ("streaming", streaming), ("endpointing", endpoint)):
            setattr(config, name, C.cast(C.pointer(obj), C.c_void_p).value)
        self.recognizer, self.stream = C.c_void_p(), C.c_void_p()
        self.check(self.lib.nemo_speech_asr_create(C.byref(config), C.byref(self.recognizer)))
        # Compile kernels before reporting Ready. The same path exercises boosting.
        self.begin(["Nemotron"])
        self.push(b"\0" * 3200)
        self.finish()

    def check(self, status):
        if status:
            error = self.lib.nemo_speech_asr_last_error()
            raise RuntimeError(error.decode() if error else "The local fast engine failed")

    def begin(self, vocabulary):
        self.close_stream()
        self.text = ""
        self.options = self.lib.nemo_speech_asr_recognition_options_default()
        self.options.language_code = b"en-US"
        self.options.interim_results = True
        self.options.word_offsets = False
        self.options.diarization = False
        self.options.verbatim = True
        self.options.profanity = False
        self.options.speech_contexts = None
        self.options.context_count = 0
        terms = boost_terms(vocabulary)
        self.phrases = (C.c_char_p * len(terms))(*[term.encode("utf-8") for term in terms])
        self.context = SpeechContext(C.sizeof(SpeechContext), self.phrases, len(terms), 2.0)
        if terms:
            self.options.speech_contexts = C.cast(C.pointer(self.context), C.c_void_p).value
            self.options.context_count = 1
        self.check(self.lib.nemo_speech_asr_streaming_recognize(
            self.recognizer, C.byref(self.options), C.byref(self.stream)
        ))
        return len(terms)

    def drain(self):
        for _ in range(10000):
            result = C.c_void_p()
            self.check(self.lib.nemo_speech_asr_stream_next(self.stream, C.byref(result)))
            if not result.value:
                return
            try:
                text = self.lib.nemo_speech_asr_result_transcript(result, 0)
                if text is not None:
                    self.text = text.decode("utf-8")
            finally:
                self.lib.nemo_speech_asr_result_destroy(result)
        raise RuntimeError("The local fast engine did not finish decoding")

    def push(self, pcm):
        if not pcm or len(pcm) % 2 or len(pcm) > MAX_PCM_BYTES:
            raise ValueError("Invalid 16 kHz mono PCM16 frame")
        samples = self.np.frombuffer(pcm, dtype="<i2").astype(self.np.float32) / 32768.0
        self.check(self.lib.nemo_speech_asr_stream_push_f32(
            self.stream, samples.ctypes.data_as(C.POINTER(C.c_float)), len(samples), 16000
        ))
        self.drain()

    def finish(self):
        try:
            self.check(self.lib.nemo_speech_asr_stream_finish(self.stream))
            self.drain()
            return self.text
        finally:
            # The worker keeps no transcript once the dictation is finished.
            self.text = ""
            self.close_stream()

    def close_stream(self):
        if self.stream.value:
            self.lib.nemo_speech_asr_stream_close(self.stream)
            self.stream = C.c_void_p()

    def close(self):
        self.close_stream()
        if self.recognizer.value:
            self.lib.nemo_speech_asr_destroy(self.recognizer)
            self.recognizer = C.c_void_p()


def fast_process(pipe):
    sys.addaudithook(deny_network)
    engine = None
    try:
        engine = NemotronRecognizer()
        pipe.send({"ready": True})
        while True:
            request = pipe.recv()
            action = request["action"]
            if action == "begin":
                result = {"vocabulary_count": engine.begin(request.get("vocabulary", []))}
            elif action == "audio":
                engine.push(request["pcm"])
                result = {"success": True}
            elif action == "finish":
                result = {"text": engine.finish()}
            else:
                raise ValueError("Unknown streaming command")
            pipe.send(result)
            request = result = None
    except (EOFError, BrokenPipeError):
        pass
    except Exception as error:
        try:
            pipe.send({"error": str(error)})
        except (BrokenPipeError, OSError):
            pass
    finally:
        if engine:
            engine.close()
        pipe.close()


def receive_exact(conn, size):
    data = bytearray()
    while len(data) < size:
        block = conn.recv(size - len(data))
        if not block:
            raise ConnectionError("The local audio stream disconnected")
        data.extend(block)
    return bytes(data)


class FastInferenceWorker:
    def __init__(self, context=None):
        self.context = context or multiprocessing.get_context("spawn")
        self.lock, self.session_lock = threading.RLock(), threading.Lock()
        self.process, self.pipe, self.active_id = None, None, None
        self.phase, self.message = "unavailable", "Fast mode has not been loaded"
        self.cancelled_ids = {}
        self.stopping = False

    def status(self):
        with self.lock:
            if self.phase == "ready" and (not self.process or not self.process.is_alive()):
                self.phase, self.message = "unavailable", "Fast mode stopped. Select Fast again to reload it."
            return {"status": self.phase, "message": self.message, "model": MODEL_LABEL}

    def prepare(self):
        with self.lock:
            if self.stopping or self.phase in ("ready", "loading"):
                return
            try:
                local_files()
            except (OSError, ValueError, RuntimeError) as error:
                self.phase, self.message = "unavailable", str(error)
                return
            self.phase, self.message = "loading", "Loading Nemotron English on Metal…"
            threading.Thread(target=self._warm, daemon=True, name="fast-warmup").start()

    def _warm(self):
        parent, child = self.context.Pipe()
        process = self.context.Process(target=fast_process, args=(child,), daemon=True)
        try:
            with self.lock:
                if self.stopping:
                    return
                process.start()
                self.process, self.pipe = process, parent
            child.close()
            if not parent.poll(90):
                raise RuntimeError("Fast mode warmup timed out. Select Accuracy or try Fast again.")
            result = parent.recv()
            if result.get("error") or not result.get("ready"):
                raise RuntimeError(result.get("error", "Fast mode could not load"))
            with self.lock:
                if self.process is process and not self.stopping:
                    self.phase, self.message = "ready", "Nemotron English is ready on Metal"
        except (OSError, EOFError, RuntimeError) as error:
            self._stop_child(process, str(error))
        finally:
            child.close()
            if self.process is not process:
                parent.close()

    def _stop_child(self, process, message):
        with self.lock:
            if self.process is process:
                self.process, self.pipe = None, None
                self.phase, self.message = "unavailable", message
            if process and process.is_alive():
                process.terminate()
        if process:
            process.join(timeout=2)
            if process.is_alive():
                process.kill()
                process.join(timeout=2)

    def cancel(self, request_id):
        with self.lock:
            now = time.monotonic()
            self.cancelled_ids = {key: expiry for key, expiry in self.cancelled_ids.items() if expiry > now}
            if len(self.cancelled_ids) >= 128:
                self.cancelled_ids.pop(next(iter(self.cancelled_ids)))
            self.cancelled_ids[request_id] = now + 10
            process = self.process if self.active_id == request_id else None
        if process:
            self._stop_child(process, "Fast dictation canceled. Reloading on the next status check…")
        return True

    def _call(self, pipe, request):
        pipe.send(request)
        if not pipe.poll(30):
            raise RuntimeError("Fast mode timed out. Select Accuracy or reload Fast.")
        result = pipe.recv()
        if "error" in result:
            raise RuntimeError(result["error"])
        return result

    def stream(self, conn, request_id, vocabulary, send_response):
        if not self.session_lock.acquire(blocking=False):
            raise RuntimeError("A fast dictation is already running")
        process, pipe = None, None
        try:
            with self.lock:
                if request_id in self.cancelled_ids:
                    raise RuntimeError("Dictation canceled")
                if self.status()["status"] != "ready":
                    raise RuntimeError(self.message)
                process, pipe, self.active_id = self.process, self.pipe, request_id
            send_response(self._call(pipe, {"action": "begin", "vocabulary": vocabulary}))
            conn.settimeout(30)
            while True:
                size = struct.unpack("<I", receive_exact(conn, 4))[0]
                if size == 0:
                    return self._call(pipe, {"action": "finish"})
                if size > MAX_PCM_BYTES or size % 2:
                    raise ValueError("Invalid streaming audio frame size")
                self._call(pipe, {"action": "audio", "pcm": receive_exact(conn, size)})
        except Exception:
            if process:
                self._stop_child(process, "Fast audio stream stopped. Select Fast again to reload it.")
            raise
        finally:
            with self.lock:
                if self.active_id == request_id:
                    self.active_id = None
            if pipe and self.pipe is not pipe:
                pipe.close()
            self.session_lock.release()

    def shutdown(self):
        with self.lock:
            self.stopping = True
            process, pipe = self.process, self.pipe
        self._stop_child(process, "Fast mode stopped")
        if pipe:
            pipe.close()
