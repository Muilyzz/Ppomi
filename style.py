#!/usr/bin/env python3
"""style — drafts messages in *your* voice, learned from messages you actually sent. Never sends anything.

  style.py ingest FILE_OR_DIR...   KakaoTalk '대화 내보내기' .txt files (iOS/Android formats) -> data/style.db
  style.py ingest-imessage         your sent SMS/iMessages from ~/Library/Messages/chat.db (needs Full Disk Access)
  style.py screen 상대이름 [PAGES]   open that KakaoTalk room through iPhone Mirroring and OCR the recent messages
  style.py profile [CHAT]          stats + representative examples -> data/style_profile.json (printed)
  style.py draft "요지" [--to 상대] [--last "상대의 마지막 말"]   3 drafts in your voice (Claude API)

env (shell or ./.env): STYLE_ME (your name as it appears in exports), ANTHROPIC_API_KEY
Only the profile stats and a few dozen example messages leave the machine; the corpus stays in data/style.db.
"""
import json, os, re, sqlite3, statistics, sys
from collections import Counter
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(os.path.join(HERE, ".env")):
    for line in open(os.path.join(HERE, ".env")):
        k, _, v = line.strip().partition("=")
        k = k.strip().removeprefix("export ").strip()
        if k and not k.startswith("#") and k not in os.environ:
            os.environ[k] = v.split(" #")[0].strip().strip("\"'")
DB = os.path.join(HERE, "data", "style.db")
PROFILE = os.path.join(HERE, "data", "style_profile.json")
ME = os.environ.get("STYLE_ME", "")
CHAT_DB = os.path.expanduser("~/Library/Messages/chat.db")

# ---------------------------------------------------------------- store
def db():
    os.makedirs(os.path.dirname(DB), exist_ok=True)
    c = sqlite3.connect(DB)
    c.executescript("""CREATE TABLE IF NOT EXISTS msgs(id INTEGER PRIMARY KEY, source TEXT, chat TEXT, ts TEXT,
                       me INTEGER, sender TEXT, text TEXT, UNIQUE(source, chat, ts, sender, text));""")
    return c

# ---------------------------------------------------------------- KakaoTalk export parsing
# iOS:     2026. 9. 2. 오후 3:21, 홍길동 : 내용        Android: 2026년 9월 2일 오후 3:21, 홍길동 : 내용
# Android (older): [홍길동] [오후 3:21] 내용  with date separators like  2026년 9월 2일 화요일
LINE = re.compile(r"^(\d{4})[.년]\s*(\d{1,2})[.월]\s*(\d{1,2})[.일]?,?\s*(오전|오후)\s*(\d{1,2}):(\d{2}),?\s*(.+?)\s*:\s?(.*)$")
LINE2 = re.compile(r"^\[(.+?)\]\s*\[(오전|오후)\s*(\d{1,2}):(\d{2})\]\s?(.*)$")
DATESEP = re.compile(r"^(\d{4})년\s*(\d{1,2})월\s*(\d{1,2})일")
SKIP = re.compile(r"^(사진|동영상|이모티콘|삭제된 메시지입니다\.?|\(이모티콘\)|파일: .*|음성메시지|보이스톡.*|페이스톡.*|송금.*원.*|.*님이 .*(들어왔습니다|나갔습니다)\.?)$")

def hm(ampm, h, m):
    h = int(h) % 12 + (12 if ampm == "오후" else 0)
    return f"{h:02d}:{int(m):02d}"

def parse_kakao(text, chat):
    """Yield (ts, sender, text) from one export file; continuation lines join the previous message."""
    out, cur_date = [], None
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        m = LINE.match(line)
        if m:
            y, mo, d, ap, h, mi, sender, body = m.groups()
            out.append([f"{int(y):04d}-{int(mo):02d}-{int(d):02d} {hm(ap, h, mi)}", sender.strip(), body])
            continue
        m = LINE2.match(line)
        if m and cur_date:
            sender, ap, h, mi, body = m.groups()
            out.append([f"{cur_date} {hm(ap, h, mi)}", sender.strip(), body])
            continue
        m = DATESEP.match(line)
        if m:
            cur_date = f"{int(m.group(1)):04d}-{int(m.group(2)):02d}-{int(m.group(3)):02d}"
            continue
        if out and line.strip() and not re.match(r"^\d{4}[.년]", line):   # continuation of a multi-line message
            out[-1][2] += "\n" + line
    for ts, sender, body in out:
        body = body.strip()
        if body and not SKIP.match(body):
            yield ts, sender, body

