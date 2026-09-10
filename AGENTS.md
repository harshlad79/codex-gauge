# CodexGauge 프로젝트 규칙

## 범위

- 이 저장소는 Windows Rainmeter용 Codex 사용량 표시 스킨과 수집기다.
- 기존 사용자 변경은 보존한다. 관련 없는 파일은 수정하지 않는다.

## 작업 규칙

- 공개 코드는 portable path와 설정 예시를 사용한다. 사용자 계정, 이메일, 컴퓨터명, 절대 경로, 세션 ID를 넣지 않는다.
- `auth.json`, 토큰, 쿠키, credential, 개인 로그, 원본 대화·스크린샷은 공개 Git 대상에서 제외한다.
- `backups/`, `conversation/`, `runtime-snapshots/`는 private/recovery 자료다. 공개 파일로 복사할 때는 개인정보를 제거한다.
- 실행 중 생성되는 usage 상태·이력 파일은 소스와 분리하고 Git에 추적하지 않는다.

## 검증

- 변경 후 Lua/controller 테스트와 PowerShell collector 테스트를 실행한다.
- Rainmeter UI 변경은 스킨 새로고침 또는 재시작 후 실제 렌더링을 확인한다.
- 완료 보고에는 변경 파일, 검증 결과, 남은 제한을 포함한다.
