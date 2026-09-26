# Orb ↔ voiced

`orb-shared-voiced.patch` applies to the branch of
[sandboxed.sh#909](https://github.com/Th0rgal/sandboxed.sh/pull/909)
(`orb/src-tauri/src/voice.rs`, base `e03f344`):

```sh
cd sandboxed.sh && git apply ../murmure/integrations/orb/orb-shared-voiced.patch
```

- Before spawning its private worker, Orb connects to
  `~/Library/Application Support/md.thomas.voice/voiced.sock`
  (`ORB_VOICE_SOCKET` overrides it, `off` disables) and speaks the same
  protocol v1 there. Orb and Murmure then share one model.
- No socket, or no answer: Orb behaves exactly as in the PR.
- In shared mode, cancel and the idle reaper close the connection instead of
  killing a process; `worker_pid()` reports the daemon's pid for metrics.
- `Worker` now wraps `Handle::{Child, Shared}` with boxed `Read`/`Write`; the
  frontend is unchanged.

Verified: `cargo test voice` (13 passed, including
`shared_daemon_is_preferred_over_a_private_worker`), no new clippy warning in
`voice.rs`.
