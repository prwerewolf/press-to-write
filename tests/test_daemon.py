"""Daemon regressions; run with: python3 -B -m unittest discover -s tests -p test_daemon.py"""

import importlib.util
import json
import os
import queue
import struct
import tempfile
import threading
import types
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import unittest
from unittest import mock


DAEMON_PATH = Path(__file__).resolve().parents[1] / "daemon" / "whisper_daemon.py"
spec = importlib.util.spec_from_file_location("whisper_daemon", DAEMON_PATH)
daemon = importlib.util.module_from_spec(spec)
spec.loader.exec_module(daemon)

# Two synthetic PCM16 samples; dictation audio reaches the daemon only as bytes.
SYNTHETIC_PCM = b"\x01\x00\x02\x00"


class RepetitionCleanupTests(unittest.TestCase):
    def test_preserves_partial_word_matches(self):
        examples = [
            "Do you do your homework?",
            "Can you can your own tomatoes?",
            "First undo it, do it again.",
            "Forecast. Cast.",
            "play-play. play.",
            "We’ll go ll go home.",
            "go now go now's turn",
            "go now go now’s turn",
            "go now go now-go later",
        ]
        for text in examples:
            with self.subTest(text=text):
                self.assertEqual(daemon.deduplicate_repetition_loops(text), text)

    def test_preserves_words_in_whisper_segments_and_text_results(self):
        text = "Do you do your homework?"
        for result in ({"text": text}, {"segments": [{"text": text}]}):
            with self.subTest(result=result):
                self.assertEqual(daemon.clean_whisper_result(result), text)

    def test_still_collapses_complete_repetition_loops(self):
        examples = {
            "Hello world, hello world, hello world.": "Hello world.",
            "Don't stop don't stop.": "Don't stop.",
            "Repeat this. Repeat this. Repeat this.": "Repeat this.",
        }
        for text, expected in examples.items():
            with self.subTest(text=text):
                self.assertEqual(daemon.deduplicate_repetition_loops(text), expected)


