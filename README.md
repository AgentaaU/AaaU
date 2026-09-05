# AaaU - Agent-as-User Architecture

A secure PTY (pseudo-terminal) bridge for running AI agents under isolated system users on Linux. This implements the "Agent-as-User" architecture where each agent runs as a dedicated system user, providing kernel-level isolation through standard Unix permissions.

## Quick Start

### 1. Install from GitHub Release

```bash
# Download the latest release
wget https://github.com/AgentaaU/AaaU/releases/latest/download/aaau-linux.tar.gz

# Extract binaries
tar -xzf aaau-linux.tar.gz

# Install to system
sudo install aaau-server /usr/local/bin/aaau-server
sudo install aaau /usr/local/bin/aaau
sudo install aaau-editor /usr/local/bin/aaau-editor
```

### 2. Initialize Agent User

```bash
# Create agent user and required directories
sudo aaau-server init
```

### 3. Start the Server

```bash
# Run the server. The service runs as the dedicated `agent` account; sudo is
# only needed once for installation and `init`.
systemctl start aaau-server
```

### 4. Connect and Run Agent

```bash
# Connect client and run claude in agent user environment
aaau -p 'claude --dangerously-skip-permissions'

# Shortcut for codex with the standard bypass flag
aaau codex

# Shortcut alias for claude with the standard skip-permissions flag
aaau claude

# Shortcut alias for opencode in automatic mode
aaau opencode
```

## Overview

```
┌─────────────┐            ┌─────────────┐
│   Human     │            │   Human     │
│  (Operator) │            │ (Observer)  │
└──────┬──────┘            └──────┬──────┘
       │                          │
       └──────────┬───────────────┘
                  │
       ┌──────────▼──────────┐
       │    aaau-server      │
       │   (Unix Socket)     │
       └──────────┬──────────┘
                  │
       ┌──────────▼──────────┐
       │   agent-session     │
       │   (PTY bridge)      │
       └──────────┬──────────┘
                  │
       ┌──────────▼──────────┐
       │   agent process     │
       │  (runs as separate  │
       │    system user)     │
       └─────────────────────┘
```

## Features

- **Process Isolation**: Each agent runs as a dedicated system user
- **Resource Limits**: Leverages cgroups via systemd for resource control
- **File Isolation**: Each agent has its own `$HOME` directory
- **Audit Logging**: Complete session recording in JSON format
- **Multi-Client Support**: Multiple humans can connect to observe/interact
- **Permission Levels**: Read-only, Interactive, and Admin access levels
- **Unix Domain Sockets**: Fast, secure local communication
- **Creator Editor Forwarding**: `C-g` editor buffers return to the session creator's existing Emacs

## Architecture

This system implements the Agent-as-User (AaaU) security model:

| Feature | Implementation |
|---------|---------------|
| User Creation | `useradd` / `systemd-sysusers` |
| Process Isolation | `setuid()` / dedicated users |
| Resource Limits | cgroups v2 (systemd) |
| File Isolation | Per-user `$HOME` directories |
| IPC Control | Unix socket permissions |
| Audit | JSONL format logs |

## Building

### Requirements

- OCaml >= 4.14
- opam
- Linux (for PTY and user isolation features)

### Install Dependencies

```bash
opam install -y dune lwt lwt_ppx logs fmt cmdliner yojson uuidm mtime cstruct
```

### Build

```bash
dune build
```

### Install

```bash
# Installs the already-built aaau-server, aaau, and aaau-editor,
# installs the systemd unit, and initializes the default AaaU user and directories.
sudo ./contrib/install.sh install

# Later, remove installed binaries and the service. This preserves accounts
# and audit logs so that session data is not removed unexpectedly.
sudo ./contrib/install.sh uninstall
```

## Setup

### Quick Setup with Init Command

```bash
# Initialize everything with defaults
sudo aaau-server init

# The init command creates:
# - User: agent
# - Group: agent
# - Private home: /home/agent (mode 0700)
# - Directories: /var/run/aaau, /var/log/aaau
```

### Manual Setup (Alternative)

If you prefer to set up manually:

#### 1. Create Agent User

```bash
# Create dedicated user for running agents
sudo useradd -r -U -s /bin/false -d /home/agent agent
sudo chmod 0700 /home/agent
```

#### 2. Create Shared Group

```bash
# Create group for authorized human users
sudo groupadd agent-shared
sudo usermod -aG agent-shared $USER

# Do not add the agent account to agent-shared and do not grant it sudo.
```

