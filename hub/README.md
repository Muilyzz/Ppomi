# ppomi-hub

뽀미 발자국(앱별 절차의 한 걸음) 공유 허브. Vercel 서버리스 + KV. Node 24, 의존성은 `@vercel/kv` 하나.

랜딩(`index.html`, `privacy.html`, 아이콘·소셜 이미지)도 여기 산다 — Vercel 배포 루트 하나가 https://ppomi.vercel.app 정적 페이지와 `/api/*` 를 같이 낸다(`cleanUrls` 로 `/privacy`).

## 엔드포인트 (응답은 전부 JSON, 오류는 4xx + `{ reasons: [...] }`)

| 메서드 | 경로 | 역할 |
|---|---|---|
| POST | `/api/footprints` | 발자국 게시. 검사 통과 → 저장, `201 {id}`. 중복 id `409`, 분당 10건 초과 `429` |
| GET | `/api/footprints?app=&since=&tier=` | 목록. 격리 제외, verified 등급 먼저, `verified.ok` 내림차순, 최대 200 |
| POST | `/api/verify` | `{id, ok, publisher, appVersion?, step?}` → 검증 카운터 갱신. 같은 publisher 는 하루 1회만 반영(`counted:false`) |
| POST | `/api/report` | `{id, reason}` → 신고 수 +1, 1 이상이면 `quarantined:true` |
| GET | `/api/export?app=` | 그 앱의 발자국을 `data/playbooks/<앱>.md` 형식 텍스트로 (`# 앱` / `콤보: …` / `- 날짜 버릇`) |
| POST | `/api/telemetry` | 앱 텔레메트리(옵트인). `{ts, event, fields}` — `fields` 키는 `name tool ok ms app step reason` 안에서만, 값은 40자 이하 문자열·bool·숫자. `tm:<event>:<name|tool>:<ok|fail>` 카운터 +1 후 `204`. 앱 기본 주소가 이 경로다(`PPOMI_TELEMETRY_URL` 로 바꿈) |

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
vercel --prod                   # hub/ 에서. 기존 프로젝트 "ppomi" 에 배포 (환경변수: KV_REST_API_URL, KV_REST_API_TOKEN, 선택 VERIFIED_PUBLISHERS)
```

배포는 `hub/` 에서 `vercel --prod` 로만 한다 — 프로젝트 `ppomi` 의 git 자동 배포는 끊어 두었다. `.vercelignore` 가 `test`, `README.md`, `node_modules`, `.env.local` 을 뺀다.
