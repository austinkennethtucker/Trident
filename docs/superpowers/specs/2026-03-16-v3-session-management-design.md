# v3 Design Spec: Session Management (Local Detach/Reattach)

**Status:** Draft
**Date:** 2026-03-16
**Depends on:** v2 (config hot-reload) — shipped
**Estimated effort:** Large (multi-milestone)

## Overview

Add tmux-style local session persistence to Trident. A background daemon owns PTY processes; the GUI connects as a thin client. Detaching closes the window without killing processes. Reattaching reconnects to live sessions. Normal (non-session) terminal usage is completely unchanged.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Architecture | Embedded mux layer (Approach B) | Rendering pipeline unchanged, incremental migration |
| Scope | Local only, no remote | Dramatically simpler, covers primary use case |
| Activation | Opt-in via `--session` flag | Zero impact on normal usage, small blast radius |
| Session ↔ window | One window per session | macOS-native, simpler than hot-swapping content |
| Switcher UI | Popup terminal-style overlay | Consistent with existing popup UX |
| Daemon lifecycle | Auto-start on first `--session`, stays alive | User never manages daemon manually |
| Wire protocol | Length-prefixed binary over Unix socket | Zero-copy friendly, no escaping needed for binary PTY output |
| Persistence | Layout restore on daemon restart, fresh processes | Best-effort comfort; live PTY persistence is the real feature |

## 1. Daemon Architecture

### Process Model

The daemon is a headless Trident process (`trident --daemon`) that:

- Starts automatically on first `trident --session` launch (or manually via `trident daemon-start`)
- Listens on a Unix domain socket (platform-specific path, see below)
- Owns all PTY file descriptors — spawns shells/commands, reads output, accepts input
- Organizes PTYs into named sessions
- Buffers scrollback per-PTY (configurable, defaults to terminal scrollback setting)
- Stays alive when all GUI clients disconnect
- Shuts down via `trident daemon-stop` or signal
- Pidfile alongside socket for locking and single-instance enforcement

### Socket & Pidfile Paths

| Platform | Socket | Pidfile |
|----------|--------|---------|
| macOS | `$TMPDIR/trident-daemon.sock` (`$TMPDIR` is per-user, set by launchd, e.g. `/var/folders/.../T/`) | `$TMPDIR/trident-daemon.pid` |
| Linux | `$XDG_RUNTIME_DIR/trident/daemon.sock` (fallback: `/tmp/trident-$UID/daemon.sock`) | Same directory, `daemon.pid` |

On macOS, `$TMPDIR` is preferred over `/tmp` because launchd sets it to a per-user private directory with correct permissions. On Linux, `$XDG_RUNTIME_DIR` (typically `/run/user/$UID/`) is the standard location for user runtime sockets.

### Daemon Startup (Daemonization)

When auto-starting the daemon (from `trident --session`), the client must NOT use `fork()` — on macOS, forking from a process that has initialized Cocoa/Metal frameworks is unsafe (Apple restriction). Instead:

1. Use `posix_spawn()` to launch `trident --daemon` as a new process
2. The daemon process calls `setsid()` to become a session leader (detaches from controlling terminal)
3. Redirects stdout/stderr to `$TMPDIR/trident-daemon.log` (macOS) or `$XDG_RUNTIME_DIR/trident/daemon.log` (Linux)
4. Closes inherited file descriptors (except the socket it creates)
5. Writes pidfile after socket is listening
6. Client polls for pidfile + socket existence (max ~2s timeout)

### Session Model

```
Daemon
 └── Sessions (named: "default", "work", "ops")
      └── Terminals (id, PTY fd, cwd, command, scrollback buffer)
           └── Layout hint (tab index, split position — stored as metadata)
```

The daemon does NOT do terminal emulation or rendering. It is a PTY multiplexer — reads bytes from PTYs and forwards them to connected clients, forwards client input to PTYs.

### Scrollback Buffer

The daemon maintains a circular buffer of recent PTY output per terminal. The buffer size defaults to the `scrollback-limit` config value (default: 10,000,000 bytes / ~10 MB). The unit is **bytes**, matching the existing config.