#### 3. Create Directories

```bash
sudo mkdir -p /var/run/aaau
sudo mkdir -p /var/log/aaau
sudo chown agent:agent-shared /var/run/aaau
sudo chmod 2710 /var/run/aaau
sudo chown agent:agent /var/log/aaau
sudo chmod 0700 /var/log/aaau
```

## Usage

### Initialize Environment

Before running the server for the first time, initialize the environment:

```bash
# Initialize with defaults
sudo aaau-server init

# Or customize all options
sudo aaau-server init \
  -u agent \
  -g agent-shared \
  -s /var/run/aaau/server.sock \
  -l /var/log/aaau \
  -h /home/agent
```

The `init` command will:
1. Create the shared group (e.g., `agent`)
2. Create the agent user (e.g., `agent`)
3. Create socket directory with proper permissions
4. Create log directory with proper permissions
5. Verify that the agent has neither human-group membership nor sudo access

### Start the Server

```bash
# Run in foreground
aaau-server run -s /var/run/aaau/server.sock -g aaau-users -u agent

# Or as daemon
aaau-server run -d -s /var/run/aaau/server.sock -g aaau-users -u agent
```

Options:
- `-s, --socket`: Unix socket path (default: `/var/run/aaau/server.sock`)
- `--editor-socket`: Agent-only editor request socket (default: `/var/run/aaau/editor.sock`)
- `-g, --group`: Authorized human group name (default: `aaau-users`)
- `-u, --user`: Agent system user (default: `agent`)
- `-l, --log-dir`: Audit log directory (default: `/var/log/aaau`)
- `-d, --daemon`: Run as daemon

### Connect with Client

```bash
# Create new session
aaau -s /var/run/aaau/server.sock

# Join existing session
aaau -s /var/run/aaau/server.sock -n <session-id>

# Read-only mode (observe only)
aaau -s /var/run/aaau/server.sock -n <session-id> -r
```

### Editing Codex or Claude buffers in your Emacs

Start an Emacs server in an existing visible Emacs frame before creating the
AaaU session:

```bash
# M-x server-start in an existing Emacs
aaau codex
```

The interactive session creator automatically registers a separate editor
provider. AaaU injects `EDITOR=aaau-editor`, `VISUAL=aaau-editor`,
`AAAU_SESSION_ID`, and `AAAU_EDITOR_SOCKET` into the isolated agent session.
When Codex or Claude invokes its editor (for example after `C-g`), the helper
accepts exactly one agent-owned regular buffer file, sends only its bounded
contents over the agent-only socket, and blocks. The creator-side provider:

1. atomically creates an unpredictable mode-`0600` file below `/tmp`;
2. invokes `emacsclient -- <temporary>` directly, without a shell (emacsclient
   waits by default; AaaU never passes `--no-wait`);
3. returns the edited bounded contents and always removes the temporary.

Save normally with `C-x C-s`, then finish the server edit with `C-x #`
(`server-edit`). Provider failure or timeout leaves the original unchanged;
success updates the helper's already-open original descriptor. A local copy-back
I/O failure returns a non-zero status and attempts to restore the bounded
original content.

Use `--no-editor-forwarding` to disable the provider. Use
`--editor-command 'emacsclient ...'` to supply a different directly executed
argv; quoting is parsed, but `/bin/sh -c` is never used. Only a new interactive
session creator provides editing: `--readonly` clients and clients joining with
`--session` never do. If Emacs is not running, the creator disconnects, or the
request times out, `aaau-editor` reports that forwarding is unavailable and the
PTY session continues normally.

If you use `emacs --daemon`, configure a client frame explicitly, for example
`aaau --editor-command 'emacsclient -c' codex`; a daemon alone has no visible
frame for the edited buffer.

### Editor security boundary

AaaU uses two distinct Unix sockets:

| Socket | Ownership/mode | Accepted role |
|---|---|---|
| Human control socket | `root:<human-group>` `0660` | session, PTY, and exact-creator provider connections |
| Editor request socket | `root:<agent-primary-group>` `0620` | exact configured agent UID; editor requests only |

The agent is not a member of the human group, cannot use `NEW`, `SESSION`, PTY,
or admin handshakes, and receives no sudo permission. Only UID 0 is Admin;
authorized humans are Interactive. Provider registration additionally requires
the exact session-creator UID—the random session ID alone is insufficient.

