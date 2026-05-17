#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
xcodebuild -project "$ROOT_DIR/AppMixer.xcodeproj" -scheme AppMixer -configuration Debug build
