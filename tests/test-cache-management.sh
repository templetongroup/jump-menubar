#!/bin/bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BUILD_SCRIPT="$ROOT/build-pkg.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

extract_script() {
  local name=$1
  local marker=$2
  awk -v start="cat > \"\$SUPPORT/$name\" <<'$marker'" -v marker="$marker" '
    $0 == start { copying=1; next }
    copying && $0 == marker { exit }
    copying { print }
  ' "$BUILD_SCRIPT" > "$TMP/$name"
  chmod +x "$TMP/$name"
}

extract_script clear-cache.sh CLEAR_EOF
extract_script import-export.sh IMPORT_EOF

TEST_HOME="$TMP/home"
mkdir -p "$TEST_HOME/JumpMenu/servers" "$TEST_HOME/Desktop" "$TEST_HOME/.Trash"
printf '{"DisplayName":"Old Machine"}\n' > "$TEST_HOME/JumpMenu/servers/old.jump"
printf 'keep\n' > "$TEST_HOME/JumpMenu/tailscale-names.txt"

HOME="$TEST_HOME" JUMPMENU_SKIP_CONFIRM=1 "$TMP/clear-cache.sh"
test -f "$TEST_HOME/JumpMenu/servers/old.jump"

HOME="$TEST_HOME" JUMPMENU_SKIP_CONFIRM=1 "$TMP/clear-cache.sh" --clear
test ! -e "$TEST_HOME/JumpMenu/servers/old.jump"
test -f "$TEST_HOME/JumpMenu/tailscale-names.txt"
find "$TEST_HOME/.Trash" -type f -name old.jump | grep -q .

EXPORT="$TMP/export"
mkdir -p "$EXPORT/servers"
printf '{"DisplayName":"New Machine"}\n' > "$EXPORT/servers/new.jump"
(
  cd "$EXPORT"
  zip -qr "$TEST_HOME/Desktop/JumpDesktopServers.jdz" servers
)

printf '{"DisplayName":"Stale Machine"}\n' > "$TEST_HOME/JumpMenu/servers/stale.jump"
HOME="$TEST_HOME" JUMPMENU_QUIET=1 "$TMP/import-export.sh"
test -f "$TEST_HOME/JumpMenu/servers/stale.jump"

HOME="$TEST_HOME" JUMPMENU_QUIET=1 "$TMP/import-export.sh" --import
test -f "$TEST_HOME/JumpMenu/servers/new.jump"
test ! -e "$TEST_HOME/JumpMenu/servers/stale.jump"
test -f "$TEST_HOME/JumpMenu/tailscale-names.txt"
find "$TEST_HOME/.Trash" -type f -name stale.jump | grep -q .

echo "cache management tests passed"
