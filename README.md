# Oracle OpenClaw

Oracle Cloud Always Free VM에 [OpenClaw](https://github.com/openclaw/openclaw)를 올리고, Telegram 봇과 Gemini API를 붙이는 실전 메모 겸 재사용용 저장소다.

이 저장소는 아래 상황을 기준으로 정리했다.

- Oracle Cloud Always Free
- OpenClaw gateway
- Telegram bot DM pairing
- Gemini API를 기본 뇌로 사용
- 새 VM이 막힐 때 기존 VM에 덧설치하는 fallback

## Why This Repo Exists

세션 중 실제로 부딪힌 문제가 있었다.

- Oracle Compute `launch_instance`가 계속 `429 TooManyRequests`
- 기존 VM은 `SSH`가 banner 단계에서 멈춤
- `Compute Instance Run Command`는 권한과 전파 시간을 많이 탐

그래서 문서만이 아니라 바로 다시 쓸 수 있는 자산을 같이 보관한다.

- [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml)
- [`scripts/bootstrap_existing_oracle_vm.sh`](./scripts/bootstrap_existing_oracle_vm.sh)
- [`scripts/setup_run_command_iam.sh`](./scripts/setup_run_command_iam.sh)
- [`env/openclaw.env.example`](./env/openclaw.env.example)

## Recommended Brain

기본 추천은 Gemini다.

- 모델: `gemini-2.5-flash-lite`
- 이유: 무료 티어, 빠른 응답, OpenAI-compatible endpoint 제공
- fallback: Groq `qwen/qwen3-32b`

Llama 계열은 기본 경로에서 제외했다.

## Repo Layout

```text
.
├── cloud-init/
│   └── cloud-init.yaml
├── docs/
│   ├── session-notes.md
│   └── troubleshooting.md
├── env/
│   └── openclaw.env.example
└── scripts/
    ├── bootstrap_existing_oracle_vm.sh
    └── setup_run_command_iam.sh
```

## Quick Start

### 1. New Ubuntu VM via cloud-init

Always Free Ubuntu VM을 새로 띄울 수 있으면 가장 단순하다.

1. [`cloud-init/cloud-init.yaml`](./cloud-init/cloud-init.yaml)을 user-data로 넣는다.
2. VM 부팅 후 `openclaw.service`가 자동으로 올라온다.
3. `~/.openclaw/GATEWAY_TOKEN`을 읽어 로컬 터널로 접속한다.

### 2. Existing Oracle VM fallback

새 VM이 Oracle 쪽에서 막힐 때 기존 VM에 얹는 경로다.

1. [`env/openclaw.env.example`](./env/openclaw.env.example)을 `/etc/openclaw/openclaw.env` 형식으로 채운다.
2. [`scripts/bootstrap_existing_oracle_vm.sh`](./scripts/bootstrap_existing_oracle_vm.sh)을 실행한다.
3. 이 스크립트가 아래를 처리한다.

- swap 확보
- Node 22 설치
- `openclaw` 글로벌 설치
- Gemini 또는 Groq provider patch
- Telegram channel patch
- systemd 등록

## Required Secrets

- `TELEGRAM_BOT_TOKEN`
- `GEMINI_API_KEY`

선택 값:

- `GROQ_API_KEY`
- `OPENAI_API_KEY`
- `OPENCLAW_MODEL`
- `OPENCLAW_GATEWAY_TOKEN`

예시는 [`env/openclaw.env.example`](./env/openclaw.env.example)에 있다.

## Telegram Flow

Telegram은 기본적으로 `pairing` 정책을 사용한다.

1. 봇에게 먼저 DM을 보낸다.
2. 서버에서 pairing code를 확인한다.
3. 아래 명령으로 승인한다.

```bash
openclaw pairing list telegram
openclaw pairing approve telegram <CODE>
```

## Notes

- 기존 Oracle Free micro 인스턴스는 메모리가 너무 작아서 swap이 사실상 필수다.
- Gemini는 OpenAI-compatible endpoint를 쓰면 OpenClaw provider patch가 단순해진다.
- Oracle Run Command는 동적 그룹 정책을 바꾼 뒤 전파 시간이 꽤 길 수 있다.

자세한 내용은 [`docs/troubleshooting.md`](./docs/troubleshooting.md) 와 [`docs/session-notes.md`](./docs/session-notes.md)를 보면 된다.

