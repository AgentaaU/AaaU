# AaaU - Agent-as-User Architecture

A secure PTY (pseudo-terminal) bridge for running AI agents under isolated system users on Linux. This implements the "Agent-as-User" architecture where each agent runs as a dedicated system user, providing kernel-level isolation through standard Unix permissions.

## Project Overview

| Property | Value |
|----------|-------|
| **Name** | AaaU (Agent-as-User) |
| **Version** | 0.1.0 |
| **Language** | OCaml (>= 4.14) |
| **Build System** | Dune (>= 3.10) |
| **Platform** | Linux only |

### Architecture Diagram

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

## Project Structure

```
.
├── lib/                    # Core library modules
│   ├── pty.mli/ml         # PTY (pseudo-terminal) operations with C stubs
│   ├── protocol.mli/ml    # Client-server communication protocol
│   ├── auth.mli/ml        # Authentication and permission management
│   ├── audit.mli/ml       # Audit logging system (JSONL format)
│   ├── session.mli/ml     # Session management (multi-client support)
│   ├── bridge.mli/ml      # Main server implementation
│   ├── pty_stubs.c        # C bindings for PTY ioctls
│   └── dune               # Library build configuration
├── bin/                    # Executables
│   ├── server.ml          # aaau-server entry point (init, run subcommands)
│   ├── client.ml          # aaau-client entry point
│   └── dune               # Executable build configuration
├── test/                   # Test suite
│   ├── test_AaaU.ml       # Comprehensive PTY and protocol tests
│   └── dune               # Test configuration
├── dune-project           # Dune project configuration
├── AaaU.opam              # Opam package file (auto-generated)
└── README.md              # User-facing documentation
```

## Build and Test Commands

### Prerequisites

- OCaml >= 4.14
- opam
- Linux system (for PTY and user isolation features)

### Install Dependencies

```bash
opam install -y dune lwt lwt_ppx logs fmt cmdliner yojson uuidm mtime cstruct
```

### Build Commands

```bash
# Build the project (development)
dune build

# Build for release
dune build --profile release

# Run tests
dune test

# Install binaries
dune install

# Build and install manually
sudo cp _build/install/default/bin/aaau-server /usr/local/bin/
sudo cp _build/install/default/bin/aaau-client /usr/local/bin/
```

### Build Configuration

