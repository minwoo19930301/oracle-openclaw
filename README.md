# Oracle OpenClaw

Oracle Cloud Always Free VM에 OpenClaw를 올리고, Gemini API를 뇌로 쓰고, Telegram bot으로 대화하는 실사용 가이드다.

이 README는 아래 두 가지를 바로 할 수 있게 쓰여 있다.

- `Gemini API` 실제 발급과 검증
- `Telegram BotFather` 로 봇 만들고 OpenClaw에 연결

새 VM이 잘 떠 있으면 `cloud-init` 경로를 쓰고, Oracle이 막히면 기존 VM에 덧설치하는 fallback 스크립트를 쓴다.

## What This Repo Contains

- [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml)
  Ubuntu Always Free VM을 새로 만들 때 쓰는 user-data
- [`scripts/bootstrap_existing_oracle_vm.sh`](./scripts/bootstrap_existing_oracle_vm.sh)
  이미 떠 있는 Oracle Linux VM에 OpenClaw를 얹는 스크립트
- [`scripts/setup_run_command_iam.sh`](./scripts/setup_run_command_iam.sh)
  SSH가 안 될 때 OCI Run Command IAM을 붙이는 스크립트
- [`env/openclaw.env.example`](./env/openclaw.env.example)
  비밀값 예시

## Architecture

```text
Telegram DM
   |
   v
Telegram Bot
   |
   v
OpenClaw Gateway on Oracle VM
   |
   v
Gemini API
```

## 0. Prerequisites

필요한 것:

- Oracle Cloud Always Free 계정
- 로컬 SSH 키
- Telegram 계정
- Gemini API key

기본 추천 뇌:

- `gemini-2.5-flash-lite`

Llama 계열은 기본 경로에서 제외했다.

## 1. Gemini API Key 만들기

