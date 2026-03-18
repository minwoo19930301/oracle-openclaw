#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-ubuntu}"
ENV_FILE="${ENV_FILE:-/etc/openclaw/openclaw.env}"
OPENCLAW_SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}"
ROTATOR_SERVICE_NAME="${ROTATOR_SERVICE_NAME:-gemini-key-rotator}"
ROTATOR_DIR="${ROTATOR_DIR:-/opt/openclaw}"
ROTATOR_BIND="${ROTATOR_BIND:-127.0.0.1}"
ROTATOR_PORT="${ROTATOR_PORT:-19091}"
OPENCLAW_PORT_DEFAULT="${OPENCLAW_PORT_DEFAULT:-18789}"

if ! id "${APP_USER}" >/dev/null 2>&1; then
  echo "User not found: ${APP_USER}" >&2
  exit 1
fi

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  exit 1
fi

if ! sudo -n true >/dev/null 2>&1; then
  echo "This script requires passwordless sudo." >&2
  exit 1
fi

APP_HOME="$(getent passwd "${APP_USER}" | cut -d: -f6)"
OPENCLAW_HOME="${OPENCLAW_HOME:-${APP_HOME}/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME}/openclaw.json}"

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
}

run_as_openclaw_user() {
  local cmd="$1"
  sudo -u "${APP_USER}" env \
    HOME="${APP_HOME}" \
    OPENCLAW_HOME="${OPENCLAW_HOME}" \
    OPENCLAW_STATE_DIR="${OPENCLAW_HOME}" \
    OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH}" \
    bash -lc "set -a; source '${ENV_FILE}'; set +a; ${cmd}"
}

set_env_value() {
  local key="$1"
  local value="$2"
  if sudo grep -q "^${key}=" "${ENV_FILE}"; then
    sudo perl -0pi -e "s#^${key}=.*#${key}=${value}#m" "${ENV_FILE}"
  else
    printf '%s=%s\n' "${key}" "${value}" | sudo tee -a "${ENV_FILE}" >/dev/null
  fi
}

normalize_gemini_keys() {
  load_env

  local raw="${GEMINI_API_KEYS:-}"
  local single="${GEMINI_API_KEY:-}"

  if [[ -z "${raw// }" ]]; then
    if [[ -z "${single// }" ]]; then
      echo "Set GEMINI_API_KEYS or GEMINI_API_KEY in ${ENV_FILE}" >&2
      exit 1
    fi
    raw="${single}"
  fi

  raw="$(printf '%s' "${raw}" | tr -d '[:space:]' | sed -E 's/,+/,/g; s/^,+//; s/,+$//')"
  local deduped
  deduped="$(
    printf '%s\n' "${raw}" | awk -F, '
      {
        for (i = 1; i <= NF; i++) {
          k = $i
          if (k != "" && !seen[k]++) {
            if (out != "") out = out ","
            out = out k
          }
        }
      }
      END { print out }
    '
  )"

  if [[ -z "${deduped}" ]]; then
    echo "No valid Gemini keys found after normalization." >&2
    exit 1
  fi

  local first
  first="$(printf '%s' "${deduped}" | cut -d',' -f1)"
  set_env_value "GEMINI_API_KEYS" "${deduped}"
  set_env_value "GEMINI_API_KEY" "${first}"
  set_env_value "GEMINI_ROTATOR_BIND" "${ROTATOR_BIND}"
  set_env_value "GEMINI_ROTATOR_PORT" "${ROTATOR_PORT}"
}

