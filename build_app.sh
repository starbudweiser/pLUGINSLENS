#!/usr/bin/env bash
# Construit pLUGINSLENS.app à la racine du projet, puis supprime tous les fichiers temporaires.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

APP_NAME="pLUGINSLENS"
SRC="$ROOT/src/Plugin_Lens_app.py"
ICON="$ROOT/assets/icon.icns"
WORK="$(mktemp -d)"

cleanup() {
  rm -rf "$WORK" "$ROOT/build" "$ROOT/${APP_NAME}.spec" "$ROOT/.venv_build"
  find "$ROOT" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
  find "$ROOT" -name ".DS_Store" -delete 2>/dev/null || true
}
trap cleanup EXIT

[[ -f "$SRC" ]] || { echo "Erreur : $SRC introuvable" >&2; exit 1; }

PY="${PYTHON:-python3}"
if ! "$PY" -c "import PyInstaller, PyQt6" 2>/dev/null; then
  echo "Installation des dépendances dans un venv temporaire..."
  "$PY" -m venv "$ROOT/.venv_build"
  PY="$ROOT/.venv_build/bin/python"
  "$PY" -m pip install -q pyinstaller PyQt6
fi

rm -rf "$ROOT/${APP_NAME}.app"

ICON_ARGS=()
[[ -f "$ICON" ]] && ICON_ARGS=(--icon "$ICON")

"$PY" -m PyInstaller --noconfirm --clean --windowed --onedir \
  --name "$APP_NAME" ${ICON_ARGS[@]+"${ICON_ARGS[@]}"} \
  --distpath "$WORK/dist" --workpath "$WORK/build" --specpath "$WORK" \
  "$SRC"

mv "$WORK/dist/${APP_NAME}.app" "$ROOT/${APP_NAME}.app"
"$(cd "$ROOT/.." && pwd)/_tools/sign_app.sh" "$ROOT/${APP_NAME}.app"  # signature stable (_tools)

echo "OK : $ROOT/${APP_NAME}.app"