1. [Google AI Studio](https://aistudio.google.com/apikey) 로 간다.
2. API key를 새로 만든다.
3. 로컬에서 아래로 key가 살아 있는지 확인한다.

```bash
export GEMINI_API_KEY="YOUR_GEMINI_API_KEY"
curl "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}"
```

응답이 오면 key 자체는 정상이다.

실제로 한 번 답변까지 받아보려면 OpenAI-compatible endpoint로 이렇게 테스트할 수 있다.

```bash
curl https://generativelanguage.googleapis.com/v1beta/openai/chat/completions \
  -H "Authorization: Bearer ${GEMINI_API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "gemini-2.5-flash-lite",
    "messages": [
      {"role": "user", "content": "한 줄로 자기소개해줘"}
    ]
  }'
```

`choices[0].message.content` 가 오면 실제 추론 호출도 정상이다.

## 2. Telegram Bot 만들기

1. Telegram에서 `@BotFather` 를 연다.
2. `/newbot` 실행
3. 봇 이름과 username을 정한다.
4. 발급된 token을 저장한다.
5. 아래로 token이 살아 있는지 확인한다.

```bash
export TELEGRAM_BOT_TOKEN="1234567890:REPLACE_ME"
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
```

응답에 bot username이 나오면 token은 정상이다.

메시지 전송 테스트도 해볼 수 있다.

1. 먼저 봇과 DM 창을 열고 `/start` 를 한 번 보낸다.
2. 아래로 `getUpdates` 를 호출해서 자신의 chat id를 확인한다.

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

3. 나온 `chat.id` 로 테스트 메시지를 보낸다.

```bash
export TELEGRAM_CHAT_ID="REPLACE_WITH_CHAT_ID"
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=telegram bot token works"
```

이 메시지가 오면 Telegram token도 실제 발송까지 정상이다.

## 3. Secret 파일 만들기

예시 파일:

- [`env/openclaw.env.example`](./env/openclaw.env.example)

실제 파일 예시:

```bash
TELEGRAM_BOT_TOKEN=1234567890:replace-with-botfather-token
GEMINI_API_KEY=AIzaSyReplaceMe
GROQ_API_KEY=
OPENAI_API_KEY=
OPENCLAW_MODEL=
OPENCLAW_GATEWAY_TOKEN=
OPENCLAW_PORT=18789
```

권장:

- `OPENCLAW_MODEL` 은 비워둔다. 스크립트가 `gemini-2.5-flash-lite` 를 기본으로 잡는다.
- `OPENCLAW_GATEWAY_TOKEN` 도 비워둔다. 스크립트가 랜덤으로 만든다.

## 4. 설치 경로 선택

### Option A. 새 Ubuntu VM에 바로 올리기

Oracle에서 Ubuntu VM을 새로 만들 수 있으면 이게 제일 깔끔하다.

1. Ubuntu 24.04 VM 생성 화면으로 간다.
2. `user-data` 에 [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml) 내용을 넣는다.
3. VM 부팅 완료 후 SSH 접속
4. 아래로 gateway token 확인

```bash
cat ~/.openclaw/GATEWAY_TOKEN
```

5. 로컬에서 터널 연다.

```bash
ssh -N -L 18789:127.0.0.1:18789 ubuntu@YOUR_PUBLIC_IP
```

6. 브라우저에서 `http://127.0.0.1:18789/` 접속

이 경로는 OpenClaw까지만 자동이다. Gemini/Telegram까지 붙이려면 아래 `Option B` 의 secret 방식처럼 추가 설정을 해줘야 한다.

### Option B. 기존 Oracle VM에 덧설치

새 VM이 Oracle 쪽에서 막힐 때 쓰는 경로다.

아래 예시는 기존 VM이 `opc` 계정으로 들어가는 Oracle Linux라고 가정한다.

1. 로컬에 secret 파일을 만든다.

```bash
cp env/openclaw.env.example /tmp/openclaw.env
```

2. `/tmp/openclaw.env` 안에 `TELEGRAM_BOT_TOKEN` 과 `GEMINI_API_KEY` 를 채운다.

3. 스크립트와 env 파일을 VM으로 올린다.

```bash
scp /tmp/openclaw.env opc@YOUR_PUBLIC_IP:/tmp/openclaw.env
scp scripts/bootstrap_existing_oracle_vm.sh opc@YOUR_PUBLIC_IP:/tmp/bootstrap_existing_oracle_vm.sh
```

4. VM에서 secret 파일을 시스템 위치로 옮기고 bootstrap 실행

```bash
ssh opc@YOUR_PUBLIC_IP
sudo install -d -m 750 -o root -g opc /etc/openclaw
sudo mv /tmp/openclaw.env /etc/openclaw/openclaw.env
chmod +x /tmp/bootstrap_existing_oracle_vm.sh
/tmp/bootstrap_existing_oracle_vm.sh
```

이 스크립트가 하는 일:

- swap 확보
- Node 22 설치
- `openclaw` 글로벌 설치
- Gemini OpenAI-compatible provider patch
- Telegram channel patch
- systemd 등록
- health check

## 5. OpenClaw UI 접속

기존 VM 경로 기준:

1. gateway token 확인

```bash
ssh opc@YOUR_PUBLIC_IP "sudo grep '^OPENCLAW_GATEWAY_TOKEN=' /etc/openclaw/openclaw.env"
```

2. 로컬에서 SSH 터널

```bash
ssh -N -L 18789:127.0.0.1:18789 opc@YOUR_PUBLIC_IP
```

3. 브라우저에서 `http://127.0.0.1:18789/` 접속

## 6. Telegram Bot 연결하기

이 저장소의 기본 정책은 `pairing` 이다.

흐름:

1. Telegram에서 봇에게 먼저 DM을 보낸다.
2. 서버에서 pairing code를 본다.
3. 그 code를 승인한다.

기존 VM 경로 기준 예시:

```bash
ssh opc@YOUR_PUBLIC_IP
sudo -u opc bash -lc 'source /etc/openclaw/openclaw.env && openclaw pairing list telegram'
sudo -u opc bash -lc 'source /etc/openclaw/openclaw.env && openclaw pairing approve telegram <CODE>'
```

그다음부터는 DM으로 대화하면 된다.

## 7. 실제로 무엇을 넣어야 하나

최소 구성:

- `TELEGRAM_BOT_TOKEN`
- `GEMINI_API_KEY`

있으면 좋은 값:

- `OPENCLAW_MODEL`
  비워두면 `gemini-2.5-flash-lite`
- `OPENCLAW_PORT`
  기본값 `18789`

Groq로 바꾸고 싶으면:

- `GROQ_API_KEY` 채우기
- `OPENCLAW_MODEL` 을 비워두면 `qwen/qwen3-32b`

## 8. Why Gemini

이 저장소의 기본 뇌를 Gemini로 둔 이유:

- 무료 티어 시작이 쉬움
- API key 하나로 끝남
- CLI 로그인 플로우가 필요 없음
- OpenAI-compatible endpoint가 있어서 OpenClaw patch가 단순함

## 9. Troubleshooting

대표적인 문제:

- Oracle `launch_instance` 가 계속 `429 TooManyRequests`
- 22/tcp 는 열렸는데 SSH banner에서 멈춤
- Run Command plugin은 `RUNNING` 인데 execution은 `ACCEPTED` 에서 안 움직임

이건 [`docs/troubleshooting.md`](./docs/troubleshooting.md)에 따로 적어뒀다.

## 10. Security Notes

- `openclaw.env` 는 절대 git에 올리지 않는다.
- Telegram bot token과 Gemini API key는 평문으로 남지 않게 한다.
- 채팅이나 스크린샷에 token을 노출했다면 새 token으로 교체하는 게 안전하다.
