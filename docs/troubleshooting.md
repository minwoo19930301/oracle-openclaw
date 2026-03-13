# Troubleshooting

## Oracle `launch_instance` returns `429 TooManyRequests`

증상:

- 새 VM 생성 시 `launch_instance`가 계속 `429 TooManyRequests`
- 몇 분 쉬고 다시 시도해도 동일

의미:

- quota 부족이라기보다 Oracle Compute API rate limit 또는 내부 throttling에 걸린 경우가 많다.

확인:

```bash
oci compute instance list --all --compartment-id "$TENANCY_ID"
```

대응:

- 같은 요청을 짧게 반복하지 않는다.
- 기존 VM fallback 경로를 준비한다.
- 장시간 계속 막히면 region 자체 문제일 수 있다.

## SSH port 22 is open but SSH login hangs before the banner

증상:

- `nc -vz <IP> 22` 는 성공
- `ssh -vvv` 는 `Local version string` 이후 멈춤

의미:

- TCP는 열렸지만 sshd 또는 OS 레벨 응답이 비정상일 수 있다.
- 기존 VM 부하, sshd 문제, Oracle 측 네트워크 이슈 가능성이 있다.

대응:

- 기존 서비스 중단을 감수할 수 있으면 VM reboot
- SSH 대신 Oracle Run Command 우회 시도

## Run Command plugin is `RUNNING` but commands stay `ACCEPTED`

증상:

- `Compute Instance Run Command` plugin status는 `RUNNING`
- command execution state는 계속 `ACCEPTED`
- plugin message는 권한 문서를 보라고 나옴

체크 포인트:

- dynamic group matching rule이 instance OCID를 정확히 가리키는지
- policy에 아래 문구들이 있는지

```text
Allow dynamic-group <name> to manage instance-family in tenancy
Allow dynamic-group <name> to use instance-agent-command-family in tenancy
Allow dynamic-group <name> to use instance-agent-command-execution-family in tenancy where request.instance.id = target.instance.id
```

대응:

- policy/dynamic group 수정 후 바로 결론 내리지 않는다.
- 전파 시간이 길 수 있으므로 30분 이상 관찰한다.
- 끝까지 `ACCEPTED`면 reboot가 현실적인 복구 수단이다.

## Existing Oracle micro VM has too little memory

증상:

- `npm install -g openclaw` 가 지나치게 오래 걸림
- 서비스가 뜨지 않거나 install 중 뻗음

대응:

- 최소 2GB 이상 swap 확보
- package upgrade 전체를 생략하고 필요한 패키지만 설치
- `NODE_OPTIONS=--max-old-space-size=384` 같이 메모리 상한을 둔다

## Telegram bot works but replies do not

원인 후보:

- `TELEGRAM_BOT_TOKEN` 은 맞지만 AI provider key가 비어 있음
- pairing 승인이 안 됨
- `OPENCLAW_MODEL` 이 잘못된 provider/model 값을 가리킴
- 선택한 Gemini 모델이 free tier quota 초과(429)
- Node TLS 인증서 체인이 깨져 Telegram/Gemini HTTPS 호출이 실패함
- 게이트웨이 토큰 인증인데 CLI 호출에 `--token` 이 빠짐

체크:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
openclaw pairing list telegram
openclaw gateway health --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw gateway call status --token "$OPENCLAW_GATEWAY_TOKEN" --json
```

추가 체크(로그):

```bash
tail -n 120 ~/Library/Logs/chaeeun2-openclaw/openclaw-gateway.err.log
```

`Network request for 'sendMessage' failed` 또는 `SELF_SIGNED_CERT_IN_CHAIN` 가 보이면 TLS 이슈일 가능성이 높다.

## Gemini key validation

```bash
curl "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}"
```

응답이 오면 key 자체는 정상이다.

## Gemini 호출이 400이고 응답이 비는 경우

증상:

- 로그에 `provider=geminiOpenAI` + `error=400 status code (no body)`
- 대화가 "No reply from agent"로 끝남

원인:

- OpenAI-compatible 경로(`geminiOpenAI/...`)에서 일부 요청 포맷이 맞지 않는 경우가 있다.

대응:

- OpenClaw 모델 라우팅을 `google/${OPENCLAW_MODEL}` 로 전환
- `OPENCLAW_MODEL=gemini-2.5-flash` 로 고정 후 재시작

확인:

```bash
openclaw cron add --name smoke-default --every 6h \
  --message "Reply exactly with: DEFAULT_OK" --no-deliver \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN" --json

openclaw cron run <JOB_ID> --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw cron runs --id <JOB_ID> --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
```

`summary: "DEFAULT_OK"` 와 `provider: "google"` 이 나오면 정상.

## Gemini API rate limit(429 RESOURCE_EXHAUSTED)

증상:

- 응답에 `API rate limit reached` 또는 `RESOURCE_EXHAUSTED`
- 특정 모델에서만 반복적으로 429

대응:

1. 모델을 `gemini-2.5-flash-lite`로 변경
2. `agents.defaults.model.fallbacks`에 lite 계열 fallback 추가

```bash
# env
OPENCLAW_MODEL=gemini-2.5-flash-lite
```

```json
"model": {
  "primary": "google/${OPENCLAW_MODEL}",
  "fallbacks": [
    "google/gemini-flash-lite-latest",
    "google/gemini-3.1-flash-lite-preview",
    "google/gemini-2.5-flash"
  ]
}
```

검증:

```bash
openclaw gateway call status --token "$OPENCLAW_GATEWAY_TOKEN" --json \
  | jq -r '.sessions.defaults.model'
```

## `gateway timeout after 1500ms` / handshake timeout

증상:

- `openclaw` CLI에서 gateway timeout 또는 connect challenge timeout

원인:

- gateway는 토큰 인증인데 CLI 호출에 `--token` 미포함

대응:

```bash
openclaw gateway probe --token "$OPENCLAW_GATEWAY_TOKEN" --json
openclaw gateway call status --token "$OPENCLAW_GATEWAY_TOKEN" --json
```

## Browser tool says unavailable / timed out

증상:

- Telegram에서 브라우저 요청 시 "브라우저가 현재 작동하지 않습니다"
- 로그에 `browser failed: timed out`

대응:

1. gateway 재시작

```bash
launchctl kickstart -k gui/$(id -u)/ai.minwokim.chaeeun2-openclaw
```

2. browser timeout/profile 설정 강화

```json
"browser": {
  "enabled": true,
  "evaluateEnabled": true,
  "headless": true,
  "remoteCdpTimeoutMs": 15000,
  "remoteCdpHandshakeTimeoutMs": 30000,
  "defaultProfile": "openclaw"
}
```

3. 동작 검증

```bash
openclaw browser status --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser start --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser open https://www.naver.com --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser snapshot --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN" --limit 60
```

`naver.com` 스냅샷이 뜨면 CDP 경로는 정상.

## Node TLS `SELF_SIGNED_CERT_IN_CHAIN`

증상:

- `curl`은 되는데 Node/OpenClaw 내부 HTTPS 호출만 실패
- 에러: `SELF_SIGNED_CERT_IN_CHAIN`

대응 우선순위:

1. 권장: 사내/프록시 루트 CA를 Node 신뢰 체인에 추가
2. 임시 우회: `OPENCLAW_INSECURE_TLS=1` (보안 리스크 수용 시에만)

주의:

- `OPENCLAW_INSECURE_TLS=1` 은 TLS 검증을 끄므로 장기 운영 기본값으로 두지 않는다.