def ingest(paths):
    c = db()
    n = 0
    files = []
    for p in paths:
        if os.path.isdir(p):
            files += [os.path.join(p, f) for f in sorted(os.listdir(p)) if f.endswith(".txt")]
        else:
            files.append(p)
    for f in files:
        chat = os.path.splitext(os.path.basename(f))[0]
        text = open(f, encoding="utf-8", errors="ignore").read()
        for ts, sender, body in parse_kakao(text, chat):
            n += c.execute("INSERT OR IGNORE INTO msgs(source,chat,ts,me,sender,text) VALUES('kakao',?,?,?,?,?)",
                           (chat, ts, int(sender == ME), sender, body)).rowcount
        c.commit()
    mine = c.execute("SELECT COUNT(*) FROM msgs WHERE me=1").fetchone()[0]
    print(f"{len(files)} files, {n} new messages, {mine} of yours in total (STYLE_ME={ME})")
    if files and not mine:
        print("none matched your name — set STYLE_ME to the name exactly as it appears in the export", file=sys.stderr)

def decode_attributed_body(blob):
    if not blob:
        return None
    i = blob.find(b"NSString")
    if i < 0:
        return None
    i += 13
    if i >= len(blob):
        return None
    n = blob[i]
    if n == 0x81:
        n = int.from_bytes(blob[i + 1:i + 3], "little"); i += 3
    elif n == 0x82:
        n = int.from_bytes(blob[i + 1:i + 5], "little"); i += 5
    else:
        i += 1
    return blob[i:i + n].decode("utf-8", "ignore")

def ingest_imessage():
    c = db()
    try:
        src = sqlite3.connect(f"file:{CHAT_DB}?mode=ro", uri=True)
        rows = src.execute("""SELECT m.ROWID, m.date/1000000000 + 978307200, m.text, m.attributedBody, m.is_from_me, h.id
                              FROM message m LEFT JOIN handle h ON h.ROWID = m.handle_id ORDER BY m.ROWID""").fetchall()
    except sqlite3.OperationalError as e:
        sys.exit(f"cannot read {CHAT_DB}: {e} -> 전체 디스크 접근 권한 필요")
    n = 0
    for rowid, epoch, text, body, me, handle in rows:
        text = text or decode_attributed_body(body)
        if not text or (handle and re.fullmatch(r"[\d+\-]+", handle) and not me):   # skip inbound SMS short codes
            continue
        ts = datetime.fromtimestamp(epoch).strftime("%Y-%m-%d %H:%M")
        n += c.execute("INSERT OR IGNORE INTO msgs(source,chat,ts,me,sender,text) VALUES('imessage',?,?,?,?,?)",
                       (handle or "?", ts, int(bool(me)), ME if me else (handle or "?"), text.strip())).rowcount
    c.commit()
    print(f"{n} new messages from Messages")

# ---------------------------------------------------------------- KakaoTalk via iPhone Mirroring (no export needed)
# Speaker = bubble side: right-aligned rows are mine, left-aligned rows are theirs. Time stamps, read counts,
# date separators, nav bar and the input bar are dropped. Pages are stitched newest -> oldest while scrolling up.
NOISE = re.compile(r"^(오전|오후)\s*\d{1,2}:\d{2}$|^\d{1,3}$|^읽음$|^\d{4}년\s*\d{1,2}월\s*\d{1,2}일.*|^\d{1,2}월\s*\d{1,2}일.*|^메시지 입력$|^\+$|^#$"
                   r"|^(페이스톡|보이스톡|페이스독)(\s|$).*|^부재중$|^\d{2}:\d{2}$|^통화 .*|^사진$|^동영상$|^이모티콘$|^삭제된 메시지입니다\.?$")
