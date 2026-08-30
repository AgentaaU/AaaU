#!/bin/bash
# Install aaau-server systemd service
# Run from release tarball directory

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="${PREFIX:-/usr/local}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"

echo "=== AaaU Systemd Installation ==="

# Check root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root"
   exit 1
fi

# Install binaries
echo "Installing binaries to ${PREFIX}/bin..."
install -m 755 "${SCRIPT_DIR}/aaau-server" "${PREFIX}/bin/"
install -m 755 "${SCRIPT_DIR}/aaau" "${PREFIX}/bin/"
install -m 755 "${SCRIPT_DIR}/aaau-editor" "${PREFIX}/bin/"

# Install systemd service
echo "Installing systemd service..."
install -m 644 "${SCRIPT_DIR}/aaau-server.service" "${SYSTEMD_DIR}/"

# Initialize aaau environment.  This one-time provisioning step creates the
# dedicated unprivileged service account; the server itself does not use sudo.
echo "Initializing aaau environment..."
aaau-server init --user agent --group aaau-users --log-dir /var/lib/aaau

# Reload systemd
systemctl daemon-reload

echo ""
echo "✓ Installation complete!"
echo ""
echo "Usage:"
echo "  systemctl start aaau-server     # Start service"
echo "  systemctl enable aaau-server    # Enable on boot"
echo "  systemctl status aaau-server    # Check status"
echo "  journalctl -u aaau-server -f    # View logs"
