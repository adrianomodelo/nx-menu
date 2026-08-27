#!/usr/bin/env bash
# install.sh — put nx-menu in ~/.local/bin, seed the item list, and bind a key.
#
#   ./install.sh                 # binds <Super>q
#   ./install.sh '<Super>space'  # binds something else
#
# Idempotent: running it twice does not duplicate the shortcut.
set -uo pipefail

KEY="${1:-<Super>q}"
BIN="${NX_MENU_BIN_DIR:-$HOME/.local/bin}"
SRC="$(cd "$(dirname "$0")" && pwd)"

export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

command -v rofi >/dev/null 2>&1 || {
  echo "rofi is required. On Debian/Ubuntu: sudo apt install rofi" >&2
  exit 1
}

mkdir -p "$BIN"
install -m 0755 "$SRC/nx-menu" "$SRC/nx-menu-sync" "$SRC/reset-keybinds.sh" "$BIN/"
echo "installed into $BIN"

case ":$PATH:" in
  *":$BIN:"*) ;;
  *) echo "note: $BIN is not in your PATH; add it to your shell profile" ;;
esac

# Seed the item list from the apps currently pinned in GNOME, if there are any.
if [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/nx-menu/apps.tsv" ]; then
  "$BIN/nx-menu-sync" || true
  if [ ! -s "${XDG_CONFIG_HOME:-$HOME/.config}/nx-menu/apps.tsv" ]; then
    mkdir -p "${XDG_CONFIG_HOME:-$HOME/.config}/nx-menu"
    cp "$SRC/examples/apps.tsv.example" "${XDG_CONFIG_HOME:-$HOME/.config}/nx-menu/apps.tsv"
    echo "seeded a sample item list; edit it with: nx-menu add <app>"
  fi
fi

SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"
SLOT="nx-menu"

cur=$(gsettings get $SCHEMA custom-keybindings)
case "$cur" in
  *"$BASE/$SLOT/"*) echo "shortcut slot already registered" ;;
  *)
    if [ "$cur" = "@as []" ] || [ "$cur" = "[]" ]; then
      gsettings set $SCHEMA custom-keybindings "['$BASE/$SLOT/']"
    else
      gsettings set $SCHEMA custom-keybindings "${cur%]}, '$BASE/$SLOT/']"
    fi
    ;;
esac

P="$SCHEMA.custom-keybinding:$BASE/$SLOT/"
gsettings set "$P" name 'nx-menu'
gsettings set "$P" command "$BIN/nx-menu"
gsettings set "$P" binding "$KEY"
echo "bound $KEY -> $BIN/nx-menu"

# See the README: registering the slot is not enough for the daemon to actually
# grab the key. This is the step people miss.
echo
echo "--- forcing the daemon to re-register the grabs ---"
"$BIN/reset-keybinds.sh" >/dev/null 2>&1 && echo "done"

echo
echo "Press $KEY. If nothing happens, check ~/.cache/nx-menu.log:"
echo "  a line there = the key reached the script, the problem is rofi"
echo "  no line     = the key never arrived, the problem is the grab"