class OfflineModelTests(unittest.TestCase):
    def make_model(self, folder):
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "config.json").write_text("{}")
        (folder / "weights.safetensors").write_bytes(b"cached weights")
        return folder

    def test_offline_environment_is_enforced(self):
        for key in ("HF_HUB_OFFLINE", "TRANSFORMERS_OFFLINE", "HF_HUB_DISABLE_TELEMETRY"):
            self.assertEqual(os.environ[key], "1")

    def test_network_guard_blocks_network_sockets_and_dns(self):
        for family in (daemon.socket.AF_INET, daemon.socket.AF_INET6):
            with self.assertRaisesRegex(OSError, "offline"):
                daemon.deny_network_access("socket.__new__", (None, family, 1, 0))
        for event in ("socket.getaddrinfo", "socket.gethostbyname", "socket.gethostbyaddr"):
            with self.assertRaisesRegex(OSError, "offline"):
                daemon.deny_network_access(event, ())
        daemon.deny_network_access("socket.__new__", (None, daemon.socket.AF_UNIX, 1, 0))

    def test_missing_model_never_downloads(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"HF_HUB_CACHE": temporary}, clear=True):
            with self.assertRaisesRegex(RuntimeError, "No model will be downloaded"):
                daemon.local_model_candidates()

    def test_existing_cache_is_resolved_to_local_folder(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"HF_HUB_CACHE": temporary}, clear=True):
            repository = Path(temporary) / "models--mlx-community--whisper-large-v3-turbo"
            snapshot = self.make_model(repository / "snapshots" / "local-revision")
            (repository / "refs").mkdir()
            (repository / "refs" / "main").write_text("local-revision")
            self.assertEqual(daemon.local_model_candidates(), [(daemon.DEFAULT_MODEL, str(snapshot.resolve()))])

    def test_incomplete_primary_uses_only_downloaded_fallback(self):
        with tempfile.TemporaryDirectory() as temporary, \
                mock.patch.dict(os.environ, {"HF_HUB_CACHE": temporary}, clear=True):
            incomplete = Path(temporary) / "models--mlx-community--whisper-large-v3-turbo" / "snapshots" / "partial"
            incomplete.mkdir(parents=True)
            (incomplete / "config.json").write_text("{}")
            fallback = self.make_model(Path(temporary) / "models--mlx-community--whisper-base.en" / "snapshots" / "complete")
            self.assertEqual(daemon.local_model_candidates(), [(daemon.FALLBACK_MODEL, str(fallback.resolve()))])

    def test_explicit_local_model_never_falls_back_to_repository_name(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = self.make_model(Path(temporary) / "my-model")
            with mock.patch.dict(os.environ, {"PRESSTOWRITE_MODEL_DIR": str(model)}):
                self.assertEqual(daemon.local_model_candidates(), [("my-model", str(model.resolve()))])
            with mock.patch.dict(os.environ, {"PRESSTOWRITE_MODEL_DIR": str(model / "missing")}):
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    daemon.local_model_candidates()

    def test_empty_weights_and_broken_symlinks_are_not_complete(self):
        with tempfile.TemporaryDirectory() as temporary:
            model = self.make_model(Path(temporary) / "model")
            (model / "weights.safetensors").write_bytes(b"")
            self.assertFalse(daemon.complete_model_folder(model))
            (model / "weights.safetensors").unlink()
            (model / "weights.safetensors").symlink_to(model / "missing")
            self.assertFalse(daemon.complete_model_folder(model))


class EngineTests(unittest.TestCase):
    def setUp(self):
        self.patches = mock.patch.multiple(
            daemon,
            active_model=None,
            active_model_path=None,
            mlx_whisper=None,
            prompt_tokenizer=None,
            prompt_token_budget=223,
            is_engine_ready=False,
            engine_load_error=None,
            engine_message="Loading the local speech model…",
        )
        self.patches.start()
        self.addCleanup(self.patches.stop)
        self.numpy = types.SimpleNamespace(zeros=mock.Mock(return_value="synthetic silence"), float32="float32")
        self.engine = types.SimpleNamespace(transcribe=mock.Mock(return_value={"text": ""}))
        self.tokenizer = types.SimpleNamespace(encode=lambda text: list(text))
        loaded_model = types.SimpleNamespace(
            is_multilingual=True, num_languages=100, dims=types.SimpleNamespace(n_text_ctx=448)
        )
        self.modules = mock.patch.dict("sys.modules", {
            "numpy": self.numpy, "mlx_whisper": self.engine,
            "mlx_whisper.transcribe": types.SimpleNamespace(ModelHolder=types.SimpleNamespace(model=loaded_model)),
            "mlx_whisper.tokenizer": types.SimpleNamespace(get_tokenizer=lambda *args, **kwargs: self.tokenizer),
        })
        self.modules.start()
        self.addCleanup(self.modules.stop)

    def warm_engine(self):
        with mock.patch.object(daemon, "local_model_candidates", return_value=[("cached-model", "/local/model")]), \
                mock.patch.object(daemon, "print", create=True):
            daemon.load_engine_background()

    def test_only_ready_after_actual_model_load_and_warmup(self):
        def while_warming(*args, **kwargs):
            status = daemon.engine_status()
            self.assertEqual(status["status"], "loading")
            self.assertEqual(status["model"], "cached-model")
            self.assertIn("Warming", status["message"])
            self.assertEqual(args[0], "synthetic silence")
            self.assertEqual(kwargs["path_or_hf_repo"], "/local/model")
            self.assertEqual(kwargs["sample_len"], 1)
            return {"text": ""}
        self.engine.transcribe.side_effect = while_warming
        self.warm_engine()
        self.engine.transcribe.assert_called_once()
        self.assertEqual(daemon.engine_status()["status"], "ready")
        self.assertTrue(daemon.engine_status()["offline"])
        self.assertEqual(daemon.active_model_path, "/local/model")

    def test_missing_model_reports_unavailable_without_loading_or_network(self):
        with mock.patch.object(daemon, "local_model_candidates", side_effect=RuntimeError("No downloaded model")), \
                mock.patch.object(daemon, "print", create=True):
            daemon.load_engine_background()
        self.engine.transcribe.assert_not_called()
        self.assertEqual(daemon.engine_status()["status"], "unavailable")
        self.assertIn("No downloaded model", daemon.engine_status()["message"])

    def test_failed_warmup_never_claims_ready(self):
        self.engine.transcribe.side_effect = RuntimeError("GPU load failed")
        self.warm_engine()
        self.assertEqual(daemon.engine_status()["status"], "unavailable")
        self.assertIn("GPU load failed", daemon.engine_status()["message"])

    def test_failed_primary_only_tries_existing_local_fallback(self):
        self.engine.transcribe.side_effect = [RuntimeError("corrupt primary"), {"text": ""}]
        with mock.patch.object(daemon, "local_model_candidates", return_value=[
            ("primary", "/local/primary"), ("fallback", "/local/fallback")
        ]), mock.patch.object(daemon, "print", create=True):
            daemon.load_engine_background()
        self.assertEqual(daemon.engine_status()["status"], "ready")
        self.assertEqual(daemon.active_model_path, "/local/fallback")
        self.assertEqual([call.kwargs["path_or_hf_repo"] for call in self.engine.transcribe.call_args_list], ["/local/primary", "/local/fallback"])

    def transcribe(self, text, vocabulary=None, style="natural", error=None, context=None):
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        self.engine.transcribe.return_value = {
            "text": text,
            "segments": [{"text": "must never replace raw output", "compression_ratio": 10}],
        }
        self.engine.transcribe.side_effect = error
        with mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                mock.patch.object(daemon, "pcm16_samples", return_value="synthetic samples"):
            result = daemon.transcribe_pcm(SYNTHETIC_PCM, vocabulary, style, context=context)
        return result

    def test_vocabulary_is_sent_to_recognizer_as_initial_prompt(self):
        result = self.transcribe("Lumora", [" Lumora ", "MLX", "lumora", "", "Sample\nUser"])
        self.assertTrue(result["success"])
        self.assertEqual(self.engine.transcribe.call_args.kwargs["initial_prompt"], "Lumora, MLX, Sample User")
        self.assertEqual(self.engine.transcribe.call_args.kwargs["path_or_hf_repo"], "/local/model")

    def test_empty_vocabulary_does_not_add_a_prompt(self):
        self.transcribe("Hello", [])
        self.assertIsNone(self.engine.transcribe.call_args.kwargs["initial_prompt"])

    def test_context_and_vocabulary_combined_in_initial_prompt(self):
        result = self.transcribe("Hello", ["Lumora", "Swift"], context="We are testing this with")
        self.assertTrue(result["success"])
        self.assertEqual(self.engine.transcribe.call_args.kwargs["initial_prompt"], "We are testing this with Lumora, Swift")

    def test_context_alone_used_as_initial_prompt(self):
        result = self.transcribe("Hello", [], context="Continuing this thought,")
        self.assertTrue(result["success"])
        self.assertEqual(self.engine.transcribe.call_args.kwargs["initial_prompt"], "Continuing this thought,")

    def test_in_memory_pcm16_is_scaled_and_passed_as_samples(self):
        class FakeSamples:
            def __init__(self, values):
                self.values = values

            def astype(self, dtype):
                if dtype != "float32":
                    raise AssertionError(f"Expected float32, got {dtype}")
                return self

            def __truediv__(self, divisor):
                return [sample / divisor for sample in self.values]

        samples = (-32768, -16384, 0, 16384, 32767)
        pcm = struct.pack("<5h", *samples)
        self.numpy.frombuffer = mock.Mock(
            side_effect=lambda data, dtype: FakeSamples(struct.unpack("<5h", data))
        )
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        with mock.patch.object(daemon, "complete_model_folder", return_value=True):
            result = daemon.transcribe_pcm(pcm)

        self.assertTrue(result["success"])
        self.numpy.frombuffer.assert_called_once_with(pcm, dtype="<i2")
        decoded = self.engine.transcribe.call_args.args[0]
        self.assertNotIsInstance(decoded, str)
        self.assertEqual(decoded, [-1.0, -0.5, 0.0, 0.5, 32767 / 32768.0])

    def test_raw_and_other_styles_preserve_recognizer_text_for_single_swift_cleanup(self):
        original = "  um go now go now.  \n"
        for style in ("raw", "natural", "professional", "code"):
            with self.subTest(style=style):
                result = self.transcribe(original, style=style)
                self.assertEqual(result["text"], original)

    def test_inference_failure_never_downloads_a_fallback(self):
        result = self.transcribe("", error=RuntimeError("inference failed"))
        self.assertEqual(result["error"], "inference failed")
        self.engine.transcribe.assert_called_once()

    def test_missing_cached_files_never_enter_model_loader(self):
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        with mock.patch.object(daemon, "complete_model_folder", return_value=False):
            result = daemon.transcribe_pcm(SYNTHETIC_PCM)
        self.assertIn("downloaded speech model is missing", result["error"])
        self.engine.transcribe.assert_not_called()

    def test_readiness_ping_does_not_wait_for_inference_lock(self):
        self.warm_engine()
        with daemon.inference_lock:
            self.assertEqual(daemon.engine_status()["status"], "ready")

    def test_warmup_and_inference_use_same_serial_worker(self):
        threads = []
        self.engine.transcribe.side_effect = lambda *args, **kwargs: threads.append(threading.get_ident()) or {"text": "hello"}
        with mock.patch.object(daemon, "local_model_candidates", return_value=[("cached-model", "/local/model")]), \
                mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                mock.patch.object(daemon, "pcm16_samples", return_value="synthetic samples"), \
                mock.patch.object(daemon, "print", create=True), \
                ThreadPoolExecutor(max_workers=1) as worker:
            worker.submit(daemon.load_engine_background).result(timeout=2)
            result = worker.submit(daemon.transcribe_pcm, SYNTHETIC_PCM).result(timeout=2)
        self.assertTrue(result["success"])
        self.assertEqual(len(threads), 2)
        self.assertEqual(len(set(threads)), 1)
        self.assertNotEqual(threads[0], threading.get_ident())

    def test_prompt_is_bounded_and_rejects_non_text(self):
        self.warm_engine()
        prompt = daemon.build_initial_prompt(["word" + str(n) for n in range(1000)])
        self.assertLessEqual(len(self.tokenizer.encode(" " + prompt)), 223)
        with self.assertRaises(ValueError):
            daemon.vocabulary_prompt("a string is not a vocabulary list")
        with self.assertRaises(ValueError):
            daemon.vocabulary_prompt([1])

    def test_vocabulary_echo_retries_same_samples_without_any_prompt(self):
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        self.engine.transcribe.side_effect = [
            {"text": "Lumora, Zephira, Acmetron"}, {"text": "Send the proposal to Lumora."}
        ]
        with mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                mock.patch.object(daemon, "pcm16_samples", return_value="same samples"):
            result = daemon.transcribe_pcm(SYNTHETIC_PCM, ["Lumora", "Zephira", "Acmetron"], context="Earlier sentence")
        self.assertEqual(result["text"], "Send the proposal to Lumora.")
        self.assertTrue(result["vocabulary_recovery"])
        self.assertEqual(self.engine.transcribe.call_count, 2)
        self.assertIsNone(self.engine.transcribe.call_args.kwargs["initial_prompt"])
        self.assertEqual([call.args[0] for call in self.engine.transcribe.call_args_list], ["same samples"] * 2)

    def test_prompt_free_retry_preserves_intentionally_spoken_dictionary_list(self):
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        self.engine.transcribe.return_value = {"text": "Lumora, Zephira, Acmetron"}
        with mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                mock.patch.object(daemon, "pcm16_samples", return_value="samples"):
            result = daemon.transcribe_pcm(SYNTHETIC_PCM, ["Lumora", "Zephira", "Acmetron"], style="raw")
        self.assertEqual(result["text"], "Lumora, Zephira, Acmetron")
        self.assertEqual(self.engine.transcribe.call_count, 2, "Recovery must not loop")

    def test_recovery_silence_returns_no_text_and_recovery_failure_reports_error(self):
        for retry in ({"text": ""}, RuntimeError("retry failed")):
            with self.subTest(retry=retry):
                self.warm_engine()
                self.engine.transcribe.reset_mock()
                self.engine.transcribe.side_effect = [{"text": "Lumora Lumora Lumora"}, retry]
                with mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                        mock.patch.object(daemon, "pcm16_samples", return_value="samples"):
                    result = daemon.transcribe_pcm(SYNTHETIC_PCM, ["Lumora"])
                if isinstance(retry, Exception): self.assertEqual(result["error"], "retry failed")
                else: self.assertEqual(result["text"], "")
                self.assertEqual(self.engine.transcribe.call_count, 2)
                self.engine.transcribe.side_effect = None


    def test_transcription_never_opens_writes_or_removes_files(self):
        self.warm_engine()

        def refuse(*args, **kwargs):
            raise AssertionError("Dictation must stay in memory")

        with mock.patch.object(daemon, "complete_model_folder", return_value=True), \
                mock.patch.object(daemon, "pcm16_samples", return_value="synthetic samples"), \
                mock.patch("builtins.open", side_effect=refuse), \
                mock.patch.object(daemon.os, "remove", side_effect=refuse), \
                mock.patch.object(daemon.os, "unlink", side_effect=refuse), \
                mock.patch.object(daemon.os, "replace", side_effect=refuse):
            result = daemon.transcribe_pcm(SYNTHETIC_PCM, ["Lumora"], context="Earlier sentence")
        self.assertTrue(result["success"])

    def test_invalid_audio_is_rejected_before_recognition(self):
        self.warm_engine()
        self.engine.transcribe.reset_mock()
        with mock.patch.object(daemon, "complete_model_folder", return_value=True):
            for pcm in (b"", b"\x01", None, "not audio"):
                with self.subTest(pcm=pcm):
                    self.assertIn("error", daemon.transcribe_pcm(pcm))
        self.engine.transcribe.assert_not_called()


class PromptAndEchoTests(unittest.TestCase):
    def setUp(self):
        # Synthetic tokenizer with deliberately expensive Unicode characters.
        self.tokenizer = types.SimpleNamespace(encode=lambda text: [
            token for character in text for token in range(3 if ord(character) > 127 else 1)
        ])

    def test_shared_token_budget_preserves_context_and_whole_terms(self):
        prompt, terms = daemon.build_prompt_plan(
            ["Lumora", "Zephira", "Acmetron", "Überraschung"], "recent context",
            tokenizer=self.tokenizer, max_tokens=48
        )
        self.assertTrue(prompt.startswith("recent context "))
        self.assertLessEqual(len(self.tokenizer.encode(" " + prompt)), 48)
        self.assertEqual(prompt, "recent context " + ", ".join(terms))

    def test_dense_context_and_vocabulary_cannot_overflow_combined_budget(self):
        prompt, terms = daemon.build_prompt_plan(
            ["語彙" + str(n) for n in range(100)], "文脈" * 100,
            tokenizer=self.tokenizer, max_tokens=223
        )
        self.assertTrue(terms)
        self.assertLessEqual(len(self.tokenizer.encode(" " + prompt)), 223)

    def test_oversized_entry_is_skipped_instead_of_partially_spelled(self):
        prompt, terms = daemon.build_prompt_plan(
            ["x" * 101, "y" * 100, "Lumora"], tokenizer=self.tokenizer, max_tokens=24
        )
        self.assertEqual(terms, ["Lumora"])
        self.assertEqual(prompt, "Lumora")

    def test_missing_tokenizer_fails_without_an_approximate_budget(self):
        with mock.patch.object(daemon, "prompt_tokenizer", None), self.assertRaisesRegex(ValueError, "tokenizer"):
            daemon.build_initial_prompt(["Lumora"])

    def test_echo_is_prompt_shape_rather_than_vocabulary_overlap(self):
        terms = ["Lumora", "Zephira", "Acmetron", "macOS"]
        for text in ("Lumora, Zephira, Acmetron", "Zephira, Acmetron, macOS", "Lumora Lumora Lumora"):
            with self.subTest(text=text): self.assertTrue(daemon.is_vocabulary_echo(text, terms))
        for text in ("Lumora", "Lumora, Lumora", "macOS and Lumora", "Lumora, Zephira", "Lumora macOS Zephira"):
            with self.subTest(text=text): self.assertFalse(daemon.is_vocabulary_echo(text, terms))
        self.assertFalse(daemon.is_vocabulary_echo("Unsent, Dictionary, Words", terms))


class DaemonConnectionTests(unittest.TestCase):
    REQUEST_ID = "11111111-1111-4111-8111-111111111111"

    def make_connection(self, payload):
        connection = mock.Mock()
        connection.recv.return_value = payload
        return connection

    def make_stream(self, payload):
        """A connection whose reads consume one byte stream, like a real socket."""
        connection = mock.Mock()
        remaining = bytearray(payload)

        def recv(size):
            chunk = bytes(remaining[:size])
            del remaining[:size]
            return chunk

        connection.recv.side_effect = recv
        return connection

    def transcription(self, audio=SYNTHETIC_PCM, **fields):
        request = {"action": "transcribe", "protocol_version": daemon.PROTOCOL_VERSION,
                   "request_id": self.REQUEST_ID, "audio_bytes": len(audio)}
        request.update(fields)
        return self.make_stream(json.dumps(request).encode() + b"\n" + audio)

    def serve_then_ping(self, first_connection):
        healthy_connection = self.make_connection(b'{"action":"ping"}\n')
        worker = mock.Mock()
        worker.submit.return_value.result.return_value = {"text": "ok"}
        # Exercise real handlers without touching live sockets, signals, MLX or files.
        daemon.handle_connection(first_connection, worker)
        daemon.handle_connection(healthy_connection, worker)
        healthy_connection.sendall.assert_called_once()
        response = json.loads(healthy_connection.sendall.call_args.args[0])
        self.assertTrue(response["success"])
        self.assertTrue(response["offline"])
        self.assertEqual(response["protocol_version"], daemon.PROTOCOL_VERSION)
        first_connection.close.assert_called_once()
        healthy_connection.close.assert_called_once()

    def test_serves_next_client_after_response_disconnect(self):
        for error_type in (BrokenPipeError, ConnectionResetError):
            with self.subTest(error=error_type.__name__):
                connection = self.transcription()
                connection.sendall.side_effect = error_type("client disconnected")
                self.serve_then_ping(connection)

    def test_serves_next_client_after_read_disconnect(self):
        connection = self.make_connection(b"")
        connection.recv.side_effect = ConnectionResetError("client disconnected")
        self.serve_then_ping(connection)

    def test_serves_next_client_when_error_response_cannot_be_delivered(self):
        for error_type in (BrokenPipeError, ConnectionResetError, TimeoutError):
            with self.subTest(error=error_type.__name__):
                connection = self.make_connection(b"invalid JSON\n")
                connection.sendall.side_effect = error_type("client unavailable")
                self.serve_then_ping(connection)

    def test_returns_request_error_to_connected_client_and_continues(self):
        connection = self.make_connection(b"invalid JSON\n")
        self.serve_then_ping(connection)
        connection.sendall.assert_called_once()
        response = json.loads(connection.sendall.call_args.args[0])
        self.assertIn("error", response)

    def test_old_client_is_refused_before_transcription(self):
        connection = self.make_connection(b'{"action":"transcribe","path":"/unused"}\n')
        worker = mock.Mock()
        daemon.handle_connection(connection, worker)
        worker.submit.assert_not_called()
        response = json.loads(connection.sendall.call_args.args[0])
        self.assertIn("Restart Press To Write", response["error"])

    def test_ping_never_queues_behind_inference(self):
        connection = self.make_connection(b'{"action":"ping"}\n')
        worker = mock.Mock()
        worker.submit.side_effect = AssertionError("Ping may not use the inference worker")
        daemon.handle_connection(connection, worker)
        self.assertTrue(json.loads(connection.sendall.call_args.args[0])["success"])

    def test_transcription_forwards_style_and_vocabulary(self):
        connection = self.transcription(vocabulary=["Lumora"], style="raw")
        worker = mock.Mock()
        worker.submit.return_value.result.return_value = {"text": " Lumora "}
        daemon.handle_connection(connection, worker)
        worker.submit.assert_called_once_with(self.REQUEST_ID, SYNTHETIC_PCM, ["Lumora"], "raw", context=None)
        self.assertEqual(json.loads(connection.sendall.call_args.args[0])["text"], " Lumora ")

    def test_transcription_forwards_context(self):
        connection = self.transcription(vocabulary=["Lumora"], style="natural", context="Preceding text")
        worker = mock.Mock()
        worker.submit.return_value.result.return_value = {"text": " Result "}
        daemon.handle_connection(connection, worker)
        worker.submit.assert_called_once_with(self.REQUEST_ID, SYNTHETIC_PCM, ["Lumora"], "natural", context="Preceding text")
        self.assertEqual(json.loads(connection.sendall.call_args.args[0])["text"], " Result ")

    def test_audio_body_is_read_completely_into_memory(self):
        # Larger than one header read, so part arrives with the header and the rest later.
        audio = bytes(range(256)) * 64
        connection = self.transcription(audio)
        worker = mock.Mock()
        worker.submit.return_value.result.return_value = {"text": "ok"}
        daemon.handle_connection(connection, worker)
        self.assertEqual(worker.submit.call_args.args[1], audio)

    def test_missing_or_malformed_audio_is_refused_before_transcription(self):
        header = {"action": "transcribe", "protocol_version": daemon.PROTOCOL_VERSION,
                  "request_id": self.REQUEST_ID}
        cases = {
            "file path instead of audio": (dict(header, path="/tmp/speech.wav"), b""),
            "odd byte count": (dict(header, audio_bytes=3), b"\x01\x02\x03"),
            "over one hour": (dict(header, audio_bytes=daemon.MAX_AUDIO_BYTES + 2), b""),
            "more audio than declared": (dict(header, audio_bytes=2), b"\x01\x00\x02\x00"),
            "truncated audio": (dict(header, audio_bytes=8), b"\x01\x00"),
        }
        for name, (request, audio) in cases.items():
            with self.subTest(name):
                connection = self.make_stream(json.dumps(request).encode() + b"\n" + audio)
                worker = mock.Mock()
                daemon.handle_connection(connection, worker)
                worker.submit.assert_not_called()
                self.assertIn("error", json.loads(connection.sendall.call_args.args[0]))

    def test_cancel_never_queues_behind_inference(self):
        connection = self.make_connection(json.dumps({
            "action": "cancel", "protocol_version": daemon.PROTOCOL_VERSION,
            "request_id": self.REQUEST_ID,
        }).encode() + b"\n")
        worker = mock.Mock()
        worker.cancel.return_value = True
        worker.submit.side_effect = AssertionError("Cancel may not use the inference worker")
        daemon.handle_connection(connection, worker)
        worker.cancel.assert_called_once_with(self.REQUEST_ID)
        self.assertTrue(json.loads(connection.sendall.call_args.args[0])["cancelled"])

    def test_shutdown_requires_exact_script_identity(self):
        worker = mock.Mock()
        with mock.patch.object(daemon.server_stop, "set") as stop:
            for expected, succeeds in (("incorrect", False), (daemon.SCRIPT_SHA256, True)):
                connection = self.make_connection(json.dumps({
                    "action": "shutdown", "protocol_version": daemon.PROTOCOL_VERSION,
                    "expected_sha256": expected,
                }).encode() + b"\n")
                daemon.handle_connection(connection, worker)
                response = json.loads(connection.sendall.call_args.args[0])
                self.assertEqual(response.get("success", False), succeeds)
            stop.assert_called_once()


class SocketLifecycleTests(unittest.TestCase):
    def test_cleanup_does_not_unlink_replacement_socket(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "speech.sock")
            with mock.patch.object(daemon, "SOCKET_PATH", path):
                Path(path).touch()
                with mock.patch.object(daemon, "bound_socket_identity", (0, 0)):
                    daemon.cleanup_socket()
                    self.assertTrue(Path(path).exists())
                identity = os.lstat(path)
                daemon.bound_socket_identity = (identity.st_dev, identity.st_ino)
                daemon.cleanup_socket()
                self.assertFalse(Path(path).exists())

    def test_stale_socket_removed_but_live_listener_preserved(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = str(Path(temporary) / "speech.sock")
            with mock.patch.object(daemon, "SOCKET_PATH", path):
                Path(path).touch()
                fake_socket = mock.Mock()
                with mock.patch.object(daemon.stat, "S_ISSOCK", return_value=True), \
                        mock.patch.object(daemon.socket, "socket", return_value=fake_socket):
                    with self.assertRaisesRegex(RuntimeError, "already running"):
                        daemon.remove_stale_socket()
                self.assertTrue(Path(path).exists())
                fake_socket.connect.side_effect = ConnectionRefusedError()
                with mock.patch.object(daemon.stat, "S_ISSOCK", return_value=True), \
                        mock.patch.object(daemon.socket, "socket", return_value=fake_socket):
                    daemon.remove_stale_socket()
                self.assertFalse(Path(path).exists())


class IsolatedWorkerTests(unittest.TestCase):
    @staticmethod
    def wait_until(predicate, timeout=2):
        end = time.monotonic() + timeout
        while time.monotonic() < end:
            if predicate():
                return
            time.sleep(0.01)
        raise AssertionError("Timed out waiting for isolated worker state")

    def test_cancel_before_delivery_prevents_inference(self):
        with mock.patch.object(daemon.threading.Thread, "start"):
            worker = daemon.IsolatedInferenceWorker()
        request_id = str(uuid.uuid4())
        self.assertTrue(worker.cancel(request_id))
        future = worker.submit(request_id, SYNTHETIC_PCM, [], "natural")
        self.assertEqual(future.result(timeout=0.1)["error"], "Dictation canceled")
        self.assertNotIn(request_id, worker.jobs)
        worker.stopping.set()

    def test_cancel_active_inference_reaps_child_then_serves_next_request(self):
        class FakePipe:
            def __init__(self, respond):
                self.messages = queue.Queue()
                self.sent = []
                self.respond = respond

            def poll(self, timeout):
                if not self.messages.empty():
                    return True
                time.sleep(min(timeout, 0.01))
                return not self.messages.empty()

            def recv(self):
                return self.messages.get_nowait()

            def send(self, message):
                self.sent.append(message)
                if self.respond:
                    self.messages.put({"kind": "result", "request_id": message["request_id"],
                                       "result": {"success": True, "text": "next"}})

            def close(self):
                pass

        class FakeProcess:
            def __init__(self, pipe):
                self.pipe = pipe
                self.alive = False
                self.terminated = False

            def start(self):
                self.alive = True
                self.pipe.messages.put({"kind": "status", "status": {
                    "status": "ready", "message": "Ready", "model": "fake-model",
                }})

            def is_alive(self):
                return self.alive

            def terminate(self):
                self.terminated = True
                self.alive = False

            def join(self, timeout):
                pass

            def kill(self):
                self.terminate()

        class FakeContext:
            def __init__(self):
                self.processes = []

            def Pipe(self):
                self.pipe = FakePipe(respond=len(self.processes) > 0)
                return self.pipe, mock.Mock()

            def Process(self, target, args, daemon):
                process = FakeProcess(self.pipe)
                self.processes.append(process)
                return process

        context = FakeContext()
        worker = daemon.IsolatedInferenceWorker(context)
        try:
            self.wait_until(lambda: len(context.processes) == 1 and daemon.engine_status()["status"] == "ready")
            first = str(uuid.uuid4())
            future = worker.submit(first, SYNTHETIC_PCM, [], "natural")
            self.wait_until(lambda: bool(context.processes[0].pipe.sent))
            sent = context.processes[0].pipe.sent[0]
            self.assertEqual(sent["pcm"], SYNTHETIC_PCM)
            self.assertNotIn("path", sent)
            self.assertTrue(worker.cancel(first))
            self.assertEqual(future.result(timeout=0.1)["error"], "Dictation canceled")
            self.wait_until(lambda: len(context.processes) >= 2 and context.processes[0].terminated)
            self.wait_until(lambda: daemon.engine_status()["status"] == "ready")
            next_future = worker.submit(str(uuid.uuid4()), SYNTHETIC_PCM, [], "natural")
            self.assertEqual(next_future.result(timeout=2)["text"], "next")
        finally:
            worker.shutdown()

if __name__ == "__main__":
    unittest.main()
