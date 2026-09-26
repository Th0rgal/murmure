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

os.environ["ORB_VOICE_FAKE"] = "1"
os.environ["VOICED_NO_LAUNCHD"] = "1"
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import voiced  # noqa: E402
import worker  # noqa: E402


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


if __name__ == "__main__":
    unittest.main()
