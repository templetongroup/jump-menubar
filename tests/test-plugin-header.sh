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
[[ "$without_icon" == "| sfimage=display symbolize=true" ]] || {
  echo "unexpected no-icon header: $without_icon" >&2
  exit 1
}

mkdir -p "$TMP/with-icon/Documents/SwiftBar"
printf 'png' > "$TMP/with-icon/Documents/SwiftBar/.jumpicon.png"
with_icon=$(run_plugin "$TMP/with-icon")
[[ "$with_icon" == "| templateImage="* ]] || {
  echo "unexpected image header: $with_icon" >&2
  exit 1
}

[[ "$with_icon" != *" width="* && "$with_icon" != *" height="* ]] || {
  echo "bitmap header contains unsupported size parameters: $with_icon" >&2
  exit 1
}

grep -q '^var S = 22;$' "$BUILD_SCRIPT" || {
  echo "icon generator is not producing a standard 22x22 template" >&2
  exit 1
}

grep -q 'x-apple.systempreferences:com.apple.ControlCenter-Settings.extension' "$BUILD_SCRIPT" || {
  echo "installer does not open the macOS 26 Menu Bar settings" >&2
  exit 1
}

grep -q 'Allow in the Menu Bar' "$BUILD_SCRIPT" || {
  echo "installer does not explain the required macOS 26 visibility toggle" >&2
  exit 1
}

if grep -q 'SEARCH_DIRS=.*Library/Containers\|^[[:space:]]*"\$HOME/Library/Containers' "$BUILD_SCRIPT"; then
  echo "plugin still scans the unbounded Jump Desktop sandbox" >&2
  exit 1
fi

echo "plugin header fallback tests passed"
