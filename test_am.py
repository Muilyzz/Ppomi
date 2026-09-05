#!/usr/bin/env python3
"""python3 test_am.py — the one check that fails if the SMS parser or OCR row logic breaks."""
import json, os, sqlite3, tempfile, time
from datetime import datetime, date
import am

NOW = datetime(2026, 9, 2, 13, 0)

SAMPLES = {
    # multi-line, masked card digits, merchant on its own line
    "kb": ("[Web발신]\nKB국민카드1*2*승인\n홍*동\n12,000원 일시불\n09/02 12:34\n스타벅스코리아\n누적1,234,567원",
           dict(kind="approval", amount=12000, merchant="스타벅스코리아", ts="2026-09-02 12:34", cumulative=1234567)),
    # single-line, merchant after the time
    "shinhan": ("[Web발신]\n신한카드(1234)승인 홍*동 45,000원(일시불)09/01 19:02 배달의민족 누적2,345,678원",
                dict(kind="approval", amount=45000, merchant="배달의민족", ts="2026-09-01 19:02", card="신한카드(1234)")),
    # cancel; 4-char Korean merchant must not be mistaken for a masked customer name
    "cancel": ("[Web발신]\n삼성카드 승인취소\n홍*동님\n8,900원\n09/02 09:10\n홈플러스",
               dict(kind="cancel", amount=8900, merchant="홈플러스")),
    # bank withdrawal with 잔액 (must not confuse 잔액 with amount)
    "bank": ("[Web발신]\nKB국민은행 출금\n09/02 08:00\n123,456원\n잔액 518,574원\n카드결제",
             dict(kind="withdrawal", amount=123456, cumulative=518574, merchant="카드결제")),
    # bank deposit whose memo mentions a card cancel: stays a deposit, is not a card cancel
    "deposit-memo": ("[Web발신]\nKB국민은행 입금\n09/02 08:00\n12,000원\n잔액 518,574원\n신한카드취소",
                     dict(kind="deposit", amount=12000)),
    # deposit with '출금계좌' in the counterparty line: still a deposit
    "kakao": ("[Web발신]\n카카오뱅크 홍*동\n09/02 12:34\n입금 50,000원\n홍길동 (출금계좌 1234)\n잔액 1,000,000원",
              dict(kind="deposit", amount=50000, cumulative=1000000)),
    # 누적 appearing before the transaction amount
    "cum-first": ("[Web발신]\n현대카드 승인 누적2,345,678원 12,340원 09/01 19:02 스타벅스", dict(amount=12340, cumulative=2345678)),
    # international prefix stripped, negative sign kept on balances
    "intl": ("[국제발신]\n우리카드 승인 3,000원 09/02 10:00 GS25", dict(kind="approval", amount=3000, merchant="GS25")),
    # year rollover: alert dated 12/31 read on 01/01
    "rollover": ("[Web발신]\n현대카드 승인 1,000원 일시불 12/31 23:59 GS25", dict(ts="2025-12-31 23:59")),
    # not transactions
    "ad": ("[Web발신] (광고) KB국민은행 내 돈 관리에 필요한 정보", None),
    "comma-won": ("[Web발신]\n고객님, 원하시는 카드 승인 알림입니다", None),      # ', 원' is not money
    "declined": ("[Web발신]\n신한카드(1234)승인거절 홍*동 12,000원(일시불)09/02 12:34 스타벅스 한도초과", None),
    "foreign": ("[Web발신]\n신한카드(1234)해외승인 홍*동 USD 12.34 09/01 19:02 AMAZON.COM 누적2,345,678원", None),
}

for name, (text, want) in SAMPLES.items():
    got = am.parse_sms(text, NOW)
    if want is None:
        assert got is None, (name, got)
        continue
    assert got, (name, "parsed nothing")
    for k, v in want.items():
        assert got[k] == v, (name, k, got[k], v)

# OCR words -> rows -> balances (shape as emitted by `phone ocr`, y grows downward)
def W(texts, y0=0.30):
    return [{"x": 0.1, "y": y0 + 0.03 * i, "w": 0.4, "h": 0.012, "conf": 1.0, "text": t} for i, t in enumerate(texts)]

