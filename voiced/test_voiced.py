"""voiced tests: stdlib only, stub backend, run anywhere.

    python3 -m unittest voiced/test_voiced.py -v
"""

from __future__ import annotations

import io
import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
import wave

import importlib.util

os.environ["ORB_VOICE_FAKE"] = "1"
os.environ["VOICED_NO_LAUNCHD"] = "1"
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)


def _load_local(name: str):
    spec = importlib.util.spec_from_file_location(name, os.path.join(_HERE, f"{name}.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod
    spec.loader.exec_module(mod)
    return mod


worker = _load_local("worker")
pipeline = _load_local("pipeline")
voiced = _load_local("voiced")
learn = _load_local("learn")


def wav(secs: float = 1.0, amp: int = 3000, rate: int = 16000) -> bytes:
    n = int(secs * rate)
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(1)
        wf.setsampwidth(2)
        wf.setframerate(rate)
        wf.writeframes(b"".join(int(amp if i % 20 < 10 else -amp).to_bytes(2, "little", signed=True) for i in range(n)))
    return buf.getvalue()


class CountingBackend(worker.FakeBackend):
    loads = 0
    threads: set = set()

    def load(self):
        if self.loaded:  # like MlxBackend: a second load is a cache hit
            return {"load_secs": 0.0, "warmup_secs": 0.0, "cached": True}
        CountingBackend.loads += 1
        CountingBackend.threads.add(threading.get_ident())
        return super().load()

    def transcribe(self, samples, rate, language, punctuation):
        CountingBackend.threads.add(threading.get_ident())
        time.sleep(0.05)
        return super().transcribe(samples, rate, language, punctuation)


class Client:
    def __init__(self, path: str) -> None:
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.connect(path)
        self.r = self.s.makefile("rb")
        self.n = 0

    def call(self, op: str, payload: bytes = b"", **kw):
        self.n += 1
        req = {"id": self.n, "op": op, **kw}
        if payload:
            req["audio_bytes"] = len(payload)
        self.s.sendall((json.dumps(req) + "\n").encode() + payload)
        resp = json.loads(self.r.readline())
        assert resp["id"] == self.n, resp
        return resp

    def close(self):
        self.r.close()
        self.s.close()


class VoicedTest(unittest.TestCase):
    def setUp(self):
        CountingBackend.loads = 0
        CountingBackend.threads = set()
        self.dir = tempfile.mkdtemp(prefix="vd")
        self.path = os.path.join(self.dir, "s.sock")
        self.engine = voiced.Engine(CountingBackend(), unload_after=600)
        self.listener = voiced.bind_socket(self.path)
        self.t = threading.Thread(target=voiced.serve, args=(self.listener, self.engine, 3600, self.path), daemon=True)
        self.t.start()

    def tearDown(self):
        self.listener.close()

    def test_socket_is_owner_only(self):
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_hello_reports_shared(self):
        c = Client(self.path)
        r = c.call("hello")
        self.assertTrue(r["ok"])
        self.assertEqual(r["result"]["protocol"], 1)
        self.assertTrue(r["result"]["shared"])
        self.assertEqual(r["result"]["clients"], 1)
        c.close()

    def test_two_clients_share_one_model_on_one_thread(self):
        results = []

        def run(lang):
            c = Client(self.path)
            c.call("load")
            for _ in range(3):
                results.append(c.call("transcribe", wav(), language=lang))
            c.close()

        ts = [threading.Thread(target=run, args=(l,)) for l in ("en", "fr", "de")]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        self.assertEqual(len(results), 9)
        self.assertTrue(all(r["ok"] for r in results), results)
        self.assertEqual(CountingBackend.loads, 1)
        self.assertEqual(len(CountingBackend.threads), 1)

    def test_errors_keep_connection_alive(self):
        c = Client(self.path)
        r = c.call("transcribe", wav(), language="xx")
        self.assertEqual(r["error"]["code"], "unsupported_language")
        r = c.call("transcribe", b"garbage!", language="en")
        self.assertEqual(r["error"]["code"], "bad_wav")
        r = c.call("transcribe", wav(amp=0), language="en")
        self.assertEqual(r["result"]["text"], "")
        self.assertTrue(c.call("status")["ok"])
        c.close()

    def test_shutdown_and_unload_do_not_affect_other_clients(self):
        a, b = Client(self.path), Client(self.path)
        a.call("load")
        self.assertTrue(a.call("unload")["result"]["loaded"])
        self.assertTrue(a.call("shutdown")["result"]["bye"])
        r = b.call("transcribe", wav(), language="en")
        self.assertTrue(r["ok"])
        self.assertEqual(CountingBackend.loads, 1)
        b.close()

    def test_disconnect_mid_request_is_harmless(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.connect(self.path)
        body = wav()
        s.sendall((json.dumps({"id": 1, "op": "transcribe", "language": "en", "audio_bytes": len(body)}) + "\n").encode() + body)
        s.close()
        c = Client(self.path)
        self.assertTrue(c.call("transcribe", wav(), language="en")["ok"])
        c.close()

    def test_idle_unload(self):
        self.engine.unload_after = 0.01
        c = Client(self.path)
        c.call("load")
        self.assertTrue(self.engine.worker.backend.loaded)
        deadline = time.time() + 8
        while self.engine.worker.backend.loaded and time.time() < deadline:
            time.sleep(0.1)
        self.assertFalse(self.engine.worker.backend.loaded)
        self.assertTrue(c.call("transcribe", wav(), language="en")["ok"])
        c.close()

    def test_context_and_vocabulary_in_transcribe_frame(self):
        c = Client(self.path)
        r = c.call(
            "transcribe",
            wav(),
            language="en",
            context="Previously on",
            vocabulary=["Murmure", "PostgreSQL"],
        )
        self.assertTrue(r["ok"])
        self.assertIn("[fake en]", r["result"]["text"])
        # Invalid vocabulary type is rejected cleanly without dropping connection
        bad = c.call("transcribe", wav(), language="en", vocabulary="not-a-list")
        self.assertFalse(bad["ok"])
        self.assertEqual(bad["error"]["code"], "bad_request")
        self.assertTrue(c.call("status")["ok"])
        c.close()


class PipelineAndLearnTest(unittest.TestCase):
    def setUp(self):
        self.home = tempfile.mkdtemp(prefix="vh")
        os.environ["VOICED_HOME"] = self.home

    def tearDown(self):
        os.environ.pop("VOICED_RETAIN_AUDIO", None)
        os.environ.pop("VOICED_HOME", None)

    def test_disfluency_corrections_and_vocabulary_snapping(self):
        import pipeline as vp

        vocab = ["Murmure", "PostgreSQL", "Grafana", "Kalshi", "Hetzner"]
        rules = {"post grass": "PostgreSQL", "graph ana": "Grafana"}
        raw = "Um, ship the post grass migration, uh fix the graph Ana alert, and rerun the kalchi backtest on Hertzner with murmure."
        cleaned = vp.postprocess_transcript(
            raw,
            language="en",
            vocabulary=vocab,
            corrections=rules,
            remove_disfluencies=True,
        )
        self.assertEqual(
            cleaned,
            "Ship the PostgreSQL migration, fix the Grafana alert, and rerun the Kalshi backtest on Hetzner with Murmure.",
        )

    def test_cross_chunk_context_casing(self):
        import pipeline as vp

        # Comma at end of previous chunk lowercases common start word of next chunk
        out = vp.postprocess_transcript(
            "The second part continues.",
            language="en",
            context="When we spoke first,",
            vocabulary=["Murmure"],
        )
        self.assertEqual(out, "the second part continues.")

        # Vocabulary term at start of next chunk preserves capitalization
        out_vocab = vp.postprocess_transcript(
            "Murmure runs locally.",
            language="en",
            context="Because",
            vocabulary=["Murmure"],
        )
        self.assertEqual(out_vocab, "Murmure runs locally.")

    def test_retention_and_learn_eval_audit_suggest(self):
        import learn
        import pipeline as vp

        with open(os.path.join(self.home, "vocabulary.txt"), "w", encoding="utf-8") as vf:
            vf.write("# Custom terms\nPostgreSQL\nKalshi\nHetzner\n")
        with open(os.path.join(self.home, "corrections.json"), "w", encoding="utf-8") as cf:
            json.dump({"post grass": "PostgreSQL", "no": "yes"}, cf)

        # Default: VOICED_RETAIN_AUDIO is unset -> nothing retained
        self.assertIsNone(
            vp.retain_recording_if_enabled(wav(), "raw", "processed", "en", 1.0, 0.05, home=self.home)
        )

        # Opt-in retention enabled
        os.environ["VOICED_RETAIN_AUDIO"] = "1"
        stamp = vp.retain_recording_if_enabled(
            wav(),
            "Ship the post grass job on Hertzner with kalchi and SandboxedSh.",
            "Ship the PostgreSQL job on Hetzner with Kalshi and SandboxedSh.",
            "en",
            1.0,
            0.05,
            home=self.home,
        )
        self.assertIsNotNone(stamp)

        # Annotate the clip with ground-truth reference & simulated raw decode to test `learn.py eval`
        meta_path = os.path.join(self.home, "recordings", f"{stamp}.json")
        with open(meta_path, "r", encoding="utf-8") as mf:
            meta = json.load(mf)
        meta["reference"] = "Ship the PostgreSQL job on Hetzner with Kalshi and SandboxedSh."
        meta["simulated_raw"] = "Um ship the post grass job on Hertzner with kalchi and SandboxedSh."
        meta["reviewed"] = True
        with open(meta_path, "w", encoding="utf-8") as mf:
            json.dump(meta, mf)

        status = learn.cmd_status(self.home)
        self.assertEqual(status["vocabulary_terms"], 3)
        self.assertEqual(status["recordings_total"], 1)

        ev = learn.cmd_eval(self.home)
        self.assertEqual(ev["clips"], 1)
        self.assertGreater(ev["raw_wer"], 0.3)
        self.assertEqual(ev["post_wer"], 0.0)
        self.assertLess(ev["raw_vocab_recall"], 1.0)
        self.assertEqual(ev["post_vocab_recall"], 1.0)
        self.assertTrue(ev["improved_or_equal"])

        audit = learn.cmd_audit(self.home)
        self.assertTrue(any("short key 'no'" in w for w in audit["warnings"]))

        sugg = learn.cmd_suggest(self.home)
        self.assertIn("SandboxedSh", sugg["suggestions"])


if __name__ == "__main__":
    unittest.main()
