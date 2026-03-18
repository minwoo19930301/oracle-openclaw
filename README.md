# Oracle OpenClaw

Oracle Cloud Always Free VM(또는 기존 VM)에 `OpenClaw`를 올리고, `Gemini API`를 뇌로 쓰고, `Telegram Bot`으로 붙이는 실사용 가이드다.

핵심 목표:

- OpenClaw 코어 기반으로 운영
- Gemini API 사용 (Llama 기본 경로 제외)
- Telegram DM 응답
- `cron` / `browser(CDP)` 자동화 가능 상태

## Quick Links

- Repo: <https://github.com/minwoo19930301/oracle-openclaw>
- Telegram bot profile: `https://t.me/<your_bot_username>`
- Telegram Web direct chat: `https://web.telegram.org/k/#@<your_bot_username>`
- Example: <https://web.telegram.org/k/#@chaeeun2_bot>
- OpenClaw dashboard (local tunnel): <http://127.0.0.1:18789/>

## What This Repo Contains

- [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml)
- [`scripts/bootstrap_existing_oracle_vm.sh`](./scripts/bootstrap_existing_oracle_vm.sh)
- [`scripts/enable_gemini_key_rotation.sh`](./scripts/enable_gemini_key_rotation.sh)
- [`scripts/setup_run_command_iam.sh`](./scripts/setup_run_command_iam.sh)
- [`env/openclaw.env.example`](./env/openclaw.env.example)
- [`config/openclaw.json.example`](./config/openclaw.json.example)

## Architecture

```text
Telegram DM
   |
   v
Telegram Bot
   |
   v
OpenClaw Gateway
   |
   v
Gemini API (google provider)
```

## 0. Prerequisites

- Oracle Cloud Always Free account
- SSH key
- Telegram account
- Gemini API key

기본 모델 권장:

- `gemini-2.5-flash-lite`

## 1. Gemini API Key 만들기

1. <https://aistudio.google.com/apikey> 접속
2. API key 발급
3. 키 검증

```bash
export GEMINI_API_KEY="YOUR_GEMINI_API_KEY"
curl -sS "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}"
```

실제 생성 테스트:

```bash
curl -sS \
  "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash-lite:generateContent?key=${GEMINI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"한 줄 자기소개"}]}]}'
```

## 2. Telegram Bot 만들기

1. Telegram에서 `@BotFather` 열기
2. `/newbot`
3. bot name + username 설정
4. token 저장
5. token 검증

```bash
export TELEGRAM_BOT_TOKEN="1234567890:REPLACE_ME"
curl -sS "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
```

DM 창 바로 열기:

- `https://t.me/<your_bot_username>`
- `https://web.telegram.org/k/#@<your_bot_username>`

## 3. Secret 파일 만들기

예시 파일: [`env/openclaw.env.example`](./env/openclaw.env.example)

```bash
TELEGRAM_BOT_TOKEN=1234567890:replace-with-botfather-token
GEMINI_API_KEY=AIzaSyReplaceMe
GEMINI_API_KEYS=AIzaSyKey1,AIzaSyKey2,AIzaSyKey3
OPENCLAW_MODEL=gemini-2.5-flash-lite
OPENCLAW_GATEWAY_TOKEN=
OPENCLAW_PORT=18789
OPENCLAW_INSECURE_TLS=0
GROQ_API_KEY=
OPENAI_API_KEY=
```

참고:

- `GEMINI_API_KEYS`를 넣으면 로테이션 프록시에서 키를 순환 사용
- `OPENCLAW_GATEWAY_TOKEN` 비워두면 설치 스크립트/런처에서 생성 가능
- 회사/프록시망에서 Node TLS가 `SELF_SIGNED_CERT_IN_CHAIN`으로 깨지면 `OPENCLAW_INSECURE_TLS=1` 임시 사용 가능

## 4. OpenClaw 코어 설정

샘플: [`config/openclaw.json.example`](./config/openclaw.json.example)

포인트:

- 모델: `google/${OPENCLAW_MODEL}` + `fallbacks`
- cron 활성화
- browser(CDP) 활성화 + 타임아웃 확장
- agent/telegram timeout 확장 (`agents.defaults.timeoutSeconds`, `channels.telegram.timeoutSeconds`)
- Telegram direct 정책에 owner/user 별 tool allow
- systemPrompt에 정체성 고정