The helper rejects missing, multiple, option-shaped, symlink, non-regular,
oversized, and non-agent-owned buffers. It holds the validated descriptor across
the request so a pathname swap cannot redirect copy-back. Paths are never sent
to the operator, and the server never opens agent files as root. Frames, buffer
size, errors, request count, and duration are bounded; editor traffic never
shares or appears in PTY output. Audit entries contain request ID, operator,
byte count, and outcome, never buffer contents.

## Protocol

The client-server protocol uses a simple text-based format:

### Human client to Server

| Message | Description |
|---------|-------------|
| `<text>` | Regular terminal input |
| `\x01RESIZE:<rows>,<cols>` | Terminal resize |
| `\x01PING` | Keepalive ping |
| `\x01GET_STATUS` | Query session status |
| `\x01FORCE_KILL` | Admin: terminate session |

The separate editor socket accepts only `EDITOR_REQUEST:<session-id>`. The
human socket accepts `EDITOR_PROVIDER:<session-id>` only from the exact creator.
Both editor roles then exchange bounded 4-byte big-endian length-prefixed JSON;
buffer bytes are hex encoded so arbitrary binary content round-trips safely.

### Server to Client

| Message | Description |
|---------|-------------|
| `<text>` | Terminal output |
| `\x01PONG` | Ping response |
| `\x01STATUS:<json>` | Session status |
| `\x01ERROR:<msg>` | Error message |
| `\x01CONTROL:<msg>` | Control notification |

## API Usage

### Creating a Session

```ocaml
open Lwt.Syntax

let () =
  let audit = AaaU.Audit.create ~log_dir:"/var/log/aaau" in
  let* result = AaaU.Session.create
    ~session_id:"sess-123"
    ~creator:"operator"
    ~audit
  in
  match result with
  | Ok session ->
      Printf.printf "Session created: %s\n" (AaaU.Session.get_id session)
  | Error e ->
      Printf.eprintf "Error: %s\n" e
```

### Running the Server

```ocaml
let server = AaaU.Bridge.create
  ~socket_path:"/var/run/aaau/server.sock"
  ~shared_group:"agent-shared"
  ~agent_user:"agent"
  ~log_dir:"/var/log/aaau"
in

Lwt_main.run (AaaU.Bridge.start server)
```

## Security Model

### Permission Levels

| Level | Permissions |
|-------|------------|
| `ReadOnly` | View output only |
| `Interactive` | View + send input |
| `Admin` | Full control + force kill |

### Authentication

Authentication is based on Unix socket credentials:
- Client's UID/GID verified via `SO_PEERCRED`
- Human users must be members of the configured human group; the agent must not be a member
- Only root (UID 0) gets Admin permissions; all authorized humans are Interactive

### Audit Trail

All actions are logged in JSON Lines format:

```json
{"timestamp": 1711523456.789, "source": "human", "user": "alice", "session_id": "sess-123", "command_type": "input", "content": "ls -la", "metadata": {}}
{"timestamp": 1711523457.012, "source": "system", "user": "system", "session_id": "sess-123", "command_type": "session_start", "content": "Agent PID 12345", "metadata": {"pty": "/dev/pts/5"}}
```

## Project Structure

```
lib/
├── pty.mli/ml       # PTY operations
├── protocol.mli/ml  # Communication protocol
├── audit.mli/ml     # Audit logging
├── auth.mli/ml      # Authentication/authorization
├── session.mli/ml   # Session management
└── bridge.mli/ml    # Main server

bin/
├── server.ml        # aaau-server executable
└── client.ml        # aaau executable
```

## Comparison with Alternatives

| Approach | Isolation | Overhead | Startup |
|----------|-----------|----------|---------|
| Docker/Podman | Namespace | High | 50-500ms |
| Firecracker VM | Hardware | Very High | ~150ms |
| gVisor | Syscall intercept | Medium | 10-20ms |
| **AaaU** | **User/UID** | **Minimal** | **~1ms** |

## Limitations

- Linux only (relies on Unix sockets, PTYs, and user isolation)
- The server runs as root for PTY user switching; the agent itself has no sudo
- Some ioctl operations require C bindings (currently simplified)
- GPU/graphics access requires additional setup

## License

MIT License - See LICENSE file

## Contributing

Contributions welcome! Please ensure:
- Code follows OCaml conventions
- Tests pass (`dune test`)
- Documentation is updated
