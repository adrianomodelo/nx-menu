# nx-menu

A tiny, opinionated app launcher for GNOME on X11: one keystroke opens a short
fixed list in the middle of the screen, and a **single digit** launches the app.

No fuzzy search to think about, no ranking that changes under you. Ten apps, ten
keys, same position every time. It is a thin layer over [rofi](https://github.com/davatorium/rofi),
which does the actual rendering.

> Built to replace the Ubuntu dock on my own machine, in the spirit of Omarchy's
> launcher. Omarchy uses [walker](https://github.com/abenz1267/walker), which
> needs `gtk4-layer-shell` and is Wayland-only. This is the X11 equivalent.

**Status:** this solves my case and I use it daily. Use it as-is. I am not
promising features, releases, or support.

## Install

```bash
sudo apt install rofi          # or your distro's equivalent
git clone https://github.com/<you>/nx-menu && cd nx-menu
./install.sh                   # binds Super+Q; pass another key to override
```

The installer copies three scripts into `~/.local/bin`, seeds the item list from
the apps currently pinned in GNOME, registers the shortcut, and forces the
keybinding daemon to actually pick it up (see the gotcha below, that last step is
not optional).

## Use

| key | action |
|---|---|
| `1`..`9` | launch items 1 through 9 |
| `0` | launch item 10 |
| arrows / typing | reach anything past the 10th item |
| `Esc` | close |

```bash
nx-menu list                  # what is in the menu and which key each item has
nx-menu add spotify           # find the app and append it
nx-menu add spotify --pos 3   # insert at position 3, pushing the rest down
nx-menu rm spotify            # remove by name
nx-menu rm 5                  # or by position
nx-menu edit                  # open the list in $EDITOR to reorder in bulk
```

### Already running? It raises, it does not duplicate

Picking an app that already has a window brings that window to the front instead
of starting a second instance. It finds the window through the `.desktop` file's
`StartupWMClass`, which is the field that exists precisely to link a launcher
entry to its window, and raises it with `wmctrl`. `gio launch` alone has no idea
the app is running and would happily open another copy.

When you *want* a second instance (a terminal, usually), mark the item:

```bash
nx-menu add kitty --new
```

That writes a fourth `new` column in the TSV. Items without it are raised.

`add` searches every standard `.desktop` location (user, system, snap, flatpak),
skips hidden entries, resolves the icon to an absolute path, and refuses
duplicates. It matches on the display name, the filename, and a normalized form,
so searching for `gnome-calculator` finds `org.gnome.Calculator.desktop` whose
`Name=` is just "Calculator". Every write makes a timestamped backup first.

Items live in `~/.config/nx-menu/apps.tsv`, one per line, **tab separated**:

```
Name shown	/path/to/app.desktop	icon	[new]
```

The target can also be a plain shell command. `nx-menu-sync` regenerates the file
from GNOME's pinned apps and **overwrites** it, so prefer `add`/`rm` once you have
curated the list.

## The gotcha that cost me an afternoon

**Creating a GNOME custom keyboard shortcut does not make `gsd-media-keys` serve
it. Changing an existing slot's `binding` does not either. What triggers the
re-registration is the `custom-keybindings` ARRAY changing.**

This bit me twice in one hour:

1. The new `Super+Q` was registered, `gsettings get` returned the right binding
   and the right command, the daemon was running, and the key did nothing. It
   only came alive when a second slot was added, which rewrote the whole array.
2. Worse, while adding slots my **Print Screen shortcut silently died** and
   stayed dead for half an hour. Its configuration was untouched and correct on
   disk. Clearing and re-setting that slot's `binding` did **not** fix it.
   Emptying and restoring the array did, instantly.

That is what `reset-keybinds.sh` does, with a backup of every slot first.

The reason this is nasty: **the configuration is right and the daemon is running
an older view of it.** Reading `gsettings get` confirms the config and proves
nothing about the grab. Same family as a config reload that returns success
while the process keeps serving the old file.

**So verify the effect, never the setting.** `nx-menu` appends a line to
`~/.cache/nx-menu.log` on every invocation, which splits the two failures that
otherwise look identical:

- a line after you press the key → the key arrives, the problem is downstream
- no line → the key never reached the script, the problem is the grab

## Other things worth knowing

- **A rofi warning is not a failure.** An early version treated any stderr output
  as fatal, so a flatpak icon that would not resolve took the whole menu down.
  The trigger is now the actual error signature, and flatpak icons are resolved
  to absolute paths.
- **`DISPLAY` may not be `:0`.** To test over SSH, read the real value from the
  running shell: `tr '\0' '\n' < /proc/$(pgrep -x gnome-shell)/environ | grep DISPLAY`.
- **No shell restart, ever.** Everything here is `gsettings` and applies live.
  Signalling `gnome-shell` to "reload" can core-dump the session and take every
  open window with it.
- Rofi closes on focus loss, so the window disappearing when you click elsewhere
  is expected, not a bug.

## Requirements

GNOME on **X11**, `rofi` 1.7+, `wmctrl`, `bash`. Wayland is not supported: GNOME does not
allow the kind of override rofi needs there. If you are on Wayland, use walker,
wofi, or fuzzel.

## License

MIT. See [LICENSE](LICENSE).
