#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_SCRIPT="$ROOT/build-pkg.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

awk '
  /^cat > "\$SUPPORT\/jumpmachines\.10s\.sh" <<'"'"'PLUGIN_EOF'"'"'$/ { copying=1; next }
  copying && /^PLUGIN_EOF$/ { exit }
  copying { print }
' "$BUILD_SCRIPT" > "$TMP/jumpmachines.10s.sh"
chmod +x "$TMP/jumpmachines.10s.sh"

run_plugin() {
  local home=$1
  local output
  mkdir -p "$home/Documents/SwiftBar"
  output=$(HOME="$home" "$TMP/jumpmachines.10s.sh")
  printf '%s\n' "${output%%$'\n'*}"
}

without_icon=$(run_plugin "$TMP/no-icon")
[[ "$without_icon" == "| sfimage=display symbolize=true width=16 height=16" ]] || {
  echo "unexpected no-icon header: $without_icon" >&2
  exit 1
}

mkdir -p "$TMP/with-icon/Documents/SwiftBar"
printf 'png' > "$TMP/with-icon/Documents/SwiftBar/.jumpicon.png"
with_icon=$(run_plugin "$TMP/with-icon")
[[ "$with_icon" == "| templateImage="*" width=16 height=16" ]] || {
  echo "unexpected image header: $with_icon" >&2
  exit 1
}

echo "plugin header fallback tests passed"
