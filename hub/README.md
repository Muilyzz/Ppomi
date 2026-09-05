# ppomi-hub

뽀미 플레이북 카탈로그와 발자국(앱별 절차의 한 걸음) 공유 허브. Vercel 서버리스 + KV. Node 24, 의존성은 `@vercel/kv` 하나.

랜딩(`index.html`, `privacy.html`, 아이콘·소셜 이미지)도 여기 산다 — Vercel 배포 루트 하나가 https://ppomi.vercel.app 정적 페이지와 `/api/*` 를 같이 낸다(`cleanUrls` 로 `/privacy`).

## 엔드포인트 (응답은 전부 JSON, 오류는 4xx + `{ reasons: [...] }`)

| 메서드 | 경로 | 역할 |
|---|---|---|
| GET | `/api/playbooks` | 공식 카탈로그. `{schemaVersion:1, playbooks:[{manifest,guide,commonGuide,assets}]}`. 앱 UI와 MCP가 사용하는 원본 패키지에서 생성 |
| GET | `/api/playbooks?id=` | 안정 ID·앱 이름·별칭으로 하나 조회. 같은 `{manifest,guide,commonGuide,assets}`. 없으면 `404` |
| POST | `/api/footprints` | 발자국 게시. 검사 통과 → 저장, `201 {id}`. 중복 id `409`, 분당 10건 초과 `429` |
| GET | `/api/footprints?app=&since=&tier=` | 목록. 격리 제외, verified 등급 먼저, `verified.ok` 내림차순, 최대 200 |
| POST | `/api/verify` | `{id, ok, publisher, appVersion?, step?}` → 검증 카운터 갱신. 같은 publisher 는 하루 1회만 반영(`counted:false`) |
| POST | `/api/report` | `{id, reason}` → 신고 수 +1, 1 이상이면 `quarantined:true` |
| GET | `/api/export?app=` | 그 앱의 발자국을 `data/playbooks/<앱>.md` 형식 텍스트로 (`# 앱` / `콤보: …` / `- 날짜 버릇`) |
| POST | `/api/telemetry` | 앱 텔레메트리(옵트인). `{ts, event, fields}` — `fields` 키는 `name tool ok ms app step reason` 안에서만, 값은 40자 이하 문자열·bool·숫자. `tm:<event>:<name|tool>:<ok|fail>` 카운터 +1 후 `204`. 앱 기본 주소가 이 경로다(`PPOMI_TELEMETRY_URL` 로 바꿈) |

## 플레이북 카탈로그

원본은 `Ppomi/Sources/Ppomi/Catalog/<id>/`의 `manifest.json`, 안내 Markdown, 공식 아이콘이다. 공통 안전 절차는 같은 카탈로그의 `common.md`에 있다. [패키지 명세](../docs/playbook-format.md)에 데이터 구조와 로컬 가져오기 방법을 설명한다.

`npm run sync:catalog`는 이 원본을 검증한 뒤 `hub/catalog/`에 참조된 파일만 바이트 그대로 복사한다. 이 디렉터리는 생성물이라 gitignore이며 직접 수정하지 않는다. `npm run deploy`가 복사를 먼저 실행하므로 배포용 별도 앱 목록을 관리할 필요가 없다. 잘못된 버전, 경로 이동, 심볼릭 링크, 겹치는 앱 별칭은 배포 전에 거부한다. Vercel 함수에는 `catalog/**`를 포함하고, 같은 파일을 `/catalog/<id>/…` 정적 경로로 제공한다. API의 `assets`가 이 상대 URL을 알려 준다.

카탈로그 API는 읽기 전용이다. 공개 카탈로그는 검토한 원본만 배포하며, 로컬에서 가져온 패키지를 자동 게시하지 않는다. 실제 실행 성공·실패, 화면 지문, 개인별 입력은 이 응답에 섞지 않는다. 기존 `/api/footprints`의 명시적인 공유·검증 흐름은 별도로 유지한다.

## 발자국 레코드