ACC = am.APPS["KB"]["account"]
assert am.parse_balances([
    {"x": 0.17, "y": 0.38, "w": 0.4, "h": 0.012, "conf": 0.5, "text": "KB국민ONE통장-보통예금 (3456) D"},
    {"x": 0.81, "y": 0.385, "w": 0.06, "h": 0.012, "conf": 0.5, "text": "이체"},
    {"x": 0.17, "y": 0.40, "w": 0.2, "h": 0.014, "conf": 1.0, "text": "518,574원"},
    {"x": 0.25, "y": 0.34, "w": 0.4, "h": 0.012, "conf": 0.5, "text": "WOW! 와우회원은 매 주문 배달비 0원"},
], ACC) == [("KB국민ONE통장-보통예금 (****)", 518574)]
# wrapped account name and a section header above: exactly one balance, not two
assert am.parse_balances(W(["KB국민ONE통장-", "보통예금 (3456)", "518,574원"]), ACC) == [("보통예금 (****)", 518574)]
assert am.parse_balances(W(["내 계좌 전체보기", "KB국민ONE통장 (3456)", "518,574원"]), ACC) == [("KB국민ONE통장 (****)", 518574)]
# two accounts, negative (overdraft) balance kept
assert am.parse_balances(W(["KB국민ONE통장 (3456)", "518,574원", "KB마이너스통장 (9876)", "-1,234,567원"]), ACC) == [
    ("KB국민ONE통장 (****)", 518574), ("KB마이너스통장 (****)", -1234567)]
# a promo banner right under an account row is not its balance
assert am.parse_balances(W(["KB국민ONE통장 (3456)", "KB카드쓰담적금 출시 기념 최대 100만원", "518,574원"]), ACC) == [("KB국민ONE통장 (****)", 518574)]
# balance on the same row as the account name; a savings account is an account too
assert am.parse_balances(W(["KB국민ONE통장 (3456) 518,574원", "KB적금 (7777) 1,000,000원"]), ACC) == [
    ("KB국민ONE통장 (****)", 518574), ("KB적금 (****)", 1000000)]
# section header '3개 계좌' is not an account row for Toss-like screens
assert am.parse_balances(W(["3개 계좌 1,518,574원", "토스뱅크 통장 (1234)", "518,574원"]), am.APPS["TOSS"]["account"]) == [("토스뱅크 통장 (****)", 518574)]
# real Toss home with expired MyData links: headers, promos and '0원 내역' must yield nothing
assert am.parse_balances(W(["길동님의 9월 최대 적립금 확인하기", "12,345원", "0원 송금", "토스뱅크 통장", "다시 연결하기 송금",
                            "입출금통장 • 만료", "계좌 대출 카드 모두보기", "0원 내역"]), am.APPS["TOSS"]["account"]) == []
# real KB 전체계좌조회: name row / number row / balance row, a savings account with 신규일·만기일 lines in between,
# plus 총 잔액 and 예금•적금 subtotals that must not become accounts
assert am.parse_balances(W(["총 잔액", "9,999,999원", "모으기 이체", "예금 • 적금 9,999,999원",
                            "KB국민ONE통장-보통예금 :", "123456-01-654321 D", "518,574원",
                            "KB마음편한통장 :", "123456-02-654321 D", "1,000원",
                            "직장인우대적금 :", "123456-03-654321 G", "신규일 2023.10.24", "만기일 2026.10.24 (D-52)", "3,000,000원"]),
                         ACC) == [("KB국민ONE통장-보통예금 …4321", 518574), ("KB마음편한통장 …4321", 1000), ("직장인우대적금 …4321", 3000000)]
# real 카카오뱅크 home: OCR splits 'AI' into 'A I' and appends the hidden-balance toggle '*'
KA = am.APPS["KAKAO"]["account"]
assert am.parse_balances(W(["A I 관련 지출 통장 *", "700,000원", "카드 이체"]), KA) == [("AI 관련 지출 통장", 700000)]
assert am.parse_balances(W(["A| 관련 지출 통장 *", "700,000원", "카드 이체"]), KA) == [("AI 관련 지출 통장", 700000)]
assert am.parse_balances(W(["^ AI 관련 지출 통장", "3333-01-1234567 C", "700,000원"]), KA) == [("AI 관련 지출 통장", 700000)]  # same label as on the home
# real 케이뱅크 home: full account number in the label is reduced to its last 4 digits
assert am.parse_balances(W(["MY 입출금통장 100-000-654321 D :", "123원", "가져오기 이체하기", "계좌", "WINGO 통장 이체", "1,000,000원"]),
                         am.APPS["KBANK"]["account"]) == [("MY 입출금통장 …4321", 123), ("WINGO 통장", 1000000)]

