#!/bin/bash
set -euo pipefail
if [[ "$(uname -s)" != Darwin ]]; then
  printf '此整合驗證需要 macOS AVFoundation，不能在 Linux 宣稱通過。\n' >&2
  exit 2
fi
mkdir -p build
xcrun swiftc -swift-version 5 -parse-as-library \
  ChaiMusic/Core/Models.swift ChaiMusic/Core/SourceModels.swift \
  ChaiMusic/Services/AudioUpgradeCoordinator.swift Tests/Integration/AudioIntegration.swift \
  -o build/audio-integration
build/audio-integration build/fixtures
