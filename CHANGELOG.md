# Changelog

All notable changes to AaaU will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed
- **Default client connection**: Plain `aaau` uses the legacy default-session handshake, avoiding `Missing or invalid JSON field: program` with older running servers. Omitted `--user` uses the server account; explicit user and program selections retain JSON framing.

### Added
- **Per-session agent account**: `aaau --user NAME` selects which isolated agent account runs a new session. It defaults to the server's configured account and is ignored when joining an existing session. The server validates that the account exists, is not root, and is isolated from the human control group; a non-root server may only keep running as its own account.
- **Agent user systemd/D-Bus access**: `aaau-server init` now enables lingering for the agent account, and agent sessions export `XDG_RUNTIME_DIR`, so processes running as the agent can use `systemctl --user` and other D-Bus clients to manage local units. Manual setups should run `loginctl enable-linger agent`.

## [v0.4.0] - 2026-04

### Added
- Client aliases: `aaau codex` and `aaau claude` shortcuts for common agent invocations

### Changed
- **Process Group Termination**: Agent process groups are now killed on shutdown, preventing orphaned child/grandchild processes
- **Robust Handshake Reading**: Handshake reads now handle fragmented network packets correctly, improving connection reliability
- **Lock-Free Broadcast Writes**: Client locks are no longer held during broadcast writes, reducing contention
- **Secure Argument Handling**: Agent arguments are no longer subject to shell re-parsing, preventing argument injection attacks

### Fixed
- **Unix Socket Authentication**: Peer credential authentication now uses proper C bindings for reliable `SO_PEERCRED` handling

## [v0.3.0] - 2026-03

### Security
- **Process Group Termination**: Agent process groups are now killed on shutdown, preventing orphaned processes from running after session ends
- **Secure Argument Handling**: Fixed shell re-parsing of agent arguments to prevent argument injection attacks
- **Unix Socket Authentication**: Fixed peer credential authentication using proper C bindings for `SO_PEERCRED`

### Reliability
- **Robust Handshake Reading**: Handshake reads now handle fragmented network packets correctly
- **Lock-Free Broadcast Writes**: Avoid holding client locks during broadcast writes to reduce contention

### Usability
- Added `aaau codex` shortcut for codex with standard bypass flag
- Added `aaau claude` shortcut for claude with standard skip-permissions flag

## [v0.2.0] - 2026-03

### Added
- Client program handshake parsing support
- Configurable audit log directory
- Release publishing with softprops action
- macOS peer credential support

### Fixed
- macOS peer credential build issues
- Client program handshake parsing edge cases
- Release draft regression
- Release artifact packaging path issues

### Changed
- PTY slave permission hardening
- Audit log directory handling

## [v0.1.0] - Initial Release

### Core Features
- Agent-as-User architecture with PTY bridge
- Process isolation via dedicated system users
- Resource limits via cgroups/systemd
- File isolation via per-user `$HOME` directories
- Audit logging in JSONL format
- Multi-client support (read-only, interactive, admin modes)
- Unix domain socket communication
- Text-based client-server protocol with `\x01` framing
