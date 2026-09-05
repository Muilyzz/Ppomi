# Ppomi 0.1.0 출시 점검

2026-09-06 로컬 저장소와 GitHub 릴리스 확인 기준. `backlog.md`는 9월 3일 자산관리 중심의 이전 계획이며, 현재 출시 상태는 이 문서를 먼저 참고한다.

## 확인한 결과

- `swift test --package-path Ppomi`: 수정 후 56개 통과, 실패 0. 발자국 재생·결제 지점 정지·중복 실행 방지·승인 게이트·미러링 인증 화면 판별 테스트 포함. 가짜 화면 기반 테스트를 실폰 검증으로 간주하지 않는다.
- `cd hub && npm test`: 18개 통과.
- `python3 test_am.py`, `python3 test_style.py`: 모두 종료 코드 0.
- 최초 `phone state`는 CONNECTED였으나 실제 화면은 `iPhone 잠금 해제` 인증 대기였다. 상태 판별을 수정해 DISCONNECTED 반환을 실폰에서 확인했다.
- 인증 대기 화면 감지 시 조작을 중단하도록 수정했고, `Phone.wake` 오류를 게이트에서 무시하지 않도록 했다. 수정 후 실제 MCP `phone_screen` 호출이 사용자 연결 인증 안내를 반환함을 확인했다. 실폰 재생은 사용자 인증 완료 후 진행해야 한다.
- GitHub v0.1.0: 프리릴리스, Ppomi-0.1.0.zip 첨부됨.
- 키체인 코드 서명 인증서: Apple Development만 존재하며 Developer ID Application은 없음.
- README와 랜딩의 공증 완료 문구를 공증 준비 중으로 수정.
- 최초 배포는 `Not authorized`로 실패했으나, `hub/`에서 `vercel deploy --prod --yes --scope muilyzz`로 팀을 명시해 배포 성공. `https://ppomi.muilyzz.com` 응답에서 수정된 안내 확인.
- 실제 MCP 초기화·`read_playbook`·`run_combo(max_steps: 1)` 호출 성공. 여기어때 구조화 발자국이 0개여서 `아는 길 없음`으로 종료. Markdown 절차와 재생용 JSONL 발자국은 별개이며, 아직 실폰 재생 성공은 검증되지 않음.
- Swift 빌드에 plist·entitlements·로컬 JSON 파일의 미처리 파일 경고가 남아 있음. 빌드와 테스트 실패는 없음.

## 실폰 재생 검증 절차

1. 폰을 잠가 Mac 옆에 두고 `phone state`가 CONNECTED인지 확인한다. 로그인과 인증은 사람이 한다.
2. MCP에서 `read_playbook`으로 대상 앱의 절차와 공통 규칙을 읽는다. 현재 날짜에 유효한 비결제 탐색 흐름을 사용하고 이전 예약 조건을 그대로 실행하지 않는다.
3. `run_combo`에 대상 `app`과 `max_steps: 1`을 전달한다. `phone_screen`으로 실제 화면과 반환 결과를 대조한다.
4. 아는 길이 없으면 그 결과를 기록한다. 비결제 탐색을 한 단계씩 수행해 발자국을 만든 후 같은 시작 화면에서 재생을 확인한다.
5. 정상 경로, 낯선 화면 정지, 사용자 차례 정지를 각각 확인한다. 결제 지점은 자동 탭 없이 멈추는지만 확인하며 이 검증에서 결제 승인을 요청하거나 결제하지 않는다.
6. 각 실행의 시각·앱·걸음 수·정지 이유·기대 결과 일치 여부를 기록한다. 화면 증거는 로컬에만 보관하고 개인정보·예약번호·금액은 공개 문서나 발자국에 옮기지 않는다.
7. 성공한 비결제 경로로 20초 데모를 만든다. 공개 전 화면의 개인정보 노출 여부를 확인한다.

## 출시를 위해 남은 입력과 작업

- Developer ID Application 인증서와 공증용 Issuer ID 확보 후 서명·공증·staple 검증.
- 공증 성공한 ZIP으로 릴리스 파일 교체, 프리릴리스 해제, 다운로드 링크와 안내 변경.
- Lemon Squeezy 상품과 결제 URL 확보 후 랜딩 연결.
- 실폰 재생 검증과 데모 완료 후 홍보 진행.

푸시와 배포 시 개인정보 파일 및 private-history 브랜치는 포함하지 않는다. 배포는 기존 hub/ Vercel 프로젝트를 사용한다.
