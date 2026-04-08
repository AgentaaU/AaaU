# Changelog

All notable changes to AaaU will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- Client aliases: `aaau codex` and `aaau claude` shortcuts for common agent invocations

### Changed
- **Process Group Termination**: Agent process groups are now killed on shutdown, preventing orphaned child/grandchild processes
- **Robust Handshake Reading**: Handshake reads now handle fragmented network packets correctly, improving connection reliability
- **Lock-Free Broadcast Writes**: Client locks are no longer held during broadcast writes, reducing contention
- **Secure Argument Handling**: Agent arguments are no longer subject to shell re-parsing, preventing argument injection attacks

### Fixed
- **Unix Socket Authentication**: Peer credential authentication now uses proper C bindings for reliable `SO_PEERCRED` handling

## [v0.3.0] - 2026-04

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
