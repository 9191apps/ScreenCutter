#!/bin/bash
# Opt-in real-app smoke test. It drives the actual mouse and keyboard, so it
# is intentionally gated behind E2E=1 and is never part of the Xcode test plan.
#
# Run the app from Xcode first, then:
#   E2E=1 scripts/e2e/smoke.sh
#
# Environment overrides:
#   E2E_APP_PID          ScreenCutter process to drive
#   E2E_HOTKEY_KEYCODE   default 19 (the "2" key)
#   E2E_HOTKEY_FLAGS     default cmd+shift
set -euo pipefail
cd "$(dirname "$0")"

if [[ "${E2E:-}" != "1" ]]; then
  echo "Refusing to run: set E2E=1 to acknowledge that this moves the real cursor and opens overlays." >&2
  exit 2
fi

TOOLS="$(pwd)/bin/e2e-tools"
ARTIFACTS="$(pwd)/artifacts"
mkdir -p "$ARTIFACTS"

if [[ ! -x "$TOOLS" ]]; then
  ./build.sh
fi

if ! "$TOOLS" check-permissions; then
  echo "E2E prerequisites are not met; see the lines above." >&2
  exit 3
fi

PID="${E2E_APP_PID:-}"
if [[ -z "$PID" ]]; then
  PID="$(pgrep -x ScreenCutter | head -1 || true)"
fi
if [[ -z "$PID" ]]; then
  PID="$(pgrep -f 'ScreenCutter.app/Contents/MacOS/ScreenCutter' | head -1 || true)"
fi
if [[ -z "$PID" ]]; then
  echo "ScreenCutter is not running. Launch scheme ScreenCutter from Xcode, or set E2E_APP_PID." >&2
  exit 4
fi

HOTKEY_CODE="${E2E_HOTKEY_KEYCODE:-19}"
HOTKEY_FLAGS="${E2E_HOTKEY_FLAGS:-cmd+shift}"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

cleanup() {
  # Never leave a full-screen shield behind, even when an assertion fails.
  if "$TOOLS" overlay-window "$PID" 0 >/dev/null 2>&1; then
    "$TOOLS" key 53 || true
  fi
}
trap cleanup EXIT

wait_for_ax() {
  local title="$1"
  local attempt
  for attempt in $(seq 1 50); do
    if "$TOOLS" ax-exists "$PID" "$title"; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

# Start from an idle app.
if "$TOOLS" overlay-window "$PID" 0 >/dev/null 2>&1; then
  "$TOOLS" key 53
  sleep 0.5
fi

SCREEN_LINE="$("$TOOLS" screens | awk '/^screen0 /{print; exit}')"
if [[ -z "$SCREEN_LINE" ]]; then
  fail "could not read the main screen size"
fi
SIZE="$(echo "$SCREEN_LINE" | awk '{print $2}')"
WIDTH="${SIZE%x*}"
HEIGHT="${SIZE#*x}"
if ! [[ "$WIDTH" =~ ^[0-9]+$ && "$HEIGHT" =~ ^[0-9]+$ ]]; then
  fail "unexpected screen size: $SIZE"
fi

X1=$((WIDTH * 12 / 100))
Y1=$((HEIGHT * 18 / 100))
X2=$((WIDTH * 62 / 100))
Y2=$((HEIGHT * 72 / 100))
RX1=$((X1 + (X2 - X1) * 15 / 100))
RY1=$((Y1 + (Y2 - Y1) * 25 / 100))
RX2=$((X1 + (X2 - X1) * 55 / 100))
RY2=$((Y1 + (Y2 - Y1) * 60 / 100))

echo "Using ScreenCutter pid=$PID screen=${WIDTH}x${HEIGHT}"

OVERLAY_ID=""
for _ in 1 2 3; do
  "$TOOLS" key "$HOTKEY_CODE" "$HOTKEY_FLAGS"
  if OVERLAY_ID="$("$TOOLS" overlay-window "$PID" 2)"; then
    break
  fi
  sleep 0.5
done
if [[ -z "$OVERLAY_ID" ]]; then
  fail "hotkey did not open the overlay (screen unlocked? app running? hotkey unchanged?)"
fi
echo "Overlay window: $OVERLAY_ID"

"$TOOLS" drag "$X1" "$Y1" "$X2" "$Y2"
wait_for_ax "标注" || fail "selection did not show the action bar"
"$TOOLS" ax-press "$PID" "标注"
wait_for_ax "矩形" || fail "annotation toolbar did not appear"

# The frozen image is captured asynchronously; wait before drawing on it.
sleep 1
"$TOOLS" screenshot "$ARTIFACTS/annotate-toolbar.png" "$OVERLAY_ID"

"$TOOLS" drag "$RX1" "$RY1" "$RX2" "$RY2"
sleep 0.4
"$TOOLS" ax-exists "$PID" "撤销" || fail "annotation toolbar is missing the undo button"
"$TOOLS" screenshot "$ARTIFACTS/rectangle-drawn.png" "$OVERLAY_ID"

"$TOOLS" key 6 cmd
sleep 0.4
"$TOOLS" screenshot "$ARTIFACTS/undo.png" "$OVERLAY_ID"

"$TOOLS" key 53
sleep 0.7
if "$TOOLS" overlay-window "$PID" 0 >/dev/null 2>&1; then
  fail "Esc did not close the overlay"
fi

echo "PASS: select → annotate → draw rectangle → undo → cancel"
echo "Artifacts: $ARTIFACTS"
