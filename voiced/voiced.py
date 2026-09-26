#!/usr/bin/env python3
"""voiced: one Cohere Transcribe model per Mac, shared by every client.

Orb's voice worker (worker.py, vendored unchanged from sandboxed.sh) speaks a
line-framed protocol over stdio and owns a private copy of the model. voiced
serves the *same* protocol v1 over a Unix domain socket, so any number of
clients (Murmure, Orb, a CLI) share one resident model:

    Murmure ─┐
    Orb ─────┼── ~/Library/Application Support/md.thomas.voice/voiced.sock ──▶ voiced
    CLI ─────┘                                  (0600, owner only)          one MLX model

Design:
- One inference thread owns the backend. MLX is only ever touched from that
  thread; connection threads parse frames and hand jobs over a queue, so
  inference is serialized across clients by construction.
- launchd socket activation (see md.thomas.voiced.plist): launchd holds the
  socket, starts voiced on the first connection, and restarts it on demand
  after it exits. Started by hand, voiced binds the socket itself.
- Memory: the model is unloaded after VOICED_UNLOAD_SECS without a request
  (default 10 min) and the process exits after VOICED_EXIT_SECS (default
  30 min) with no connection, so an idle Mac pays nothing.
- A client disconnecting never cancels or kills anything shared: its pending
  result is simply discarded. `shutdown` closes that client's connection
  only; `unload` is advisory (voiced manages residency itself).

Extra fields over worker.py: `hello` reports {"shared": true, "clients": n}.
"""

from __future__ import annotations

import ctypes
import os
import queue
import signal
import socket
import sys
import threading
import time
from typing import Any, Dict, Optional

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import worker as w  # noqa: E402  (sets HF offline env vars on import)

DEFAULT_HOME = os.path.expanduser("~/Library/Application Support/md.thomas.voice")


def env_secs(name: str, default: float) -> float:
    try:
        v = float(os.environ.get(name, default))
        return v if v > 0 else default
    except ValueError:
        return default


def voice_home() -> str:
    return os.environ.get("VOICED_HOME") or DEFAULT_HOME


def socket_path() -> str:
    return os.environ.get("VOICED_SOCKET") or os.path.join(voice_home(), "voiced.sock")


def log(msg: str) -> None:
    sys.stderr.write(f"[voiced] {time.strftime('%H:%M:%S')} {msg}\n")
    sys.stderr.flush()


# --------------------------------------------------------------------------
# Inference thread


class Job:
    __slots__ = ("req", "payload", "done", "response")

    def __init__(self, req: Dict[str, Any], payload: bytes) -> None:
        self.req = req
        self.payload = payload
        self.done = threading.Event()
        self.response: Dict[str, Any] = {}