KAKAOTALK = {"search": "kakaotalk", "title": "카카오톡", "home": r"^채팅$|^친구$"}

# Korean through the mirror: ⌘-shortcuts and the Mac IME both fail, but the iPhone's own 두벌식 keyboard composes
# Hangul from plain letter keys. So we send the 2-set key sequence (김영희 -> "rladudgml") while the iOS keyboard is Korean.
CHO = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ"; CHO_K = ["r", "R", "s", "e", "E", "f", "a", "q", "Q", "t", "T", "d", "w", "W", "c", "z", "x", "v", "g"]
JUNG_K = ["k", "o", "i", "O", "j", "p", "u", "P", "h", "hk", "ho", "hl", "y", "n", "nj", "np", "nl", "b", "m", "ml", "l"]
JONG_K = ["", "r", "R", "rt", "s", "sw", "sg", "e", "f", "fr", "fa", "fq", "ft", "fx", "fv", "fg", "a", "q", "qt", "t", "T", "d", "w", "c", "z", "x", "v", "g"]

def hangul_keys(text):
    out = []
    for ch in text:
        code = ord(ch) - 0xAC00
        if 0 <= code < 11172:
            cho, rest = divmod(code, 588); jung, jong = divmod(rest, 28)
            out.append(CHO_K[cho] + JUNG_K[jung] + JONG_K[jong])
        elif ch in CHO:
            out.append(CHO_K[CHO.index(ch)])
        else:
            out.append(ch)                                # ASCII passes through
    return "".join(out)

def bubbles(words, partner):
    """OCR words of one chat screen -> [(side, text)] top to bottom, multi-line bubbles joined."""
    rows = []
    for w in sorted(words, key=lambda w: w["y"] + w["h"] / 2):
        cy = w["y"] + w["h"] / 2
        if rows and abs(rows[-1]["cy"] - cy) < 0.012:
            rows[-1]["ws"].append(w)
        else:
            rows.append({"cy": cy, "ws": [w]})
    out = []
    for r in rows:
        ws = sorted(r["ws"], key=lambda w: w["x"])
        text = " ".join(w["text"] for w in ws).strip()
        if r["cy"] < 0.12 or r["cy"] > 0.9 or NOISE.match(text) or text == partner:
            continue
        text = re.sub(r"\s*(오전|오후)\s*\d{1,2}:\d{2}$|^(오전|오후)\s*\d{1,2}:\d{2}\s*", "", text).strip()  # inline time stamps
        text = re.sub(r"^\d{1,2}\s+(?=\S)|\s+\d{1,2}$", "", text).strip()                          # unread counts
        if not text or text == partner:
            continue
        minx, maxx = ws[0]["x"], max(w["x"] + w["w"] for w in ws)
        center = (minx + maxx) / 2
        side = "me" if center > 0.55 else "them" if center < 0.45 else None
        if not side:
            continue
        if NOISE.match(text):                                            # call-log lines after time stripping
            continue
        if out and out[-1][0] == side and r["cy"] - out[-1][2] < 0.03:   # continuation line of the same bubble
            out[-1] = (side, out[-1][1] + "\n" + text, r["cy"])
        else:
            out.append((side, text, r["cy"]))
    return [(s, t) for s, t, _ in out]

