#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/cache
# The installed SwiftPM manifest libraries do not match this machine's Swift compiler.
# Compile the standalone source directly with the installed macOS SDK.
swiftc -O -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path "${PWD}/.build/cache" \
  -o .build/TouchlessHorizon Sources/*.swift \
  -framework AppKit -framework AVFoundation -framework Vision \
  -framework Speech -framework ApplicationServices
APP="${PWD}/Touchless Horizon.app"
mkdir -p "${APP}/Contents/MacOS"
cp .build/TouchlessHorizon "${APP}/Contents/MacOS/TouchlessHorizon"
cp Info.plist "${APP}/Contents/Info.plist"
codesign --force --deep --sign - "${APP}"
echo "Built ${APP}"
