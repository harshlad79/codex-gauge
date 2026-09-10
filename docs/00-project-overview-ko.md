# 프로젝트 개요

Codex 계정의 Session(5시간)·Weekly(7일) 사용량을 Windows Rainmeter에서 표시하는 스킨.

구조:

```text
FetchUsage.ps1
  → chatgpt.com/backend-api/wham/usage
  → Usage.inc + UsageHistory.jsonl
  → ApplyUsage.lua
  → GraphModel.lua (계산) + GraphView.lua (도형)
  → CodexGauge.ini
```

현재 작업 핵심은 인증 방식 변경이 아니라 그래프 표현 개선이다.

2026-09-10 재설계 배포 및 검증 기록은 `docs/06-verification-report-ko.md`. 현재 코드와 과거 사용량 스냅샷은 분리하여 취급한다.