## 5. 설치 경로 선택

### Option A. 새 Ubuntu VM + cloud-init

1. Ubuntu 24.04 VM 생성
2. `user-data` 에 [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml)
3. 부팅 후 token 확인

```bash
cat ~/.openclaw/GATEWAY_TOKEN
```

4. 로컬 터널

```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@YOUR_PUBLIC_IP
```

### Option B. 기존 Oracle VM 덧설치 (fallback)

```bash
cp env/openclaw.env.example /tmp/openclaw.env
scp /tmp/openclaw.env opc@YOUR_PUBLIC_IP:/tmp/openclaw.env
scp scripts/bootstrap_existing_oracle_vm.sh opc@YOUR_PUBLIC_IP:/tmp/bootstrap_existing_oracle_vm.sh

ssh opc@YOUR_PUBLIC_IP
sudo install -d -m 750 -o root -g opc /etc/openclaw
sudo mv /tmp/openclaw.env /etc/openclaw/openclaw.env
chmod +x /tmp/bootstrap_existing_oracle_vm.sh
/tmp/bootstrap_existing_oracle_vm.sh
```

Gemini 무료 티어 429를 줄이려면(키 여러 개 보유 시):

```bash
scp scripts/enable_gemini_key_rotation.sh ubuntu@YOUR_PUBLIC_IP:/tmp/enable_gemini_key_rotation.sh
ssh ubuntu@YOUR_PUBLIC_IP
chmod +x /tmp/enable_gemini_key_rotation.sh
APP_USER=ubuntu ENV_FILE=/etc/openclaw/openclaw.env /tmp/enable_gemini_key_rotation.sh
```

## 6. 기본 동작 확인

```bash
openclaw config validate
openclaw cron list --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser status --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw gateway call status --token "$OPENCLAW_GATEWAY_TOKEN" --json
```

## 7. Telegram 연결/정체성 확인

Telegram DM에서:

- `ㅎㅇ`
- `너 누구야? provider/model까지 한 줄로 말해`

기대 결과:

- OpenClaw 기반이라고 답함
- provider/model이 Gemini(`google/gemini-*`)로 표시됨

게이트웨이 기준 기본 모델 확인:

```bash
openclaw gateway call status --token "$OPENCLAW_GATEWAY_TOKEN" --json \
  | jq -r '.sessions.defaults.model'
```

## 8. cron + Browser(CDP) 실검증

### 8.1 Cron smoke test

```bash
openclaw cron add --name smoke-default --every 6h \
  --message "Reply exactly with: DEFAULT_OK" --no-deliver \
  --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN" --json

openclaw cron run <JOB_ID> --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw cron runs --id <JOB_ID> --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw cron rm <JOB_ID> --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
```

### 8.2 Browser smoke test

```bash
openclaw browser start --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser open https://www.naver.com --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser snapshot --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN" --limit 60
```

`naver.com` 스냅샷이 나오면 CDP 경로는 정상이다.

### 8.3 Naver `우산` 검색 요약 예시

```bash
openclaw browser start --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser open "https://search.naver.com/search.naver?query=%EC%9A%B0%EC%82%B0" --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
openclaw browser snapshot --format ai --limit 250 --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
```

요약 포인트(실제 실행 기준):

- 상단은 `우산 관련 광고` 블록이 크게 노출됨
- 본문은 쇼핑/가격비교 카드 중심(브랜드, 형태, 배송 필터)
- 일반 지식형보다 구매 의도 결과(상품/광고)가 우선됨

## 9. Troubleshooting

자주 막히는 케이스:

- Oracle `launch_instance` 429
- SSH banner hang
- Telegram token 정상인데 응답 없음
- browser 툴 타임아웃
- Gemini 400/no reply

자세한 내용: [`docs/troubleshooting.md`](./docs/troubleshooting.md)

## 10. Security Notes

- `openclaw.env` 절대 git 커밋 금지
- Telegram token / Gemini key 노출 시 즉시 rotation
- `OPENCLAW_INSECURE_TLS=1`은 임시 우회용 (가능하면 사내 CA 신뢰 설정으로 교체)
