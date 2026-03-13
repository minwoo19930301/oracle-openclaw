#!/usr/bin/env bash
set -euo pipefail

APP_USER="${APP_USER:-opc}"
ENV_FILE="${ENV_FILE:-/etc/openclaw/openclaw.env}"
OPENCLAW_PORT_DEFAULT="${OPENCLAW_PORT_DEFAULT:-18789}"
OPENCLAW_SWAP_MB="${OPENCLAW_SWAP_MB:-4096}"
OPENCLAW_SWAPFILE="${OPENCLAW_SWAPFILE:-/swapfile-openclaw}"
OPENCLAW_SERVICE_NAME="${OPENCLAW_SERVICE_NAME:-openclaw}"

if ! id "${APP_USER}" >/dev/null 2>&1; then
  echo "User not found: ${APP_USER}" >&2
  exit 1
fi

APP_HOME="$(getent passwd "${APP_USER}" | cut -d: -f6)"
OPENCLAW_HOME="${OPENCLAW_HOME:-${APP_HOME}/.openclaw}"
OPENCLAW_CONFIG_PATH="${OPENCLAW_CONFIG_PATH:-${OPENCLAW_HOME}/openclaw.json}"
OPENCLAW_RUNTIME_DIR="${OPENCLAW_RUNTIME_DIR:-/var/tmp/openclaw-compile-cache}"

if [[ ! -f "${ENV_FILE}" ]]; then
  echo "Missing env file: ${ENV_FILE}" >&2
  echo "Create it from env/openclaw.env.example first." >&2
  exit 1
fi

if ! sudo -n true >/dev/null 2>&1; then
  echo "This script requires passwordless sudo." >&2
  exit 1
fi

