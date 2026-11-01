#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p .build/cache
swiftc -sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  -module-cache-path "${PWD}/.build/cache" \
  Sources/GestureControl.swift Tests/main.swift -o .build/gesture-tests
.build/gesture-tests
