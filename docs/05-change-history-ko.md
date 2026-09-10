# 변경 이력 요약

- 2026-09-07: Rainmeter Codex 사용량 스킨 조사·구조 확인.
- 2026-09-07~09-09: Usage.inc, PowerShell 수집, Lua 적용, 오류 이력, forecast, 호버, 확장 패널 작업.
- 2026-09-09: Session 10칸·Weekly 14칸의 reset-window 샘플링으로 변경.
- 2026-09-09: Weekly 기존값/증가값 색상 분리와 separator 추가.
- 2026-09-09: 현재 그래프 분석 결과, 미래 bucket을 0으로 처리하는 문제와 낮은 Session 시각성 문제 확인.

원본 단계별 백업은 `backups/`에 보관한다.

## 2026-09-10 재설계

- GraphModel/GraphView 분리, Session 구간 증가 막대와 Weekly 영구 누적층으로 교체.
- 고정 시간축·세로 100/50 라벨, 두 예측선·100% 도달 시각·reset 여유.
- 기본/호버/경고/오류 레이아웃 정리. 숨긴 미터 좌표로 창이 줄지 않는 버그 수정.
- reset 시각의 초 단위 흔들림과 0% 대기 창 때문에 과거 예측이 사라지던 문제 수정.
- Lua 파서의 지수 표기·legacy UTC offset 처리, reset 경계 갱신 보완.
- 60일 보관·append·파일 잠금·원자적 교체·오류 최근 3개·마지막 성공 시각 보존.
- 초기 중복 폴링 제거. 코드만 백업/배포하는 tools/Deploy-Skin.ps1 추가.
- Lua 26개 테스트와 PowerShell 13그룹, 라이브 미터 좌표 진단 추가. 최종 화면 확인 상태는 검증 보고서 참조.
