#!/usr/bin/env python3
"""nx-menu-deck — mirrors nx-menu's apps.tsv on an Elgato Stream Deck MK.2.

The app list is never duplicated here: this script reads the same TSV that
`nx-menu` reads, in the same order, and a key press just runs
`nx-menu launch <N>` — so raising an already-open window, honouring the
"new" flag, and non-.desktop targets all come for free, from nx-menu itself.
Two copies of the same list drift, and the symptom is the worst kind: a new
item just does not show up, with no error at all — see selftest.sh for the
check that catches this before it ships.

Usage:
    nx-menu-deck.py                       # run as the deck daemon
    nx-menu-deck.py --dry-run --out DIR   # render the 15 key PNGs to DIR and
                                           # print the key -> item mapping,
                                           # without touching any hardware

The StreamDeck library is only imported inside run_device(), which the
--dry-run path never calls — so --dry-run works on a machine with no Stream
Deck attached and no `streamdeck` package installed.
"""
from __future__ import annotations

import argparse
import os
import subprocess
import sys
import time
from pathlib import Path

KEY_COUNT = 15
KEY_COLS = 5
KEY_ROWS = 3
KEY_IMAGE_SIZE = 72  # px, square — the MK.2's native key image size.
POLL_SECONDS = 2.0  # how often the daemon checks apps.tsv's mtime.

NX_MENU_BIN = os.environ.get("NX_MENU_BIN", "nx-menu")

# Same search order as nx-menu-sync's resolve_icon(), minus the SVG branch —
# by the time this runs, opening the item's own icon already failed, so this
# only looks for a same-basename PNG. Kept in lockstep on purpose: the two
# tools disagreeing about where an icon lives would be its own silent-drift
# bug, the same class this file's docstring already warns about.
_ICON_SEARCH_DIRS = [
    Path.home() / ".local" / "share" / "flatpak" / "exports" / "share" / "icons",
    Path("/var/lib/flatpak/exports/share/icons"),
    Path.home() / ".local" / "share" / "icons",
    Path("/usr/share/icons"),
    Path("/usr/share/pixmaps"),
]
# Last resort, matching resolve_icon(): inside the flatpak app tree itself,
# for apps that do not export an icon at all.
_ICON_APP_TREE_DIRS = [
    Path.home() / ".local" / "share" / "flatpak" / "app",
    Path("/var/lib/flatpak/app"),
]

# The tree walk below is not cheap, and render_key_image() runs on every
# reload — cache the answer per icon string so a broken icon only ever gets
# looked up once.
_icon_fallback_cache: "dict[str, Path | None]" = {}


def log(msg: str) -> None:
    ts = time.strftime("%Y-%m-%d %H:%M:%S")
    print(f"[{ts}] {msg}", flush=True)


def _icon_size_key(path: Path) -> int:
    """Rank a candidate PNG by the size implied by its directory name (e.g.
    .../128x128/apps/foo.png), so the largest available one wins — matching
    resolve_icon()'s "prefer the largest size" behaviour in nx-menu-sync.
    """
    for part in path.parts:
        head, _, tail = part.partition("x")
        if head.isdigit() and tail.isdigit():
            return int(head)
    return 0


def find_icon_png_fallback(icon: str) -> "Path | None":
    """Look for a same-basename .png in the places nx-menu-sync's
    resolve_icon() already searches, in the same priority order — the
    first search dir with any match wins (picking its largest size), and
    the flatpak app tree is only checked once none of them have anything.
    Only called after Pillow has already failed to open `icon` directly (an
    SVG, most often — Pillow does not rasterize those). Never raises: any
    lookup trouble here just means "no fallback, fall through to the
    placeholder", not a crashed daemon.
    """
    if icon in _icon_fallback_cache:
        return _icon_fallback_cache[icon]

    stem = Path(icon).stem
    result: "Path | None" = None
    if stem:
        try:
            for base in _ICON_SEARCH_DIRS:
                if not base.is_dir():
                    continue
                candidates = list(base.rglob(f"{stem}.png"))
                if candidates:
                    result = max(candidates, key=_icon_size_key)
                    break
            else:
                for base in _ICON_APP_TREE_DIRS:
                    if not base.is_dir():
                        continue
                    hit = next(base.rglob(f"{stem}.png"), None)
                    if hit is not None:
                        result = hit
                        break
        except OSError:
            result = None

    _icon_fallback_cache[icon] = result
    return result


def default_conf() -> Path:
    conf = os.environ.get("NX_MENU_CONF")
    if conf:
        return Path(conf)
    return Path.home() / ".config" / "nx-menu" / "apps.tsv"