# 카카오뱅크 transaction list: date header, then (merchant -amount) / (time #tag balance) row pairs
NOW = datetime(2026, 9, 2, 17, 0)
tx = am.parse_transactions(["^ AI 관련 지출 통장", "3333-02-1234567 C", "518,574원", "Q 3개월 • 전체 • 최신순 ✓",
                            "AI 이체의 새로운 방법", "09.02",
                            "쿠팡이츠 -12,345원", "15:50 #체크카드 518,574원",
                            "이디야커피 IBK고객 -4,500원", "13:06 #체크카드 530,919원",
                            "월급 +1,000,000원", "09:00 #입금 535,419원",
                            "12.31", "GS25 -1,000원", "23:59 #체크카드 100원"], NOW, "KAKAO")
assert [(t["ts"], t["kind"], t["amount"], t["merchant"], t["cumulative"]) for t in tx] == [
    ("2026-09-02 15:50", "approval", 12345, "쿠팡이츠", 518574),
    ("2026-09-02 13:06", "approval", 4500, "이디야커피 IBK고객", 530919),
    ("2026-09-02 09:00", "deposit", 1000000, "월급", 535419),
    ("2025-12-31 23:59", "approval", 1000, "GS25", 100)], tx          # 12.31 read in September is last year
assert len({t["uid"] for t in tx}) == 4
# rows accumulate across scrolled pages: page 2 has no date header and a merchant/time pair straddles the boundary
p1 = ["09.02", "가맹점1 -1,000원", "18:00 #체크카드 9,000원", "가맹점2 -1,000원"]
p2 = ["17:00 #체크카드 10,000원", "가맹점3 -1,000원", "16:00 #체크카드 11,000원", "09.01 :", "가맹점4 -2,000원", "21:00 #체크카드 13,000원"]
got = [(t["ts"], t["merchant"]) for t in am.parse_transactions(p1 + p2, NOW, "KAKAO")]
assert got == [("2026-09-02 18:00", "가맹점1"), ("2026-09-02 17:00", "가맹점2"), ("2026-09-02 16:00", "가맹점3"), ("2026-09-01 21:00", "가맹점4")], got
# a scrolled page opens with the rows that sat just above its first date header on the previous page: they keep the newer date
q1 = ["09.01", "가맹점A -1,000원", "22:48 #체크카드 64,041원", "08.31", "가맹점B -2,000원", "23:24 #체크카드 979,417원"]
q2 = ["가맹점A -1,000원", "22:48 #체크카드 64,041원", "08.31", "가맹점B -2,000원", "23:24 #체크카드 979,417원", "가맹점C -3,000원", "19:06 #체크카드 348,770원"]
got = [(t["ts"], t["merchant"]) for t in am.parse_transactions([am.PAGE] + q1 + [am.PAGE] + q2, NOW, "KAKAO")]
assert got == [("2026-09-01 22:48", "가맹점A"), ("2026-08-31 23:24", "가맹점B"), ("2026-09-01 22:48", "가맹점A"), ("2026-08-31 23:24", "가맹점B"),
               ("2026-08-31 19:06", "가맹점C")], got
# the natural key ignores OCR drift in the merchant text, a tag with a space still parses, '-' with 취소 in the name is spend
a = am.parse_transactions(["09.02", "이디야커피 IBK고객 -4,500원", "13:06 #체크카드 530,919원"], NOW, "KAKAO")[0]
b = am.parse_transactions(["09.02", "이디야커피 I BK고객 -4,500원", "13:06 # 체크카드 530,919원"], NOW, "KAKAO")[0]
assert a["uid"] == b["uid"] and b["card"] == "체크카드", (a, b)
c1 = am.parse_transactions(["09.02", "취소마트 -3,000원", "12:00 #체크카드 1,000원", "쿠팡 +3,000원", "12:30 #체크카드 취소 4,000원"], NOW, "KAKAO")
assert [t["kind"] for t in c1] == ["approval", "cancel"], c1
# deposits carry no sign and (transfers in) no tag; interest has a tag; OCR sometimes reads '-' as '~'
d = am.parse_transactions(["08.30", "CURSOR USAGE MID AU -155,934원", "22:59 #체크카드 989,222원", "홍길동 1,000,000원", "22:59 1,145,156원",
                           "입출금통장 이자 40원", "04:29 #예금이자 1,087,310원", "CURSOR USAGE AUG ~152,308원", "14:12 #체크카드 913,102원"], NOW, "KAKAO")
