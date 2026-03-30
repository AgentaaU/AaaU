# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Install dependencies
opam install -y dune lwt lwt_ppx logs fmt cmdliner yojson uuidm mtime cstruct

# Build (development)
dune build

# Build (release)
dune build --profile release

# Run all tests
dune test

# Run single test (e.g., test_pty_resize)
dune test test_pty_resize

# Install binaries
dune install
# Or manually:
sudo cp _build/install/default/bin/aaau-server /usr/local/bin/
sudo cp _build/install/default/bin/aaau /usr/local/bin/
```

## High-Level Architecture

**Agent-as-User (AaaU)** - Secure PTY bridge running AI agents under isolated Linux system users.

```
Human Client → Unix Socket → aaau-server → PTY Bridge → Agent (separate user)
```

### Module Dependencies

```
server.ml / client.ml  →  cmdliner CLI entry points
                           ↓
bridge.ml ─────────────→ Server: Unix socket, session lifecycle, auth
                           ↓
session.ml ────────────→ Multi-client PTY multiplexing
                           ↓
pty.ml ────────────────→ PTY ops (C stubs: pty_stubs.c)
protocol.ml ───────────→ \x01-prefixed wire format
auth.ml ───────────────→ SO_PEERCRED-based permissions
audit.ml ──────────────→ JSONL logging
```

### Key Types & Flows

- **Session lifecycle**: `bridge.start` → client handshake (`NEW` or `SESSION:<id>`) → `session.create` → PTY fork → I/O loops → shutdown
- **Permissions**: `ReadOnly` / `Interactive` / `Admin` — system users (UID < 1000) get Admin
- **Protocol**: Control char `\x01` prefixes commands (`RESIZE`, `PING`, `STATUS`, `ERROR`)
- **PTY**: `open_pty` → `fork_agent` (setuid) → `set_raw_mode` → I/O forwarding

### C Stubs (`lib/pty_stubs.c`)

Bindings for PTY ioctls: `aaau_openpt`, `aaau_grantpt`, `aaau_unlockpt`, `aaau_ptsname`, `aaau_set_winsize`, `aaau_get_winsize`, `aaau_set_ctty`

## Development Notes

- **MLI first**: Interface files document public API; keep signatures in sync
- **Error handling**: Return `(result, string) result` — no exceptions for recoverable errors. Use `Lwt.try_bind` around handshake/session creation to catch exceptions and send error responses
- **Lwt syntax**: Use `let*` and `let+` from `Lwt.Syntax`
- **Warnings**: `-warn-error -A` (warnings don't fail in dev; release may differ)
- **Tests**: One file per test case in `test/`; all linked against `AaaU` library
- **Platform**: Linux-only (PTY, setuid, Unix sockets)

## Common Issues

**Client hangs/unresponsive during commands**: Usually means I/O loop is blocked.

- **Server-side timeouts**: broadcast_loop and pty_write_loop now have 5-second timeouts to prevent blocking on slow clients or stuck agents
- **Check logs**: Look for "PTY write timeout" or "Client X slow, disconnecting" warnings
- **gh/git commands**: May wait for authentication - check if prompt is being displayed
- **Terminal echo**: Ensure `c_echo` is enabled in PTY slave configuration
- **Client has 5-second handshake timeout**; server should always respond or close connection

**Debugging tips**:
1. Check server logs for timeout warnings
2. Verify agent process is running: `ps aux | grep <agent>`
3. Test with simple commands first (`echo hello`, `ls`)
4. For interactive commands, ensure PTY is properly configured

See `AGENTS.md` for detailed module documentation and `README.md` for user-facing setup.
