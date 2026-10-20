#!/usr/bin/env bash
# Diagnostic only. Does not change Mac networking.
set -euo pipefail

echo "macOS: $(sw_vers -productVersion 2>/dev/null || echo 'unknown')"
echo "Python: $(python3 --version 2>&1 || echo 'not installed')"
if command -v route >/dev/null 2>&1 && command -v ipconfig >/dev/null 2>&1; then
    iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
    if [[ -n "$iface" ]]; then
        echo "Default interface: $iface"
        echo "IPv4: $(ipconfig getifaddr "$iface" 2>/dev/null || echo 'not assigned')"
    else
        echo "Default interface not detected"
    fi
fi
echo "No networking settings were changed."