```json
{
  "id": "fp-abc123", "app": "여기어때", "appVersion": "5.2.0",
  "glyph": "⊙", "target": "모든 객실 보기",
  "fingerprintBefore": ["숙소", "상세", "모든", "객실", "보기"],
  "fingerprintAfter": ["객실", "목록", "예약하기"],
  "note": "객실 목록은 아래로만 스크롤된다.",
  "publisher": "<ed25519 공개키 raw 32바이트 base64>",
  "sig": "<ed25519 서명 base64>",
  "createdAt": "2026-09-05T01:00:00.000Z",
  "verified": { "ok": 0, "fail": 0, "lastOk": "…", "lastFail": "…", "versions": [] },
  "tier": "community", "quarantined": false
}
```

- 기호: `▶` 앱 열기 `⊙` 탭(정규식, `|` 택일) `⌨` 입력 `↓` 스크롤 뒤 탭 `⎋` 닫기 `👤` 사용자 차례 `🎟` 쿠폰 `🔍` 결제수단 `✋` 승인 `📝` 기록
- 서명 대상: `sig`·`verified`·`tier`·`quarantined` 를 뺀 나머지를 키 정렬 JSON 으로 직렬화한 바이트. 클라이언트가 보낸 `verified`/`tier`/`quarantined` 는 무시하고 서버가 채운다.
- `tier: "verified"` 는 환경변수 `VERIFIED_PUBLISHERS`(공개키 콤마 목록)에 있는 publisher 에만 붙는다. 없으면 전부 community.

## 게시 거부 규칙 (`lib/validate.js`)

개인정보(금액 `\d{1,3}(,\d{3})+원|₩`, 계좌·카드 `\d{4}-\d{4}`, 전화번호, 이메일, URL, 2~4자 한글 이름+님 — 고객님·회원님 등 UI 단어는 허용), 결제 단어(결제|송금|이체|구매|주문|입금|충전)를 target 으로 쓰는 탭(⊙·↓), 허용 외 기호, note 140자 초과, 지문 단어 3~8개·각 24자 이하 위반, ⊙의 target 정규식이 fingerprintBefore 에 안 맞음, 탭(⊙·↓) target 정규식에 수량자(`* + ? {`)가 있거나 `|` 택일이 8개 초과(백트래킹 폭주 방지 — target 은 탭할 글자이지 프로그램이 아니다), 정의된 필드 외의 키, 서명 불일치, 같은 publisher 분당 10건 초과. 결제 단어 검사는 target 문자열뿐 아니라 정규식이 실제로 맞추는 글자(결제 단어 자체, 그리고 fingerprintBefore 의 결제 단어가 든 낱말)에도 건다 — `.`·`[결]제`·`하기`(→"결제하기") 같은 우회를 막는다. 승인(✋) 뒤의 결제 탭은 허브에 올리지 않는다 — export 콤보는 `✋승인` 에서 끝나고 마지막 걸음은 뽀미가 붙인다.

## KV 키

`fp:<app>:<id>` 레코드 · `idx:<app>` id 집합 · `app:<id>` id→app · `pub:<publisher>:rate` 분당 카운트(TTL 60) · `rep:<id>` 신고 수 · `ver:<id>:<publisher>` 하루 1회 검증 잠금(TTL 86400) · `tm:<event>:<name|tool>:<ok|fail>` 텔레메트리 카운터

`KV_REST_API_URL` 이 없으면 메모리 Map 으로 동작한다(테스트). Vercel 위(`VERCEL` env)에서 KV env 가 없으면 기동을 거부한다 — 인스턴스마다 데이터가 증발하는 조용한 실패 방지.

## 실행

```
npm install && npm test        # node --test
npm run sync:catalog           # 개발용 정적 카탈로그 생성
npm run deploy                 # 원본 검증·복사 후 기존 ppomi 프로젝트 / muilyzz 팀에 배포
```

배포는 `hub/`에서 `npm run deploy`로 한다 — 프로젝트 `ppomi`의 git 자동 배포는 끊어 두었다. 환경변수는 `KV_REST_API_URL`, `KV_REST_API_TOKEN`, 선택적으로 `VERIFIED_PUBLISHERS`다. `.vercelignore`는 `test`, `README.md`, `node_modules`, `.env.local`을 빼며 생성한 `catalog/`는 업로드한다.
