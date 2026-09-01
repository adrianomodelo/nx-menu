#!/usr/bin/env bash
# selftest.sh — end-to-end checks for `nx-menu launch` and nx-menu-deck.py's
# dry run. Every assertion here needs a way to observe it fail, not just a
# way to observe it pass: invalid input is checked against valid input,
# counts are exact numbers (never "some output"), and the anti-drift scan
# proves it can reprove by being fed a planted failure first.
#
# Run with: bash contrib/streamdeck/selftest.sh
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
NX_MENU="$REPO_ROOT/nx-menu"
DECK_PY="$HERE/nx-menu-deck.py"
EXAMPLE_TSV="$REPO_ROOT/examples/apps.tsv.example"

PASS=0
FAIL=0

ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n' "$1" >&2; }

assert_nonzero() {
  local desc="$1"; shift
  "$@" >/dev/null 2>&1
  local rc=$?
  if [ "$rc" -ne 0 ]; then ok "$desc"; else bad "$desc (expected exit != 0, got 0)"; fi
}

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

TSV="$WORK/apps.tsv"
LOG="$WORK/nx-menu.log"
MARK="$WORK/mark"

# Command targets are inert on purpose: they only touch files under $WORK,
# nothing here reaches the real desktop. "Gamma Icon" points at a missing
# icon file on purpose, to exercise the placeholder fallback in the dry run.
printf 'Alpha One\ttouch %s.alpha\t\t\n'    "$MARK" >  "$TSV"
printf 'Beta Two\ttouch %s.beta\t\tnew\n'   "$MARK" >> "$TSV"
printf 'Gamma Icon\ttrue\t/no/such/icon.png\t\n'     >> "$TSV"

run_nx_menu() {
  env NX_MENU_CONF="$TSV" NX_MENU_LOG="$LOG" "$NX_MENU" "$@"
}

echo "== nx-menu launch: invalid N must fail loudly, not exit 0 in silence =="
assert_nonzero "launch with no argument"  run_nx_menu launch
assert_nonzero "launch 0"                 run_nx_menu launch 0
assert_nonzero "launch -1"                run_nx_menu launch -1
assert_nonzero "launch 99 (past the end)" run_nx_menu launch 99
assert_nonzero "launch abc (non-numeric)" run_nx_menu launch abc

echo "== nx-menu launch: valid N must produce the effect, not just exit 0 =="
run_nx_menu launch 1 >/dev/null 2>&1
for _ in $(seq 1 30); do [ -f "$MARK.alpha" ] && break; sleep 0.1; done
if [ -f "$MARK.alpha" ]; then
  ok "launch 1 ran the target command (marker file exists)"
else
  bad "launch 1 did not run the target command"
fi

if grep -q 'launch 1' "$LOG" 2>/dev/null; then
  ok "launch 1 left a trace in the log"
else
  bad "launch 1 left no trace in the log"
fi

echo "== nx-menu-deck.py --dry-run =="
OUT="$WORK/deck-out"
DRY_LOG="$WORK/dry-run.out"
env NX_MENU_CONF="$TSV" python3 "$DECK_PY" --dry-run --out "$OUT" > "$DRY_LOG" 2>"$WORK/dry-run.err"
rc=$?
if [ "$rc" -eq 0 ]; then ok "dry-run exits 0"; else bad "dry-run exited $rc"; fi

png_count=$(find "$OUT" -maxdepth 1 -name '*.png' 2>/dev/null | wc -l | tr -d ' ')
if [ "$png_count" -eq 15 ]; then
  ok "dry-run produced exactly 15 PNGs (the deck has 15 keys, no more no less)"
else
  bad "dry-run produced $png_count PNGs, expected exactly 15"
fi

empty_png=0
for f in "$OUT"/*.png; do
  [ -s "$f" ] || empty_png=$((empty_png + 1))
done
if [ "$empty_png" -eq 0 ]; then
  ok "no empty PNG among the 15"
else
  bad "$empty_png PNG(s) came out empty"
fi

if grep -qE '^  key  0 -> item  1: Alpha One$' "$DRY_LOG" \
   && grep -qE '^  key  1 -> item  2: Beta Two$' "$DRY_LOG" \
   && grep -qE '^  key  2 -> item  3: Gamma Icon$' "$DRY_LOG"; then
  ok "mapping printed in the right order (item 1/2/3 -> key 0/1/2)"
else
  bad "mapping order is wrong or missing, dry-run stdout was:"
  sed 's/^/    /' "$DRY_LOG" >&2
fi

echo "== anti-drift invariant: apps.tsv names must never be literal in the script =="

extract_names() {
  awk -F'\t' '/^[^#]/ && NF>0 {print $1}' "$1"
}

# Returns 0 (clean) if no name from $2 appears literally in $1, 1 otherwise.
scan_drift() {
  local script="$1" tsv="$2" name found=0
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    if grep -qF -- "$name" "$script"; then
      found=1
      echo "    drift: '$name' (from $(basename "$tsv")) is hardcoded in $(basename "$script")" >&2
    fi
  done < <(extract_names "$tsv")
  return "$found"
}

if scan_drift "$DECK_PY" "$EXAMPLE_TSV" 2>/dev/null; then
  ok "no example app name is hardcoded in nx-menu-deck.py"
else
  bad "an example app name is hardcoded in nx-menu-deck.py"
fi

# Prove the scan can actually fail: without this, "the scan passed" and "the
# scan cannot fail" look identical. Plant a name, require a failure, remove
# it, require a pass again, and require the file to come back byte-identical.
DECK_BACKUP="$WORK/nx-menu-deck.py.orig"
cp "$DECK_PY" "$DECK_BACKUP"
restore_deck() { cp "$DECK_BACKUP" "$DECK_PY"; }
trap 'restore_deck; rm -rf "$WORK"' EXIT

printf '\n# selftest canary — must never survive: Firefox\n' >> "$DECK_PY"
if scan_drift "$DECK_PY" "$EXAMPLE_TSV" >/dev/null 2>&1; then
  bad "control: injected name was NOT caught by the drift scan"
else
  ok "control: injected name IS caught by the drift scan"
fi

restore_deck
if cmp -s "$DECK_BACKUP" "$DECK_PY"; then
  ok "nx-menu-deck.py restored byte-identical after the canary injection"
else
  bad "nx-menu-deck.py was NOT restored correctly after the canary injection"
fi

if scan_drift "$DECK_PY" "$EXAMPLE_TSV" 2>/dev/null; then
  ok "control: scan passes again after removing the injected name"
else
  bad "control: scan still fails after removing the injected name"
fi

MIN_ASSERTIONS=13
TOTAL=$((PASS + FAIL))
echo
echo "== summary =="
echo "  passed: $PASS"
echo "  failed: $FAIL"
echo "  total:  $TOTAL"

if [ "$TOTAL" -lt "$MIN_ASSERTIONS" ]; then
  echo "selftest: only $TOTAL assertion(s) ran, expected at least $MIN_ASSERTIONS — refusing to call this a pass" >&2
  exit 1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "selftest: ALL GREEN ($PASS/$TOTAL)"
  exit 0
else
  echo "selftest: $FAIL/$TOTAL FAILED" >&2
  exit 1
fi