On client attach, the daemon sends the buffer contents as `screen_snapshot` messages.

### Attach Screen Reconstruction

Raw byte replay alone cannot perfectly reconstruct terminal screen state — the buffer may start mid-escape-sequence, and terminal modes (alternate screen, scroll region, cursor position) are unknown. The daemon addresses this with a two-phase sync:

1. **Screen snapshot:** The daemon maintains a minimal terminal state tracker per PTY — just enough to capture the current screen contents (rows × cols of cell data) and cursor position. This is sent first as a `screen_snapshot` message. The client renders this as the initial screen.
2. **Live output:** After the snapshot, the client receives live `output` messages and processes them normally through its terminal emulator.

The screen snapshot is lightweight — the daemon does NOT run a full terminal emulator. It tracks only: current screen grid (for the visible area), cursor position, and whether alternate screen is active. This is ~100 KB per terminal at typical sizes (80×24 × ~50 bytes/cell).

Scrollback history from before the attach point is NOT available to the client (it was processed by a previous client session or never displayed). This is the same limitation tmux has — `tmux attach` shows the current screen, not deep history.

## 2. Wire Protocol

Communication over the Unix domain socket. Length-prefixed binary frames.

### Frame Format

```
[4 bytes: payload length, big-endian u32][1 byte: message type][payload]
```

Maximum frame size: 16 MiB (sanity limit, mostly for scrollback sync).

### Client → Daemon Messages

| Type ID | Name | Payload |
|---------|------|---------|
| 0x01 | `create_session` | session name (len-prefixed string), optional cwd |
| 0x02 | `create_terminal` | session id (u32), command (len-prefixed string), cwd (len-prefixed string), cols (u16), rows (u16) |
| 0x03 | `attach_session` | session name (len-prefixed string) |
| 0x04 | `detach_session` | session name (len-prefixed string) |
| 0x05 | `input` | terminal id (u32), byte payload |
| 0x06 | `resize` | terminal id (u32), cols (u16), rows (u16) |
| 0x07 | `close_terminal` | terminal id (u32) |
| 0x08 | `list_sessions` | (empty) |
| 0x09 | `destroy_session` | session name (len-prefixed string) |

### Daemon → Client Messages

| Type ID | Name | Payload |
|---------|------|---------|
| 0x81 | `output` | terminal id (u32), byte payload |
| 0x82 | `session_info` | JSON-encoded array of {name, terminal_count, created_at} |
| 0x83 | `terminal_created` | terminal id (u32), session name |
| 0x84 | `terminal_exited` | terminal id (u32), exit code (i32) |
| 0x85 | `error` | error code (u16), message (len-prefixed string) |
| 0x86 | `screen_snapshot` | terminal id (u32), cols (u16), rows (u16), cursor_x (u16), cursor_y (u16), cell data (rows×cols encoded cells) |
| 0x87 | `session_layout` | session name, JSON-encoded layout tree |

### Design Notes

- Binary format avoids escaping PTY output bytes (which can contain any byte value)
- Terminal id is daemon-assigned, unique across all sessions for the daemon's lifetime
- The socket is `SOCK_STREAM` (TCP-like reliable ordered delivery over Unix domain)
- **Single-client-per-session (v3):** The daemon tracks which client connection (socket fd) owns each session. `attach_session` fails if another client is already attached. `detach_session` or client socket close (including abnormal disconnect) releases ownership. The daemon detects client disconnects via socket EOF/error on the connection fd — no heartbeat needed.

## 3. Mux Client Integration

### MuxClient (`src/termio/MuxClient.zig`)

New module that replaces the direct PTY read/write path when in session mode.

```
Normal mode:  Termio → reads PTY fd → feeds terminal emulator
Session mode: Termio → reads MuxClient → feeds terminal emulator
```

