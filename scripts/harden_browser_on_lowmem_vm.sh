#!/usr/bin/env bash
set -euo pipefail

OPENCLAW_SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}"
OPENCLAW_DIST_DIR="${OPENCLAW_DIST_DIR:-/usr/lib/node_modules/openclaw/dist}"
NODE_MAX_OLD_SPACE_SIZE="${NODE_MAX_OLD_SPACE_SIZE:-640}"
SERVICE_FILE="/etc/systemd/system/${OPENCLAW_SERVICE_NAME}.service"

if ! sudo -n true >/dev/null 2>&1; then
  echo "This script requires passwordless sudo." >&2
  exit 1
fi

FILES=(
  "${OPENCLAW_DIST_DIR}/reply-Deht_wOB.js"
  "${OPENCLAW_DIST_DIR}/pi-embedded-CQnl8oWA.js"
  "${OPENCLAW_DIST_DIR}/pi-embedded-CaI0IFWw.js"
  "${OPENCLAW_DIST_DIR}/plugin-sdk/reply-Duq0R59W.js"
  "${OPENCLAW_DIST_DIR}/subagent-registry-CVXe4Cfs.js"
)

for f in "${FILES[@]}"; do
  if [[ ! -f "${f}" ]]; then
    echo "Missing expected bundle: ${f}" >&2
    exit 1
  fi
done

for f in "${FILES[@]}"; do
  if [[ ! -f "${f}.bak-browser-timeout" ]]; then
    sudo cp -a "${f}" "${f}.bak-browser-timeout"
  fi
  sudo perl -i -pe '
    s/timeoutMs:\s*2e4/timeoutMs: 6e4/g;
    s/timeoutMs:\s*15e3/timeoutMs: 3e4/g;
    s/DEFAULT_BROWSER_PROXY_TIMEOUT_MS\s*=\s*2e4/DEFAULT_BROWSER_PROXY_TIMEOUT_MS = 6e4/g;
  ' "${f}"
done

if [[ -f "${SERVICE_FILE}" ]]; then
  sudo perl -0pi -e "s/Environment=NODE_OPTIONS=--max-old-space-size=\d+/Environment=NODE_OPTIONS=--max-old-space-size=${NODE_MAX_OLD_SPACE_SIZE}/" "${SERVICE_FILE}"
fi

sudo systemctl daemon-reload
sudo systemctl restart "${OPENCLAW_SERVICE_NAME}.service"
sleep 3

echo "Patched browser timeout defaults and restarted ${OPENCLAW_SERVICE_NAME}."
echo
sudo systemctl --no-pager --full status "${OPENCLAW_SERVICE_NAME}" | sed -n '1,20p'
echo
ss -ltnp | grep -E '18789|18791|18800|19091' || true