load_env() {
  set -a
  # shellcheck disable=SC1090
  source "${ENV_FILE}"
  set +a
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

ensure_gateway_token() {
  load_env
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    local token
    token="$(openssl rand -hex 24)"
    set_env_value "OPENCLAW_GATEWAY_TOKEN" "${token}"
  fi
}

ensure_default_port() {
  load_env
  if [[ -z "${OPENCLAW_PORT:-}" ]]; then
    set_env_value "OPENCLAW_PORT" "${OPENCLAW_PORT_DEFAULT}"
  fi
}

ensure_default_model() {
  load_env
  if [[ -n "${GEMINI_API_KEY:-}" && -z "${OPENCLAW_MODEL:-}" ]]; then
    set_env_value "OPENCLAW_MODEL" "gemini-2.5-flash"
  elif [[ -n "${GROQ_API_KEY:-}" && -z "${OPENCLAW_MODEL:-}" ]]; then
    set_env_value "OPENCLAW_MODEL" "qwen/qwen3-32b"
  elif [[ -n "${OPENAI_API_KEY:-}" && -z "${OPENCLAW_MODEL:-}" ]]; then
    set_env_value "OPENCLAW_MODEL" "openai/gpt-5.4"
  fi
}

ensure_swap() {
  local current_swap_mb
  current_swap_mb="$(free -m | awk '/^Swap:/ {print $2}')"
  if [[ -n "${current_swap_mb}" ]] && (( current_swap_mb >= 2048 )); then
    return
  fi

  if [[ ! -f "${OPENCLAW_SWAPFILE}" ]]; then
    sudo fallocate -l "${OPENCLAW_SWAP_MB}M" "${OPENCLAW_SWAPFILE}"
    sudo chmod 0600 "${OPENCLAW_SWAPFILE}"
    sudo mkswap "${OPENCLAW_SWAPFILE}"
    sudo swapon "${OPENCLAW_SWAPFILE}"
    echo "${OPENCLAW_SWAPFILE} none swap sw 0 0" | sudo tee -a /etc/fstab >/dev/null
  elif ! swapon --show=NAME | grep -qx "${OPENCLAW_SWAPFILE}"; then
    sudo swapon "${OPENCLAW_SWAPFILE}"
  fi
}

install_node() {
  if command -v node >/dev/null 2>&1; then
    local current_major
    current_major="$(node -p 'process.versions.node.split(\".\")[0]')"
    if [[ "${current_major}" =~ ^[0-9]+$ ]] && (( current_major >= 22 )); then
      return
    fi
  fi

  curl -fsSL https://rpm.nodesource.com/setup_22.x | sudo bash -
  sudo dnf install -y nodejs
}

install_openclaw() {
  if command -v openclaw >/dev/null 2>&1; then
    return
  fi

  sudo mkdir -p /var/tmp/npm-cache "${OPENCLAW_RUNTIME_DIR}"
  sudo chown -R "${APP_USER}:${APP_USER}" /var/tmp/npm-cache "${OPENCLAW_RUNTIME_DIR}"
  sudo env npm_config_cache=/var/tmp/npm-cache SHARP_IGNORE_GLOBAL_LIBVIPS=1 npm install -g --unsafe-perm openclaw@latest
}

ensure_dirs() {
  sudo install -d -m 0700 -o "${APP_USER}" -g "${APP_USER}" "${OPENCLAW_HOME}" "${OPENCLAW_HOME}/workspace"
  sudo install -d -m 0755 -o "${APP_USER}" -g "${APP_USER}" "${OPENCLAW_RUNTIME_DIR}"
  sudo install -d -m 0750 -o root -g "${APP_USER}" "$(dirname "${ENV_FILE}")"
  sudo chown root:"${APP_USER}" "${ENV_FILE}"
  sudo chmod 0640 "${ENV_FILE}"
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

run_onboard() {
  load_env

  if [[ -f "${OPENCLAW_CONFIG_PATH}" ]]; then
    return
  fi

  if [[ -n "${GEMINI_API_KEY:-}" || -n "${GROQ_API_KEY:-}" ]]; then
    run_as_openclaw_user "openclaw onboard --non-interactive --mode local --auth-choice skip --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --skip-health --accept-risk"
  elif [[ -n "${OPENAI_API_KEY:-}" ]]; then
    run_as_openclaw_user "openclaw onboard --non-interactive --mode local --auth-choice openai-api-key --secret-input-mode ref --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --skip-health --accept-risk"
  else
    run_as_openclaw_user "openclaw onboard --non-interactive --mode local --auth-choice skip --gateway-auth token --gateway-token-ref-env OPENCLAW_GATEWAY_TOKEN --skip-health --accept-risk"
  fi
}

patch_config() {
  load_env

  local patch_script="/tmp/openclaw-patch-config.cjs"
  cat >"${patch_script}" <<'EOF'
const fs = require('fs');

const configPath = process.env.OPENCLAW_CONFIG_PATH;
const defaultModel = (process.env.OPENCLAW_MODEL || '').trim();
const hasTelegram = Boolean((process.env.TELEGRAM_BOT_TOKEN || '').trim());
const geminiApiKey = (process.env.GEMINI_API_KEY || '').trim();
const groqApiKey = (process.env.GROQ_API_KEY || '').trim();
let config = {};

try {
  config = JSON.parse(fs.readFileSync(configPath, 'utf8'));
} catch (err) {
  config = {};
}

config.gateway = config.gateway || {};
config.gateway.mode = 'local';
config.gateway.bind = 'loopback';
config.gateway.auth = config.gateway.auth || {};
config.gateway.auth.mode = 'token';
config.gateway.auth.token = {
  source: 'env',
  provider: 'default',
  id: 'OPENCLAW_GATEWAY_TOKEN',
};

config.agents = config.agents || {};
config.agents.defaults = config.agents.defaults || {};
config.agents.defaults.model = config.agents.defaults.model || {};
config.models = config.models || {};
config.models.providers = config.models.providers || {};
config.cron = config.cron || {};
config.browser = config.browser || {};

config.cron.enabled = true;
if (!config.cron.maxConcurrentRuns) config.cron.maxConcurrentRuns = 4;

config.browser.enabled = true;
if (typeof config.browser.evaluateEnabled !== 'boolean') config.browser.evaluateEnabled = true;
if (typeof config.browser.headless !== 'boolean') config.browser.headless = true;
if (!config.browser.remoteCdpTimeoutMs) config.browser.remoteCdpTimeoutMs = 15000;
if (!config.browser.remoteCdpHandshakeTimeoutMs) config.browser.remoteCdpHandshakeTimeoutMs = 30000;
if (!config.browser.defaultProfile) config.browser.defaultProfile = 'openclaw';
config.browser.profiles = config.browser.profiles || {};
config.browser.profiles.openclaw = config.browser.profiles.openclaw || {
  cdpPort: 18800,
  color: '#FF4500',
};

if (geminiApiKey) {
  const modelId = defaultModel || 'gemini-2.5-flash';
  config.agents.defaults.model.primary = `google/${modelId}`;
  if (config.models.providers.geminiOpenAI) delete config.models.providers.geminiOpenAI;
} else if (groqApiKey) {
  const modelId = defaultModel || 'qwen/qwen3-32b';
  config.models.providers.groqOpenAI = {
    baseUrl: 'https://api.groq.com/openai/v1',
    apiKey: groqApiKey,
    api: 'openai-completions',
    models: [{ id: modelId, name: modelId, contextWindow: 131072, maxTokens: 8192 }],
  };
  config.agents.defaults.model.primary = `groqOpenAI/${modelId}`;
} else if (defaultModel) {
  config.agents.defaults.model.primary = defaultModel;
}

config.channels = config.channels || {};
if (hasTelegram) {
  config.channels.telegram = {
    ...(config.channels.telegram || {}),
    enabled: true,
    dmPolicy: 'open',
    allowFrom: ['*'],
    groups: {
      '*': { requireMention: true },
    },
  };
}

fs.writeFileSync(configPath, JSON.stringify(config, null, 2) + '\n');
EOF

  run_as_openclaw_user "node '${patch_script}'"
  rm -f "${patch_script}"
}

verify_telegram_token() {
  load_env
  if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
    echo "TELEGRAM_BOT_TOKEN is not set. Telegram channel will stay disabled." >&2
    return
  fi

  curl -fsS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe" >/tmp/openclaw-telegram-getme.json
}

verify_ai_provider() {
  load_env

  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    curl -fsS "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}" >/tmp/openclaw-gemini-models.json
    return
  fi

  if [[ -n "${GROQ_API_KEY:-}" ]]; then
    curl -fsS https://api.groq.com/openai/v1/models \
      -H "Authorization: Bearer ${GROQ_API_KEY}" >/tmp/openclaw-groq-models.json
    return
  fi

  if [[ -z "${OPENAI_API_KEY:-}" ]]; then
    echo "No AI provider key set. OpenClaw will start, but replies will fail until GEMINI_API_KEY, GROQ_API_KEY, or OPENAI_API_KEY is configured." >&2
  fi
}

write_service() {
  load_env
  local port="${OPENCLAW_PORT:-${OPENCLAW_PORT_DEFAULT}}"

  cat <<EOF | sudo tee "/etc/systemd/system/${OPENCLAW_SERVICE_NAME}.service" >/dev/null
[Unit]
Description=OpenClaw Gateway
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_HOME}
EnvironmentFile=${ENV_FILE}
Environment=HOME=${APP_HOME}
Environment=OPENCLAW_HOME=${OPENCLAW_HOME}
Environment=OPENCLAW_STATE_DIR=${OPENCLAW_HOME}
Environment=OPENCLAW_CONFIG_PATH=${OPENCLAW_CONFIG_PATH}
Environment=OPENCLAW_NO_RESPAWN=1
Environment=NODE_COMPILE_CACHE=${OPENCLAW_RUNTIME_DIR}
Environment=NODE_DISABLE_COMPILE_CACHE=1
Environment=NODE_OPTIONS=--max-old-space-size=384
ExecStartPre=/usr/bin/mkdir -p ${OPENCLAW_HOME} ${OPENCLAW_HOME}/workspace ${OPENCLAW_RUNTIME_DIR}
ExecStartPre=/usr/bin/chown -R ${APP_USER}:${APP_USER} ${OPENCLAW_HOME} ${OPENCLAW_RUNTIME_DIR}
ExecStart=/usr/bin/bash -lc 'if [ "\${OPENCLAW_INSECURE_TLS:-0}" = "1" ]; then export NODE_TLS_REJECT_UNAUTHORIZED=0; fi; exec /usr/bin/openclaw gateway --port ${port}'
Restart=always
RestartSec=5
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
}

write_access_notes() {
  load_env
  local notes_path="${APP_HOME}/OPENCLAW_ACCESS.txt"
  local port="${OPENCLAW_PORT:-${OPENCLAW_PORT_DEFAULT}}"

  cat <<EOF | sudo tee "${notes_path}" >/dev/null
SSH tunnel:
ssh -N -L ${port}:127.0.0.1:${port} ${APP_USER}@<PUBLIC_IP>

Gateway token:
sudo cat ${ENV_FILE} | grep '^OPENCLAW_GATEWAY_TOKEN='

Control UI:
http://127.0.0.1:${port}/

Approve Telegram pairing:
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>
EOF
  sudo chown "${APP_USER}:${APP_USER}" "${notes_path}"
  sudo chmod 0600 "${notes_path}"
}

start_service() {
  sudo systemctl daemon-reload
  sudo systemctl enable --now "${OPENCLAW_SERVICE_NAME}.service"
}

verify_service() {
  load_env
  local port="${OPENCLAW_PORT:-${OPENCLAW_PORT_DEFAULT}}"
  run_as_openclaw_user "openclaw --version"
  run_as_openclaw_user "openclaw gateway health --url ws://127.0.0.1:${port} --token \"\${OPENCLAW_GATEWAY_TOKEN}\""
  sudo systemctl --no-pager --full status "${OPENCLAW_SERVICE_NAME}.service" | sed -n '1,30p'
}

main() {
  ensure_gateway_token
  ensure_default_port
  ensure_default_model
  ensure_swap
  install_node
  install_openclaw
  ensure_dirs
  verify_telegram_token
  verify_ai_provider
  run_onboard
  patch_config
  write_service
  write_access_notes
  start_service
  verify_service
}

main "$@"
