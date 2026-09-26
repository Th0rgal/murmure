# Architecture

Goals: one resident model per Mac whatever the number of clients, low
perceived latency even on long dictations, no memory used when idle, no
network.

```
 Murmure.app (Swift)                      Orb (Tauri, voice.rs)
 CGEventTap shortcut → pill               mic button
 AVAudioEngine → 16 kHz → VAD chunks      WebAudio → WAV
        └──────────────┬─────────────────────────┘
                       ▼  protocol v1 (JSON line + WAV bytes)
   ~/Library/Application Support/md.thomas.voice/voiced.sock   (0600, launchd socket activation)
                       ▼
   voiced.py: one process, one inference thread, one MLX model (~0.95 GB peak)
```

## `voiced/`: shared daemon (Python + MLX)

- `worker.py` and `mlx_audio_cohere_quant_patch.py` are copied unchanged from
  `orb/voice/` in sandboxed.sh (PR #909, `e03f344`). Pins: model
  `MarkChen1214/cohere-transcribe-03-2026-MLX-Mixed-2bit3bit4bit@553445e`,
  mlx-audio `77a6cfc`.
- `voiced.py` serves the same protocol v1 over a Unix socket, one connection
  per client. A single inference thread owns the MLX backend; connection
  threads parse frames and queue jobs, so inference is serialized across
  clients and MLX is never touched from two threads.
- `shutdown` closes only the caller's connection; `unload` is advisory. A
  client disconnecting mid-request (e.g. cancel) only discards its result.
- The model is unloaded after `VOICED_UNLOAD_SECS` (600 s) without requests;
  the process exits after `VOICED_EXIT_SECS` (1800 s) without clients.
- `md.thomas.voiced.plist.in` is a socket-activated LaunchAgent: launchd owns
  the socket and starts voiced on the first connection.
- `scripts/install-voiced.sh` reuses Orb's venv when present
  (`--own-venv` builds a dedicated one).

`hello` adds `{"shared": true, "daemon": "voiced", "clients", "pid", "loaded"}`
to Orb's fields.

## `Sources/MurmureCore`: testable logic

- `Shortcut`: modifiers alone (left/right distinguished) or modifiers + key;
  `ShortcutCapture` records one from key events.
- `HotkeyState`: tap toggles, hold (> 0.35 s) is push-to-talk.
- `Chunker`: energy VAD on 30 ms frames with an adaptive threshold; cuts in
  the middle of a ≥ 450 ms pause once 7 s have accumulated, forced before
  28 s (the model works on ≤ 35 s windows).
- `VoiceClient`: POSIX socket client, `SO_RCVTIMEO` timeouts, one reconnect.
- `Wav`: 16-bit PCM mono 16 kHz encoder.

## `Sources/Murmure`: the app

- `HotkeyMonitor`: `CGEventTap` (needs Accessibility); swallows Esc/Return
  during a session.
- `Recorder`: `AVAudioEngine` → `AVAudioConverter` to 16 kHz mono, plus a
  10 ms level envelope (45 ms attack, 180 ms release).
- `Dictation`: session state machine. The model is preloaded when a session
  starts; VAD chunks are transcribed while you speak on a serial queue; on
  commit only the tail is sent, chunks are joined in order and pasted.
- `Overlay`: non-activating `NSPanel` (the target app keeps focus) with a
  SwiftUI pill.
- `Paster`: pasteboard + synthetic ⌘V, previous clipboard restored.
- `SettingsWindow`: shortcut, language, open at login, missing permissions.

## Measured (M2, 16 GB)

| | |
| --- | --- |
| Model load | 1.2–2.5 s |
| Warm transcription, 5.4 s clip | 0.6–0.9 s |
| MLX memory active / peak | 0.87 / 0.95 GB |
| 60 s dictation, no chunking (Orb log) | ~10 s after stopping |
| 60 s dictation, with chunking | only the last sentence remains (~1 s) |

## Tests

```sh
swift test                          # shortcut, VAD, WAV, languages + live tests against voiced
python3 voiced/test_voiced.py -v    # daemon with a fake backend
```
