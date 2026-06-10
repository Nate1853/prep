#!/usr/bin/env bash
#
# prep.sh — prime a fresh Fedora 44+ machine.
# Asks for the sudo password once, then runs unattended.

set -euo pipefail

# --- Ask for sudo once, keep it alive for the rest of the script ---
sudo -v
# Refresh the sudo timestamp in the background until this script exits.
while true; do sudo -n true; sleep 60; kill -0 "$$" 2>/dev/null || exit; done &

echo "==> Updating package metadata and upgrading the system..."
sudo dnf upgrade --refresh -y

echo "==> Done."