The library build configuration (`lib/dune`) includes:
- C foreign stubs for PTY ioctl operations
- Lwt PPX preprocessor for async syntax
- Warning flag `-warn-error -A` (warnings don't fail build in development)

## Technology Stack

| Package | Version | Purpose |
|---------|---------|---------|
| ocaml | >= 4.14 | Language |
| dune | >= 3.10 | Build system |
| lwt | >= 5.6 | Async I/O |
| lwt_ppx | >= 2.1 | Lwt syntax extension |
| logs | >= 0.7 | Logging |
| fmt | >= 0.9 | Formatting |
| cmdliner | >= 1.1 | CLI parsing |
| yojson | >= 2.0 | JSON handling |
| uuidm | >= 0.9 | UUID generation (session IDs) |
| mtime | >= 1.4 | Time handling |
| cstruct | >= 6.0 | Binary data structures |

## Module Details

### Pty (`lib/pty.mli/ml`)

Low-level PTY (pseudo-terminal) operations with C bindings:

**Key types:**
- `type t` - PTY master file descriptor wrapper
- `type slave = private string` - PTY slave device path

**Key functions:**
- `open_pty : unit -> (t * slave, string) result` - Open PTY master/slave pair using `posix_openpt`
- `fork_agent : slave:slave -> user:string -> program:string -> args:string list -> env:(string * string) list -> (int, string) result` - Fork and switch to agent user
- `set_raw_mode : Unix.file_descr -> unit` - Configure raw terminal mode
- `set_terminal_size : Unix.file_descr -> rows:int -> cols:int -> unit` - TIOCSWINSZ ioctl
- `get_terminal_size : Unix.file_descr -> (int * int)` - TIOCGWINSZ ioctl, returns (rows, cols)
- `set_controlling_terminal : Unix.file_descr -> unit` - TIOCSCTTY ioctl
- `check_program : string -> bool` - Check if program exists in PATH
- `read/write/close : t -> ...` - Lwt wrappers for I/O

**C Stubs (`pty_stubs.c`):**
- `aaau_openpt` - posix_openpt wrapper
- `aaau_grantpt` - grantpt wrapper
- `aaau_unlockpt` - unlockpt wrapper
- `aaau_ptsname` - Get slave path via TIOCGPTN ioctl
- `aaau_set_winsize` - TIOCSWINSZ ioctl
- `aaau_get_winsize` - TIOCGWINSZ ioctl
- `aaau_set_ctty` - TIOCSCTTY ioctl

### Protocol (`lib/protocol.mli/ml`)

Text-based client-server communication using control character `\x01`:

**Client messages:**
```ocaml
type client_message =
  | Input of string           (* Normal terminal input - no prefix *)
  | Resize of { rows; cols }  (* \x01RESIZE:<rows>,<cols> *)
  | Ping                      (* \x01PING *)
  | GetStatus                 (* \x01GET_STATUS *)
  | ForceKill                 (* \x01FORCE_KILL *)
  | Unknown of string
```

**Server messages:**
```ocaml
type server_message =
  | Output of string          (* Normal output - no prefix *)
  | Pong                      (* \x01PONG *)
  | Status of Yojson.Safe.t   (* \x01STATUS:<json> *)
  | Error of string           (* \x01ERROR:<msg> *)
  | Control of string         (* \x01CONTROL:<msg> *)
```

**Key functions:**
- `encode_client/decode_client` - Serialize/deserialize client messages
- `encode_server/decode_server` - Serialize/deserialize server messages
- `is_control : string -> bool` - Check if message starts with control character

### Auth (`lib/auth.mli/ml`)

Authentication and permission management:

**Permission levels:**
```ocaml
type permission =
  | ReadOnly      (* View output only *)
  | Interactive   (* View + send input *)
  | Admin         (* Full control + force kill *)
```

**Key functions:**
- `authenticate : peer_uid:int -> peer_gid:int -> shared_group:string -> (user_info, string) result` - Authenticate via Unix socket credentials
- `check_permission : permission -> action:string -> bool` - Check action permission
- `string_of_permission/permission_of_string` - Convert to/from strings

**Authentication policy:**
- Users must be member of configured shared group
- System users (UID < 1000) get Admin permissions automatically
- Regular users get Interactive permissions

### Audit (`lib/audit.mli/ml`)

JSONL-format audit logging:

```ocaml
type record = {
  timestamp : float;
  source : string;           (* "human", "agent", "system" *)
  user : string;
  session_id : string;
  command_type : string;     (* "input", "output", "control", "session_start" *)
  content : string;
  metadata : (string * string) list;
}
```

**Features:**
- Batched writes with 5-second flush interval
- Log files: `audit-YYYY-MM-DD.logl`
- Automatic log directory creation
- Thread-safe with Lwt_mutex

### Session (`lib/session.mli/ml`)

Single agent session with multi-client support:

**Features:**
- PTY management
- Client multiplexing (up to 10 clients per session)
- Input/output forwarding loops
- Permission checking for client operations
- Output buffering with history replay for new clients

**Key components:**
- `Lwt_queue` - Thread-safe queue for input handling
- `pty_read_loop` - Read from PTY and broadcast to clients
- `pty_write_loop` - Write client input to PTY
- `broadcast_loop` - Efficiently broadcast output to all clients

**Key functions:**
- `create : session_id:string -> creator:string -> agent_user:string -> ?program:string -> ?args:string list -> audit:Audit.t -> (t, string) result Lwt.t` - Create new session (default: /bin/bash)
- `add_client/remove_client` - Client lifecycle management
- `handle_client_input` - Process client messages with permission checks
- `is_alive : t -> bool` - Check if agent process is running
- `shutdown : t -> unit Lwt.t` - Terminate session and cleanup

### Bridge (`lib/bridge.mli/ml`)

Main server implementation:

**Features:**
- Unix domain socket server
- Session lifecycle management
- Client authentication and handshake
- Dead session cleanup (every 60 seconds)
- Configurable default program and args

**Key functions:**
- `create : socket_path:string -> shared_group:string -> agent_user:string -> log_dir:string -> ?default_program:string -> ?default_args:string list -> unit -> t` - Create server config
- `start : t -> unit Lwt.t` - Start server (blocks until stopped)
- `stop : t -> unit Lwt.t` - Stop server and cleanup

**Handshake protocol:**
- `NEW` - Create new session with default program
- `NEW:program` - Create new session with specific program
- `NEW:program:arg1:arg2` - Create new session with program and args
- `SESSION:<id>` - Join existing session

## Executables

### aaau-server (`bin/server.ml`)

Two subcommands:

**init** - Initialize environment:
```bash
sudo aaau-server init \
  -u agent \              # Agent user name (default: agent)
  -g agent-shared \       # Shared group name (default: agent)
  -s /var/run/aaau.sock \ # Socket path (default: /var/run/aaau.sock)
  -l /var/log/aaau \      # Log directory (default: /var/log/aaau)
  -h /home/agent           # Home directory (default: /home/agent)
  --shell /bin/false      # Login shell (default: /bin/false)
```

**run** - Start server:
```bash
sudo aaau-server run \
  -s /var/run/aaau.sock \ # Socket path
  -g agent-shared \       # Authorized group
  -u agent \              # Agent user
  -l /var/log/aaau \      # Log directory
  -p /bin/bash \          # Default program (default: /bin/bash)
  -d                      # Daemonize
```

### aaau-client (`bin/client.ml`)

```bash
# Create new session
aaau-client -s /var/run/aaau.sock

# Create new session with specific program
aaau-client -s /var/run/aaau.sock -p kimi-cli

# Join existing session
aaau-client -s /var/run/aaau.sock -n <session-id>

# Read-only mode
aaau-client -s /var/run/aaau.sock -n <session-id> -r
```

**Client options:**
- `-s, --socket` - Server socket path (default: /var/run/aaau.sock)
- `-n, --session` - Session ID to join
- `-r, --readonly` - Read-only mode (observe only)
- `-p, --program` - Program to run for new session

## Code Style Guidelines

1. **MLI First**: Each module has a corresponding `.mli` interface file with documentation
2. **Documentation**: Use `(** docstring *)` format for module and function documentation
3. **Lwt Syntax**: Use `Lwt.Syntax` with `let*` for async operations:
   ```ocaml
   let* result = some_async_op () in
   process result
   ```
4. **Error Handling**: Return `(type, string) result` for recoverable errors:
   ```ocaml
   val open_pty : unit -> (t * slave, string) result
   ```
5. **Warnings**: Build uses `-warn-error -A` (treat all warnings as non-errors in development)
6. **Pattern Matching**: Be exhaustive; use `| Unknown of string` for extensibility

## Testing Strategy

### Test Suite (`test/test_AaaU.ml`)

Comprehensive tests covering:

1. **PTY Operations**
   - `test_pty_open_close` - Open and close PTY pairs
   - `test_pty_error_handling` - Error handling for invalid states
   - `test_pty_no_exceptions` - Verify Error results instead of exceptions
   - `test_escape_sequence_passthrough` - Verify escape sequences pass through
   - `test_terminal_size` - Get terminal size
   - `test_pty_resize` - Set terminal size
   - `test_controlling_terminal` - TIOCSCTTY ioctl

2. **Concurrency**
   - `test_concurrent_input` - Stress test for race conditions
   - `test_process_group` - Process group termination
   - `test_agent_cleanup` - Zombie process prevention

3. **Utilities**
   - `test_check_program` - Program existence check

### Running Tests

```bash
# Run all tests
dune test

# Run with detailed output
dune test --verbose

# Run specific test (via test binary)
./_build/default/test/test_AaaU.exe
```

## Security Considerations

### Permission Levels

| Level | Permissions |
|-------|-------------|
| ReadOnly | View output only |
| Interactive | View + send input |
| Admin | Full control + force kill |

### Permission Checks

```ocaml
let check_permission perm ~action =
  match perm, action with
  | Admin, _ -> true
  | Interactive, ("input" | "resize" | "ping") -> true
  | Interactive, _ -> false
  | ReadOnly, "read" -> true
  | ReadOnly, _ -> false
```

### Authentication Flow

1. Socket permissions (0660, root:shared_group) enforce group membership
2. Server accepts connection
3. Handshake determines session (new or existing)
4. Permission level checked on each operation

### Isolation Features

| Feature | Implementation |
|---------|---------------|
| User Creation | `useradd --system` / `groupadd --system` |
| Process Isolation | `setsid()` + `setuid()` / `setgid()` |
| Resource Limits | Designed for cgroups v2 (systemd) |
| File Isolation | Per-user `$HOME` directories |
| IPC Control | Unix socket permissions (0660) |
| Audit | JSONL format logs with timestamps |

### Security Notes for Developers

- PTY slave permissions are set to 666 temporarily after opening (for agent access)
- Agent processes run in their own session with the PTY as controlling terminal
- Process groups are terminated together (negative PID to `kill`)
- Zombie processes are reaped via periodic `waitpid` calls
- Session cleanup removes dead sessions after all clients disconnect
- Client terminal enters alternate screen buffer (`\x1b[?1049h`) for clean TUI experience

## Deployment Notes

### Requirements

- Linux kernel with PTY support (`/dev/ptmx`, `/dev/pts`)
- Root privileges for server (user switching requires root)
- Pre-created agent user and shared group

### File Permissions

| Path | Owner | Permissions |
|------|-------|-------------|
| `/var/run/aaau.sock` | root:shared_group | 0660 |
| `/var/run/aaau/` | root:shared_group | 0775 |
| `/var/log/aaau/` | root:root | 1777 |
| `/home/agent/` | agent:shared_group | 0755 |

### Limitations

- Linux only (relies on Unix sockets, PTYs, and user isolation)
- Requires root/sudo for user switching
- GPU/graphics access requires additional setup
- Some TTY ioctls may not work on all terminal emulators

## Common Tasks for Developers

### Adding a New Protocol Message

1. Update `protocol.mli` - Add to `client_message` or `server_message` type
2. Update `protocol.ml` - Implement encoding/decoding
3. Update `session.ml` - Handle the message in `handle_client_input`
4. Add tests in `test_AaaU.ml`

### Adding C Bindings

1. Add function signature in `pty.mli`
2. Add external declaration in `pty.ml`
3. Implement in `pty_stubs.c` following OCaml C API conventions
4. Register in `lib/dune` if adding new stub files

### Adding a New Permission Level

1. Update `auth.mli` and `auth.ml` - Add to `permission` type
2. Update `auth.check_permission` with new action mappings
3. Update `session.ml` - Check permission in relevant handlers
4. Update string conversion functions

## Debugging Tips

1. **PTY Issues**: Check `/dev/pts/` exists and is writable
2. **Permission Denied**: Verify user is in shared group (`groups` command)
3. **Socket Issues**: Check socket path permissions
4. **Audit Logs**: Check `/var/log/aaau/audit-*.logl`
5. **Zombie Processes**: Server has built-in reaper, but check with `ps aux | grep defunct`

## Related Files

- `README.md` - User-facing documentation
- `dune-project` - Package metadata and dependencies
- `AaaU.opam` - Opam package file (auto-generated from dune-project)
