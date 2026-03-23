# Dual VM Split (Core + Browser CDP)

`Always Free` 1GB VM에서 `OpenClaw + Telegram + Browser`를 한 프로세스에 몰아넣으면 OOM/timeout이 자주 난다.  
실사용은 아래처럼 분리하는 게 안정적이다.

## Topology

- `openclaw-core-vm`: OpenClaw gateway + Telegram + cron + Gemini API
- `browser-cdp-vm`: headless Chrome + fixed CDP proxy

Core config는 로컬 브라우저 포트 대신 remote CDP URL을 사용한다.

```json
{
  "browser": {
    "enabled": true,
    "defaultProfile": "remote",
    "profiles": {
      "remote": {
        "cdpUrl": "ws://browser-cdp-vm.<subnet-domain>:3000/cdp?secret=<CDP_SECRET>",
        "color": "22aa66"
      }
    }
  }
}
```

## Why This Works

- 브라우저 렌더링 메모리 피크(Chrome)는 browser VM으로 격리
- core VM은 텔레그램 응답/모델 호출에 집중
- CDP 경로 실패가 core 전체 장애로 번지지 않음

## OCI Security Rules

서브넷 보안 목록(또는 NSG)에 최소로 아래를 둔다.

- ingress tcp/22 from `0.0.0.0/0`
- ingress tcp/3000 from `<subnet-cidr>` (예: `10.42.1.0/24`)
- egress all to `0.0.0.0/0`

## Bootstrapping Strategy

SSH가 불안정한 구간이 있으면 수동 설치 대신 `cloud-init`로 처음부터 올린다.

- browser VM cloud-init:
  - Node 설치
  - Chrome 설치
  - `chrome-headless.service`
  - `cdp-proxy.service`
- core VM cloud-init:
  - Node + OpenClaw 설치
  - `/etc/openclaw/openclaw.env` 작성
  - config patch (`google/gemini-*`, Telegram, remote CDP)
  - `openclaw.service` enable/start

## Validation Checklist

1. `openclaw-core-vm`에서 OpenClaw service active
2. `browser-cdp-vm`에서 `cdp-proxy` health OK (`/health`)
3. Telegram DM에서 `ㅎㅇ` 즉시 응답
4. Telegram DM에서 `브라우저 켜서 naver.com 열어줘` 성공
5. `API rate limit reached` 발생 시 Gemini key/모델 fallback 확인