Responsibilities:
- Maintains a single socket connection to the daemon (shared across all surfaces in a session window)
- Demultiplexes incoming `output` frames by terminal id to the correct Termio instance
- Sends `input`, `resize`, `close_terminal` on behalf of surfaces
- Handles `screen_snapshot` on attach (feeds buffered output to terminal emulator as if it were live)
- Reconnection logic: if daemon connection drops, surfaces show a "disconnected" overlay; auto-reconnects when daemon is available

### Surface Creation in Session Mode

1. User opens new tab/split → Surface init
2. Instead of spawning a PTY directly, Surface asks MuxClient to `create_terminal` in the current session
3. MuxClient sends `create_terminal` to daemon
4. Daemon spawns the PTY, returns terminal id via `terminal_created`
5. MuxClient maps terminal id → Surface's Termio instance
6. Output flows: daemon → socket → MuxClient → Termio → terminal emulator → renderer

### What Doesn't Change

Surface, Terminal, Renderer, Overlay, vi-mode, line numbers, popups, config hot-reload, keybindings — all identical. They consume a byte stream from Termio and don't know or care whether it originates from a local PTY or a daemon socket.

### Mode Selection

A `--session <name>` CLI flag controls which mode a window uses. No config file setting — session mode is a per-invocation choice, not a global default.

