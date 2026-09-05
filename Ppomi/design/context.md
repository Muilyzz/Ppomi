# 뽀미(Ppomi) 디자인 작업 컨텍스트

## 앱이 무엇인가
macOS 메뉴바 앱. iPhone 미러링 창(폰)을 검은 "링(도넛)" 안에 붙이고, 링의 왼쪽 띠에 작업대(웹 페이지 4개)를 둔다.
- 창 모드: 제목줄 투명한 패널(RingContent.swift) = 위/아래/왼쪽/오른쪽 검은 띠 + 금색 테두리(#c7a300, 2px) + 오른쪽 구멍(폰 자리).
- 키오스크 모드(⌃⌘F/초록 버튼): 같은 링이 화면 전체(Kiosk.swift, 4개 NSPanel). 폰은 화면 가운데 고정.
- 작업대 = SwiftUI Workbench(Views/EvidenceView.swift): 상단 탭 줄(타임라인 · 증빙·전표 · 뽀미 · 절차 + 오른쪽 ⟳) 아래에 WKWebView 페이지.
- 페이지: Web/timeline.html(순자산 차트+일별 재무상태표, Swift TimelineView가 JSON 주입), Web/evidence.html(OCR 증빙 열, HTML은 Ledger/Column.swift가 생성), Web/chat.html(Deep Chat 2.5.1 벤더, 승인 버튼, 하단 진행 상태줄), Web/playbooks.html(앱별 절차 = 콤보 칩 + 규칙).
- 공통 CSS: Web/theme.css 가 Views/Web.swift 의 Web.page() 로 각 페이지의 /*THEME*/ 자리에 주입된다(방금 만든 빈 파일). 페이지별 스타일은 각 html 안에 있다.
- 하단 띠: "나가기: 검은 부분 클릭 후 ×" 힌트(Kiosk.swift Ring.furnish). 위 띠: 신호등(창 모드) / × 표시(ExitMark, 클릭·Esc로 나타남).
- 사용자: 한국어 1인 개발자. 앱 문구는 한국어.

## 참고 디자인: https://www.agentation.com/
CSS 토큰(실측, 흰 배경 전체 페이지 기준):
- 배경 #fdfdfc, 본문 #111, 링크 #2480ed, 마커 #4c74ff, 선택 배경 #ededed, 포커스 rgba(0,122,255,.5)
- 본문 15px Inter(system-ui 대체), 제목 IBM Plex Serif(세리프 디스플레이, 밑줄/형광 강조), 인라인 코드 모노 + 연회색 배경
- 크기 계열 .625/.6875/.75/.8125/.875rem — 작은 회색 메타 텍스트를 많이 씀
- 모서리 .375rem/.5rem, 그림자 거의 없음(inset 1px rgba(0,0,0,.12) 헤어라인)
- 구조: 왼쪽 좁은 사이드 내비(아주 작은 회색 텍스트, 섹션 소제목 "Tools", "Resources"), 본문 한 열(폭 ~600px), 섹션 제목이 헤어라인 위에 작은 라벨로 얹힘("How you use it ————"), 굵은 리드인 불릿, 알약 버튼(검정 primary / 흰 secondary / 파랑), 연회색 예시 카드
- 인상: 절제, 문서 같은 편집 디자인, 색은 링크 파랑 하나, 여백 넉넉, 장식 없음

## 제약
- 링은 검정이어야 한다(폰 베젤과 이어지는 프레임). 금색 테두리는 정체성이지만 과용 중(탭 활성, 칩, 버튼, 승인까지 전부 금색).
- 다크가 기본(밤에 폰 옆에서 씀). 페이지 안에 밝은 종이 카드를 넣는 안도 후보로 검토 가능.
- Deep Chat은 벤더 라이브러리: chat.html 의 messageStyles/textInput 등 설정으로만 스타일링.
- 폰트: Inter는 로컬에 없을 수 있다 → -apple-system/Apple SD Gothic Neo 기본, 세리프는 Apple의 'New York'/Georgia 계열 가능. 외부 폰트 로드는 하지 않는다(오프라인).
- 코드 규모: html 4개 총 ~280줄, Swift 뷰 ~330줄. 새 프레임워크·의존성 추가 금지. 최소 diff.