def screen_ingest(partner, pages=6):
    import time
    sys.path.insert(0, HERE)
    import am
    c = db()
    collected = []
    def in_room(words):
        """Already inside the partner's room? (title row carries the name and the input bar is visible)"""
        return am.find(words, r"메시지 입력") and any(partner in w["text"] and w["y"] < 0.2 for w in words)
    def read_room():
        step = int(int(am.phone("window").split()[4]) * 0.5)
        prev = None
        for _ in range(pages):
            _, words = am.screen()
            rows = am.rows_from(words)
            if rows == prev:                              # the screen did not move: top of the history
                break
            prev = rows
            collected[:0] = bubbles(words, partner)      # older page goes in front (a page may hold only call logs)
            am.phone("scroll", str(+step))                # scroll up = older messages
    def go():
        am.ensure_connected()
        if not am.open_app({k: v for k, v in KAKAOTALK.items() if k != "home"}):   # don't navigate away yet
            sys.exit("카카오톡을 열지 못했습니다")
        _, words = am.screen()
        if in_room(words):                                # easiest path: the room was left open on the phone
            return read_room()
        am.to_home(KAKAOTALK)
        _, words = am.screen()
        tab = am.find(words, r"^채팅$")
        if tab and tab["y"] > 0.85:
            am.tap(tab)
        else:
            am.phone("tap", "0.30", "0.955")              # 2nd bottom-tab icon = 채팅 (labels often aren't OCR'd)
        time.sleep(1.5)
        step = int(int(am.phone("window").split()[4]) * 0.6)
        _, words = am.screen()
        if am.find(words, r"채팅방 정렬|채팅방 관리"):   # a sort/manage sheet left open: tap outside to close it
            am.phone("tap", "0.5", "0.25"); time.sleep(1); _, words = am.screen()
        cancel = next((w for w in words if w["text"].strip() == "취소" and w["y"] < 0.2), None)
        if cancel:                                        # a previous search is still open: leave it first
            am.tap(cancel); time.sleep(1.2); _, words = am.screen()
        room = next((w for w in words if partner in w["text"] and 0.12 < w["y"] < 0.9), None)
        if not room:
            # Search instead of scrolling (the chat list ignores our scroll gesture). The magnifier is the glyph OCR
            # reads as 'Q' next to the '채팅' title; Korean can't be typed through the mirror, but the Mac clipboard pastes.
            import subprocess
            nav = [w for w in words if w["y"] < 0.2]
            glass = next((w for w in nav if w["text"].strip() in ("Q", "O", "🔍", "⌕")), None)
            t = next((w for w in nav if w["text"].startswith("채팅")), None)
            if not t:
                sys.exit("채팅 탭 상단바를 못 찾았습니다")
            ty = t["y"] + t["h"] / 2
            # header icons sit right of the title: magnifier, new chat, settings(0.93 opens the sort sheet). Try the
            # OCR'd glyph first, then the likely x positions, and accept only when a search field ('취소') appears.
            for x in ([glass["x"] + glass["w"] / 2] if glass else []) + [0.72, 0.80, 0.64]:
                am.phone("tap", str(x), str(ty)); time.sleep(1.5)
                _, words = am.screen()
                if any(w["text"].strip() == "취소" and w["y"] < 0.2 for w in words):
                    break
                if am.find(words, r"채팅방 정렬|채팅방 관리|새로운 채팅"):       # wrong icon: close its sheet
                    am.phone("tap", "0.5", "0.25"); time.sleep(1)
            else:
                sys.exit("검색창을 열지 못했습니다")
            for _ in range(20):                                                    # backspace whatever the field held
                am.phone("key", "delete")
            am.phone("typeko", hangul_keys(partner)); time.sleep(3)                # Mac IME Korean -> iPhone composes Hangul
            _, words = am.screen()
            if not any(partner in w["text"] for w in words if w["y"] < 0.2):
                sys.exit(f"검색어가 제대로 입력되지 않았습니다: {[r[:24] for r in am.rows_from(words)][:3]}")
            # results: the '채팅방' section lists rooms; the 1:1 room's title is exactly the partner's name
            head = next((w for w in words if w["text"].strip() == "채팅방" and 0.15 < w["y"] < 0.9), None)
            below = [w for w in words if head and w["y"] > head["y"] and w["y"] < 0.9]
            room = next((w for w in below if w["text"].strip() == partner), None) or \
                   next((w for w in below if partner in w["text"]), None)
        if not room:
            names = [r[:24] for r in am.rows_from(words)]
            sys.exit(f"'{partner}' 방을 못 찾았습니다. 화면: {names[:14]}")
        am.tap(room); time.sleep(2.5)
        _, words = am.screen()
        chat_btn = am.find(words, r"^채팅$")
        if chat_btn and am.find(words, r"보이스톡|페이스톡"):   # search opened the friend's profile card, not the room
            am.tap(chat_btn); time.sleep(2.5)
            _, words = am.screen()
        if not (am.find(words, r"메시지 입력|^\+$") or any(w["x"] + w["w"] > 0.7 for w in words if 0.2 < w["y"] < 0.85)):
            sys.exit(f"채팅방이 열리지 않았습니다: {[r[:24] for r in am.rows_from(words)][:10]}")
        read_room()
    am.with_phone(go)
    # stitch: drop exact repeats produced by overlapping pages
    seen, msgs, n = set(), [], 0
    for side, text in collected:
        if (side, text) in seen:
            continue
        seen.add((side, text)); msgs.append((side, text))
    for i, (side, text) in enumerate(msgs):
        n += c.execute("INSERT OR IGNORE INTO msgs(source,chat,ts,me,sender,text) VALUES('kakao-screen',?,?,?,?,?)",
                       (partner, f"screen-{datetime.now().strftime('%Y%m%d')}-{i:04d}", int(side == "me"), ME if side == "me" else partner, text)).rowcount
    c.commit()
    print(f"{partner}: {len(msgs)} bubbles read ({sum(s == 'me' for s, _ in msgs)} mine), {n} new")

