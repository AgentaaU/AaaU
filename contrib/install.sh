#!/usr/bin/env bash
# Install or uninstall AaaU and its systemd service.
#
# Usage:
#   sudo ./contrib/install.sh install
#   sudo ./contrib/install.sh uninstall
#
# Environment overrides:
#   PREFIX=/opt/aaau SYSTEMD_DIR=/etc/systemd/system sudo ./contrib/install.sh install

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
readonly PREFIX="${PREFIX:-/usr/local}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly SERVICE_NAME="aaau-server.service"
readonly SERVICE_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}"
readonly BIN_DIR="${PREFIX}/bin"
readonly SERVER_BINARY="${PROJECT_DIR}/_build/default/bin/server.exe"
readonly CLIENT_BINARY="${PROJECT_DIR}/_build/default/bin/client.exe"
readonly EDITOR_BINARY="${PROJECT_DIR}/_build/default/bin/editor.exe"
readonly SERVICE_FILE="${SCRIPT_DIR}/${SERVICE_NAME}"

usage() {
  cat <<'EOF'
Usage: sudo ./contrib/install.sh {install|uninstall}

Commands:
  install    Install already-built AaaU binaries and the systemd service.
  uninstall  Stop and disable the service, then remove installed binaries and
             the systemd unit. The agent user, groups, sockets, and audit logs
             are deliberately preserved.

Environment:
  PREFIX       Installation prefix (default: /usr/local)
  SYSTEMD_DIR  systemd unit directory (default: /etc/systemd/system)
EOF
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Error: this script must be run as root (for example, with sudo)." >&2
    exit 1
  fi
}

require_systemd() {
  if ! command -v systemctl >/dev/null 2>&1; then
    echo "Error: systemctl is required to manage the AaaU service." >&2
    exit 1
  fi
}

install_project() {
  require_systemd

  local file
  for file in "${SERVER_BINARY}" "${CLIENT_BINARY}" "${EDITOR_BINARY}" "${SERVICE_FILE}"; do
    if [[ ! -f "${file}" ]]; then
      echo "Error: missing required file ${file}. Run 'dune build' first." >&2
      exit 1
    fi
  done

  echo "Installing binaries to ${BIN_DIR}..."
  install -Dm755 "${SERVER_BINARY}" "${BIN_DIR}/aaau-server"
  install -Dm755 "${CLIENT_BINARY}" "${BIN_DIR}/aaau"
  install -Dm755 "${EDITOR_BINARY}" "${BIN_DIR}/aaau-editor"

  echo "Installing systemd service..."
  install -Dm644 "${SERVICE_FILE}" "${SERVICE_PATH}"
  systemctl daemon-reload

  # This one-time provisioning step creates the dedicated unprivileged
  # service account; the server itself does not use sudo.
  echo "Initializing the default AaaU environment..."
  "${BIN_DIR}/aaau-server" init --user agent --group aaau-users --log-dir /var/lib/aaau

  cat <<EOF

Installation complete.

Start now:     systemctl start aaau-server
Start at boot: systemctl enable aaau-server
Check status:  systemctl status aaau-server
EOF
}

uninstall_project() {
  require_systemd

  echo "Stopping and disabling ${SERVICE_NAME} (if present)..."
  systemctl disable --now aaau-server.service 2>/dev/null || true

  echo "Removing installed files..."
  rm -f -- "${SERVICE_PATH}"
  rm -f -- \
    "${BIN_DIR}/aaau-server" \
    "${BIN_DIR}/aaau" \
    "${BIN_DIR}/aaau-editor"
  systemctl daemon-reload

  cat <<'EOF'

Uninstallation complete.
The agent user, groups, /run/aaau, and /var/lib/aaau were preserved.
Remove those manually only after confirming no AaaU data is needed.
EOF
}

main() {
  if [[ $# -ne 1 ]]; then
    usage >&2
    exit 2
  fi

  case "$1" in
    -h|--help) usage ;;
    install)
      require_root
      install_project
      ;;
    uninstall)
      require_root
      uninstall_project
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
}

main "$@"
