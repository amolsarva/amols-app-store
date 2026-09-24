#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEMP="$(mktemp -d "${TMPDIR:-/tmp}/sunlight-checks.XXXXXX")"
swiftc -parse-as-library -target "$(uname -m)-apple-macos14.0" "$ROOT/Sources/Sunlight/Scenes.swift" "$ROOT/Sources/Sunlight/Program.swift" "$ROOT/Sources/Sunlight/Chime.swift" "$ROOT/Sources/Sunlight/LightModel.swift" "$ROOT/tests/check.swift" -o "$TEMP/check"
"$TEMP/check" "$@"
