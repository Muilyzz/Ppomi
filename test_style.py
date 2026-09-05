#!/usr/bin/env python3
"""python3 test_style.py — parser, profile stats, and prompt builder on a synthetic KakaoTalk export (no API calls)."""
import json, os, tempfile
import style

IOS = """김철수 님과 카카오톡 대화
저장한 날짜 : 2026. 9. 2. 오후 6:00

2026. 9. 1. 오후 3:21, 김철수 : 내일 저녁 시간 돼?
2026. 9. 1. 오후 3:22, 홍길동 : ㅇㅇ 7시쯤 어때
2026. 9. 1. 오후 3:22, 김철수 : 좋아 어디서 볼까
2026. 9. 1. 오후 3:25, 홍길동 : 강남역 쪽으로 오면 될 듯
두 번째 줄도 같은 메시지
2026. 9. 1. 오후 3:26, 홍길동 : 사진
2026. 9. 1. 오후 3:27, 홍길동 : 이모티콘
"""
ANDROID = """이대리 님과 카카오톡 대화
2026년 9월 2일 화요일
[이대리] [오전 10:05] 대표님 견적서 확인 부탁드립니다
[홍길동] [오전 10:11] 네 확인했습니다. 금액은 그대로 진행해주세요~
2026년 9월 2일 오전 10:12, 이대리 : 감사합니다!
2026년 9월 2일 오전 10:13, 홍길동 : 넵 수고하세요 ㅎㅎ
"""

assert style.hangul_keys("김영희") == "rladudgml" and style.hangul_keys("박철수") == "qkrcjftn" and style.hangul_keys("ab 1") == "ab 1"
assert style.hangul_keys("뽀미") == "Qhal"                     # ㅃ needs shift (uppercase key)
msgs = list(style.parse_kakao(IOS, "chat1"))
assert [m[1] for m in msgs] == ["김철수", "홍길동", "김철수", "홍길동"], msgs     # 사진/이모티콘 lines dropped
assert msgs[3][2] == "강남역 쪽으로 오면 될 듯\n두 번째 줄도 같은 메시지", msgs[3]
assert msgs[0][0] == "2026-09-01 15:21"
msgs2 = list(style.parse_kakao(ANDROID, "chat2"))
assert [(m[0], m[1]) for m in msgs2] == [("2026-09-02 10:05", "이대리"), ("2026-09-02 10:11", "홍길동"),
                                          ("2026-09-02 10:12", "이대리"), ("2026-09-02 10:13", "홍길동")], msgs2

with tempfile.TemporaryDirectory() as d:
    style.DB, style.PROFILE, style.ME = os.path.join(d, "style.db"), os.path.join(d, "p.json"), "홍길동"
    open(os.path.join(d, "chat1.txt"), "w").write(IOS); open(os.path.join(d, "chat2.txt"), "w").write(ANDROID)
    style.ingest([d])
    style.ingest([d])                                                          # idempotent
    c = style.db()
    assert c.execute("SELECT COUNT(*) FROM msgs").fetchone()[0] == 8
    assert c.execute("SELECT COUNT(*) FROM msgs WHERE me=1").fetchone()[0] == 4
    prof = style.profile()
    s = prof["stats"]
    assert s["messages"] == 4 and 0 < s["polite_ratio"] < 1 and s["hh_ratio"] == 0.25, s
    assert prof["examples"] and all(p["them"] for p in prof["examples"]), prof["examples"]
    system, user = style.build_prompt(prof, "내일 미팅 30분 늦을 것 같다고", to="김철수", last="몇 시에 와?")
    assert "홍길동" in system and "강남역" in system and "1) " in system
    assert user.endswith("내가 전하려는 요지: 내일 미팅 30분 늦을 것 같다고") and "몇 시에 와?" in user
    assert json.load(open(style.PROFILE))["me"] == "홍길동"
print("ok")
