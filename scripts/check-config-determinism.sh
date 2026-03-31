#!/usr/bin/env bash
set -euo pipefail

TMPDIR_PATH="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR_PATH"; }
trap cleanup EXIT

export OPENCLAW_STATE_DIR="${TMPDIR_PATH}/state"
export USER_SLUG="alice"
export COMPASS_API_KEY="test-compass"
export OPENCLAW_GATEWAY_AUTH_TOKEN="test-gateway-token"
export SIGNAL_BOT_NUMBER="+10000000000"
export SIGNAL_USER_PHONE="+10000000001"
export SIGNAL_CLI_URL="http://signal-proxy.local"
export MSTEAMS_APP_ID="00000000-0000-0000-0000-000000000001"
export MSTEAMS_APP_PASSWORD="test-password"
export MSTEAMS_TENANT_ID="00000000-0000-0000-0000-000000000002"

OUT1="${TMPDIR_PATH}/openclaw-1.json"
OUT2="${TMPDIR_PATH}/openclaw-2.json"

python3 scripts/build-openclaw-config.py --template openclaw.json.example --output "$OUT1"
python3 scripts/build-openclaw-config.py --template openclaw.json.example --output "$OUT2"

SUM1="$(sha256sum "$OUT1" | awk '{print $1}')"
SUM2="$(sha256sum "$OUT2" | awk '{print $1}')"

if [[ "$SUM1" != "$SUM2" ]]; then
  echo "Determinism check failed: checksums differ" >&2
  echo "first=$SUM1 second=$SUM2" >&2
  exit 1
fi

echo "Determinism check passed: $SUM1"
