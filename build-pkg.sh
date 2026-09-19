#!/bin/bash
# build-pkg.sh — builds signed + notarized Jump Menubar installer (Templeton Group)
set -e

VERSION="1.2.2"
IDENTIFIER="com.templeton.jumpmenu"
NOTARY_PROFILE="templeton-notary"

if [ -z "${SIGN_ID:-}" ]; then
  SIGN_ID=$(security find-identity -v -p basic 2>/dev/null | grep -o '"Developer ID Installer:[^"]*"' | head -1 | tr -d '"')
fi
if [ -z "$SIGN_ID" ]; then
  echo "!! No 'Developer ID Installer' certificate found. Create it in Xcode:"
  echo "   Xcode > Settings > Accounts > Manage Certificates > + > Developer ID Installer"
  exit 1
fi
echo "== Signing as: $SIGN_ID"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
PAYLOAD="$WORK/payload"
SCRIPTS="$WORK/scripts"
SUPPORT="$PAYLOAD/usr/local/jumpmenu"
mkdir -p "$PAYLOAD/Applications" "$SUPPORT" "$SCRIPTS"

echo "== Downloading SwiftBar for bundling..."
url=$(curl -s https://api.github.com/repos/swiftbar/SwiftBar/releases/latest | grep -o 'https://[^"]*\.zip' | head -1)
curl -sL -o "$WORK/SwiftBar.zip" "$url"
ditto -x -k "$WORK/SwiftBar.zip" "$PAYLOAD/Applications"
[ -d "$PAYLOAD/Applications/SwiftBar.app" ] || { echo "!! SwiftBar download failed"; exit 1; }

cat > "$SUPPORT/jumpmachines.10s.sh" <<'PLUGIN_EOF'
#!/bin/bash
# <bitbar.title>Jump Desktop Machines</bitbar.title>
# <swiftbar.hideAbout>true</swiftbar.hideAbout>
# <swiftbar.hideRunInTerminal>true</swiftbar.hideRunInTerminal>
# <swiftbar.hideLastUpdated>true</swiftbar.hideLastUpdated>

ICON="$HOME/Documents/SwiftBar/.jumpicon.png"
if [ -s "$ICON" ]; then
  echo "| templateImage=$(/usr/bin/base64 -i "$ICON")"
else
  echo "| sfimage=display symbolize=true"
fi
echo "---"

# The app sandbox can block directory enumeration indefinitely on macOS 26.
# The Jump export is small, stable, and is the supported machine source.
SEARCH_DIRS=(
  "$HOME/JumpMenu"
)
MAP="$HOME/JumpMenu/tailscale-names.txt"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

for d in "${SEARCH_DIRS[@]}"; do
  [ -d "$d" ] || continue
  find "$d" -type f -name "*.jump" 2>/dev/null
done | while IFS= read -r f; do
  info=$(/usr/bin/osascript -l JavaScript -e '
    function run(argv) {
      ObjC.import("Foundation");
      var s = $.NSString.stringWithContentsOfFileEncodingError(argv[0], $.NSUTF8StringEncoding, null);
      if (!s) return "";
      try {
        var j = JSON.parse(ObjC.unwrap(s));
        var name = j.DisplayName || j.TcpHostName || "";
        var host = j.TcpHostName || "";
        var port = "";
        if (j.TcpPort) port = String(j.TcpPort);
        else if (j.ProtocolTypeCode == 1) port = "3389";
        else if (j.ProtocolTypeCode == 2) port = "5900";
        return [name, host, port].join("\t");
      } catch(e) { return ""; }
    }' "$f" 2>/dev/null)
  name=$(printf '%s' "$info" | cut -f1)
  host=$(printf '%s' "$info" | cut -f2)
  port=$(printf '%s' "$info" | cut -f3)
  [ -z "$name" ] && name=$(basename "$f" .jump)
  name=$(printf '%s' "$name" | sed 's/[[:space:]]*$//')
  [ -z "$host" ] && host="-"
  [ -z "$port" ] && port="-"
  printf '%s\t%s\t%s\t%s\n' "$name" "$f" "$host" "$port"
done > "$TMP/raw"

sort -f "$TMP/raw" | awk -F'\t' '!seen[tolower($1)]++' > "$TMP/list"

# Authoritative status from tailscale where possible
TS_BIN=""
command -v tailscale >/dev/null 2>&1 && TS_BIN="tailscale"
[ -z "$TS_BIN" ] && [ -x "/Applications/Tailscale.app/Contents/MacOS/Tailscale" ] && TS_BIN="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
if [ -n "$TS_BIN" ]; then
  "$TS_BIN" status --json > "$TMP/ts.json" 2>/dev/null || true
fi
touch "$TMP/ts.json"

/usr/bin/osascript -l JavaScript - "$TMP/list" "$MAP" "$TMP/ts.json" <<'JXA' > "$TMP/tstatus" 2>/dev/null
function run(argv) {
  ObjC.import("Foundation");
  function read(p){var s=$.NSString.stringWithContentsOfFileEncodingError(p,$.NSUTF8StringEncoding,null);return s?ObjC.unwrap(s):"";}
  function norm(x){return x.toLowerCase().replace(/[^a-z0-9]/g,"");}
  var list = read(argv[0]).split("\n").filter(function(l){return l;});
  var map = {};
  read(argv[1]).split("\n").forEach(function(l){
    if (l.indexOf("#") === 0) return;
    var i = l.indexOf("|");
    if (i > 0) map[norm(l.slice(0,i))] = l.slice(i+1).trim();
  });
  var peers = {};
  try {
    var ts = JSON.parse(read(argv[2]));
    var P = ts.Peer || {};
    Object.keys(P).forEach(function(k){
      var p = P[k];
      if (p.HostName) { var h = norm(p.HostName); if (peers[h] === undefined) peers[h] = p.Online ? 1 : 0; }
    });
    Object.keys(P).forEach(function(k){
      var p = P[k];
      if (p.DNSName) peers[norm(p.DNSName.split(".")[0])] = p.Online ? 1 : 0;
    });
  } catch(e) {}
  var out = [];
  list.forEach(function(line){
    var name = line.split("\t")[0];
    var nn = norm(name);
    var target = null;
    if (map[nn] !== undefined) { target = (map[nn] === "-") ? null : norm(map[nn]); }
    else if (peers[nn] !== undefined) { target = nn; }
    else {
      var hits = Object.keys(peers).filter(function(p){ return p.indexOf(nn) >= 0 || nn.indexOf(p) >= 0; });
      if (hits.length === 1) target = hits[0];
    }
    if (target !== null && peers[target] !== undefined) out.push(name + "\t" + (peers[target] ? "O" : "X"));
    else out.push(name + "\tN");
  });
  return out.join("\n");
}
JXA

if [ ! -s "$TMP/list" ]; then
  echo "No machines found | color=gray"
  echo "In Jump Desktop: File > Export to Desktop, | color=gray"
  echo "then click Import below. | color=gray"
else
  # Fallback probes only for machines tailscale couldn't answer
  n=0
  while IFS=$'\t' read -r name path host port; do
    n=$((n+1))
    [ "$host" = "-" ] && host=""
    [ "$port" = "-" ] && port=""
    ts=$(grep -F "$name	" "$TMP/tstatus" 2>/dev/null | head -1 | cut -f2)
    if [ "$ts" = "O" ] || [ "$ts" = "X" ]; then
      echo "$ts" > "$TMP/st.$n"
    else
      {
        if [ -z "$host" ]; then
          echo "U"
        elif [ -n "$port" ]; then
          nc -z -G 1 "$host" "$port" >/dev/null 2>&1 && echo "O" || echo "X"
        else
          ping -c 1 -t 1 "$host" >/dev/null 2>&1 && echo "O" || echo "X"
        fi
      } > "$TMP/st.$n" &
    fi
  done < "$TMP/list"
  wait
  n=0
  while IFS=$'\t' read -r name path host port; do
    n=$((n+1))
    st=$(cat "$TMP/st.$n" 2>/dev/null)
    case "$st" in
      O) dot="🟢" ;;
      X) dot="🔴" ;;
      *) dot="⚪" ;;
    esac
    echo "$dot $name | bash=/usr/bin/open param1=\"$path\" terminal=false"
  done < "$TMP/list"
