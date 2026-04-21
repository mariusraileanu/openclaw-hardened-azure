#!/usr/bin/env bash
set -euo pipefail

ENV_NAME="${1:-${ENV:-dev}}"
if [[ "$ENV_NAME" != "dev" && "$ENV_NAME" != "stage" && "$ENV_NAME" != "prod" ]]; then
  echo "Unsupported ENV '$ENV_NAME'. Use dev|stage|prod." >&2
  exit 1
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
TEAMS_DIR="$ROOT_DIR/channels/teams-app"
DIST_DIR="$TEAMS_DIR/dist/$ENV_NAME"
PACKAGE_PATH="$DIST_DIR/openclaw-teams-$ENV_NAME.zip"

mkdir -p "$DIST_DIR"

ENV="$ENV_NAME" node "$TEAMS_DIR/render-manifest.mjs"
ENV="$ENV_NAME" node "$TEAMS_DIR/check-manifest.mjs"

cp "$TEAMS_DIR/color.png" "$DIST_DIR/color.png"
cp "$TEAMS_DIR/outline.png" "$DIST_DIR/outline.png"

rm -f "$PACKAGE_PATH"
python3 -m zipfile -c "$PACKAGE_PATH" "$DIST_DIR/manifest.json" "$DIST_DIR/color.png" "$DIST_DIR/outline.png"

echo "Created Teams package: ${PACKAGE_PATH#$ROOT_DIR/}"