# ---------------------------------------------------------------- profile
EMOJI = re.compile(r"[\U0001F300-\U0001FAFF☀-➿]")
POLITE = re.compile(r"(요|니다|세요|십시오|습니까|까요|죠|네요)[.!?~ㅋㅎ\s]*$")

def profile(chat=None):
    c = db()
    where, args = ("AND chat=?", (chat,)) if chat else ("", ())
    rows = c.execute(f"SELECT id, chat, ts, text FROM msgs WHERE me=1 {where} ORDER BY chat, ts", args).fetchall()
    if not rows:
        sys.exit("no messages of yours yet — run ingest first")
    texts = [t for _, _, _, t in rows]
    lens = [len(t) for t in texts]
    ends = Counter(re.sub(r"[\s.!?~]+$", "", t)[-2:] for t in texts if t.strip())
    tokens = Counter(w for t in texts for w in re.findall(r"[가-힣]{2,}|[A-Za-z]{2,}", t))
    stats = {
        "messages": len(texts), "avg_chars": round(statistics.mean(lens), 1), "median_chars": statistics.median(lens),
        "polite_ratio": round(sum(bool(POLITE.search(t)) for t in texts) / len(texts), 2),
        "kk_ratio": round(sum("ㅋ" in t for t in texts) / len(texts), 2),
        "hh_ratio": round(sum("ㅎ" in t for t in texts) / len(texts), 2),
        "tear_ratio": round(sum("ㅠ" in t or "ㅜ" in t for t in texts) / len(texts), 2),
        "exclaim_ratio": round(sum("!" in t for t in texts) / len(texts), 2),
        "question_ratio": round(sum("?" in t for t in texts) / len(texts), 2),
        "tilde_ratio": round(sum("~" in t for t in texts) / len(texts), 2),
        "ellipsis_ratio": round(sum(".." in t for t in texts) / len(texts), 2),
        "emoji_ratio": round(sum(bool(EMOJI.search(t)) for t in texts) / len(texts), 2),
        "period_end_ratio": round(sum(t.rstrip().endswith(".") for t in texts) / len(texts), 2),
        "common_endings": [e for e, _ in ends.most_common(15)],
        "common_words": [w for w, _ in tokens.most_common(40)],
    }
    # examples: reply pairs (what the other person said -> what I answered) spread across chats and lengths
    pairs = []
    for i, (mid, chat, ts, text) in enumerate(rows):
        prev = c.execute("SELECT sender, text FROM msgs WHERE chat=? AND me=0 AND ts<=? AND id<? ORDER BY id DESC LIMIT 1",
                         (chat, ts, mid)).fetchone()
        pairs.append({"chat": chat, "them": prev[1][:200] if prev else None, "me": text[:300]})
    buckets = {"short": [p for p in pairs if len(p["me"]) <= 15], "mid": [p for p in pairs if 15 < len(p["me"]) <= 60],
               "long": [p for p in pairs if len(p["me"]) > 60]}
    examples = []
    for name, bucket in buckets.items():
        step = max(1, len(bucket) // 14)
        examples += [p for p in bucket[::step] if p["them"]][:14]           # ~40 pairs, evenly spaced in time
    prof = {"me": ME, "chat": chat, "generated": datetime.now().strftime("%Y-%m-%d %H:%M"), "stats": stats, "examples": examples}
    json.dump(prof, open(PROFILE, "w"), ensure_ascii=False, indent=1)
    print(json.dumps(stats, ensure_ascii=False, indent=1))
    print(f"{len(examples)} example pairs -> {PROFILE}")
    return prof

# ---------------------------------------------------------------- draft (the only part that calls an LLM)
def build_prompt(prof, brief, to=None, last=None):
    s = prof["stats"]
    rules = [
        f"평균 {s['avg_chars']}자, 중앙값 {s['median_chars']}자. 이보다 길게 쓰지 마라.",
        f"존댓말 비율 {s['polite_ratio']}: " + ("기본 존댓말" if s["polite_ratio"] > 0.6 else "기본 반말" if s["polite_ratio"] < 0.3 else "상대에 따라 다름 — 예문에서 같은 상대의 말투를 따라라"),
        f"ㅋ 사용 {s['kk_ratio']}, ㅎ {s['hh_ratio']}, ㅠ {s['tear_ratio']}, 느낌표 {s['exclaim_ratio']}, 물결 {s['tilde_ratio']}, 말줄임 {s['ellipsis_ratio']}, 이모지 {s['emoji_ratio']}, 마침표로 끝냄 {s['period_end_ratio']} — 이 빈도를 넘지 마라.",
        "자주 쓰는 끝맺음: " + ", ".join(s["common_endings"][:10]),
        "자주 쓰는 말: " + ", ".join(s["common_words"][:25]),
    ]
    ex = "\n".join(f"- 상대: {p['them']}\n  나: {p['me']}" for p in prof["examples"])
    system = (f"너는 {prof['me']}의 메시지 초안 작성기다. 아래 통계와 실제 예문에 드러난 말투를 그대로 재현한다. "
              "새로운 정보를 지어내지 말고, 요지에 있는 내용만 쓴다. 과장된 친절함·이모지 남발·설명조를 피한다. "
              "출력은 서로 다른 초안 3개를 '1) ', '2) ', '3) '로 시작하는 줄에 각각 한 개씩, 다른 말 없이.\n\n"
              "[말투 규칙]\n" + "\n".join("- " + r for r in rules) + "\n\n[실제 주고받은 예문]\n" + ex)
    user = (f"상대: {to or '미지정'}\n" + (f"상대의 마지막 말: {last}\n" if last else "") + f"내가 전하려는 요지: {brief}")
    return system, user

def draft(args):
    to = last = None
    rest = []
    it = iter(args)
    for a in it:
        if a == "--to": to = next(it, None)
        elif a == "--last": last = next(it, None)
        else: rest.append(a)
    brief = " ".join(rest).strip()
    if not brief:
        sys.exit('usage: style.py draft "요지" [--to 상대] [--last "상대의 마지막 말"]')
    if not os.path.exists(PROFILE):
        sys.exit("no profile yet — run: style.py profile")
    prof = json.load(open(PROFILE))
    system, user = build_prompt(prof, brief, to, last)
    sys.path.insert(0, HERE)
    import llm
    try:
        text, usage = llm.complete(system, user)
    except RuntimeError as e:
        sys.exit(str(e))
    print(text)
    print(f"\n({usage} — 전송되지 않음, 복사해서 쓰세요)")

if __name__ == "__main__":
    cmd, *rest = sys.argv[1:] or ["help"]
    {"ingest": lambda: ingest(rest), "ingest-imessage": ingest_imessage,
     "screen": lambda: screen_ingest(rest[0], int(rest[1]) if len(rest) > 1 else 6),
     "profile": lambda: profile(rest[0] if rest else None), "draft": lambda: draft(rest),
     }.get(cmd, lambda: print(__doc__))()