fi

echo "---"
echo "Import Jump export from Desktop | bash=/bin/bash param1=/usr/local/jumpmenu/import-export.sh terminal=false refresh=true"
echo "Open Jump Desktop | bash=/usr/bin/open param1=-a param2=\"Jump Desktop\" terminal=false"
echo "Refresh | refresh=true"
PLUGIN_EOF
chmod +x "$SUPPORT/jumpmachines.10s.sh"

cat > "$SUPPORT/import-export.sh" <<'IMPORT_EOF'
#!/bin/bash
jdz=$(ls -t "$HOME/Desktop"/*.jdz 2>/dev/null | head -1)
if [ -n "$jdz" ]; then
  mkdir -p "$HOME/JumpMenu"
  unzip -o "$jdz" -d "$HOME/JumpMenu" >/dev/null
  osascript -e 'display notification "Machines imported. Menu updates in a few seconds." with title "Jump Menubar"'
else
  osascript -e 'display notification "No export found. In Jump Desktop: File > Export, save to Desktop, then click Import again." with title "Jump Menubar"'
fi
IMPORT_EOF
chmod +x "$SUPPORT/import-export.sh"

cat > "$SUPPORT/geticon.jxa" <<'JXA_EOF'
ObjC.import('AppKit');
var ws = $.NSWorkspace.sharedWorkspace;
var app = ws.URLForApplicationWithBundleIdentifier('com.p5sys.jump.mac.viewer');
var path = (app && !app.isNil()) ? app.path : $('/Applications/Jump Desktop.app');
var icon = ws.iconForFile(path);
// SwiftBar renders bitmap pixels at their intrinsic point size. Generate a
// standard menu-bar-sized template instead of relying on unsupported
// width/height output parameters.
var S = 22;
icon.size = $.NSMakeSize(S, S);
function newRep() {
  return $.NSBitmapImageRep.alloc.initWithBitmapDataPlanesPixelsWidePixelsHighBitsPerSampleSamplesPerPixelHasAlphaIsPlanarColorSpaceNameBytesPerRowBitsPerPixel(null, S, S, 8, 4, true, false, $.NSCalibratedRGBColorSpace, 0, 0);
}
var rep = newRep();
$.NSGraphicsContext.saveGraphicsState;
$.NSGraphicsContext.setCurrentContext($.NSGraphicsContext.graphicsContextWithBitmapImageRep(rep));
icon.drawInRectFromRectOperationFraction($.NSMakeRect(0,0,S,S), $.NSZeroRect, $.NSCompositingOperationSourceOver, 1.0);
$.NSGraphicsContext.restoreGraphicsState;
var vals = [], bright = 0;
for (var y=0; y<S; y++) for (var x=0; x<S; x++) {
  var c = rep.colorAtXY(x,y).colorUsingColorSpace($.NSColorSpace.sRGBColorSpace);
  var a = c.alphaComponent, b = 0;
  if (a > 0.5) b = 0.299*c.redComponent + 0.587*c.greenComponent + 0.114*c.blueComponent;
  vals.push([a,b]);
  if (a>0.5 && b>0.7) bright++;
}
var useBright = bright >= 20;
var mask = [];
var i=0;
for (var y=0; y<S; y++) { mask.push([]); for (var x=0; x<S; x++) {
  var a=vals[i][0], b=vals[i][1]; i++;
  mask[y].push(useBright ? (a>0.5 && b>0.7) : (a>0.5 && b<0.35));
}}
var label = [], comps = {}, next = 1;
for (var y=0; y<S; y++) { label.push([]); for (var x=0; x<S; x++) label[y].push(0); }
for (var y=0; y<S; y++) for (var x=0; x<S; x++) {
  if (mask[y][x] && label[y][x] === 0) {
    var id = next++, stack = [[x,y]], count = 0;
    label[y][x] = id;
    while (stack.length) {
      var p = stack.pop(); count++;
      var px = p[0], py = p[1];
      for (var dy=-1; dy<=1; dy++) for (var dx=-1; dx<=1; dx++) {
        var nx = px+dx, ny = py+dy;
        if (nx>=0 && ny>=0 && nx<S && ny<S && mask[ny][nx] && label[ny][nx]===0) {
          label[ny][nx] = id; stack.push([nx,ny]);
        }
      }
    }
    comps[id] = count;
  }
}
var best = 0, bestCount = 0;
for (var k in comps) if (comps[k] > bestCount) { bestCount = comps[k]; best = parseInt(k); }
var out = newRep();
var black = $.NSColor.colorWithCalibratedRedGreenBlueAlpha(0,0,0,1);
var clear = $.NSColor.colorWithCalibratedRedGreenBlueAlpha(0,0,0,0);
for (var y=0; y<S; y++) for (var x=0; x<S; x++) {
  out.setColorAtXY(label[y][x] === best ? black : clear, x, y);
}
var png = out.representationUsingTypeProperties($.NSBitmapImageFileTypePNG, $({}));
png.writeToFileAtomically($(ObjC.unwrap($.NSHomeDirectory()) + '/Documents/SwiftBar/.jumpicon.png'), true);
JXA_EOF

cat > "$SUPPORT/user-setup.sh" <<'USER_EOF'
#!/bin/bash
SRC="/usr/local/jumpmenu"
PLUG="$HOME/Documents/SwiftBar"
mkdir -p "$PLUG"
cp "$SRC/jumpmachines.10s.sh" "$PLUG/"
chmod +x "$PLUG/jumpmachines.10s.sh"
/usr/bin/osascript -l JavaScript "$SRC/geticon.jxa" >/dev/null 2>&1 || true
defaults write com.ameba.SwiftBar PluginDirectory -string "$PLUG"
jdz=$(ls -t "$HOME/Desktop"/*.jdz 2>/dev/null | head -1)
if [ -n "$jdz" ]; then
  mkdir -p "$HOME/JumpMenu"
  unzip -o "$jdz" -d "$HOME/JumpMenu" >/dev/null 2>&1
fi
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$HOME/Library/LaunchAgents/com.templeton.jumpmenu.plist" <<'LA'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.templeton.jumpmenu</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/open</string>
    <string>-a</string>
    <string>SwiftBar</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
LA
open -a SwiftBar
os_major=$(/usr/bin/sw_vers -productVersion | /usr/bin/cut -d. -f1)
if [ "${os_major:-0}" -ge 26 ]; then
  visibility_btn=$(osascript <<'OSA' 2>/dev/null
display dialog "Jump Menubar is installed, but macOS 26 hides newly installed menu-bar apps until you allow them.

In System Settings > Menu Bar, turn on SwiftBar under ‘Allow in the Menu Bar.’ This is required even when the menu bar has plenty of room." buttons {"Later", "Open Menu Bar Settings"} default button "Open Menu Bar Settings" with title "Finish Jump Menubar Setup" with icon note
OSA
)
  case "$visibility_btn" in
    *"Open Menu Bar Settings"*) open "x-apple.systempreferences:com.apple.ControlCenter-Settings.extension" || true ;;
  esac
fi
count=$(find "$HOME/JumpMenu" -type f -name "*.jump" 2>/dev/null | wc -l | tr -d ' ')
if [ "$count" -eq 0 ]; then
  btn=$(osascript <<'OSA' 2>/dev/null
display dialog "Jump Menubar is installed, but no machines were found on this Mac yet.

Machines synced through your Jump account need a one-time export:

1. Open Jump Desktop
2. Click File > Export and save to the Desktop
3. Click the Jump icon in the menubar, then 'Import Jump export from Desktop'" buttons {"Later", "Open Jump Desktop"} default button "Open Jump Desktop" with title "Jump Menubar" with icon note
OSA
)
  case "$btn" in *"Open Jump Desktop"*) open -a "Jump Desktop" || true ;; esac
fi
USER_EOF
chmod +x "$SUPPORT/user-setup.sh"

cat > "$SCRIPTS/postinstall" <<'POST_EOF'
#!/bin/bash
cu=$(/usr/sbin/scutil <<< "show State:/Users/ConsoleUser" | /usr/bin/awk '/Name :/ && !/loginwindow/ {print $3}')
if [ -n "$cu" ] && [ "$cu" != "root" ]; then
  uid=$(/usr/bin/id -u "$cu")
  /bin/launchctl asuser "$uid" /usr/bin/sudo -u "$cu" /bin/bash /usr/local/jumpmenu/user-setup.sh || true
fi
exit 0
POST_EOF
chmod +x "$SCRIPTS/postinstall"

OUT="$HOME/Desktop/JumpMenubar-$VERSION.pkg"
echo "== Building component package..."
pkgbuild --root "$PAYLOAD" --scripts "$SCRIPTS" \
  --identifier "$IDENTIFIER" --version "$VERSION" \
  --install-location / "$WORK/component.pkg"

RES="$WORK/resources"
mkdir -p "$RES"
cat > "$RES/conclusion.html" <<'HTML_EOF'
<!DOCTYPE html><html><head><meta charset="utf-8"><style>
body{font-family:-apple-system,Helvetica,Arial,sans-serif;font-size:13px;color:#333;padding:0 10px}
h2{font-size:16px;margin-bottom:6px}
.box{background:#f5f5f7;border-radius:8px;padding:10px 14px;margin:12px 0}
</style></head><body>
<h2>Jump Desktop Menubar is installed</h2>
<p>Look for the Jump icon in the menubar at the top-right of the screen.
Click it to see your machines &mdash; a green dot means the machine is
responding. Click any machine to connect. The menubar starts
automatically at login.</p>
<div class="box"><b>Using macOS 26?</b><br>
macOS hides newly installed menu-bar apps by default. Open
<b>System Settings &gt; Menu Bar</b> and turn on <b>SwiftBar</b> under
<b>Allow in the Menu Bar</b>. This is required even when there is plenty
of room in the menu bar.
</div>
<div class="box"><b>Menu empty or machines missing?</b><br>
Machines synced through your Jump account need a one-time export:<br>
1. Open <b>Jump Desktop</b><br>
2. Click <b>File &gt; Export</b> and save to the <b>Desktop</b><br>
3. Click the Jump menubar icon &gt; <b>Import Jump export from Desktop</b>
</div>
</body></html>
HTML_EOF

cat > "$WORK/distribution.xml" <<DIST_EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
  <title>Jump Desktop Menubar $VERSION</title>
  <conclusion file="conclusion.html"/>
  <options customize="never" require-scripts="false"/>
  <choices-outline><line choice="default"><line choice="$IDENTIFIER"/></line></choices-outline>
  <choice id="default"/>
  <choice id="$IDENTIFIER" visible="false"><pkg-ref id="$IDENTIFIER"/></choice>
  <pkg-ref id="$IDENTIFIER" version="$VERSION" onConclusion="none">component.pkg</pkg-ref>
</installer-gui-script>
DIST_EOF

echo "== Wrapping and signing installer..."
productbuild --distribution "$WORK/distribution.xml" \
  --package-path "$WORK" --resources "$RES" \
  --sign "$SIGN_ID" "$OUT"

echo "== Submitting to Apple for notarization (usually 1-5 minutes)..."
xcrun notarytool submit "$OUT" --keychain-profile "$NOTARY_PROFILE" --wait

echo "== Stapling notarization ticket..."
xcrun stapler staple "$OUT"

echo ""
echo "== DONE: $OUT"