assert [(t["kind"], t["amount"], t["merchant"], t["card"], t["cumulative"]) for t in d] == [
    ("approval", 155934, "CURSOR USAGE MID AU", "체크카드", 989222), ("deposit", 1000000, "홍길동", "", 1145156),
    ("deposit", 40, "입출금통장 이자", "예금이자", 1087310), ("approval", 152308, "CURSOR USAGE AUG", "체크카드", 913102)], d
assert am.tx_uid("KAKAO", "2026-09-02 13:06", "approval", 4500, 530919) == a["uid"]

# KB스타뱅킹 거래내역조회: the month header carries the year; four consecutive rows per transaction; '+' deposits, 취소 refunds;
# a transaction cut by a page boundary is dropped there and picked up whole on the next page; '|' may OCR as 'I'
kb = am.parse_kb_transactions(["< 거래내역조회 =", "KB국민ONE통장 >", "123456-04-123456 V", "518,574원", "출금가능금액 518,574원",
                               "2026.06.04 ~ 2026.09.03 잔액표기", "2026.08",
                               "08.24 21:56:29 | 스마트출금", "홍길동", "-100,000원", "518,574원",
                               "08.10 15:00:56 | ATM", "ATM입금", "+300,000원", "818,574원",
                               "08.05 09:00:00 I 체크카드", "스타벅스", "~4,500원", "518,574원",        # OCR: '-' read as '~'
                               "08.03 10:00:00 | 체크카드취소", "스타벅스", "+4,500원", "523,074원",
                               "08.01 12:00:00 | 스마트출금",                       # page ends mid-transaction
                               "< 거래내역조회 =", "518,574원",
                               "08.01 12:00:00 | 스마트출금", "홍길동", "-50,000원", "518,574원",
                               "2025.12", "12.31 23:59:00 | 예금이자", "이자", "+10원", "100원"], NOW, "KB")
assert [(t["ts"], t["kind"], t["amount"], t["merchant"], t["card"], t["cumulative"]) for t in kb] == [
    ("2026-08-24 21:56", "withdrawal", 100000, "홍길동", "스마트출금", 518574),
    ("2026-08-10 15:00", "deposit", 300000, "ATM입금", "ATM", 818574),
    ("2026-08-05 09:00", "approval", 4500, "스타벅스", "체크카드", 518574),
    ("2026-08-03 10:00", "cancel", 4500, "스타벅스", "체크카드취소", 523074),
    ("2026-08-01 12:00", "withdrawal", 50000, "홍길동", "스마트출금", 518574),
    ("2025-12-31 23:59", "deposit", 10, "이자", "예금이자", 100)], kb
assert len({t["uid"] for t in kb}) == 6

