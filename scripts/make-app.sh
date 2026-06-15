#!/usr/bin/env bash
# Build + install a real macOS menu-bar app: /Applications/WHOOP.app
#
# Uses py2app in ALIAS mode: the bundle's executable lives INSIDE the .app (so macOS
# resolves it to WHOOP.app and applies LSUIElement → a proper menu-bar app), while
# importing whoop_dashboard + dependencies from this project's .venv. Keep this project
# folder and its .venv in place — the app references them.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="$PROJECT_DIR/.venv/bin/python"
DEST="${1:-/Applications/WHOOP.app}"

if [[ ! -x "$PY" ]]; then
  echo "Virtualenv python not found at $PY — run the install steps in README.md first." >&2
  exit 1
fi

"$PY" -c "import py2app" 2>/dev/null || { echo "Installing py2app…"; "$PY" -m pip install py2app; }

# Generate the app icon if it's missing.
[[ -f "$PROJECT_DIR/icon/WHOOP.icns" ]] || arch -arm64 "$PY" "$PROJECT_DIR/scripts/make-icon.py"

cd "$PROJECT_DIR"
rm -rf build dist
arch -arm64 "$PY" setup.py py2app -A 2>&1 | tail -3

# py2app (alias) symlinks resources; make the icon a real file so it always renders.
ICNS="dist/WHOOP.app/Contents/Resources/WHOOP.icns"
if [[ -L "$ICNS" ]]; then
  cp -L "$PROJECT_DIR/icon/WHOOP.icns" /tmp/_whoop.icns && rm -f "$ICNS" && mv /tmp/_whoop.icns "$ICNS"
fi

EXE="dist/WHOOP.app/Contents/MacOS/WHOOP"
# On Apple Silicon, strip the x86_64 slice so it always runs natively (never Rosetta,
# which can't load arm64-only native wheels).
if [[ "$(uname -m)" == "arm64" ]] && lipo "$EXE" -archs 2>/dev/null | grep -q x86_64; then
  lipo "$EXE" -thin arm64 -output "$EXE.tmp" && mv "$EXE.tmp" "$EXE"
fi

# Code-sign with a STABLE identity so macOS can PERSIST privacy ("Allow") decisions. An
# ad-hoc signature (--sign -) has no stable identity, so TCC can't remember the grant and
# re-prompts every time — e.g. "WHOOP would like to access data from other apps" when the
# engine mirrors latest.json into the widget's App Group container. Prefer an Apple
# Development / Developer ID cert; fall back to ad-hoc if the machine has none.
# (Deliberately NOT adding the App Group entitlement: without an embedded provisioning
# profile it makes macOS restrict the app and the local dashboard fails to bind.)
SIGN_ID="$(security find-identity -v -p codesigning 2>/dev/null \
  | awk '/Apple Development|Developer ID Application/{print $2; exit}')"
if [[ -n "$SIGN_ID" ]]; then
  echo "Signing with stable identity: $SIGN_ID"
else
  SIGN_ID="-"
  echo "No Developer identity found — signing ad-hoc (macOS may re-prompt for permissions)."
fi
codesign --force --sign "$SIGN_ID" "$EXE" >/dev/null 2>&1 || true
codesign --force --sign "$SIGN_ID" --identifier com.lawrencetang.whoop dist/WHOOP.app >/dev/null 2>&1 || true

rm -rf "$DEST"
cp -R dist/WHOOP.app "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

echo "Installed: $DEST"
echo "Launch from Spotlight (⌘Space → WHOOP) or Finder → Applications."
