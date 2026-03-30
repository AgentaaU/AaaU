#!/bin/bash
# Install aaau-server systemd service
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "=== Installing aaau-server systemd service ==="

# Check if running as root
if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root (sudo)"
   exit 1
fi

# Install binary
echo "Installing aaau-server binary..."
install -Dm755 "${SCRIPT_DIR}/_build/default/bin/server.exe" /usr/local/bin/aaau-server
install -Dm755 "${SCRIPT_DIR}/_build/default/bin/client.exe" /usr/local/bin/aaau-client

# Install systemd service
echo "Installing systemd service..."
install -Dm644 "${SCRIPT_DIR}/aaau-server.service" /etc/systemd/system/aaau-server.service

# Reload systemd
echo "Reloading systemd daemon..."
systemctl daemon-reload

# Initialize aaau environment
echo "Initializing aaau environment..."
aaau-server init || true

echo ""
echo "Installation complete!"
echo ""
echo "Usage:"
echo "  systemctl start aaau-server     - Start the service"
echo "  systemctl stop aaau-server      - Stop the service"
echo "  systemctl enable aaau-server    - Enable on boot"
echo "  systemctl status aaau-server    - Check status"
echo "  journalctl -u aaau-server -f     - View logs"
