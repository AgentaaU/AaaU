#!/usr/bin/env bash
# Install or uninstall AaaU and its systemd service.
#
# Usage:
#   sudo ./install.sh install
#   sudo ./install.sh uninstall
#
# Environment overrides:
#   PREFIX=/opt/aaau SYSTEMD_DIR=/etc/systemd/system sudo ./install.sh install

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PREFIX="${PREFIX:-/usr/local}"
readonly SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
readonly SERVICE_NAME="aaau-server.service"
readonly SERVICE_PATH="${SYSTEMD_DIR}/${SERVICE_NAME}"
readonly BIN_DIR="${PREFIX}/bin"

usage() {
  cat <<'EOF'
Usage: sudo ./install.sh {install|uninstall}

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

  local binary
  for binary in server client editor; do
    if [[ ! -f "${SCRIPT_DIR}/_build/default/bin/${binary}.exe" ]]; then
      echo "Error: missing ${binary}.exe. Run 'dune build' before installation." >&2
      exit 1
    fi
  done

  echo "Installing binaries to ${BIN_DIR}..."
  install -Dm755 "${SCRIPT_DIR}/_build/default/bin/server.exe" "${BIN_DIR}/aaau-server"
  install -Dm755 "${SCRIPT_DIR}/_build/default/bin/client.exe" "${BIN_DIR}/aaau-client"
  install -Dm755 "${SCRIPT_DIR}/_build/default/bin/editor.exe" "${BIN_DIR}/aaau-editor"

  echo "Installing systemd service..."
  install -Dm644 "${SCRIPT_DIR}/contrib/${SERVICE_NAME}" "${SERVICE_PATH}"
  systemctl daemon-reload

  echo "Initializing the default AaaU environment..."
  "${BIN_DIR}/aaau-server" init

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
    "${BIN_DIR}/aaau-client" \
    "${BIN_DIR}/aaau-editor"
  systemctl daemon-reload

  cat <<'EOF'

Uninstallation complete.
The agent user, groups, /var/run/aaau, and /var/log/aaau were preserved.
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
