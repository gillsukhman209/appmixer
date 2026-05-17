#!/bin/zsh
set -euo pipefail

PLUGIN="/Library/Audio/Plug-Ins/HAL/AppMixerVirtualAudio.driver"

if [[ "${EUID}" -ne 0 ]]; then
  exec /usr/bin/sudo "$0" "$@"
fi

/bin/rm -rf "$PLUGIN"
/usr/bin/killall coreaudiod 2>/dev/null || true
echo "Removed $PLUGIN"