Termio checks at init: if session mode is active, use MuxClient. Otherwise, spawn PTY directly (today's behavior, unchanged).

### Backend Integration Notes

The existing Termio backend system (`src/termio/backend.zig`) defines `Kind = enum { exec }` with a `Backend` union and per-kind `ThreadData`. Adding a `mux` variant is more than a simple swap — key differences from `exec`:

- **No child process watcher:** `exec` uses `xev.Process` to detect PTY exit. The mux backend receives `terminal_exited` messages over the wire instead.
- **No termios polling:** `exec` runs a timer to poll termios state (`Exec.termiosTimer`). Dead code for mux — the daemon owns the PTY fd.
- **Different read model:** `exec` spawns a dedicated `ReadThread` that blocks on the PTY fd. The mux backend integrates with the IO thread's `xev.Loop` to read from the daemon socket (non-blocking, event-driven).
- **Shared socket:** Multiple mux-backed Termio instances share one socket connection. The MuxClient demultiplexes by terminal id. This is fundamentally different from `exec` where each Termio has its own PTY fd.

## 4. CLI Commands & Launch Modes

| Command | Behavior |
|---------|----------|
| `trident` | Normal launch. Direct PTY, no daemon. Today's behavior exactly. |
| `trident --session work` | Connect to daemon (auto-start if needed), create or attach session "work". Opens a window. |
| `trident attach work` | Attach to existing session "work". Error if it doesn't exist. |
| `trident detach` | Detach the focused session window. Sends `detach_session`, closes window. Processes keep running. |
| `trident list-sessions` | Print active daemon sessions to stdout (name, terminal count, uptime). |
| `trident kill-session work` | Send `destroy_session`. Kills all PTYs in "work", removes session. |
| `trident daemon-start` | Start daemon in background (usually auto-started). |
| `trident daemon-stop` | Shut down daemon. All session PTYs are killed. |

### Auto-Start

When `trident --session work` runs and no daemon is listening:

1. Launch daemon via `posix_spawn()` (`trident --daemon`) — see Daemonization section above
2. Poll for pidfile + socket (max ~2s timeout)
3. Connect and proceed

The user never needs to manually manage the daemon.

### Detach Behavior

`trident detach` or a keybind (action: `detach_session`, default unbound) closes the session window immediately. No confirmation prompt — nothing is being killed. The daemon keeps all PTYs alive.

### Session Window Identification

Windows opened via `--session` show the session name in the title bar: "Trident — work". This makes it visually clear which windows are session-managed vs normal throwaway terminals.

## 5. Session Persistence (Daemon Restart)

Two levels of persistence:

### Level 1: Daemon Alive (Primary Feature)

Processes keep running in the daemon indefinitely. Scrollback preserved in daemon's memory buffer. `trident attach work` reconnects instantly with `screen_snapshot` catch-up.

This is the core value — detach Friday afternoon, reattach Monday morning. Claude is still running.

### Level 2: Daemon Dies (Reboot, Crash — Best-Effort)

PTY processes die with the daemon (unavoidable — daemon owns the fds). To mitigate:

- Daemon periodically writes session metadata to `~/.local/state/trident/sessions/<name>.json`:
  ```json
  {
    "name": "work",
    "terminals": [
      {"cwd": "/Users/tucker/projects/ghostty", "command": "zsh", "env": {}},
      {"cwd": "/Users/tucker/projects/ghostty", "command": "claude", "env": {}}
    ],
    "layout": {
      "type": "split_v",
      "ratio": 0.5,
      "children": [{"type": "leaf", "terminal": 0}, {"type": "leaf", "terminal": 1}]
    },
    "updated_at": "2026-03-16T12:00:00Z"
  }
  ```
- On next `trident --session work`, if daemon has no live "work" session but a state file exists, restore the layout with fresh shells in the saved cwds.
- Commands like `claude` are re-executed. Simple shells get the saved cwd.

### Config

```
session-restore = layout | off
```

- `layout` (default when using sessions): restore layout + cwd + commands on daemon restart
- `off`: start clean every time

### What Gets Saved

- Session name
- Per-terminal: cwd (tracked via OSC 7), original command, environment variables
- Layout: tab order, split tree structure, split ratios

### What Doesn't Get Saved

- Scrollback content (memory-only, dies with daemon)
- Process state (live PTY state is not serializable)
- Terminal emulator state (modes, colors, cursor position)

## 6. Session Picker UI

Triggered by `show_session_picker` keybind action. Uses the same popup overlay pattern as existing popup terminals.

### Behavior

- Queries daemon via `list_sessions`
- Displays: session name, terminal count, uptime
- Fuzzy-searchable (same filtering as command palette)
- Enter: attach to selected session (opens new window)
- Esc: dismiss
- Only appears when at least one daemon session exists; otherwise shows "No active sessions"

### Rendering

Rendered as an overlay on the current surface using the existing z2d overlay pipeline. Same visual style as vi-mode indicator / popup system.

## 7. Implementation Milestones

### v3.0: Daemon + Single Terminal (MVP)

**Deliverables:**
- Daemon binary/mode (`trident --daemon`)
- Wire protocol implementation (create/attach/detach/input/output/resize)
- `MuxClient.zig` — socket-based I/O source for Termio
- `trident --session <name>` launch mode
- `trident attach <name>` / `trident detach` CLI commands
- `trident list-sessions` / `trident kill-session`
- Auto-start daemon on first `--session` use
- Single terminal per session (no tabs/splits in daemon mode yet)
- Screen snapshot sync on attach

**Exit criteria:** Can run `trident --session work`, start a long-running process, close the window, run `trident attach work`, and see the process still running with current screen state intact.

### v3.1: Multi-Terminal Sessions

**Deliverables:**
- Multiple terminals per session (tabs and splits)
- Layout metadata tracked in daemon
- New tab/split in session window creates terminal via daemon
- Split tree serialized in session state

**Exit criteria:** Session "work" can have 3 tabs with splits, detach, reattach, and all tabs/splits are restored with live processes.

### v3.2: Session Picker + CLI Polish

**Deliverables:**
- `show_session_picker` popup overlay (fuzzy-searchable)
- Session name in window title bar
- `daemon-start` / `daemon-stop` commands
- Improved error messages (daemon not running, session not found, etc.)

**Exit criteria:** User can open session picker, see all active sessions, select one to attach.

### v3.3: Persistence on Daemon Restart

**Deliverables:**
- Session metadata written to disk periodically
- Layout + cwd + command restore on `trident --session <name>` when daemon has no live session
- `session-restore = layout | off` config

**Exit criteria:** Reboot machine, run `trident --session work`, get the same tab/split layout with fresh shells in the correct cwds.

## 8. Files to Create / Modify

| File | Change |
|------|--------|
| `src/daemon/` (new) | Daemon main loop, session manager, PTY ownership, socket listener |
| `src/daemon/Protocol.zig` (new) | Wire protocol types, frame encode/decode |
| `src/daemon/Session.zig` (new) | Session + terminal state, scrollback buffer |
| `src/termio/MuxClient.zig` (new) | Socket-based I/O source, demultiplexer |
| `src/termio/Termio.zig` | Add MuxClient as alternative I/O source (conditional on session mode) |
| `src/main.zig` | Route `--daemon`, `attach`, `detach`, `list-sessions`, etc. |
| `src/main_ghostty.zig` | Pass `--session` flag through to apprt |
| `src/config/Config.zig` | Add `session-restore` config field |
| `src/input/Binding.zig` | Add `detach_session`, `show_session_picker` actions |
| `src/Surface.zig` | Session-aware surface init (MuxClient vs direct PTY) |
| `src/renderer/Overlay.zig` | Session picker overlay rendering |
| `src/apprt/embedded.zig` | Session mode flag passthrough |

### No Platform-Specific Changes (v3.0)

The daemon and mux client are pure Zig, cross-platform. The GUI doesn't change — surfaces still receive bytes from Termio, which abstracts the source. macOS Swift code and GTK code are unaffected in v3.0.

Tab/split layout restore (v3.1+) will need platform-specific code to recreate tabs and splits.

## 9. Edge Cases

| Scenario | Behavior |
|----------|----------|
| Daemon crashes | GUI surfaces show "disconnected" overlay. Auto-reconnect when daemon restarts. Session state file enables layout restore. |
| Multiple clients attach same session | v3 scope: second attach gets an error "session already attached". Future: allow shared sessions. |
| Terminal exits in detached session | Daemon records `terminal_exited`. On reattach, client sees the exited terminal (shows exit code). User closes it. |
| Daemon socket permission denied | Error message with instructions. Socket created with user-only permissions (0700 directory, 0600 socket). |
| `trident --session` when daemon binary not found | Trident IS the daemon binary (`trident --daemon`), so this can't happen. |
| Very large scrollback sync | Capped at configured scrollback buffer size. Sent in chunks to avoid blocking the socket. |
| Resize while detached | Not possible (no GUI). On reattach, client sends `resize` with current window dimensions. Daemon forwards SIGWINCH to PTY. |

## 10. Security Considerations

- Socket directory created with `0700` permissions (user-only access)
- Socket file created with `0600` permissions
- Pidfile prevents multiple daemon instances for the same user
- No authentication on socket (relies on filesystem permissions, same model as tmux)
- Daemon runs as the invoking user, not root
- No network exposure — Unix domain socket only
- **State file command re-execution (v3.3):** Session restore re-executes commands saved in `~/.local/state/trident/sessions/<name>.json`. A tampered state file could cause arbitrary command execution. Mitigated by: file permissions (0600), user-only directory (0700), same trust model as `.bashrc` / `.ssh/authorized_keys`. Not a concern for single-user local-only scope.

## 11. Performance

- **Output latency:** One extra memcpy (daemon buffer → socket → client) vs direct PTY read. Measured in microseconds, imperceptible.
- **Throughput:** Unix domain sockets handle >1 GB/s. Terminal output rarely exceeds 100 MB/s even in extreme cases (e.g. `cat /dev/urandom`).
- **Memory:** Daemon screen snapshot per terminal: ~100 KB at 80×24. 10 terminals across sessions = ~1 MB. Negligible.
- **CPU:** Daemon is mostly idle (blocked on epoll/kqueue). Only active when PTY output arrives or client sends input.
- **Zero cost when not using sessions:** No daemon, no socket, no overhead. Normal `trident` launch is identical to today.

## What's NOT in v3 Scope

- Remote sessions (SSH, network protocol, authentication)
- Scrollback persistence to disk (dies with daemon)
- Session sharing (multiple GUIs attached to same session)
- Session-scoped popups (deferred to later enhancement)
- Process migration between sessions
- Session templates in config file (use CLI workflow instead)
