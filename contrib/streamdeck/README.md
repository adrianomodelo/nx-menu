# nx-menu on a Stream Deck MK.2

Mirrors the same menu `nx-menu` shows in rofi (`~/.config/nx-menu/apps.tsv`)
as buttons on an Elgato Stream Deck MK.2: item 1 goes to the top-left key,
item 2 next to it, and so on, reading order, left to right and top to
bottom. Pressing a key runs `nx-menu launch <N>`, so it inherits window
raising, the `new` flag, and non-`.desktop` targets for free — nothing about
launching is reimplemented here.

The item list is never copied into this script. It is read from the TSV at
every start and re-read whenever the file's mtime changes, so `nx-menu add`
shows up on the deck without restarting anything. See `selftest.sh` for the
check that would catch a copy of the list drifting from the source.

## Dependencies

- `libhidapi-libusb0` (the system library the Python `hidapi` binding needs
  to talk to the USB device)
- Python packages: `streamdeck`, `pillow`

```bash
sudo apt install libhidapi-libusb0
pip install --user streamdeck pillow
```

## Install

1. Copy the script and mark it executable:

   ```bash
   cp nx-menu-deck.py ~/.local/bin/nx-menu-deck
   chmod +x ~/.local/bin/nx-menu-deck
   ```

2. Install the udev rule so the device is usable without root, then reload:

   ```bash
   sudo cp 99-streamdeck.rules /etc/udev/rules.d/
   sudo udevadm control --reload-rules && sudo udevadm trigger
   ```

   Unplug and replug the deck after this if it was already connected.

3. Install and enable the user service:

   ```bash
   mkdir -p ~/.config/systemd/user
   cp nx-menu-deck.service ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now nx-menu-deck.service
   ```

   The unit uses `%h` (systemd's specifier for the invoking user's home), so
   it does not need editing for a specific username or path.

## Dry run (no hardware required)

```bash
python3 nx-menu-deck.py --dry-run --out /tmp/deck-preview
```

Renders `key-00.png` .. `key-14.png` (72x72, one per key, blank for unused
ones) into the given directory and prints the key -> item mapping to stdout.
This path never imports the `streamdeck` package — it only needs Pillow — so
it works on a machine with no Stream Deck attached and no `streamdeck`
package installed. This is also what `selftest.sh` exercises.

To point either the dry run or the real daemon at a different file, same
convention as `nx-menu` itself:

```bash
NX_MENU_CONF=/path/to/apps.tsv nx-menu-deck.py --dry-run --out /tmp/deck-preview
```

## Known limitations

- **SVG icons are not rendered directly.** Pillow does not rasterize SVG. An
  item whose icon is an `.svg` file (or any icon Pillow can't open) first
  looks for a same-basename `.png` in the usual icon directories and the
  flatpak app tree — the same places `nx-menu-sync`'s `resolve_icon()`
  already searches — preferring the largest size found. Only when that also
  turns up nothing does it fall back to the plain placeholder (a bordered
  box with the name).
- Only the first 15 items show up on the deck (3 rows x 5 columns). Items
  past the 15th are left off, and the daemon logs how many instead of
  truncating silently.

## The service's PATH does not include `~/.local/bin`

The unit runs under systemd's **user manager**, whose `PATH` is a fixed
system default — it does *not* include `~/.local/bin`, even though that's
where step 1 above installs `nx-menu`. Without the `NX_MENU_BIN` override in
`nx-menu-deck.service`, the daemon still starts, still finds the device,
still renders every key with the right icon and name — and every press just
does nothing, because `nx-menu` isn't on that `PATH` to be found. Nothing
about that failure is visible without reading the log: it's a deck that
looks completely correct and is completely mute. The service file pins
`NX_MENU_BIN=%h/.local/bin/nx-menu` explicitly so this can't happen.