install_rotator_script() {
  sudo install -d -m 0755 "${ROTATOR_DIR}"

  local tmp_script
  tmp_script="$(mktemp)"

  cat >"${tmp_script}" <<'EOF'
#!/usr/bin/env node
import http from 'node:http';
import { URL } from 'node:url';

const bind = process.env.GEMINI_ROTATOR_BIND || '127.0.0.1';
const port = Number(process.env.GEMINI_ROTATOR_PORT || 19091);
const upstreamBase = (process.env.GEMINI_UPSTREAM_BASE || 'https://generativelanguage.googleapis.com').replace(/\/$/, '');
const timeoutMs = Number(process.env.GEMINI_ROTATOR_TIMEOUT_MS || 45000);

const keys = [...new Set(
  (process.env.GEMINI_API_KEYS || process.env.GEMINI_API_KEY || '')
    .split(',')
    .map((k) => k.trim())
    .filter(Boolean)
)];

if (keys.length === 0) {
  console.error('[gemini-rotator] Missing GEMINI_API_KEYS/GEMINI_API_KEY');
  process.exit(1);
}

let nextIndex = 0;

function shouldRetry(status, bodyText) {
  if ([429, 500, 502, 503, 504].includes(status)) return true;
  if (status !== 401 && status !== 403) return false;
  const s = bodyText.toLowerCase();
  return (
    s.includes('resource_exhausted') ||
    s.includes('quota') ||
    s.includes('rate limit') ||
    s.includes('free_tier_requests') ||
    s.includes('api key not valid') ||
    s.includes('permission denied')
  );
}

function requestHeaders(inputHeaders, bodyLength) {
  const headers = new Headers();
  for (const [k, v] of Object.entries(inputHeaders)) {
    if (v == null) continue;
    const lk = k.toLowerCase();
    if (lk === 'host' || lk === 'connection' || lk === 'content-length' || lk === 'accept-encoding') continue;
    if (Array.isArray(v)) {
      for (const item of v) headers.append(k, item);
    } else {
      headers.set(k, v);
    }
  }
  if (bodyLength > 0) headers.set('content-length', String(bodyLength));
  return headers;
}

function writeResponse(res, upstream, body) {
  res.statusCode = upstream.status;
  for (const [k, v] of upstream.headers.entries()) {
    if (k.toLowerCase() === 'transfer-encoding') continue;
    res.setHeader(k, v);
  }
  res.end(body);
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  return Buffer.concat(chunks);
}

const server = http.createServer(async (req, res) => {
  let body;
  try {
    body = await readBody(req);
  } catch (err) {
    res.statusCode = 400;
    res.setHeader('content-type', 'application/json');
    res.end(JSON.stringify({ error: 'invalid_request_body', message: String(err?.message || err) }));
    return;
  }

  const incoming = new URL(req.url || '/', 'http://127.0.0.1');
  const start = nextIndex;
  let fallbackResponse = null;
  let fallbackError = null;

  for (let offset = 0; offset < keys.length; offset += 1) {
    const index = (start + offset) % keys.length;
    const key = keys[index];
    nextIndex = (index + 1) % keys.length;

    const upstream = new URL(`${upstreamBase}${incoming.pathname}${incoming.search}`);
    upstream.searchParams.delete('key');
    upstream.searchParams.set('key', key);

    try {
      const response = await fetch(upstream, {
        method: req.method,
        headers: requestHeaders(req.headers, body.length),
        body: body.length > 0 ? body : undefined,
        redirect: 'manual',
        signal: AbortSignal.timeout(timeoutMs),
      });
      const responseBody = Buffer.from(await response.arrayBuffer());
      const text = responseBody.toString('utf8');
      const retry = shouldRetry(response.status, text);
      if (retry && offset < keys.length - 1) {
        fallbackResponse = { response, responseBody };
        continue;
      }
      writeResponse(res, response, responseBody);
      return;
    } catch (err) {
      fallbackError = err;
      if (offset < keys.length - 1) continue;
    }
  }

  if (fallbackResponse) {
    writeResponse(res, fallbackResponse.response, fallbackResponse.responseBody);
    return;
  }

  res.statusCode = 502;
  res.setHeader('content-type', 'application/json');
  res.end(
    JSON.stringify({
      error: 'upstream_unavailable',
      message: String(fallbackError?.message || fallbackError || 'No upstream response'),
    })
  );
});

server.listen(port, bind, () => {
  console.log(`[gemini-rotator] listening on http://${bind}:${port} keys=${keys.length}`);
});
EOF

  sudo install -m 0755 "${tmp_script}" "${ROTATOR_DIR}/gemini-key-rotator.mjs"
  rm -f "${tmp_script}"
}

write_rotator_service() {
  cat <<EOF | sudo tee "/etc/systemd/system/${ROTATOR_SERVICE_NAME}.service" >/dev/null
[Unit]
Description=Gemini API Key Rotator Proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${ROTATOR_DIR}
EnvironmentFile=${ENV_FILE}
ExecStart=/usr/bin/node ${ROTATOR_DIR}/gemini-key-rotator.mjs
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

patch_openclaw_config() {
  local patch_script
  patch_script="$(mktemp)"

  cat >"${patch_script}" <<'EOF'
const fs = require('fs');

const configPath = process.env.OPENCLAW_CONFIG_PATH;
const port = process.env.GEMINI_ROTATOR_PORT || '19091';
const modelId = (process.env.OPENCLAW_MODEL || '').trim() || 'gemini-2.5-flash-lite';

let config = {};
try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch {
  config = {};
}

config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.models.providers.geminiOpenAI = config.models.providers.geminiOpenAI || {};
config.models.providers.geminiOpenAI.baseUrl = `http://127.0.0.1:${port}/v1beta`;
config.models.providers.geminiOpenAI.apiKey = '${GEMINI_API_KEY}';
config.models.providers.geminiOpenAI.api = 'google-generative-ai';

if (!Array.isArray(config.models.providers.geminiOpenAI.models) || config.models.providers.geminiOpenAI.models.length === 0) {
  config.models.providers.geminiOpenAI.models = [
    { id: modelId, name: modelId, contextWindow: 32768, maxTokens: 4096 },
  ];
}

config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
if (!config.agents.defaults.model.primary) {
  config.agents.defaults.model.primary = `geminiOpenAI/${modelId}`;
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
EOF

  run_as_openclaw_user "node '${patch_script}'"
  rm -f "${patch_script}"
}

start_services() {
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${ROTATOR_SERVICE_NAME}.service"
  sudo systemctl restart "${OPENCLAW_SERVICE_NAME}.service"
}

verify() {
  load_env
  local openclaw_port="${OPENCLAW_PORT:-${OPENCLAW_PORT_DEFAULT}}"

  sudo systemctl --no-pager --full status "${ROTATOR_SERVICE_NAME}.service" | sed -n '1,20p'
  sudo systemctl --no-pager --full status "${OPENCLAW_SERVICE_NAME}.service" | sed -n '1,20p'
  curl -fsS "http://${GEMINI_ROTATOR_BIND:-127.0.0.1}:${GEMINI_ROTATOR_PORT:-19091}/v1beta/models" >/tmp/gemini-rotator-models.json
  run_as_openclaw_user "openclaw gateway health --url ws://127.0.0.1:${openclaw_port} --token \"\${OPENCLAW_GATEWAY_TOKEN}\""

  local key_count
  key_count="$(printf '%s' "${GEMINI_API_KEYS}" | awk -F, '{print NF}')"
  echo "Gemini key rotation is active. keys=${key_count} bind=${GEMINI_ROTATOR_BIND:-127.0.0.1} port=${GEMINI_ROTATOR_PORT:-19091}"
}

main() {
  normalize_gemini_keys
  install_rotator_script
  write_rotator_service
  patch_openclaw_config
  start_services
  verify
}

main "$@"