class Engine:
    """Owns the single backend; runs every op on one thread."""

    def __init__(self, backend=None, unload_after: float = 600.0) -> None:
        self.worker = w.Worker(backend)
        self.jobs: "queue.Queue[Optional[Job]]" = queue.Queue()
        self.unload_after = unload_after
        self.last_used = time.monotonic()
        self.clients = 0
        self.lock = threading.Lock()
        self.thread = threading.Thread(target=self._run, name="voiced-inference", daemon=True)
        self.thread.start()

    def submit(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        job = Job(req, payload)
        self.jobs.put(job)
        job.done.wait()
        return job.response

    def stop(self) -> None:
        self.jobs.put(None)
        self.thread.join(timeout=5)

    def idle_for(self) -> float:
        return time.monotonic() - self.last_used

    def _run(self) -> None:
        while True:
            try:
                job = self.jobs.get(timeout=5.0)
            except queue.Empty:
                if self.worker.backend.loaded and self.idle_for() >= self.unload_after:
                    log(f"idle {self.idle_for():.0f}s: unloading model")
                    self.worker.backend.unload()
                continue
            if job is None:
                return
            self.last_used = time.monotonic()
            job.response = self._handle(job.req, job.payload)
            self.last_used = time.monotonic()
            job.done.set()

    def _handle(self, req: Dict[str, Any], payload: bytes) -> Dict[str, Any]:
        rid = req.get("id")
        op = req.get("op")
        try:
            if op == "shutdown":
                result: Dict[str, Any] = {"bye": True}
            elif op == "unload":
                result = {"loaded": self.worker.backend.loaded, "shared": True}
            else:
                result = self.worker.handle(req, payload)
                if op == "hello":
                    with self.lock:
                        result.update({"shared": True, "daemon": "voiced", "clients": self.clients, "pid": os.getpid(), "loaded": self.worker.backend.loaded})
            return {"id": rid, "ok": True, "result": result}
        except w.WorkerError as e:
            return {"id": rid, "ok": False, "error": {"code": e.code, "message": e.message}}
        except MemoryError:
            self.worker.backend.unload()
            return {"id": rid, "ok": False, "error": {"code": "internal", "message": "out of memory"}}
        except Exception as e:  # keep serving
            log(f"unhandled error: {type(e).__name__}: {e}")
            return {"id": rid, "ok": False, "error": {"code": "internal", "message": f"{type(e).__name__}: {e}"}}


# --------------------------------------------------------------------------
# Connections


def serve_connection(engine: Engine, conn: socket.socket) -> None:
    with engine.lock:
        engine.clients += 1
    rfile = conn.makefile("rb")
    wfile = conn.makefile("wb")
    try:
        while True:
            req_id: Any = None
            try:
                frame = w.read_request(rfile)
            except w.ProtocolError as e:
                w.write_response(wfile, {"id": e.req_id, "ok": False, "error": {"code": e.code, "message": e.message}})
                return
            except w.WorkerError as e:
                w.write_response(wfile, {"id": e.req_id, "ok": False, "error": {"code": e.code, "message": e.message}})
                continue
            if frame is None:
                return
            req, payload = frame
            if not req:
                continue
            req_id = req.get("id")
            response = engine.submit(req, payload)
            try:
                w.write_response(wfile, response)
            except (BrokenPipeError, ConnectionResetError):
                return  # client went away (cancel); result discarded
            if req.get("op") == "shutdown":
                return
    except (BrokenPipeError, ConnectionResetError, OSError):
        return
    finally:
        with engine.lock:
            engine.clients -= 1
        for f in (rfile, wfile):
            try:
                f.close()
            except OSError:
                pass
        conn.close()


def launchd_socket() -> Optional[socket.socket]:
    """The listener launchd created for us, when socket-activated."""
    if os.environ.get("VOICED_NO_LAUNCHD") == "1" or sys.platform != "darwin":
        return None
    try:
        libc = ctypes.CDLL(None)
        fn = libc.launch_activate_socket
    except (OSError, AttributeError):
        return None
    fn.argtypes = [ctypes.c_char_p, ctypes.POINTER(ctypes.POINTER(ctypes.c_int)), ctypes.POINTER(ctypes.c_size_t)]
    fn.restype = ctypes.c_int
    fds = ctypes.POINTER(ctypes.c_int)()
    count = ctypes.c_size_t(0)
    if fn(b"Listener", ctypes.byref(fds), ctypes.byref(count)) != 0 or count.value == 0:
        return None
    fd = fds[0]
    libc.free(fds)
    return socket.socket(socket.AF_UNIX, socket.SOCK_STREAM, fileno=fd)


def bind_socket(path: str) -> socket.socket:
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.connect(path)
        probe.close()
        raise SystemExit(f"voiced already running on {path}")
    except (FileNotFoundError, ConnectionRefusedError):
        probe.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    old = os.umask(0o177)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.bind(path)
    finally:
        os.umask(old)
    s.listen(16)
    return s


def serve(listener: socket.socket, engine: Engine, exit_after: float, owned_path: Optional[str]) -> int:
    listener.settimeout(5.0)
    log(f"ready pid={os.getpid()} backend={engine.worker.backend.name} python={sys.executable}")
    try:
        while True:
            try:
                conn, _ = listener.accept()
            except socket.timeout:
                with engine.lock:
                    clients = engine.clients
                if clients == 0 and engine.idle_for() >= exit_after:
                    log(f"idle {engine.idle_for():.0f}s with no client: exiting")
                    return 0
                continue
            conn.settimeout(None)
            threading.Thread(target=serve_connection, args=(engine, conn), name="voiced-conn", daemon=True).start()
    finally:
        engine.stop()
        if owned_path:
            try:
                os.unlink(owned_path)
            except FileNotFoundError:
                pass


def main() -> int:
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    engine = Engine(unload_after=env_secs("VOICED_UNLOAD_SECS", 600.0))
    listener = launchd_socket()
    owned = None
    if listener is None:
        owned = socket_path()
        listener = bind_socket(owned)
        log(f"bound {owned}")
    else:
        log("socket-activated by launchd")
    if os.environ.get("VOICED_PRELOAD") == "1":
        engine.submit({"op": "load"}, b"")
    return serve(listener, engine, env_secs("VOICED_EXIT_SECS", 1800.0), owned)


if __name__ == "__main__":
    sys.exit(main())
