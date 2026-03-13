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

체크:

```bash
curl "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
openclaw pairing list telegram
openclaw gateway health --url ws://127.0.0.1:18789 --token "$OPENCLAW_GATEWAY_TOKEN"
```

## Gemini key validation

```bash
curl "https://generativelanguage.googleapis.com/v1beta/models?key=${GEMINI_API_KEY}"
```

응답이 오면 key 자체는 정상이다.

