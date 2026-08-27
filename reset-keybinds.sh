#!/usr/bin/env bash
# reset-keybinds.sh — force gnome-settings-daemon to re-register every custom
# keyboard shortcut grab.
#
# Why this exists: creating a custom keybinding does NOT make gsd-media-keys
# start serving it, and changing an existing slot's `binding` does not either.
# What triggers the re-registration is the `custom-keybindings` ARRAY changing.
#
# Symptom: `gsettings get` shows the correct binding and command, the daemon is
# running, and the key does nothing. Or worse, a shortcut that used to work goes
# silently dead after you add an unrelated one.
#
# This script empties the array, waits, and puts the exact same list back. It
# writes a snapshot of every slot to a backup file first.
#
# No arguments. Safe to run at any time. Does not restart gnome-shell.
set -uo pipefail

export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=/run/user/$(id -u)/bus}"

SCHEMA="org.gnome.settings-daemon.plugins.media-keys"
BASE="/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings"

ORIG=$(gsettings get "$SCHEMA" custom-keybindings)
echo "current array: $ORIG"

if [ "$ORIG" = "@as []" ] || [ "$ORIG" = "[]" ]; then
  echo "no custom keybindings configured, nothing to do"
  exit 0
fi

# Slot names, derived from the array itself so this works on any machine.
slots=$(printf '%s' "$ORIG" | tr ',' '\n' | sed -n "s#.*custom-keybindings/\([^/]*\)/.*#\1#p")

BKP="${XDG_CACHE_HOME:-$HOME/.cache}/gnome-keybinds-backup-$(date +%Y%m%d-%H%M%S).txt"
mkdir -p "$(dirname "$BKP")"
{
  echo "custom-keybindings = $ORIG"
  for slot in $slots; do
    P="$SCHEMA.custom-keybinding:$BASE/$slot/"
    printf '%s: name=%s binding=%s command=%s\n' "$slot" \
      "$(gsettings get "$P" name 2>/dev/null)" \
      "$(gsettings get "$P" binding 2>/dev/null)" \
      "$(gsettings get "$P" command 2>/dev/null)"
  done
} > "$BKP"
echo "backup written to: $BKP"

echo "--- emptying the array (grabs are released) ---"
gsettings set "$SCHEMA" custom-keybindings "@as []"
sleep 2

echo "--- restoring the full list (grabs are re-registered) ---"
gsettings set "$SCHEMA" custom-keybindings "$ORIG"
sleep 1

echo
echo "--- verifying no slot lost its values ---"
for slot in $slots; do
  P="$SCHEMA.custom-keybinding:$BASE/$slot/"
  printf '  %-22s %-24s %s\n' "$slot" \
    "$(gsettings get "$P" binding 2>/dev/null)" \
    "$(gsettings get "$P" command 2>/dev/null)"
done

echo
echo "Now press your shortcuts. Reading gsettings proves the config, not the grab:"
echo "the only real check is whether the command actually runs."
