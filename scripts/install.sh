#!/bin/zsh
# Build, quit the running copy, install to ~/Applications and relaunch. Launch at login
# (SMAppService.mainApp) registers whichever copy is running, so run the installed one.
set -euo pipefail
cd "${0:A:h}/.."
./scripts/bundle.sh release
dest=~/Applications/S12AdaptiveEQ.app
osascript -e 'tell application id "com.emiralan.s12-adaptive-eq" to quit' 2>/dev/null || true
for _ in {1..30}; do pgrep -xq S12AdaptiveEQ || break; sleep 0.1; done
mkdir -p ~/Applications
rm -rf "$dest"
cp -R build/S12AdaptiveEQ.app "$dest"
open "$dest"
echo "installed → $dest"
