#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR=""
for candidate in "$SCRIPT_DIR/.." "$SCRIPT_DIR" "/Users/sukhmansingh/Desktop/Coding/2026/AppMixer"; do
  if [[ -d "$candidate/VirtualAudioPlugin" ]]; then
    ROOT_DIR="$(cd "$candidate" && pwd)"
    break
  fi
done

if [[ -z "$ROOT_DIR" ]]; then
  echo "Could not find VirtualAudioPlugin sources. Run this script from the AppMixer repository."
  exit 1
fi
PLUGIN_NAME="AppMixerVirtualAudio.driver"
BUILD_DIR="$ROOT_DIR/.build/Driver"
PLUGIN_DIR="$BUILD_DIR/$PLUGIN_NAME"
MACOS_DIR="$PLUGIN_DIR/Contents/MacOS"
INSTALL_DIR="/Library/Audio/Plug-Ins/HAL"

if [[ "${EUID}" -ne 0 ]]; then
  exec /usr/bin/sudo "$0" "$@"
fi

/bin/rm -rf "$PLUGIN_DIR"
/bin/mkdir -p "$MACOS_DIR"
/bin/cp "$ROOT_DIR/VirtualAudioPlugin/Info.plist" "$PLUGIN_DIR/Contents/Info.plist"

/usr/bin/clang++ \
  -std=c++17 \
  -dynamiclib \
  -isysroot "$(/usr/bin/xcrun --sdk macosx --show-sdk-path)" \
  -framework CoreAudio \
  -framework CoreFoundation \
  -Wl,-exported_symbols_list,"$ROOT_DIR/VirtualAudioPlugin/AppMixerPlugin.exp" \
  "$ROOT_DIR/VirtualAudioPlugin/AppMixerAudioServerPlugIn.cpp" \
  -o "$MACOS_DIR/AppMixerVirtualAudio"

/usr/bin/codesign --force --sign - "$MACOS_DIR/AppMixerVirtualAudio"
/bin/mkdir -p "$INSTALL_DIR"
/bin/rm -rf "$INSTALL_DIR/$PLUGIN_NAME"
/bin/cp -R "$PLUGIN_DIR" "$INSTALL_DIR/$PLUGIN_NAME"
/usr/sbin/chown -R root:wheel "$INSTALL_DIR/$PLUGIN_NAME"
/bin/chmod -R 755 "$INSTALL_DIR/$PLUGIN_NAME"

/usr/bin/killall coreaudiod 2>/dev/null || true
echo "Installed $INSTALL_DIR/$PLUGIN_NAME"
