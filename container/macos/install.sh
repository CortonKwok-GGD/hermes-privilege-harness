#!/bin/bash
# Install macOS container sandbox for Hermes
# Run this on macOS 26+ with Apple container CLI installed.

set -e
echo "=== Hermes macOS Container Sandbox Install ==="

# Build image
echo "[1/3] Building hermes-vm image..."
container build -t hermes-vm:latest --arch amd64 \
    -f "$(dirname "$0")/Dockerfile.hermes-vm" "$(dirname "$0")"

# Install hermes-run
echo "[2/3] Installing hermes-run..."
cp "$(dirname "$0")/hermes-run.sh" /tmp/hermes-run
# macOS 26 SIP protection — use dd instead of cp for /usr/local/bin/
if [ -f /usr/local/bin/hermes-run ]; then rm -f /usr/local/bin/hermes-run; fi
dd if=/tmp/hermes-run of=/usr/local/bin/hermes-run 2>/dev/null
chmod 755 /usr/local/bin/hermes-run

echo "[3/3] Verifying..."
/usr/local/bin/hermes-run whoami
echo ""
echo "=== Install complete ==="
echo "hermes-run is ready at /usr/local/bin/hermes-run"
