# Session Notes

이 문서는 실제 작업 세션에서 관찰한 내용을 짧게 정리한 것이다.

## What Worked

- OCI API key 기반 접근은 정상
- Chuncheon tenancy 조회 정상
- Telegram bot token 검증 정상
- Gemini API key 검증 정상
- 기존 Oracle VM의 `Compute Instance Run Command` plugin 자체는 `RUNNING`
- OpenClaw 모델을 `google/gemini-2.5-flash` 로 전환 후 cron run 응답 정상
- Browser(CDP)에서 `https://www.naver.com` open + snapshot 정상

## What Did Not Work Cleanly

### 1. New VM provisioning

- 새 `openclaw-vm` 생성은 여러 차례 `429 TooManyRequests`
- 단순 재시도나 수 분 대기만으로는 해결되지 않음

### 2. Existing VM direct SSH

- `opc@<public-ip>` 로 이전에는 접속되었지만 이후 `ssh` 가 banner 단계에서 멈춤
- 22/tcp 자체는 열려 있었음

### 3. Run Command

- dynamic group / policy는 ACTIVE
- plugin도 RUNNING
- 그런데 command execution은 오래 `ACCEPTED` 상태 유지

## Practical Conclusion

Oracle Always Free에 OpenClaw를 올리는 경로는 두 개를 모두 준비해두는 게 좋다.

- primary: 새 Ubuntu VM + cloud-init
- fallback: 기존 VM + bootstrap script

그리고 운영 메모:

- micro VM은 swap 없이는 매우 빡빡하다
- Telegram 쪽은 token 검증보다 pairing 승인 흐름을 먼저 염두에 둬야 한다
- Gemini는 OpenAI-compatible 경로보다 OpenClaw 기본 `google` provider 경로가 안정적이었다
