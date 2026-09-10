---
title: "Rainmeter hidden bounds and reset-history normalization"
module: CodexGauge
date: "2026-09-10"
category: ui-bugs
problem_type: ui_bug
component: tooling
severity: high
symptoms:
  - "Hidden meter coordinates extend compact window bounds."
  - "Reset timestamp jitter fragments one usage cycle."
  - "Zero-only idle histories suppress overall forecasts."
root_cause: logic_error
resolution_type: code_fix
tags: ["rainmeter", "hidden-meters", "reset-jitter", "idle-history", "forecast"]
---

# Rainmeter 크기와 사용 이력 정규화

## Problem

계산 테스트가 통과해도 실제 Rainmeter에서는 숨긴 미터가 축소 창 크기에 영향을 줬다. 응답의 reset timestamp를 정확히 일치하는 키로만 묶고 0% 대기 창까지 동일한 과거 주기로 세면, 실제 사용 기록이 있는데도 History 예측이 사라졌다.

## Symptoms

- 상세 미터를 숨겨도 Y=538이 창 높이 계산에 남음.
- 동일한 실제 reset 응답이 1788999906/1788999907처럼 1초 차이.
- 런타임 History 표본 115개/14개인데 Collecting trend. 0% 대기 동안 이동하는 reset을 별도 사용 주기로 취급한 결과.

## What Didn't Work

- `HideMeter`만 호출: Rainmeter는 미터의 GetY()+GetH()로 크기를 계산하므로 숨긴 Y도 제거해야 함.
- fixture 기대값끼리 비교: 실제 Lua와 렌더러 연결 오류를 찾지 못함.
- 전체 구간을 평균할 때 대기 중 새로 보고된 0% 창마다 한 표를 주는 방식.
- reset 변경을 곧바로 0% 관측으로 합성하는 제안: 변화나 누락 자체는 0% 관측 증거가 아님.

## Solution

`ApplyUsage.lua`는 숨김 상세·오류·미래 hitbox를 Y=0에 두고, 나타날 때만 원래 좌표로 이동한다. 실제 runtime-probe에서 경고 포함 축소 321×189, 확장 321×619를 확인했다.

`GraphModel.lua`는 reset 시각을 60초 이내의 비연쇄 클러스터로 묶는다. 원본 JSONL은 유지하고, 현재 창 끝은 최신 응답을 사용한다. 기울기 계산에 유효한 표본이 있고 사용량도 0보다 큰 주기만 History 중앙값에 포함한다. 0보다 큰 누적치를 유지하는 실제 휴지 기간의 0 기울기는 배제하지 않는다.

실제 0%가 시작 후 5분 안에 관측되면 첫 Session 막대 기준으로 사용할 수 있다. 누락 구간은 미상으로 남긴다. 지수 표기와 legacy timestamp offset도 보존하도록 파서를 수정했다.

## Why This Works

표시 여부, 창 경계, 데이터의 의미를 분리한다. 좌표는 실제 렌더러 규칙에 맞추고, 예측은 단순히 API 응답 횟수가 아니라 사용이 관측된 reset별 기울기를 반영한다. 현재/과거 두 직선 모두 마지막 실제 값에 맞춰 예측 시각과 도형 교점을 일치시킨다.

## Prevention

- 실제 Lua 5.1을 실행하는 테스트로 Session 10/15/6, Weekly [10]/[10,15]/[10,15,6] 및 모든 과거 경계 검증.
- 숨김 좌표, reset 경계, 시각 jitter, 대기 이력, 서로 다른 샘플 수의 과거 주기, 지수/시간대 파싱 회귀 테스트 유지.
- 동적 UI는 테스트가 생성한 PNG와 실제 사용자 스크린샷을 구분. 실제 실행은 runtime-probe 좌표와 함께 검증.
- 초기 Poll과 OnRefresh를 둘 다 수집기 시작점으로 쓰면 RunCommand Error 101 중복 실행 알림이 발생하므로 하나만 사용.
- 배포는 코드 5개만. 현재 사용 이력을 과거 보관본으로 덮어쓰지 않음.

## Related Issues

- [그래프 규격](../../03-graph-spec-ko.md)
- [검증 보고서](../../06-verification-report-ko.md)
- [실행 결정 기록](../../superpowers/plans/execution-ledger.md)
- GitHub 이슈 검색은 프로젝트 전용 remote가 없어 생략했다.