class MenuItem:
    __slots__ = ("name", "target", "icon", "flag")

    def __init__(self, name: str, target: str, icon: str, flag: str):
        self.name = name
        self.target = target
        self.icon = icon
        self.flag = flag


def load_items(conf_path: Path) -> list[MenuItem]:
    """Parse apps.tsv exactly like nx-menu's load_items(): TAB separated,
    blank names and lines starting with '#' skipped, trailing columns
    optional. Kept in lockstep with nx-menu on purpose — see the module
    docstring above.
    """
    items: list[MenuItem] = []
    try:
        raw = conf_path.read_text(encoding="utf-8")
    except OSError:
        return items
    for line in raw.splitlines():
        fields = line.split("\t")
        name = fields[0] if fields else ""
        if not name or name.startswith("#"):
            continue
        target = fields[1] if len(fields) > 1 else ""
        icon = fields[2] if len(fields) > 2 else ""
        flag = fields[3] if len(fields) > 3 else ""
        items.append(MenuItem(name, target, icon, flag))
    return items


def build_key_mapping(items: list[MenuItem]) -> tuple[dict[int, MenuItem], int]:
    """Item at position i (0-based, reading order) goes to key i (same
    reading order on the 3x5 grid). Returns (mapping, overflow) — overflow
    is how many items did not fit on KEY_COUNT keys.
    """
    mapping: dict[int, MenuItem] = {}
    overflow = 0
    for i, item in enumerate(items):
        if i >= KEY_COUNT:
            overflow += 1
            continue
        mapping[i] = item
    return mapping, overflow


