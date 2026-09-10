# 구조 및 데이터 흐름

## 수집

`FetchUsage.ps1`가 60초마다 usage endpoint를 조회한다. 성공하면 `UsageHistory.jsonl`에 UTC timestamp, Session %, Weekly %, 각 reset epoch를 추가하고 `Usage.inc`를 갱신한다.

## 그래프 샘플링

`ApplyUsage.lua`가 이력을 읽고, 순수 Lua 5.1 `GraphModel.lua`가 계산한다. `GraphView.lua`는 실제 Rainmeter Shape 좌표를 생성한다.

- Session: `sessionReset - 5h`부터 reset 시각까지 10개 bucket.
- Weekly: `weeklyReset - 7d`부터 reset 시각까지 14개 bucket.
- 각 bucket 값은 그 구간 안에서 관측한 최신 API snapshot. 현재 진행 중 칸은 현재까지 반영.
- 아직 시간이 오지 않은 bucket은 실제 0%가 아니라 미래/미관측 상태로 다뤄야 한다.

## 표시

Rainmeter INI가 막대, 누적 Weekly 막대, 추세선, 기준선, 호버 hitbox를 그린다.

변하는 좌표·문자는 Lua의 SetOption으로 적용한다. 숨김 상세·오류 미터의 Y도 0으로 이동해야 창 높이가 줄어든다. 초 단위 업데이트는 상대 시각/리셋 남은 시간만 갱신하며, reset 경계를 넘으면 캐시한 이력으로 예측을 만료시킨다.

## 저장 안전성

단일 수집기 잠금, 동일 폴더 임시 파일을 통한 원자적 교체. 정상 폴링은 JSONL 한 줄 append, UTC 날짜 변경 때 60일 정리. 최대 86,400행에 도달하면 84,960행으로 줄여 매분 전체 재작성 방지. 원본 JSONL에는 응답의 시각을 보존하고 그래프에서만 작은 reset 오차를 묶는다.
