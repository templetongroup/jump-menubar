# Jump Desktop Menubar
The Templeton Group


Unofficial tool — not affiliated with or endorsed by Jump Desktop / p5sys.
A macOS menubar for Jump Desktop: lists every machine with a live
status dot — click to connect. White Jump icon, starts at login.

- green = responding on the network
- red = not responding (may still connect via Jump relay)
- white = no address on file to probe

Runs on SwiftBar (MIT), which the installer bundles automatically.

## Deploy to a Mac

Copy `JumpMenubar-<version>.pkg` to the Mac, double-click, Install.
The pkg is signed and notarized — no Gatekeeper prompts.

If account-synced (Fluid) machines are missing from the menu:
in Jump Desktop do File > Export, save to the Desktop, then click
"Import Jump export from Desktop" in the menubar menu.

## Build the installer

Requires: a Mac with Xcode command line tools, a
"Developer ID Installer" certificate in the keychain, and notary
credentials stored once via:

    xcrun notarytool store-credentials templeton-notary \
      --apple-id APPLE_ID_EMAIL --team-id 5VY66S6G3M

Then:

    bash build-pkg.sh

Output: `~/Desktop/JumpMenubar-<version>.pkg` — signed, notarized,
stapled. Bump VERSION inside build-pkg.sh for new releases.

## Layout

- `build-pkg.sh` — builds the pkg; contains the menubar plugin,
  the icon generator (traces a white template icon from the local
  Jump Desktop app icon), the Desktop-export importer, and the
  per-user postinstall setup, all embedded as heredocs.

Installed footprint on target Macs:
- `/Applications/SwiftBar.app`
- `/usr/local/jumpmenu/` (plugin source + helpers)
- `~/Documents/SwiftBar/` (active plugin + generated icon)
- `~/Library/LaunchAgents/com.templeton.jumpmenu.plist`

## Machine status dots

Where Tailscale is installed, online status comes from `tailscale
status` — authoritative across networks, no probing. Jump machine
names are matched to tailscale hostnames automatically; for names
that differ or collide, add lines to `~/JumpMenu/tailscale-names.txt`:

    Jump Name|tailscale-hostname
    Some Machine|-        (dash = not on tailscale)

Machines without a tailscale match fall back to a direct network
probe if they have an address, otherwise show a white "unknown" dot.