def render_key_image(item: "MenuItem | None"):
    """Draw one 72x72 key: the icon (if it loads) plus the name at the
    bottom. An icon Pillow can't open (an SVG, most often — Pillow does not
    rasterize those) first tries a same-basename PNG via
    find_icon_png_fallback(), then falls back to a plain placeholder with
    the name — a bad icon on one item must never take the whole daemon
    down.
    """
    from PIL import Image, ImageDraw, ImageFont

    size = KEY_IMAGE_SIZE
    img = Image.new("RGB", (size, size), "black")
    if item is None:
        return img

    draw = ImageDraw.Draw(img)
    try:
        font = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 11)
    except Exception:
        font = ImageFont.load_default()

    icon_img = None
    if item.icon:
        try:
            icon_img = Image.open(item.icon).convert("RGBA")
        except Exception:
            icon_img = None
        if icon_img is None:
            fallback = find_icon_png_fallback(item.icon)
            if fallback is not None:
                try:
                    icon_img = Image.open(fallback).convert("RGBA")
                except Exception:
                    icon_img = None

    if icon_img is not None:
        area = int(size * 0.62)
        icon_img.thumbnail((area, area))
        pos = ((size - icon_img.width) // 2, 4)
        img.paste(icon_img, pos, icon_img)
    else:
        draw.rectangle([3, 3, size - 4, size - 22], outline="#555555", width=1)

    label = item.name if len(item.name) <= 11 else item.name[:10] + "…"
    bbox = draw.textbbox((0, 0), label, font=font)
    text_width = bbox[2] - bbox[0]
    x = max(0, (size - text_width) // 2)
    draw.text((x, size - 16), label, fill="white", font=font)
    return img


def render_all(mapping: dict[int, MenuItem]):
    return {key: render_key_image(mapping.get(key)) for key in range(KEY_COUNT)}


def print_mapping(conf_path: Path, mapping: dict[int, MenuItem]) -> None:
    print(f"apps.tsv: {conf_path}")
    print(f"keys: {KEY_COUNT} ({KEY_ROWS}x{KEY_COLS})")
    for key in range(KEY_COUNT):
        item = mapping.get(key)
        if item is None:
            print(f"  key {key:2d} -> (empty)")
        else:
            print(f"  key {key:2d} -> item {key + 1:2d}: {item.name}")


def dry_run(conf_path: Path, out_dir: Path) -> None:
    items = load_items(conf_path)
    mapping, overflow = build_key_mapping(items)
    if overflow:
        print(
            f"nx-menu-deck: {overflow} item(s) do not fit on {KEY_COUNT} keys "
            "and were left out",
            file=sys.stderr,
        )
    out_dir.mkdir(parents=True, exist_ok=True)
    for key, img in render_all(mapping).items():
        img.save(out_dir / f"key-{key:02d}.png")
    print_mapping(conf_path, mapping)


# ---------------------------------------------------------------------------
# Everything below this line touches the physical device. Kept out of the
# --dry-run path on purpose: the StreamDeck import happens only inside
# run_device(), so a machine with no device and no `streamdeck` package can
# still run --dry-run to check the rendering and the mapping.
# ---------------------------------------------------------------------------

def launch_item(item: "MenuItem", key: int) -> None:
    """Launch the app for one key press by running `nx-menu launch <N>` via
    NX_MENU_BIN, logging both the attempt and any failure. Never raises: a
    missing or broken NX_MENU_BIN must not take the callback thread — and
    with it every other key — down with it. This is the exact failure the
    published unit hit with a systemd --user PATH that lacks ~/.local/bin
    (see README.md) — the deck looked perfect and did nothing on every
    press, silently. Kept as a module-level function (not inlined in
    run_device()'s on_key_change closure) so selftest.sh can exercise it
    without a real Stream Deck attached.
    """
    cmd = [NX_MENU_BIN, "launch", str(key + 1)]
    log(f"key {key} -> item {key + 1}: {item.name} ({' '.join(cmd)})")
    try:
        subprocess.Popen(cmd)
    except Exception as exc:
        log(f"failed to launch {cmd!r}: {exc}")


def run_device(conf_path: Path) -> None:
    from StreamDeck.DeviceManager import DeviceManager
    from StreamDeck.ImageHelpers import PILHelper

    decks = DeviceManager().enumerate()
    if not decks:
        log("no Stream Deck device found")
        sys.exit(1)

    deck = decks[0]
    deck.open()
    deck.reset()
    # USB settle: right after open() the device sometimes answers before it
    # is actually ready. Learned the hard way on this same MK.2.
    time.sleep(0.3)

    for attempt in range(3):
        try:
            deck.set_brightness(100)
            break
        except Exception as exc:
            # Without the retry, the deck sometimes lights up with the
            # brightness call silently not applied — symptom: "the deck is
            # off", no error anywhere.
            log(f"set_brightness attempt {attempt + 1}: {exc}")
            time.sleep(0.3)

    try:
        model = deck.deck_type()
    except Exception as exc:
        model = f"unknown ({exc})"
    try:
        serial = deck.get_serial_number()
    except Exception as exc:
        serial = f"unknown ({exc})"
    log(f"device: {model} serial={serial} keys={KEY_COUNT} conf={conf_path}")

    state: dict = {"mtime": None, "mapping": {}}

    def reload_if_changed(force: bool = False) -> None:
        try:
            mtime = conf_path.stat().st_mtime
        except OSError:
            mtime = None
        if not force and mtime == state["mtime"]:
            return
        state["mtime"] = mtime
        items = load_items(conf_path)
        mapping, overflow = build_key_mapping(items)
        if overflow:
            log(f"{overflow} item(s) do not fit on {KEY_COUNT} keys and were left out")
        state["mapping"] = mapping
        for key in range(KEY_COUNT):
            img = render_key_image(mapping.get(key))
            native = PILHelper.to_native_key_format(deck, img)
            deck.set_key_image(key, native)
        verb = "reloaded" if not force else "loaded"
        log(f"apps.tsv {verb}: {len(mapping)} item(s) mapped")

    def on_key_change(_deck, key, pressed):
        if not pressed:
            return
        item = state["mapping"].get(key)
        if item is None:
            return
        launch_item(item, key)

    reload_if_changed(force=True)
    deck.set_key_callback(on_key_change)

    try:
        while True:
            time.sleep(POLL_SECONDS)
            reload_if_changed()
    except KeyboardInterrupt:
        pass
    finally:
        deck.close()


def main(argv: "list[str] | None" = None) -> None:
    parser = argparse.ArgumentParser(description="Mirror nx-menu's apps.tsv on a Stream Deck MK.2")
    parser.add_argument(
        "--dry-run", action="store_true",
        help="render the 15 key PNGs and print the mapping, without touching the hardware",
    )
    parser.add_argument("--out", type=Path, help="output directory for --dry-run")
    parser.add_argument(
        "--conf", type=Path, default=None,
        help="apps.tsv path (default: $NX_MENU_CONF, else ~/.config/nx-menu/apps.tsv)",
    )
    args = parser.parse_args(argv)
    conf_path = args.conf if args.conf else default_conf()

    if args.dry_run:
        if not args.out:
            parser.error("--dry-run requires --out <dir>")
        dry_run(conf_path, args.out)
        return

    run_device(conf_path)


if __name__ == "__main__":
    main()