# /balance reports the latest run per app and per-app subtotals (Toss re-lists other banks, so no grand total)
REAL_DB = am.DB
with tempfile.TemporaryDirectory() as d:
    am.DB = os.path.join(d, "ledger.db")
    c = am.db()
    c.executemany("INSERT INTO snapshots(ts,app,account,balance,shot) VALUES(?,?,?,?,?)", [
        ("2026-09-01 08:00", "KB", "A (****)", 100, "s1.png"), ("2026-09-01 08:00", "KB", "B (****)", 50, "s1.png"),
        ("2026-09-02 08:00", "KB", "A (****)", 120, "s2.png"),                       # B missing in the latest run
        ("2026-09-02 08:01", "TOSS", "A (****)", 120, "s3.png"), ("2026-09-02 08:01", "TOSS", "C (****)", 7, "s3.png")])
    c.commit()
    text = am.balance_text()
    assert "<tg-spoiler>" in text, "balances hide behind spoilers"
    text = am.plain(text)
    assert "KB스타뱅킹 소계 120원" in text and "토스 소계 127원" in text and "B (****)" not in text and "합계" not in text, text
    assert am.handle("/sql SELECT * FROM nope").startswith("sql error"), "bad SQL must answer, not raise"
    # 미루는 대화: add, list with days, done by name, pattern by who/tag; never sends anything
    assert "김영희" in am.handle("/later 김영희 회비 답장 #돈")
    assert am.handle("/later 박대리 견적 회신 #업무 #돈").startswith("적어뒀어요")
    lst = am.plain(am.handle("/list"))
    assert "김영희 회비 답장 #돈 · 0일째" in lst and "박대리" in lst, lst
    assert am.handle("/done 김영희").startswith("✅") and "김영희" not in am.handle("/list")
    assert "해당 항목이 없어요" in am.handle("/done 없는사람")
    pat = am.plain(am.handle("/pattern"))
    assert "총 2건, 보낸 것 1" in pat and "#돈" in pat and "박대리" in pat, pat
    assert "프로필이 없어요" in am.handle("/draft 김영희 회비는 내가 낼게") or "초안" in am.handle("/draft 김영희 회비는 내가 낼게")
    # advice facts: categories via rules, recurring detection, spend vs previous period, no LLM needed for the numbers
    today_s = am.date.today().isoformat()
    c.executemany("INSERT INTO transactions(ts,kind,amount,merchant,source,uid,status) VALUES(?,?,?,?,'app:KAKAO',?,'confirmed')", [
        (f"{today_s} 09:00", "approval", 4500, "이디야커피 IBK고객", "u1"), (f"{today_s} 12:00", "approval", 27000, "쿠팡이츠", "u2"),
        (f"{today_s} 13:00", "approval", 187571, "CURSOR USAGE MID AU", "u3"), (f"{today_s} 14:00", "cancel", 27000, "쿠팡이츠", "u4"),
        ((am.date.today() - am.timedelta(days=40)).isoformat() + " 10:00", "approval", 187571, "CURSOR USAGE MID AU", "u5"),
        (f"{today_s} 08:00", "deposit", 1000000, "월급", "u6")])
    c.commit()
    import llm
    llm.complete = lambda *a, **k: ('{"뭔가": "기타"}', "stub")           # unknown merchants -> LLM once (stubbed)
    s = am.summary(c)
    cats = {x["카테고리"]: x["금액"] for x in s["카테고리별"]}
    assert cats["구독/도구"] == 187571 and cats["카페"] == 4500 and cats["배달"] == 0, cats
    assert s["카드/체크카드 지출"] == 192071 and s["직전 같은 기간 지출"] == 187571 and s["입금"]["금액"] == 1000000, s
    assert any(r["가맹점"].startswith("CURSOR") and r["개월"] == 2 for r in s["반복 결제(2개월 이상)"]), s["반복 결제(2개월 이상)"]
    llm.complete = lambda *a, **k: ("📊 한눈에 — 테스트", "stub 입력 1 / 출력 1")
    assert "주간 재무 리뷰" in am.advise_text() and "자문업자가 아닙니다" in am.advise_text()
    # 토스증권 API response (official example shape): KR+US holdings -> KRW total with an FX rate, per-item rows
    example = {"totalPurchaseAmount": {"krw": "6500000", "usd": "1553"},
               "marketValue": {"amount": {"krw": "7200000", "usd": "1785"}},
               "profitLoss": {"amount": {"krw": "700000", "usd": "232"}, "rate": "0.1179"},
               "items": [{"symbol": "005930", "name": "삼성전자", "marketCountry": "KR", "currency": "KRW", "quantity": "100", "lastPrice": "72000",
                          "averagePurchasePrice": "65000", "marketValue": {"amount": "7200000"}, "profitLoss": {"amount": "700000", "rate": "0.1077"}},
                         {"symbol": "AAPL", "name": "Apple Inc.", "marketCountry": "US", "currency": "USD", "quantity": "10", "lastPrice": "178.5",
                          "averagePurchasePrice": "155.3", "marketValue": {"amount": "1785"}, "profitLoss": {"amount": "232", "rate": "0.1494"}}]}
    total, items, rate = am.parse_holdings(example, 1400.0)
    assert total == 7200000 + 1785 * 1400 and rate == 0.1179 and items[1]["market_value_krw"] == 1785 * 1400, (total, items)
    c.executemany("INSERT INTO holdings(ts,app,account,symbol,name,country,currency,quantity,last_price,avg_price,market_value_krw,pnl_krw,pnl_rate) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                  [("2026-09-02 19:00", "TOSSINVEST", "토스증권 …8901", i["symbol"], i["name"], i["country"], i["currency"], i["quantity"], i["last_price"], i["avg_price"], i["market_value_krw"], i["pnl_krw"], i["pnl_rate"]) for i in items])
    c.commit()
    hs = am.holdings_summary(c)
    assert hs[0]["종목수"] == 2 and hs[0]["상위 종목"][0]["종목"] == "삼성전자" and 0.7 < hs[0]["국내/해외 비중"]["KR"] < 0.8, hs
    assert isinstance(am.summary(c)["증권(토스증권 API)"], list)
am.DB = REAL_DB
# bot command router (offline parts); replies are Telegram HTML
assert "/today" in am.handle("/help") and am.handle("/help").startswith("<b>")
import llm
_real_chat = llm.chat                                          # kept: some checks below exercise the real loop
llm.chat = lambda system, messages, tools=None, execute=None, **k: ("응, 그런 날이 있지. 어떤 문장이 제일 걸렸어?", "stub", [])
assert am.handle("무슨 말이든") == "응, 그런 날이 있지. 어떤 문장이 제일 걸렸어?"   # free text -> conversation
assert am.handle("/없는명령") == am.handle("/help")
# SSE stream -> the same message shape as a normal completion (text deltas + tool-call argument chunks)
import llm as _llm
sse = ['data: {"choices":[{"delta":{"role":"assistant","content":"응, "}}]}',
       'data: {"choices":[{"delta":{"content":"그런 날."}}]}',
       'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"note_later","arguments":"{\\"who\\":"}}]}}]}',
       'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\\"박철수\\"}"}}]}}]}',
       'data: {"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":5}}', 'data: [DONE]']
seen = []
d = _llm.parse_sse(sse, on_delta=seen.append)
m = d["choices"][0]["message"]
assert m["content"] == "응, 그런 날." and seen == ["응, ", "응, 그런 날."], (m, seen)
assert m["tool_calls"][0]["id"] == "c1" and json.loads(m["tool_calls"][0]["function"]["arguments"]) == {"who": "박철수"}
assert d["usage"]["completion_tokens"] == 5

# a model that keeps calling the same tool must still end the turn in words (never the old canned failure)
_key, os.environ["OPENAI_API_KEY"] = os.environ.get("OPENAI_API_KEY", ""), "sk-test"
_real_openai, runs = _llm._openai, []
def loop_openai(body):
    runs.append("tools" in body)
    if "tools" in body:                                    # always asks for the same tool again
        return {"choices": [{"message": {"role": "assistant", "content": None, "tool_calls": [
            {"id": f"c{len(runs)}", "type": "function", "function": {"name": "list_later", "arguments": "{}"}}]}}], "usage": {}}
    return {"choices": [{"message": {"role": "assistant", "content": "최종 답"}}], "usage": {}}
_llm._openai = loop_openai
ran = []
txt, _, tools_called = _real_chat("s", [{"role": "user", "content": "?"}],
                                  tools=[am.T("list_later", "d")], execute=lambda n, a: ran.append(n) or "ok")
assert txt == "최종 답" and runs[-1] is False, (txt, runs)          # last call was made without tools
assert tools_called == ["list_later"] and ran == ["list_later"], (tools_called, ran)   # repeats deduped, not re-run
_llm._openai, os.environ["OPENAI_API_KEY"] = _real_openai, _key

# tool calling from conversation: the model asks for note_later, the executor stores it, the reply names the tool
def fake_chat(system, messages, tools=None, execute=None, **k):
    assert any(t["function"]["name"] == "note_later" for t in tools) and "보내기 도구는 없다" in system
    out = execute("note_later", {"who": "박철수", "topic": "어제 얘기 답장", "tags": "#감정"})
    assert out.startswith("적어뒀어요"), out
    return "적어뒀어. 저녁에 다시 볼까?", "stub", ["note_later"]
llm.chat = fake_chat
with tempfile.TemporaryDirectory() as d:
    am.DB = os.path.join(d, "ledger.db"); am.db()
    r = am.handle("박철수한테 답장 계속 미루고 있어")
    assert r.startswith("적어뒀어.") and "note_later" in r, r
    assert "박철수" in am.plain(am.handle("/list"))
    assert am.execute_tool("remind", {"at": "23:59", "text": "박철수 답장"}).startswith(am.date.today().strftime("%m/%d") + " 23:59")
    am.execute_tool("remind", {"at": "2020-01-01 00:00", "text": "지난 알림"})       # already due -> fires on the next tick
    fired = []
    am.notify = lambda t, b: fired.append(b)
    am.fire_reminders(am.db()); am.fire_reminders(am.db())                            # second tick must not repeat it
    assert fired == ["지난 알림"], fired
    # the phone is never driven without an explicit yes in the current user message (prompt rules are not enough),
    # and that refusal is the ONLY place buttons appear — no button tool for the model to over-use
    assert not any(t["function"]["name"] == "buttons" for t in am.TOOLS)
    am.PENDING.clear()
    am.CURRENT["text"] = "지출·잔액 같이 볼래"
    assert am.execute_tool("collect_now", {}).startswith("실행 안 함")
    assert am.PENDING["buttons"] == ["응 잠겨있어", "아직"]
    kb = json.loads(am.keyboard_for(am.PENDING["buttons"]))
    assert kb["inline_keyboard"][1][0] == {"text": "아직", "callback_data": "opt:1"}, kb
    am.PENDING.clear()
    am.run_sub = lambda *a: "KAKAO: ok"
    am.CURRENT["text"] = "응 잠겨있어"
    assert am.execute_tool("collect_now", {"app": "KAKAO"}) == "KAKAO: ok" and not am.PENDING   # no buttons on success
    for read_only in ("today_spending", "balances", "list_later"):
        am.execute_tool(read_only, {})
    assert not am.PENDING, "읽기 전용 도구는 버튼을 붙이지 않는다"
    assert am.execute_tool("remember", {"fact": "김영희는 아내, 갓난아기가 있음"}).startswith("기억했어요")
    assert "김영희는 아내" in am.facts(am.db())[0][2] and am.execute_tool("forget_fact", {"id": 999}) == "그 번호의 기억이 없어요."
am.DB = REAL_DB
assert "read-only" in am.handle("/sql DELETE FROM snapshots")   # never let the chat mutate the ledger
assert am.handle("/sql SELECT 1 AS one") == "<pre>one\n1</pre>"
assert am.handle("/sql SELECT '<x>&' AS t") == "<pre>t\n&lt;x&gt;&amp;</pre>"   # user data is escaped, never injected
assert "소스" in am.handle("/today") or "오늘" in am.handle("/today")   # empty ledger says so instead of '0원'
# SMS watcher against a fake Messages db: ingests card alerts, ignores people/noise, dedupes ticks, notifies with totals
with tempfile.TemporaryDirectory() as d:
    am.CHAT_DB, am.DB = os.path.join(d, "chat.db"), os.path.join(d, "ledger.db")
    notes = []
    am.notify = lambda t, b: notes.append((t, b))
    src = sqlite3.connect(am.CHAT_DB)
    src.executescript("CREATE TABLE handle(ROWID INTEGER PRIMARY KEY, id TEXT);"
                      "CREATE TABLE message(ROWID INTEGER PRIMARY KEY, date INTEGER, text TEXT, attributedBody BLOB, handle_id INTEGER, is_from_me INTEGER);")
    src.execute("INSERT INTO handle VALUES(1,'15889999'),(2,'friend@icloud.com')")
    t = int((time.time() - 978307200) * 1e9)
    src.execute("INSERT INTO message VALUES(1,?,?,NULL,1,0)", (t, SAMPLES["kb"][0]))
    src.execute("INSERT INTO message VALUES(2,?,?,NULL,2,0)", (t, "저녁 뭐 먹을래 12,000원 승인"))
    src.commit()
    c = am.db()
    class D(date):                                         # the samples say 09/02: pin 'today' so the 오늘 line is stable
        @classmethod
        def today(cls): return date(2026, 9, 2)
    am.date = D
    am.watch_sms(c); am.watch_sms(c)                       # second tick: unchanged file, nothing happens
    src.execute("INSERT INTO message VALUES(3,?,?,NULL,1,0)", (t, SAMPLES["cancel"][0])); src.commit()
    time.sleep(0.02); am.watch_sms(c)
    rows = c.execute("SELECT kind, amount, status FROM transactions ORDER BY id").fetchall()
    assert rows == [("approval", 12000, "pending"), ("cancel", 8900, "pending")], rows
    assert [n[0] for n in notes] == ["💳 결제", "↩︎ 취소"], notes
    assert am.plain(notes[1][1]).endswith("오늘 1건 3,100원"), notes[1]
    am.date = date
print("ok")
