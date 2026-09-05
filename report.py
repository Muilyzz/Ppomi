#!/usr/bin/env python3
"""python3 report.py 2026-08  ->  data/report-2026-08.html

Evidence-first month ledger. The OCR'd screenshots of each app's transaction list are stitched into one column,
registered by matched rows the way sky surveys register frames by matched stars (never by pixels), with every parsed
transaction boxed on it. From those rows: a double-entry journal, then a balance sheet at the first and last day of
the month. Spend whose debit side is a non-monetary capital (역량/시간/건강/관계/즐거움/유지) is highlighted: the credit
is in won, the debit is never valued in won, so net worth stays honest."""
import base64, glob, html, itertools, json, os, re, subprocess, sys, tempfile
from datetime import date, datetime, timedelta
import am

SHOTS, FRAME_H = am.SHOTS, 766                   # displayed frame height in px (348x766, half the PNG); OCR coords are normalized
ME = os.environ.get("STYLE_ME", "")

LISTS = {app: (marker, am.PARSERS.get(app, am.parse_transactions)) for app, marker in am.LIST_MARKERS.items()}   # list-row marker, parser
ACCOUNT = {"KAKAO": (r"AI 관련 지출", "카카오뱅크 AI 관련 지출 통장"), "KB": (r"ONE통장", "KB국민ONE통장")}   # the account each list belongs to
# what the won turned into (debit side of a spend); first match wins, default 유지. Value: (capital, how much of it remains)
CAPITAL = [(r"CURSOR|AWS|VERCEL|Google|GROK|APPLE|Amazon|OPENAI|ANTHROPIC", "역량"), (r"쿠팡이츠|배달|택시|카카오 ?T", "시간"),
           (r"사우나|헬스|병원|약국", "건강"), (r"축의|조의|부의|경조", "관계"), (r"유튜브|넷플릭스|멜론|게임", "즐거움")]
REMAINS = {"역량": "쌓임", "시간": "그 시간을 뭘 했느냐에 달림", "건강": "서서히 줄어듦", "관계": "남음", "즐거움": "그 자리에서 소비", "유지": "그 자리에서 소비"}

def capital(merchant):
    return next((cap for pat, cap in CAPITAL if re.search(pat, merchant or "", re.I)), "유지")

def won(n):
    return f"{n:,}원"

def esc(s):
    return html.escape(str(s))

# ---------------------------------------------------------------- evidence: frames -> one registered column per app
def anchor(r):
    """Registration key of a row, or None: the timestamped list rows (time + balance after, or KB's date-time), reduced
    to their digits so OCR drift in the text between runs ('# 체크카드' vs '#체크카드') still matches."""
    m = am.TX_META.match(r)
    if m:
        return f"{m.group(1)}:{m.group(2)}|{m.group(4)}"
    m = am.KB_TX.match(r)
    return m and "|".join(m.groups()[:5])

BOTTOM = re.compile(r"가져오기|이체하기|^홈 메뉴")          # the floating action bar at the foot of a list: nothing below it is evidence

def load_frames(app):
    """Frames of this app's transaction list, each with its rows, row extents and the transactions parsed from it.
    Frames are parsed per scrolling run (consecutive frames under 2 minutes apart, pages joined with am.PAGE) exactly
    as the collector does, so a row whose date header sits on an earlier frame still gets its date."""
    marker, parse = LISTS[app]
    out = []
    for j in sorted(glob.glob(os.path.join(SHOTS, "*.jsonl"))):
        words = [json.loads(l) for l in open(j) if l.strip()]
        groups = am.row_groups(words)
        rows = [" ".join(x["text"] for x in sorted(ws, key=lambda w: w["x"])) for _, ws in groups]
        if sum(bool(marker.match(r)) for r in rows) < 2:
            continue                                  # not this app's transaction list
        when = datetime.strptime(os.path.basename(j)[:15], "%Y%m%d-%H%M%S")
        out.append({"png": j[:-6] + ".png", "when": when, "rows": rows, "tx": [],
                    "words": [sorted(ws, key=lambda w: w["x"]) for _, ws in groups],
                    "ys": [(min(w["y"] for w in ws), max(w["y"] + w["h"] for w in ws)) for _, ws in groups]})
    run, run_no = [], 0
    for f in out + [None]:
        if run and (f is None or (f["when"] - run[-1]["when"]).total_seconds() > 120):
            pages, starts = [], []
            for fr in run:
                fr["run"] = run_no
                starts.append(len(pages) + 1); pages += [am.PAGE] + fr["rows"]
            for t in parse(pages, run[-1]["when"], app):
                k = max(i for i, s0 in enumerate(starts) if s0 <= t["rows"][0])
                a, b = t["rows"][0] - starts[k], t["rows"][1] - starts[k]
                if b < len(run[k]["rows"]):           # both rows on the same frame (a pair straddling frames is boxed nowhere)
                    run[k]["tx"].append(dict(t, rows=(a, b)))
            run, run_no = [], run_no + 1
        if f:
            run.append(f)
    return out

def stitch(frames, app):
    """Place frames on one vertical canvas. A frame's offset = median(y_a - y_b) over the anchor rows it shares with an
    already placed frame; keys are time + balance-after, unique enough that one shared row suffices (more agreeing rows win). Frames are placed in order of overlap strength, not capture time, so a
    run that started deep in the list still lands on the run that covers the top. No overlap at all: a new segment
    below. Same offset as a placed frame (scroll did not move): dropped. clip/bottom: the frame's own sticky header
    and floating footer are not evidence and would paint over the neighbours."""
    for f in frames:
        ks = [anchor(r) for r in f["rows"]]
        f["keys"] = {k: i for i, k in enumerate(ks) if k and ks.count(k) == 1}
    placed, todo = [], list(frames)
    def fit(f):
        best = (0, None)
        for p in placed:
            shared = [(p["f"]["keys"][k], i) for k, i in f["keys"].items() if k in p["f"]["keys"]]
            if not shared:
                continue
            ds = sorted(p["f"]["ys"][a][0] - f["ys"][b][0] for a, b in shared)
            d = ds[len(ds) // 2]
            n = sum(abs(x - d) < 0.01 for x in ds)
            if n > best[0]:
                best = (n, p["top"] + d)
        return best
    while todo:
        (n, top), f = max(((fit(x), x) for x in todo), key=lambda c: c[0][0]) if placed else ((0, None), todo[0])
        todo.remove(f)
        if n >= 1:
            if any(abs(top - q["top"]) < 0.02 for q in placed):
                continue
        else:
            top = max(q["top"] for q in placed) + 1.05 if placed else 0.0
        # the seam goes above the first COMPLETE transaction in this frame. A frame often opens with the second line of a
        # transaction whose first line sits under the app's sticky header; that line is an anchor (it registers the
        # frame) but not evidence here — the frame above shows that transaction whole, so the seam must fall below it.
        first = min([f["ys"][t["rows"][0]][0] for t in f["tx"]] or [f["ys"][i][0] for i in f["keys"].values()])
        clip = first - (0.035 if first - 0.035 >= 0.15 else 0.012)        # take its date line too, but never the nav bar above 0.15
        foot = min((f["ys"][i][0] for i, r in enumerate(f["rows"]) if BOTTOM.search(r) and f["ys"][i][0] > 0.5), default=1.0)
        last = max([f["ys"][t["rows"][1]][1] for t in f["tx"]] + [f["ys"][i][1] for i in f["keys"].values()], default=0.85)   # below the last row: blank/spinner/bezel
        cap = 0.88 if app == "KAKAO" else 0.97                          # 카카오's floating 가져오기/이체하기 bar even when OCR misses it
        placed.append({"f": f, "top": top, "clip": clip, "bottom": min(foot - 0.005, last + 0.05, cap)})
    return placed

def jpeg_b64(png):
    out = os.path.join(tempfile.gettempdir(), os.path.basename(png)[:-4] + ".jpg")
    subprocess.run(["sips", "-s", "format", "jpeg", "-s", "formatOptions", "60", png, "--out", out], capture_output=True, check=True)
    return "data:image/jpeg;base64," + base64.b64encode(open(out, "rb").read()).decode()

def app_icon(app):
    """data: URI of the app's icon, cropped from a captured frame where its label appears (home page or Spotlight grid: the
    icon sits centred above the label). Cached as data/icons/<app>.png. Returns "" if no frame shows the label."""
    out = os.path.join(am.HERE, "data", "icons", f"{app}.png")
    if not os.path.exists(out):
        titles = {am.APPS[app]["title"], am.APPS[app].get("home_label", "")} - {""}
        for j in sorted(glob.glob(os.path.join(SHOTS, "*.jsonl")), reverse=True):
            words = [json.loads(l) for l in open(j) if l.strip()]
            w = next((w for w in words if w["text"].strip() in titles and 0.15 < w["y"] < 0.9), None)
            if not w:
                continue
            W, H, side = 696, 1532, int(0.155 * 696)
            x0, y0 = int((w["x"] + w["w"] / 2) * W - side / 2), int(w["y"] * H - 8 - side)
            os.makedirs(os.path.dirname(out), exist_ok=True)
            if subprocess.run(["sips", "-c", str(side), str(side), "--cropOffset", str(max(0, y0)), str(max(0, x0)), j[:-6] + ".png", "--out", out],
                              capture_output=True).returncode == 0:
                break
    return "data:image/png;base64," + base64.b64encode(open(out, "rb").read()).decode() if os.path.exists(out) else ""

def evid_id(uid):
    return "ev-" + re.sub(r"\W", "_", uid)

def column_html(app, placed, in_db):
    """The evidence column as text at the screenshots' own positions: every OCR word sits where it was on screen (frames
    registered by stitch), a row shared by overlapping frames is drawn once (the topmost frame's reading), and the app's
    chrome (status bar, nav, filter bar, floating buttons) is left out; each word's colour and size come from the source
    pixels at load, not from per-app rules. The text itself is the OCR evidence, so a row that
    became a ledger line gets no mark; only anomalies are boxed: amber = parsed but not stored, red = an amount row nothing
    parsed. A transaction's first row carries the id the journal's "근거" jumps to. While the pointer is over the column, one
    whole original screenshot (the frame in which the pointer's height sits nearest mid-screen, never a crop) pulses in and
    out over the text at its registered place, like a blink comparator: the eye catches where pixels and reading differ."""
    base = min(p["top"] + p["clip"] for p in placed)
    height = max(p["top"] + p["bottom"] for p in placed) - base
    imgs = [f'<img id="im-{app}-{k}" src="{jpeg_b64(p["f"]["png"])}" hidden>' for k, p in enumerate(placed)]   # one copy each, for the peek
    rows_html, boxes, drawn, warned, red, taken = [], [], set(), set(), set(), []
    # alignment from the boxes: the x where most rows' last word ends is the list's right margin; a word ending there is
    # right-aligned and gets anchored by its right edge, so its digits end exactly where the app ends them
    ends = [round(ws[-1]["x"] + ws[-1]["w"], 2) for p in placed for i, ws in enumerate(p["f"]["words"]) if p["clip"] <= p["f"]["ys"][i][0] < p["bottom"]]
    right_margin = max(set(ends), key=ends.count) if ends else 1.0
    for k, p in reversed(list(enumerate(placed))):     # topmost frame first: its reading of a shared row wins
        f, top, clip, bottom = p["f"], p["top"] - base, p["clip"], p["bottom"]
        spans = {i: t for t in f["tx"] for i in range(t["rows"][0], t["rows"][1] + 1)}
        for i, ws in enumerate(f["words"]):
            y0, y1 = f["ys"][i]
            r = f["rows"][i]
            if not (clip <= y0 < bottom) or len(r.strip()) < 2 or BOTTOM.search(r) or any(abs(top + y0 - q) < 0.012 for q in taken):
                continue
            taken.append(top + y0)
            t = spans.get(i)
            rid = f' id="{evid_id(t["uid"])}"' if t and t["rows"][0] == i and t["uid"] not in drawn and not drawn.add(t["uid"]) else ""
            # positions are the screenshot's. Colour and size are not rules: at load, the page samples each word's ink colour from
            # the frame it was read from and fits the font size so the rendered width matches the OCR box (see SCRIPT).
            words = "".join(f'<span style="{f"right:{(1 - w["x"] - w["w"]) * 348:.0f}px" if abs(w["x"] + w["w"] - right_margin) < 0.012 else f"left:{w["x"] * 348:.0f}px"};'
                            f'top:{(w["y"] - y0) * FRAME_H:.0f}px" data-b="{w["x"]:.4f},{w["y"]:.4f},{w["w"]:.4f},{w["h"]:.4f}">{esc(w["text"])}</span>' for w in ws)
            rows_html.append(f'<div class="row"{rid} data-src="im-{app}-{k}" '
                             f'style="top:{(top + y0) * FRAME_H:.0f}px;height:{(y1 - y0) * FRAME_H:.0f}px" '
                             f'title="{f["when"]:%m/%d %H:%M} 촬영 · {os.path.basename(f["png"])}">{words}</div>')
        for t in f["tx"]:
            a, b = t["rows"]
            if f["ys"][a][0] < clip or f["ys"][b][1] > bottom or t["uid"] in in_db or t["uid"] in warned:
                continue
            warned.add(t["uid"])
            y0, y1 = f["ys"][a][0], f["ys"][b][1]
            boxes.append(f'<div class="box warn" style="top:{(top + y0) * FRAME_H:.1f}px;height:{(y1 - y0) * FRAME_H:.1f}px" title="파싱됐지만 원장에 없음: {esc(t["merchant"])} {t["amount"]:,}원"></div>')
        for i, r in enumerate(f["rows"]):
            m = am.KB_WON.match(r)
            pair = am.TX_AMT.match(r) and not am.TX_META.match(r) and i + 1 < len(f["rows"]) and am.TX_META.match(f["rows"][i + 1])
            if (pair or (m and m.group(1))) and not any(a <= i <= b for a, b in (t["rows"] for t in f["tx"])) and clip <= f["ys"][i][0] < bottom and r not in red:
                red.add(r)
                y0, y1 = f["ys"][i]
                boxes.append(f'<div class="box bad" style="top:{(top + y0) * FRAME_H:.1f}px;height:{(y1 - y0) * FRAME_H:.1f}px" title="파싱 안 됨: {esc(r)}"></div>')
    frames_js = json.dumps([[round(p["top"] - base, 4), round(p["clip"], 4), round(p["bottom"], 4)] for p in placed])   # for the hover: [top, clip, bottom] per frame
    col = "\n".join([f'<div class="col" data-app="{app}" data-frames=\'{frames_js}\' style="height:{height * FRAME_H:.0f}px">'] + imgs + boxes + rows_html
                     + ['<div class="peek"><img></div>', "</div>"])
    return col, len(drawn), len(warned) + len(red)

# ---------------------------------------------------------------- ledger: journal, balance sheet
def journal(rows):
    """Double-entry lines from transaction rows. Each: dict(ts, memo, dr, cr, amount, uid, note, rev). A line names both ends
    as concretely as the data allows and nothing else: whether it is a transfer, income or spend depends on where the
    entity boundary is drawn, and that is decided at read time by classify(). rev marks a refund/cancellation."""
    out = []
    for ts, kind, amount, merchant, tag, cum, source, uid in rows:
        app = source.split(":")[1]
        acct, m, tag = ACCOUNT[app][1], merchant or "", tag or ""
        own = bool(ME) and ME in m
        if kind == "deposit":
            if "체크카드" in tag:                        # a card refund shows as an unsigned deposit tagged 체크카드
                out.append(dict(ts=ts, memo=f"{tag} {m} 환불", dr=acct, cr=capital(m), amount=amount, rev=True, uid=uid, note=""))
            elif "ATM입금" in m:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr=acct, cr="현금(수중)", amount=amount, rev=False, uid=uid, note="현금의 출처는 장부 밖"))
            elif "이자" in tag or "이자" in m:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr=acct, cr="이자수입", amount=amount, rev=False, uid=uid, note=""))
            elif own:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr=acct, cr="내 다른 계좌(미확인)", amount=amount, rev=False, uid=uid, note="본인 명의 입금"))
            else:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr=acct, cr="수입(미분류)", amount=amount, rev=False, uid=uid, note=""))
        elif kind == "withdrawal":
            if "스마트출금" in tag or "ATM" in tag or own:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr="현금(수중)", cr=acct, amount=amount, rev=False, uid=uid, note="현금 인출: 자산 간 이동"))
                cap = next((c for p, c in CAPITAL if re.search(p, m)), None)
                if cap:                                # the memo says what the cash was for: a second, inferred line
                    out.append(dict(ts=ts, memo=f"↳ {m} (메모에서 추정)", dr=cap, cr="현금(수중)", amount=amount, rev=False, uid=uid, note="추정"))
            else:
                out.append(dict(ts=ts, memo=f"{tag} {m}", dr=capital(m), cr=acct, amount=amount, rev=False, uid=uid, note=""))
        elif kind == "approval":
            out.append(dict(ts=ts, memo=f"{tag} {m}", dr=capital(m), cr=acct, amount=amount, rev=False, uid=uid, note=""))
        elif kind == "cancel":
            out.append(dict(ts=ts, memo=f"{tag} {m} 취소", dr=acct, cr=capital(m), amount=amount, rev=True, uid=uid, note=""))
    return out

NEVER_INSIDE = {"이자수입", "수입(미분류)"} | {c for _, c in CAPITAL} | {"유지"}    # capitals and outside sources: no lens contains them

def classify(l, inside):
    """What a journal line is under a boundary: both ends inside = transfer (net worth unchanged); money leaving = conversion
    (spend, won -> a non-monetary capital); money arriving = income, or a reversal when it is a refund; neither end inside = ''."""
    d, c = l["dr"] in inside, l["cr"] in inside
    return "transfer" if d and c else "conversion" if c else ("reversal" if l["rev"] else "income") if d else ""

def chain_order(chain):
    """The chain in true order. Rows sharing a minute come out of the app newest-first, so their ids run backwards; within such
    a group take the permutation whose balances follow from the previous one (like chain_gaps), else leave the group as is."""
    signed = lambda r: r[2] if r[1] in ("deposit", "cancel") else -r[2]
    out, bal = [], None
    for _, g in itertools.groupby(chain, key=lambda r: r[0]):
        g = list(g)
        if bal is not None and len(g) > 1:
            g = next((list(p) for p in itertools.permutations(g) if all(p[i][3] == (bal if i == 0 else p[i - 1][3]) + signed(p[i]) for i in range(len(p)))), g)
        out += g; bal = g[-1][3]
    return out

def chain_gaps(chain):
    """(gaps, uncaptured net flow, rows): each balance must equal the previous one +/- the amount. Rows sharing a minute
    have no order in the data, so any order of them that closes the chain counts as closed."""
    signed = lambda r: r[2] if r[1] in ("deposit", "cancel") else -r[2]
    groups = [list(g) for _, g in itertools.groupby(chain, key=lambda r: r[0])]
    gaps, other, bal = 0, 0, None
    for g in groups:
        if bal is None:
            bal = g[-1][3]; continue
        ok = next((p for p in itertools.permutations(g) if all(p[i][3] == (bal if i == 0 else p[i - 1][3]) + signed(p[i]) for i in range(len(p)))), None)
        if ok is None:
            diff = g[-1][3] - (bal + sum(signed(r) for r in g))
            gaps += 1; other += diff
        bal = g[-1][3] if ok is None else ok[-1][3]
    return (gaps, other, len(chain))

def norm_label(acct):
    a = re.sub(r"^\d+\s+", "", acct)                                     # OCR noise '1 AI 관련 지출 통장'
    a = re.sub(r"\s*\(\*+\)|\s*…\d{4}", "", a)                            # masked / last-4 account numbers
    return " ".join(a.split())

def balance_sheet(c, ym, first_next):
    """{label: {app, start: (value, how), end: (value, how), gaps}} for the month. 'measured' = balance after a
    transaction in the chain; 'carried' = the earliest snapshot after the month (assumed unchanged); None = unknown."""
    accts = {}
    for app, acct, bal, ts in c.execute("SELECT app, account, balance, ts FROM snapshots ORDER BY ts"):
        lab = norm_label(acct)
        a = accts.setdefault(lab, {"app": app, "start": (None, ""), "end": (None, ""), "gaps": None})
        if ts < ym + "-01" and a["start"][0] is None:
            a["start"] = (bal, f"스냅샷 {ts[:10]}")
        if ts < first_next:
            a["end"] = (bal, f"스냅샷 {ts[:10]}")                            # a snapshot inside the month, latest wins
        elif a["end"][1].startswith("스냅샷") is False and (a["end"][0] is None or a["end"][1].startswith("이월")):
            a["end"] = a["end"] if a["end"][0] is not None else (bal, f"이월 ({ts[:10]} 스냅샷, 8월 중 변동 미상)")
    for app, (pat, name) in ACCOUNT.items():
        lab = next((l for l, a in accts.items() if a["app"] == app and re.search(pat, l)), None) or name
        a = accts.setdefault(lab, {"app": app, "start": (None, ""), "end": (None, ""), "gaps": None})
        chain = c.execute("SELECT ts, kind, amount, cumulative FROM transactions WHERE source=? AND cumulative IS NOT NULL ORDER BY ts, id",
                          (f"app:{app}",)).fetchall()
        before = [r for r in chain if r[0] < ym + "-01"]
        upto = [r for r in chain if r[0] < first_next]
        if before:
            a["start"] = (before[-1][3], f"거래 사슬 ({before[-1][0]} 거래 후 잔액)")
        if upto:
            a["end"] = (upto[-1][3], f"거래 사슬 ({upto[-1][0]} 거래 후 잔액)")
        month = [r for r in upto if r[0] >= ym + "-01"]
        a["gaps"] = chain_gaps(month)
    return accts

# ---------------------------------------------------------------- page
SCRIPT = """<script>
// typography from the source, not from rules: for every word, the ink colour is the mean of the darkest 15% of pixels in its
// OCR box on the frame it was read from, and the font size starts at the box height and is scaled so the rendered width
// equals the box width (width spans many glyphs, so it is far steadier than height). Weight is left alone.
window.addEventListener('load',function(){
  var canv=document.createElement('canvas'),ctx=canv.getContext('2d',{willReadFrequently:true}),cache={};
  function pixels(id){if(cache[id])return cache[id];var im=document.getElementById(id);canv.width=im.naturalWidth;canv.height=im.naturalHeight;ctx.drawImage(im,0,0);return cache[id]=ctx.getImageData(0,0,canv.width,canv.height);}
  document.querySelectorAll('.row').forEach(function(r){
    var d=pixels(r.dataset.src),W=d.width,H=d.height;
    r.querySelectorAll('span').forEach(function(sp){
      var b=sp.dataset.b.split(',').map(Number),x0=Math.round(b[0]*W),y0=Math.round(b[1]*H),x1=Math.round((b[0]+b[2])*W),y1=Math.round((b[1]+b[3])*H),px=[];
      for(var y=y0;y<y1;y++)for(var x=x0;x<x1;x++){var i=(y*W+x)*4;px.push(d.data[i]+d.data[i+1]+d.data[i+2]);}
      px.sort(function(a,b){return a-b});var n=Math.max(1,Math.floor(px.length*0.15)),c=[0,0,0],m=0;
      for(var y=y0;y<y1&&m<n;y++)for(var x=x0;x<x1&&m<n;x++){var i=(y*W+x)*4;if(d.data[i]+d.data[i+1]+d.data[i+2]<=px[n-1]){c[0]+=d.data[i];c[1]+=d.data[i+1];c[2]+=d.data[i+2];m++;}}
      sp.style.color='rgb('+Math.round(c[0]/m)+','+Math.round(c[1]/m)+','+Math.round(c[2]/m)+')';
      var h=b[3]*766,w=b[2]*348;sp.style.fontSize=h+'px';var mw=sp.getBoundingClientRect().width;if(mw>0)sp.style.fontSize=(h*w/mw).toFixed(1)+'px';
    });
  });
});
// blink comparator: while the pointer is anywhere over a column, one whole original screenshot (never a crop) pulses in and
// out over the text at its registered place — the frame in which the pointer's height sits nearest mid-screen. The target is
// the column, not the rows, so crossing the blank between rows changes nothing; the frame switches only where the best
// frame changes, and the pulse keeps its rhythm across switches.
document.querySelectorAll('.col').forEach(function(col){
  var fr=JSON.parse(col.dataset.frames),peek=col.querySelector('.peek'),img=peek.querySelector('img'),cur=-1;
  col.addEventListener('mousemove',function(ev){
    var y=(ev.clientY-col.getBoundingClientRect().top)/766,best=-1,bd=9;
    for(var i=0;i<fr.length;i++){var l=y-fr[i][0];if(l>=fr[i][1]&&l<fr[i][2]&&Math.abs(l-0.5)<bd){bd=Math.abs(l-0.5);best=i;}}
    if(best<0){peek.classList.remove('on');cur=-1;return;}
    if(best!==cur){cur=best;img.src=document.getElementById('im-'+col.dataset.app+'-'+best).src;peek.style.top=(fr[best][0]*766)+'px';}
    peek.classList.add('on');
  });
  col.addEventListener('mouseleave',function(){peek.classList.remove('on');cur=-1;});
});
</script>"""

CSS = """
body{font:14px/1.5 -apple-system,'Apple SD Gothic Neo',sans-serif;margin:0 auto;max-width:1240px;padding:24px;color:#222;background:#fafaf8}
h1{font-size:22px;margin:0 0 4px} h2{font-size:17px;margin:36px 0 10px;border-bottom:1px solid #ddd;padding-bottom:4px} h3{font-size:14px;margin:18px 0 6px}
.sub{color:#666;margin-bottom:18px}
table{border-collapse:collapse;width:100%;font-size:13px} th,td{padding:5px 8px;border-bottom:1px solid #e6e6e2;text-align:left;vertical-align:top} th{background:#f1f1ec;font-weight:600}
td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
tr.conversion td{background:#fff6dc} tr.transfer td{background:#eaf3fb} tr.inferred td{font-style:italic;color:#555} tr.income td{background:#eefae9}
.badge{display:inline-block;font-size:11px;padding:1px 6px;border-radius:9px;background:#e5e5e0;color:#444;margin-left:6px;white-space:nowrap}
.badge.m{background:#d9efd3} .badge.c{background:#fde3c8} .badge.u{background:#f0d6d6}
.cols{display:flex;gap:28px;align-items:flex-start;overflow-x:auto}
.evidence{flex:0 0 350px} .evidence h3{margin:0 0 6px}
.col{position:relative;width:348px;background:#fff;border:1px solid #ddd}
.row{position:absolute;left:0;width:348px;color:#222} .row span{position:absolute;white-space:nowrap;line-height:1;font-size:15px;font-family:-apple-system,'Apple SD Gothic Neo',sans-serif}
.row:hover{background:#f4f4ef}
.peek{position:absolute;left:0;width:348px;height:766px;opacity:0;z-index:5;pointer-events:none} .peek.on{animation:blink 1.6s ease-in-out infinite}
@keyframes blink{0%,40%{opacity:1} 50%,90%{opacity:0} 100%{opacity:1}}   /* the pulse: pixels, then the reading, then pixels again */
.peek img{display:block;width:348px;height:766px;border:1px solid #bbb;box-sizing:border-box;background:#fff}
.box{position:absolute;left:4px;width:338px;border:2px solid;border-radius:3px;box-sizing:border-box}
.box.warn{border-color:#e8a317;background:rgba(232,163,23,.12)} .box.bad{border-color:#d33;background:rgba(221,51,51,.14)}
.row.hit{outline:3px solid #ffd43b;outline-offset:2px}
.legend span{display:inline-block;margin-right:14px} .legend i{display:inline-block;width:12px;height:12px;border:2px solid;border-radius:2px;vertical-align:-2px;margin-right:4px}
.call{border-left:4px solid #e8a317;background:#fff6dc;padding:10px 14px;margin:12px 0} .call.blue{border-color:#4c8fd6;background:#eaf3fb} .call.grey{border-color:#999;background:#f1f1ec}
.note{color:#777;font-size:12px} .ev{color:#2b6cb0;font-size:12px;text-decoration:underline dotted}
.nav{color:#666;font-size:13px;margin-bottom:14px} .nav a{color:#2b6cb0;text-decoration:none} .nav b{color:#222}
.row:target{outline:3px solid #ffd43b;outline-offset:2px}
.toolbar{margin:10px 0} .toolbar button{font:13px -apple-system,'Apple SD Gothic Neo',sans-serif;padding:4px 10px;margin-right:6px;border:1px solid #bbb;border-radius:12px;background:#fff;cursor:pointer}
/* dark: the page chrome follows the system; the evidence column and the peeked screenshot stay paper, because the words'
   colours are sampled from the phone's (light) pixels and the column is a reproduction of that paper, not our UI */
@media (prefers-color-scheme: dark){
:root{color-scheme:dark}
body{color:#d8dcd9;background:#111413} h2{border-color:#2b3330} .sub,.nav,.note{color:#9aa5a0} .nav b{color:#d8dcd9} .nav a,.ev{color:#7fb3ea}
th,td{border-color:#242a28} th{background:#1b201e}
tr.conversion td{background:#2a2412} tr.transfer td{background:#0f1f2a} tr.inferred td{color:#9aa5a0} tr.income td{background:#0f2a24}
.badge{background:#2b3330;color:#d8dcd9} .badge.m{background:#1d3a32} .badge.c{background:#3a2a14} .badge.u{background:#3a2020}
.call{background:#2a2412} .call.blue{background:#0f1f2a} .call.grey{background:#1b201e;border-color:#555}
.card{background:#1b201e;border-color:#2b3330} .toolbar button{background:#151a18;color:#d8dcd9;border-color:#2b3330}
.col{border-color:#444} .row:hover{background:#f4f4ef}
#flow{background:#151a18!important;border-color:#2b3330!important}
}
.acct{display:flex;gap:8px;align-items:center;width:168px;height:58px;box-sizing:border-box;padding:6px 8px;background:#fff;border:1px solid #bbb;border-radius:8px;font-size:12px}
.acct.unk{border-style:dashed;color:#666} .acct img,.acct .ph{width:34px;height:34px;border-radius:8px;flex:none} .acct .ph{background:#eee;text-align:center;line-height:34px;color:#888;font-size:16px}
.acct .nm{font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:112px} .acct .bal{color:#777;font-size:11px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:112px}
.outside{width:110px;height:34px;box-sizing:border-box;padding:0 8px;line-height:32px;font-size:12px;color:#666;background:#f6f6f2;border:1px dashed #aaa;border-radius:17px;text-align:center}
.grp{width:100%;height:100%;background:rgba(255,230,120,.12);border:2px solid #c7a300;border-radius:10px;box-sizing:border-box} .gname{position:absolute;top:-1px;left:10px;font-size:13px;font-weight:700;color:#8a6d00;background:#fafaf8;padding:0 6px;transform:translateY(-55%)}
.react-flow__node-group{padding:0;border:none;background:none;width:auto;height:auto}
.cards{display:flex;gap:16px;flex-wrap:wrap} .card{flex:0 0 300px;border:1px solid #ddd;border-radius:8px;padding:10px 12px;background:#fff} .card.sel{border-color:#c7a300;box-shadow:0 0 0 2px rgba(199,163,0,.25)} .card table{margin-top:6px}
"""

ENTITY_JS = r"""<script>
(function(){
if(!window.ReactFlow||!window.React){return;}
var h=React.createElement, RF=ReactFlow, KEY='entity-'+D.ym, NW=168, NH=58, OW=110, OH=34;
function won(n){return (n<0?'−':'')+Math.abs(n).toLocaleString('ko-KR')+'원';}
// ---- layout: default boundary on the left holding the accounts of "내 것 전부" in a grid; the outside places in a column at right
function defaults(){
  var nodes=[], ins=D.accounts.filter(function(a){return D.default_inside.indexOf(a.id)>=0}), outs=D.accounts.filter(function(a){return D.default_inside.indexOf(a.id)<0});
  var cols=3, gw=cols*(NW+18)+40, gh=Math.ceil(ins.length/cols)*(NH+18)+56;
  nodes.push({id:'g:내 것 전부', type:'group', position:{x:0,y:0}, style:{width:gw,height:gh}, data:{name:'내 것 전부'}, zIndex:-1});
  ins.forEach(function(a,i){nodes.push({id:a.id,type:'account',position:{x:20+(i%cols)*(NW+18),y:44+Math.floor(i/cols)*(NH+18)},data:a});});
  outs.forEach(function(a,i){nodes.push({id:a.id,type:'account',position:{x:20+i*(NW+18),y:gh+40},data:a});});
  D.outside.forEach(function(o,i){nodes.push({id:o,type:'outside',position:{x:gw+90,y:10+i*(OH+16)},data:{label:o}});});
  return nodes;
}
function load(){try{var s=JSON.parse(localStorage.getItem(KEY));if(s&&s.nodes)return s.nodes;}catch(e){}return null;}
function save(nodes){try{localStorage.setItem(KEY,JSON.stringify({nodes:nodes.map(function(n){return {id:n.id,type:n.type,position:n.position,style:n.style,data:n.data,zIndex:n.zIndex}})}));}catch(e){}}
// ---- edges: money moves from the credit side to the debit side; one edge per pair, width by amount
var agg={};D.lines.forEach(function(l){var k=l.cr+'>'+l.dr;agg[k]=agg[k]||{s:l.cr,t:l.dr,a:0,n:0};agg[k].a+=l.amount;agg[k].n++;});
var edges=Object.keys(agg).map(function(k){var e=agg[k];return {id:k,source:e.s,target:e.t,label:won(e.a)+(e.n>1?' ×'+e.n:''),
  markerEnd:{type:'arrowclosed'},style:{strokeWidth:1+Math.log10(e.a/1000+1)*1.6,stroke:'#7a7a74'},labelStyle:{fontSize:11,fill:'#555'},labelBgStyle:{fill:'#fff'}};});
// ---- node renderers
function AccountNode(p){var a=p.data;return h('div',{className:'acct'+(a.end==null?' unk':'')},
  h(RF.Handle,{type:'target',position:'left',style:{opacity:0}}),h(RF.Handle,{type:'source',position:'right',style:{opacity:0}}),
  a.icon?h('img',{src:a.icon}):h('div',{className:'ph'},'₩'),
  h('div',null,h('div',{className:'nm'},a.id),h('div',{className:'bal'},a.end==null?'잔액 미측정':won(a.end)+' · '+a.app)));}
function OutsideNode(p){return h('div',{className:'outside'},h(RF.Handle,{type:'target',position:'left',style:{opacity:0}}),h(RF.Handle,{type:'source',position:'right',style:{opacity:0}}),p.data.label);}
function GroupNode(p){return h('div',{className:'grp',onDoubleClick:function(){var n=prompt('경계 이름',p.data.name);if(n){p.data.rename(p.id,n);}}},
  h(RF.NodeResizer,{minWidth:160,minHeight:90,lineStyle:{borderColor:'#c7a300'},handleStyle:{width:8,height:8,background:'#c7a300',border:'none'}}),
  h('div',{className:'gname'},p.data.name));}
var types={account:AccountNode,outside:OutsideNode,group:GroupNode};
// ---- membership and statements
function rect(n){return {x:n.position.x,y:n.position.y,w:(n.style&&n.style.width)||n.width||160,h:(n.style&&n.style.height)||n.height||90};}
function inside(nodes,g){var r=rect(g);return nodes.filter(function(n){if(n.type!=='account')return false;var cx=n.position.x+NW/2,cy=n.position.y+NH/2;return cx>=r.x&&cx<=r.x+r.w&&cy>=r.y&&cy<=r.y+r.h;}).map(function(n){return n.id});}
function stats(ids){var acc=D.accounts.filter(function(a){return ids.indexOf(a.id)>=0}),sum=0,unk=[];acc.forEach(function(a){if(a.end==null)unk.push(a.id);else sum+=a.end;});
  var inc=0,out=0,xf=0,rows=[];D.lines.forEach(function(l){var d=ids.indexOf(l.dr)>=0,c=ids.indexOf(l.cr)>=0,k,lab;
    if(d&&c){k='transfer';lab='이체 (안→안)';xf+=l.amount;}else if(c){k='conversion';lab='지출 (안→밖)';out+=l.amount;}
    else if(d&&l.rev){k='conversion';lab='지출 취소';out-=l.amount;}else if(d){k='income';lab='수입 (밖→안)';inc+=l.amount;}else{k='';lab='무관';}
    rows.push({l:l,k:k,lab:lab});});
  return {n:acc.length,sum:sum,unk:unk,inc:inc,out:out,xf:xf,rows:rows};}
function renderStats(nodes,selected){
  var gs=nodes.filter(function(n){return n.type==='group'});
  document.getElementById('stmt').innerHTML='<div class="cards">'+gs.map(function(g){var ids=inside(nodes,g),s=stats(ids);
    return '<div class="card'+(g.id===selected?' sel':'')+'"><b>'+g.data.name+'</b> <span class="note">'+ids.length+'계좌'+(s.unk.length?' · 미측정 '+s.unk.length:'')+'</span>'+
      '<table><tr><td>자산 (월말, 측정만)</td><td class="n">'+won(s.sum)+'</td></tr><tr class="income"><td>수입</td><td class="n">'+won(s.inc)+'</td></tr>'+
      '<tr class="conversion"><td>지출</td><td class="n">−'+won(s.out)+'</td></tr><tr class="transfer"><td>이체 (순효과 0)</td><td class="n">'+won(s.xf)+'</td></tr>'+
      '<tr><th>순자산 변동</th><th class="n">'+won(s.inc-s.out)+'</th></tr></table></div>';}).join('')+'</div>';
  var g=gs.find(function(x){return x.id===selected})||gs[0];
  if(!g){document.getElementById('lines').innerHTML='';return;}
  var s=stats(inside(nodes,g));
  document.getElementById('lines').innerHTML='<p class="note">경계: '+g.data.name+' (캔버스에서 경계를 클릭해 바꿉니다)</p><table><tr><th>일시</th><th>적요</th><th>차변</th><th>대변</th><th class="n">금액</th><th>이 경계에서는</th></tr>'+
    s.rows.map(function(r){return '<tr class="'+r.k+(r.l.inferred?' inferred':'')+'"><td>'+r.l.ts+'</td><td>'+r.l.memo+'</td><td>'+r.l.dr+'</td><td>'+r.l.cr+'</td><td class="n">'+won(r.l.amount)+'</td><td>'+r.lab+'</td></tr>';}).join('')+'</table>';
}
// ---- the app
function App(){
  var st=RF.useNodesState(load()||defaults()),nodes=st[0],setNodes=st[1],onNodesChange=st[2];
  var sel=React.useState(null),selected=sel[0],setSelected=sel[1];
  var rename=React.useCallback(function(id,name){setNodes(function(ns){return ns.map(function(n){return n.id===id?Object.assign({},n,{data:{name:name,rename:rename}}):n;});});},[setNodes]);
  var withFns=nodes.map(function(n){return n.type==='group'?Object.assign({},n,{data:Object.assign({},n.data,{rename:rename})}):n;});
  React.useEffect(function(){save(nodes);renderStats(nodes,selected);},[nodes,selected]);
  document.getElementById('addGroup').onclick=function(){var k=nodes.filter(function(n){return n.type==='group'}).length+1;
    setNodes(function(ns){return ns.concat([{id:'g:'+Date.now(),type:'group',position:{x:40*k,y:40*k},style:{width:300,height:180},data:{name:'경계 '+k},zIndex:-1}]);});};
  document.getElementById('reset').onclick=function(){localStorage.removeItem(KEY);setNodes(defaults());};
  return h(RF.default,{nodes:withFns,edges:edges,nodeTypes:types,onNodesChange:onNodesChange,fitView:true,minZoom:0.3,
    onNodeClick:function(ev,n){if(n.type==='group')setSelected(n.id);},proOptions:{hideAttribution:true}},
    h(RF.Background,{gap:18,color:'#eee'}),h(RF.Controls,null),h(RF.MiniMap,{pannable:true,zoomable:true}));
}
var root=ReactDOM.createRoot(document.getElementById('flow'));root.render(h(RF.ReactFlowProvider,null,h(App)));
})();
</script>"""

STAGES = [("evidence", "1. 증빙·전표", "스크린샷(원시증빙)과 그것을 옮겨 적은 OCR 행(전표)"),
          ("journal", "2. 분개장", "전표의 각 거래를 차변과 대변으로"),
          ("balance", "3. 대차대조표", "분개를 계정별로 모아 월초와 월말 한 시점씩"),
          ("entity", "4. 실체", "경계 안에 넣을 계좌를 고르면 그 경계의 재무제표")]

def page(ym, stage, title, body, script=""):
    """One stage, one file. The header names the stage's input and output and links the other stages."""
    nav = " → ".join(f'<b>{t}</b>' if k == stage else f'<a href="report-{ym}-{k}.html">{t}</a>' for k, t, _ in STAGES)
    out = f"""<!doctype html><meta charset="utf-8"><title>{ym} {title}</title><style>{CSS}</style>
<div class="nav">{nav}</div>
<h1>{ym} {title}</h1>
{body}
{script}"""
    path = os.path.join(am.HERE, "data", f"report-{ym}-{stage}.html")
    open(path, "w").write(out)
    return path

def render(ym):
    y, mo = map(int, ym.split("-"))
    first_next = (date(y, mo, 28) + timedelta(days=4)).replace(day=1).isoformat()
    last = (date.fromisoformat(first_next) - timedelta(days=1)).isoformat()
    c = am.db()
    rows = c.execute("""SELECT ts,kind,amount,merchant,card,cumulative,source,uid FROM transactions
                        WHERE source LIKE 'app:%' AND ts >= ? AND ts < ? ORDER BY ts, id""", (ym + "-01", first_next)).fetchall()
    in_db = {u for (u,) in c.execute("SELECT uid FROM transactions WHERE uid IS NOT NULL")}
    sheet = balance_sheet(c, ym, first_next)
    jl = {name: next((l for l, a in sheet.items() if a["app"] == app and re.search(pat, l)), name) for app, (pat, name) in ACCOUNT.items()}
    lines = journal(rows)
    for l in lines:                                    # one vocabulary for accounts across all stages: the balance sheet's labels
        l["dr"], l["cr"] = jl.get(l["dr"], l["dr"]), jl.get(l["cr"], l["cr"])
    lenses = [("내 것 전부", list(sheet) + ["현금(수중)", "내 다른 계좌(미확인)"]),
              ("관측된 계좌만", list(sheet)),
              ("현금 빼고", list(sheet) + ["내 다른 계좌(미확인)"]),
              ("AI 통장만", [jl["카카오뱅크 AI 관련 지출 통장"]])]
    for l in lines:
        l["kind"] = classify(l, set(lenses[0][1]))     # stages 2 and 3 read under the first lens; stage 4 lets you switch
    gaps = {lab: a["gaps"] for lab, a in sheet.items() if a["gaps"]}
    when = f"생성 {datetime.now():%Y-%m-%d %H:%M}"
    paths = []

    # ---- stage 1: evidence. In: screenshots + their OCR (data/shots/*.jsonl). Out: the transactions table (the slips).
    ev_html, ev_stats = [], []
    for app in LISTS:
        frames = load_frames(app)
        if not frames:
            continue
        placed = stitch(frames, app)
        col, n_ok, n_bad = column_html(app, placed, in_db)
        ev_html.append(f'<div class="evidence"><h3>{esc(am.title(app))} · {esc(ACCOUNT[app][1])}</h3>'
                       f'<div class="note">프레임 {len(frames)}장 중 {len(placed)}장 배치 · 전표가 된 거래 {n_ok} · 이상(주황·빨강 상자) {n_bad}</div>{col}</div>')
        ev_stats.append((app, len(frames), len(placed), n_ok, n_bad))
    chain = "".join(f'<tr><td>{esc(lab)}</td><td class="n">{"+" if o >= 0 else ""}{won(o)}</td><td>{n}건 사이 {g}곳에서 잔액이 안 맞음 → 이만큼의 흐름이 파서에 안 잡힘 (위의 빨간 상자)</td></tr>' if g
                    else f'<tr><td>{esc(lab)}</td><td class="n">0원</td><td>{n}건 전부 앞 잔액 ± 금액 = 뒤 잔액</td></tr>' for lab, (g, o, n) in gaps.items())
    body = f"""<div class="sub">입력: 폰 화면 스크린샷과 그 OCR 결과(원시증빙). 출력: 옮겨 적은 거래 행(전표) = transactions 테이블. {when} · 이 달 거래 {len(rows)}건</div>
<div class="legend"><span>글자가 보이면 OCR이 읽은 것이고, 전표가 된 거래는 따로 표시하지 않습니다. 이상만 상자로:</span><span><i style="border-color:#e8a317"></i>파싱됐지만 전표에 없음</span><span><i style="border-color:#d33"></i>금액 행인데 파싱 안 됨 (파서가 놓친 것)</span></div>
<p class="note">글자는 스크린샷에서 읽힌 그 위치에 놓이고, 색과 크기는 원본 픽셀에서 가져옵니다. 프레임 사이의 자리 맞추기는 두 프레임이 공유하는 행(시각+잔액)의 y 차이 중앙값이고, 같은 행은 한 번만 놓습니다.
열 위에 마우스를 두면 그 높이가 가운데에 오는 원본 한 장이 글자 위에서 맥동처럼 나타났다 사라지기를 반복합니다. 블링크 비교기처럼 눈으로 대조하세요.</p>
<div class="cols">{"".join(ev_html) or "<p>거래 목록 프레임이 없습니다.</p>"}</div>

<h2>전표 검산 — 거래 후 잔액 사슬</h2>
<table><tr><th>계좌</th><th class="n">안 맞는 금액</th><th>결과</th></tr>{chain}</table>
<div class="call grey">은행 목록의 각 행에 찍힌 "거래 후 잔액"은 그 거래 시점에 확정되어 영원히 바뀌지 않는 값이라 자연키가 되고, 앞 행 잔액 ± 금액 = 뒤 행 잔액이 어긋나면 그 사이에 파서가 놓친 행이 있다는 뜻입니다. 원본을 버리지 않았기 때문에 파서를 고치면 같은 프레임에서 다시 뽑을 수 있습니다.</div>

<h2>이 달 증빙의 한계</h2>
<ul class="note">
<li>카카오뱅크 AI 관련 지출 통장은 {rows and min(r[0] for r in rows if r[6] == 'app:KAKAO')[:10] or '—'}부터만 읽혔습니다 (수집 당시 3일 소급).</li>
<li>케이뱅크 2계좌, 토스뱅크, KB 마음편한통장·적금은 잔액만 있고 거래 목록을 아직 읽지 않았습니다.</li>
<li>증권(토스증권, 삼성증권, 카카오페이증권, 한국투자)과 부채(카드, 대출)는 미수집.</li>
</ul>"""
    paths.append(page(ym, "evidence", "증빙·전표", body, SCRIPT))

    # ---- stage 2: journal. In: the transactions table. Out: one debit/credit line per transaction.
    jr = []
    for l in lines:
        cls = l["kind"] + (" inferred" if l["note"] == "추정" else "")
        jr.append(f'<tr class="{cls}"><td>{esc(l["ts"][5:])}</td><td>{esc(l["memo"])}</td><td>{esc(l["dr"])}</td><td>{esc(l["cr"])}</td>'
                  f'<td class="n">{won(l["amount"])}</td><td>{ {"transfer": "이체", "income": "수입", "conversion": "전환", "reversal": "취소", "": "무관"}[l["kind"]] }'
                  f'{" · " + esc(l["note"]) if l["note"] else ""}</td><td><a class="ev" href="report-{ym}-evidence.html#{evid_id(l["uid"])}">증빙</a></td></tr>')
    body = f"""<div class="sub">입력: 전표(transactions 테이블). 출력: 거래마다 차변(들어온 곳)과 대변(나간 곳) 한 줄. {when} · 분개 {len(lines)}줄</div>
<table><tr><th>일시</th><th>적요</th><th>차변 (들어온 곳)</th><th>대변 (나간 곳)</th><th class="n">금액</th><th>유형</th><th></th></tr>{"".join(jr)}</table>
<p class="note">분개 자체는 양끝 계정만 적습니다. "유형" 열(이체·전환·수입·취소)은 렌즈 "내 것 전부"로 읽은 것이고, 4단계에서 렌즈를 바꾸면 같은 줄이 다른 유형이 됩니다. 노랑 = 전환(차변을 원으로 평가하지 않음). 파랑 = 이체(순자산 불변). 기울임 = 메모에서 추정한 줄. "증빙"은 1단계 파일의 그 행으로 갑니다.</p>

<h2>분개 규칙 — 복식부기가 여기서 독특하게 하는 것</h2>
<div class="call"><b>① 차변을 원으로 적지 않는 전환.</b> Cursor 43만원은 "비용"으로 사라지는 것이 아니라 대변 카카오뱅크 43만원, 차변 <b>역량</b>으로 적힙니다. 다만 차변에는 원 금액을 붙이지 않습니다. 붙이는 순간 순자산이 검증 불가능한 숫자로 부풀기 때문입니다. 무엇으로 바뀌었는지는 3단계의 전환표가 따로 들고 있습니다.</div>
<div class="call blue"><b>② 현금 인출과 ATM 입금은 지출도 수입도 아닙니다.</b> KB의 스마트출금 3건은 단식 가계부라면 30만원 지출입니다. 복식에서는 KB국민ONE통장 → 현금(수중)의 자산 이동이라 순자산이 그대로이고, 그중 메모가 "경조사비"인 1건만 현금 → 관계로 한 번 더 전환됩니다(추정 표시). 8/10 ATM 입금 40만원도 수입이 아니라 현금 → 통장입니다. 그 현금이 어디서 왔는지는 장부 밖이고, 그것이 이 장부의 경계입니다.</div>"""
    paths.append(page(ym, "journal", "분개장", body))

    # ---- stage 3: balance sheet. In: the journal lines + balance snapshots. Out: assets at the first and last day, and why they moved.
    income = sum(l["amount"] for l in lines if l["kind"] == "income")
    conv, inferred = {}, {}
    for l in lines:
        if l["kind"] == "conversion" and l["note"] != "추정":
            conv[l["dr"]] = conv.get(l["dr"], 0) + l["amount"]
        elif l["kind"] == "conversion":
            inferred[l["dr"]] = inferred.get(l["dr"], 0) + l["amount"]
        elif l["kind"] == "reversal":
            conv[l["cr"]] = conv.get(l["cr"], 0) - l["amount"]
    spend = sum(conv.values())
    def cell(v, how):
        if v is None:
            return '<td class="n">—<span class="badge u">미측정</span></td>'
        b = "m" if how.startswith("거래 사슬") or how.startswith("스냅샷") else "c"
        return f'<td class="n">{won(v)}<span class="badge {b}" title="{esc(how)}">{"측정" if b == "m" else "이월"}</span></td>'
    bs, tot = [], {"start": [0, 0], "end": [0, 0]}     # [measured, carried]
    for lab, a in sorted(sheet.items(), key=lambda x: (x[1]["app"], x[0])):
        bs.append(f'<tr><td>{esc(am.title(a["app"]))}</td><td>{esc(lab)}</td>{cell(*a["start"])}{cell(*a["end"])}<td class="note">'
                  + esc(a["end"][1] or a["start"][1]) + "</td></tr>")
        for k in ("start", "end"):
            v, how = a[k]
            if v is not None:
                tot[k][0 if (how.startswith("거래 사슬") or how.startswith("스냅샷")) else 1] += v
    measured_delta = [(lab, a["end"][0] - a["start"][0]) for lab, a in sheet.items()
                      if a["start"][0] is not None and a["end"][0] is not None and a["start"][1].startswith("거래 사슬") and a["end"][1].startswith("거래 사슬")]
    conv_rows = "".join(f'<tr class="conversion"><td>{esc(k)}</td><td class="n">{won(v)}</td><td>{esc(REMAINS.get(k, ""))}</td><td class="note">(비어 있음: 뽀미가 물어서 채울 칸)</td></tr>'
                        for k, v in sorted(conv.items(), key=lambda x: -x[1]))
    conv_rows += "".join(f'<tr class="conversion inferred"><td>{esc(k)} (추정)</td><td class="n">{won(v)}</td><td>{esc(REMAINS.get(k, ""))}</td><td class="note">현금 인출 메모에서 추정, 장부 밖</td></tr>'
                         for k, v in inferred.items())
    body = f"""<div class="sub">입력: 분개(2단계)와 잔액 스냅샷. 출력: {ym}-01과 {last}의 자산, 그리고 그 사이 순자산이 왜 움직였는지. 렌즈: 내 것 전부. {when}</div>
<table><tr><th>앱</th><th>자산 계정</th><th class="n">{ym}-01</th><th class="n">{last}</th><th>근거</th></tr>{"".join(bs)}
<tr><th></th><th>자산 합계 (측정만)</th><th class="n">{won(tot["start"][0])}</th><th class="n">{won(tot["end"][0])}</th><th></th></tr>
<tr><th></th><th>자산 합계 (이월 포함)</th><th class="n">{won(tot["start"][0] + tot["start"][1])}</th><th class="n">{won(tot["end"][0] + tot["end"][1])}</th><th class="note">이월 = 다음 달 초 스냅샷을 월말로 가정</th></tr>
<tr><th></th><th>부채</th><th class="n">—</th><th class="n">—</th><th class="note">신용카드·대출 없음으로 확인된 것이 아니라 아직 수집 안 됨</th></tr>
<tr><th></th><th>순자산 = 자산 − 부채</th><th class="n">{won(tot["start"][0] + tot["start"][1])}</th><th class="n">{won(tot["end"][0] + tot["end"][1])}</th><th class="note">부채 미수집 → 자산 합계와 같음</th></tr></table>
<p class="note">측정 = 거래 사슬이나 그날의 스냅샷으로 정해진 값. 이월 = 다른 날의 스냅샷을 그대로 옮긴 값. 미측정 = 아무 근거도 없음.</p>

<h2>순자산 변동의 설명 (원 단위)</h2>
<table><tr><th>항목</th><th class="n">금액</th><th>비고</th></tr>
<tr class="income"><td>수입</td><td class="n">{won(income)}</td><td>이자·급여 등 장부 밖에서 들어온 것</td></tr>
<tr class="conversion"><td>지출 (비화폐 자본으로 전환)</td><td class="n">−{won(spend)}</td><td>아래 전환표. 순자산은 이만큼 줄고, 그 대가는 원으로 적지 않음</td></tr>
<tr class="transfer"><td>자산 간 이동</td><td class="n">0원</td><td>현금 인출·ATM 입금·내 계좌 간 이체: 합계는 항상 0</td></tr>
{"".join(f'<tr><td>측정된 계좌 변동: {esc(lab)}</td><td class="n">{"+" if d >= 0 else ""}{won(d)}</td><td>사슬 양끝이 모두 측정된 계좌만</td></tr>' for lab, d in measured_delta)}
</table>

<h2>비화폐 자본 전환 — 대차대조표에 없는 차변</h2>
<table><tr><th>전환된 자본</th><th class="n">이 달에 들어간 원</th><th>남는 정도</th><th>결과물</th></tr>{conv_rows}</table>
<div class="call">차변에 원 금액이 없는 이유: 붙이는 순간 순자산이 검증 불가능한 숫자로 부풉니다. 그래서 대차대조표에는 순자산 감소로만 나타나고, 무엇으로 바뀌었는지는 이 표가 따로 듭니다. 결과물 칸이 비어 있는 것이 정상입니다. 그 칸은 숫자가 아니라 답("KB 파서를 만들었다")으로 채워집니다.</div>"""
    paths.append(page(ym, "balance", "대차대조표", body))

    # ---- stage 4: the entity, as a canvas. Accounts are nodes (with the app's icon, cropped from a captured frame), flows
    # are edges whose width follows the amount, and a boundary is a resizable rectangle: whatever sits inside it is the
    # entity, and its statements follow. Arrangement and boundaries persist in the browser (localStorage).
    accounts = [{"id": lab, "app": am.title(a["app"]), "icon": app_icon(a["app"]), "end": a["end"][0], "how": a["end"][1]}
                for lab, a in sorted(sheet.items(), key=lambda x: (x[1]["app"], x[0]))]
    accounts += [{"id": "현금(수중)", "app": "지갑", "icon": "", "end": None, "how": "잔액을 세지 않음"},
                 {"id": "내 다른 계좌(미확인)", "app": "아직 관측 안 함", "icon": "", "end": None, "how": "케이뱅크 등, 목록을 읽기 전"}]
    outside = sorted({l["dr"] for l in lines} | {l["cr"] for l in lines}) 
    outside = [x for x in outside if x in NEVER_INSIDE]
    data = {"ym": ym, "accounts": accounts, "outside": outside, "default_inside": lenses[0][1],
            "lines": [{"ts": l["ts"][5:], "memo": l["memo"], "dr": l["dr"], "cr": l["cr"], "amount": l["amount"], "inferred": l["note"] == "추정", "rev": l["rev"]} for l in lines]}
    body = f"""<div class="sub">입력: 분개(2단계)와 월말 잔액(3단계). 출력: 경계 사각형 안에 들어온 계좌들의 자산·수입·지출·이체. 노드를 끌어 배치하고, 경계를 옮기거나 늘리면 즉시 다시 계산됩니다. 배치는 이 브라우저에 저장됩니다. {when}</div>
<div class="call grey">회계실체: 먼저 "무엇의 장부인가"를 정하고 그 경계 안을 닫힌 계로 다룹니다. 안에서 안으로 가는 선은 이체(합계 0), 경계를 넘는 선만 수입과 지출. 서로 오가는 선이 굵은 계좌들을 한쪽에 모아 두고 경계로 감싸 보세요. 경계는 여러 개 둘 수 있고 겹쳐도 됩니다(AI 통장 ⊂ 나).</div>
<div class="toolbar"><button id="addGroup">경계 추가</button> <button id="reset">배치 초기화</button> <span class="note">경계 이름은 더블클릭으로 바꿉니다. 회색 점선 노드(자본·수입 출처)는 언제나 경계 밖입니다.</span></div>
<div id="flow" style="height:560px;border:1px solid #ddd;background:#fff"><p class="note" style="padding:20px">React Flow를 CDN에서 불러오는 중입니다. 인터넷이 없거나 뷰어가 외부 스크립트를 막으면 이 페이지는 브라우저에서 직접 열어야 합니다.</p></div>
<h2>경계별 재무제표</h2><div id="stmt"></div>
<h2>선택한 경계에서 분개가 무엇이 되는가</h2><div id="lines"></div>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/reactflow@11.11.4/dist/style.css">
<script src="https://cdnjs.cloudflare.com/ajax/libs/react/18.3.1/umd/react.production.min.js"></script>
<script src="https://cdnjs.cloudflare.com/ajax/libs/react-dom/18.3.1/umd/react-dom.production.min.js"></script>
<script src="https://cdn.jsdelivr.net/npm/reactflow@11.11.4/dist/umd/index.js"></script>
<script>var D={json.dumps(data, ensure_ascii=False)};</script>
{ENTITY_JS}"""
    paths.append(page(ym, "entity", "실체", body))

    for p in paths:
        print(p, f"{os.path.getsize(p) / 1e6:.2f}MB")
    print(ev_stats)
    return paths

# ---------------------------------------------------------------- timeline (the kiosk's side band)
def timeline_data(c):
    """Every observation of every account as a step function, plus the journal: enough to state the balance sheet at any
    instant (each account's last observation before it) and the flows of any range. Times are the stored KST strings."""
    accts, series = {}, {}
    for app, acct, bal, ts in c.execute("SELECT app, account, balance, ts FROM snapshots ORDER BY ts, id"):
        lab = norm_label(acct); accts.setdefault(lab, app); series.setdefault(lab, []).append([ts, bal, "스냅샷"])
    jl = {}
    for app, (pat, name) in ACCOUNT.items():
        lab = next((l for l, a in accts.items() if a == app and re.search(pat, l)), name)
        accts.setdefault(lab, app); jl[name] = lab
        chain = c.execute("SELECT ts, kind, amount, cumulative FROM transactions WHERE source=? AND cumulative IS NOT NULL ORDER BY ts, id", (f"app:{app}",)).fetchall()
        for ts, _, _, cum in chain_order(chain):
            series.setdefault(lab, []).append([ts, cum, "거래 사슬"])
    for v in series.values():
        v.sort(key=lambda p: p[0])
    rows = c.execute("SELECT ts,kind,amount,merchant,card,cumulative,source,uid FROM transactions WHERE source LIKE 'app:%' ORDER BY ts, id").fetchall()
    lines = journal(rows)
    return {"accounts": [{"id": lab, "app": am.title(app)} for lab, app in sorted(accts.items(), key=lambda x: (x[1], x[0]))],
            "series": series, "inside": list(accts) + ["현금(수중)", "내 다른 계좌(미확인)"],
            "lines": [{"ts": l["ts"], "memo": l["memo"], "dr": jl.get(l["dr"], l["dr"]), "cr": jl.get(l["cr"], l["cr"]), "amount": l["amount"], "rev": l["rev"]} for l in lines]}

TIMELINE_CSS = """
:root{color-scheme:dark}
body{margin:0;background:#000;color:#d8dcd9;font:13px/1.45 -apple-system,'Apple SD Gothic Neo',sans-serif;padding:14px 16px;user-select:none}
h1{font-size:14px;font-weight:600;margin:0 0 6px;color:#9aa5a0} h2{font-size:13px;font-weight:600;margin:14px 0 6px;color:#9aa5a0}
svg{display:block;width:100%} #chart{height:220px;cursor:pointer} #eq{height:190px}
.grid{stroke:#1e2422} .axis{fill:#6f7b76;font-size:11px} .zero{stroke:#3a4441}
.nw{fill:none;stroke:#8fd0c2;stroke-width:1.5} .pin{fill:rgba(199,163,0,.18);stroke:#c7a300;stroke-width:1}
.hover{stroke:#3a4441;stroke-width:1} .htext{fill:#9aa5a0;font-size:11px}
.obs{fill:#8fd0c2} .exp{fill:#5b8fd6} .res{fill:#c7a300} .dayhit{fill:transparent} .sel{fill:rgba(199,163,0,.12)}
.chips{display:flex;gap:6px;margin:12px 0 4px} .chips button{font:12px -apple-system,'Apple SD Gothic Neo',sans-serif;color:#d8dcd9;background:#151a18;border:1px solid #2b3330;border-radius:12px;padding:3px 10px;cursor:pointer}
.chips button.on{background:#c7a300;color:#000;border-color:#c7a300}
table{border-collapse:collapse;width:100%;font-size:12.5px} td,th{padding:3px 6px;border-bottom:1px solid #1e2422;text-align:left;vertical-align:top}
th{color:#6f7b76;font-weight:500} td.n,th.n{text-align:right;font-variant-numeric:tabular-nums;white-space:nowrap}
.m{color:#8fd0c2} .c{color:#c7a300} .u{color:#6f7b76} .big{font-size:18px;font-weight:600;color:#fff}
.note{color:#6f7b76;font-size:11.5px} .row{display:flex;gap:18px;flex-wrap:wrap;margin:6px 0} .row>div{flex:1;min-width:150px}
tr.inc td{background:#0f2a24} tr.out td{background:#2a2412} tr.xf td{background:#0f1f2a}
.legend span{display:inline-block;margin-right:12px;font-size:11.5px;color:#9aa5a0} .legend i{display:inline-block;width:10px;height:10px;margin-right:4px;vertical-align:-1px}
"""

TIMELINE_JS = r"""
var P=function(s){return new Date(s.replace(' ','T'));},DAY=86400000;
function dayStart(t){var d=new Date(t);d.setHours(0,0,0,0);return d;}
function addDays(d,n){return new Date(d.getTime()+n*DAY);}
function won(n){return (n<0?'−':'')+Math.abs(Math.round(n)).toLocaleString('ko-KR')+'원';}
function signed(n){return (n>0?'+':'')+won(n);}
function fmt(d){return (d.getMonth()+1)+'/'+d.getDate();}
function fmtFull(d){return d.getFullYear()+'-'+String(d.getMonth()+1).padStart(2,'0')+'-'+String(d.getDate()).padStart(2,'0');}
function valueAt(id,t){var a=D.series[id]||[],v=null;for(var i=0;i<a.length;i++){if(P(a[i][0])<=t)v=a[i];else break;}return v;}
function sheet(t){return D.accounts.map(function(a){return {id:a.id,app:a.app,v:valueAt(a.id,t)};});}
function total(t){var s=0,unk=0;sheet(t).forEach(function(r){if(r.v)s+=r.v[1];else unk++;});return {sum:s,unk:unk};}
var INS={};D.inside.forEach(function(x){INS[x]=1;});
function flows(t1,t2){var inc=0,out=0,xf=0,cap={},rows=[];
  D.lines.forEach(function(l){var t=P(l.ts);if(t<t1||t>=t2)return;var d=!!INS[l.dr],c=!!INS[l.cr],k='';
    if(d&&c){xf+=l.amount;k='xf';}else if(c){out+=l.amount;cap[l.dr]=(cap[l.dr]||0)+l.amount;k='out';}
    else if(d&&l.rev){out-=l.amount;cap[l.cr]=(cap[l.cr]||0)-l.amount;k='out';}else if(d){inc+=l.amount;k='inc';}
    rows.push({l:l,k:k});});
  return {inc:inc,out:out,xf:xf,cap:cap,rows:rows};}
// observed change of the assets between two instants: only accounts observed at both ends count
function observed(a,b){var s=0,n=0;D.accounts.forEach(function(acc){var v1=valueAt(acc.id,a),v2=valueAt(acc.id,b);if(v1&&v2){s+=v2[1]-v1[1];n++;}});return {sum:s,n:n};}
// ---- domain
var allTs=[];Object.keys(D.series).forEach(function(k){D.series[k].forEach(function(p){allTs.push(P(p[0]));});});
var today=dayStart(new Date()),t0=dayStart(allTs.length?new Date(Math.min.apply(null,allTs)):today),tEnd=addDays(today,1);
// ---- top: net worth step, day ticks, click a day
var svg=document.getElementById('chart'),W=svg.clientWidth||800,H=220,L=8,R=8,T=16,B=26;
svg.setAttribute('viewBox','0 0 '+W+' '+H);
var X=function(t){return L+(t-t0)/(tEnd-t0)*(W-L-R);};
var times=allTs.slice();for(var d=new Date(t0);d<=tEnd;d=addDays(d,1))times.push(new Date(d));times.sort(function(a,b){return a-b;});
var pts=times.map(function(t){return [t,total(t).sum];}),ys=pts.map(function(p){return p[1];}),ymin=Math.min.apply(null,ys),ymax=Math.max.apply(null,ys);
if(ymax===ymin){ymax+=1;ymin-=1;}var pad=(ymax-ymin)*0.15;ymin-=pad;ymax+=pad;
var Y=function(v){return T+(1-(v-ymin)/(ymax-ymin))*(H-T-B);};
var g='',nDays=Math.round((tEnd-t0)/DAY);
for(var d=new Date(t0);d<=tEnd;d=addDays(d,1)){var x=X(d);g+='<line class="grid" x1="'+x+'" y1="'+T+'" x2="'+x+'" y2="'+(H-B)+'"/>';
  if(d<tEnd&&(nDays<45||d.getDate()===1))g+='<text class="axis" x="'+(x+3)+'" y="'+(H-8)+'">'+fmt(d)+'</text>';}
var path='';pts.forEach(function(p,i){var x=X(p[0]),y=Y(p[1]);path+=(i?'H'+x+'V'+y:'M'+x+' '+y);});path+='H'+X(tEnd);
g+='<path class="nw" d="'+path+'"/>';
g+='<text class="axis" x="'+L+'" y="'+(T-4)+'">순자산 (관측된 계좌만)</text>';
g+='<rect id="pinr" class="pin" x="0" y="'+T+'" width="0" height="'+(H-T-B)+'" style="display:none"/>';
g+='<line id="hov" class="hover" x1="0" y1="'+T+'" x2="0" y2="'+(H-B)+'" style="display:none"/><text id="htext" class="htext" x="0" y="'+(T+10)+'"></text>';
for(var d=new Date(t0);d<tEnd;d=addDays(d,1))g+='<rect class="dayhit" data-t="'+d.getTime()+'" x="'+X(d)+'" y="0" width="'+(X(addDays(d,1))-X(d))+'" height="'+H+'"/>';
svg.innerHTML=g;
svg.addEventListener('pointermove',function(e){var t=new Date(t0.getTime()+(e.offsetX-L)/(W-L-R)*(tEnd-t0));if(t<t0||t>tEnd)return;var h=document.getElementById('hov'),ht=document.getElementById('htext');
  h.style.display='';h.setAttribute('x1',X(t));h.setAttribute('x2',X(t));ht.textContent=fmtFull(dayStart(t))+' '+won(total(t).sum);ht.setAttribute('x',Math.min(X(t)+6,W-170));});
svg.addEventListener('pointerleave',function(){document.getElementById('hov').style.display='none';document.getElementById('htext').textContent='';});
svg.addEventListener('click',function(e){var r=e.target.closest('.dayhit');if(r)showDay(new Date(+r.dataset.t));});
// ---- range chips
var RANGES={'오늘':function(){return [today,addDays(today,1)];},'7일':function(){return [addDays(today,-6),addDays(today,1)];},
  '이번 달':function(){return [new Date(today.getFullYear(),today.getMonth(),1),addDays(today,1)];},
  '지난 달':function(){return [new Date(today.getFullYear(),today.getMonth()-1,1),new Date(today.getFullYear(),today.getMonth(),1)];}};
var chips=document.getElementById('chips');Object.keys(RANGES).forEach(function(k){var b=document.createElement('button');b.textContent=k;b.onclick=function(){setRange(k);};chips.appendChild(b);});
var range=null,selDay=null;
function setRange(k){range=k;chips.querySelectorAll('button').forEach(function(b){b.classList.toggle('on',b.textContent===k);});drawEq();}
// ---- bottom: per day, observed change vs explained change (income − spend); the difference is what the ledger did not see
function drawEq(){var ab=RANGES[range](),a=ab[0],b=ab[1],days=[];
  for(var d=new Date(a);d<b;d=addDays(d,1)){var o=observed(d,addDays(d,1)),f=flows(d,addDays(d,1));days.push({d:d,obs:o.sum,exp:f.inc-f.out,inc:f.inc,out:f.out,n:o.n});}
  var e=document.getElementById('eq'),w=e.clientWidth||800,h=190,l=8,rr=8,t=16,bb=26;e.setAttribute('viewBox','0 0 '+w+' '+h);
  var vals=[];days.forEach(function(x){vals.push(x.obs,x.exp,x.obs-x.exp);});var m=Math.max.apply(null,vals.map(Math.abs).concat([1]));
  var y0=t+(h-t-bb)/2,ys=function(v){return -v/m*(h-t-bb)/2;},bw=(w-l-rr)/days.length,s='';
  s+='<line class="zero" x1="'+l+'" y1="'+y0+'" x2="'+(w-rr)+'" y2="'+y0+'"/>';
  days.forEach(function(x,i){var x0=l+i*bw,g3=Math.max(2,bw*0.22),gap=bw*0.06;
    if(selDay&&x.d.getTime()===selDay.getTime())s+='<rect class="sel" x="'+x0+'" y="'+t+'" width="'+bw+'" height="'+(h-t-bb)+'"/>';
    [['obs',x.obs],['exp',x.exp],['res',x.obs-x.exp]].forEach(function(p,j){var v=p[1],yy=ys(v);
      s+='<rect class="'+p[0]+'" x="'+(x0+gap+j*g3)+'" y="'+(v>=0?y0+yy:y0)+'" width="'+(g3-1)+'" height="'+Math.abs(yy)+'"/>';});
    if(days.length<=31)s+='<text class="axis" x="'+(x0+bw/2)+'" y="'+(h-8)+'" text-anchor="middle">'+fmt(x.d)+'</text>';
    s+='<rect class="dayhit" data-t="'+x.d.getTime()+'" x="'+x0+'" y="0" width="'+bw+'" height="'+h+'"/>';});
  e.innerHTML=s;
  var O=0,E=0,I=0,U=0;days.forEach(function(x){O+=x.obs;E+=x.exp;I+=x.inc;U+=x.out;});
  document.getElementById('eqsum').innerHTML='<div class="row"><div><div class="note">관측된 자산 증감</div><div class="big">'+signed(O)+'</div></div>'+
    '<div><div class="note">설명된 증감 = 수입 − 지출</div><div class="big">'+signed(E)+'</div><div class="note">'+won(I)+' − '+won(U)+'</div></div>'+
    '<div><div class="note">미관측 = 관측 − 설명</div><div class="big '+(Math.abs(O-E)>0?'c':'')+'">'+signed(O-E)+'</div><div class="note">'+(Math.abs(O-E)>0?'경계 밖에서 드나든 돈. 0이면 장부가 닫힘':'장부가 닫힘')+'</div></div></div>';}
document.getElementById('eq').addEventListener('click',function(e){var r=e.target.closest('.dayhit');if(r)showDay(new Date(+r.dataset.t));});
// ---- a day: its start and end balance sheets, its flows
function showDay(d){selDay=d;var a=d,b=addDays(d,1),p=document.getElementById('pinr');p.style.display='';p.setAttribute('x',X(a));p.setAttribute('width',X(b)-X(a));
  var s1=sheet(a),s2=sheet(b),f=flows(a,b),o=observed(a,b),ta=total(a),tb=total(b);
  var h='<h2>'+fmtFull(d)+' · 00:00 → 24:00 (한국시간)</h2><div class="row"><div><div class="note">시작 순자산</div><div class="big">'+won(ta.sum)+'</div></div><div><div class="note">끝 순자산</div><div class="big">'+won(tb.sum)+'</div></div>'+
    '<div><div class="note">관측 증감</div><div class="big">'+signed(o.sum)+'</div></div><div><div class="note">수입 − 지출</div><div class="big">'+signed(f.inc-f.out)+'</div></div><div><div class="note">미관측</div><div class="big '+(o.sum-(f.inc-f.out)?'c':'')+'">'+signed(o.sum-(f.inc-f.out))+'</div></div></div>';
  h+='<table><tr><th>계좌</th><th class="n">00:00</th><th class="n">24:00</th><th class="n">증감</th><th>근거 (끝 시점)</th></tr>'+D.accounts.map(function(acc,i){var v1=s1[i].v,v2=s2[i].v;
    return '<tr><td>'+acc.id+' <span class="note">'+acc.app+'</span></td><td class="n">'+(v1?won(v1[1]):'<span class="u">—</span>')+'</td><td class="n">'+(v2?won(v2[1]):'<span class="u">—</span>')+'</td><td class="n">'+(v1&&v2?signed(v2[1]-v1[1]):'<span class="u">—</span>')+'</td><td class="'+(v2?(v2[2]==='스냅샷'?'c':'m'):'u')+'">'+(v2?v2[2]+' · '+v2[0]:'관측 없음')+'</td></tr>';}).join('')+'</table>';
  var caps=Object.keys(f.cap).sort(function(x,y){return f.cap[y]-f.cap[x];});
  if(f.rows.length)h+='<h2>거래 '+f.rows.length+'건'+(caps.length?' · 어디로: '+caps.map(function(k){return k+' '+won(f.cap[k]);}).join(', '):'')+'</h2><table>'+f.rows.map(function(x){return '<tr class="'+x.k+'"><td>'+x.l.ts.slice(11)+'</td><td>'+x.l.memo+'</td><td>'+x.l.cr+' → '+x.l.dr+'</td><td class="n">'+won(x.l.amount)+'</td><td class="note">'+({inc:'수입',out:'지출',xf:'이체',"":'무관'})[x.k]+'</td></tr>';}).join('')+'</table>';
  document.getElementById('panel').innerHTML=h;if(range)drawEq();}
setRange('7일');showDay(today);
"""

def timeline(path=None):
    """data/timeline.html: the net-worth step line with day ticks (KST midnights); click a day for its start/end balance sheets
    and flows; range chips; and per day the accounting equation as a check — observed asset change vs income − spend, the
    difference being what the ledger did not see. Self-contained, dark (it lives in the kiosk's black band)."""
    c = am.db()
    data = timeline_data(c)
    out = f"""<!doctype html><meta charset="utf-8"><title>timeline</title><style>{TIMELINE_CSS}</style>
<h1>순자산 · 자정마다 눈금 · 하루를 클릭하면 그날의 시작·끝 재무상태표</h1>
<svg id="chart"></svg>
<div id="chips" class="chips"></div>
<div class="legend"><span><i class="obs"></i>관측된 자산 증감</span><span><i class="exp"></i>설명된 증감 (수입 − 지출)</span><span><i class="res"></i>미관측 (둘의 차이)</span></div>
<svg id="eq"></svg>
<div id="eqsum"></div>
<div id="panel"></div>
<p class="note">생성 {datetime.now():%Y-%m-%d %H:%M} · 계좌 {len(data["accounts"])} · 관측 {sum(len(v) for v in data["series"].values())} · 분개 {len(data["lines"])}줄</p>
<script>var D={json.dumps(data, ensure_ascii=False)};</script>
<script>{TIMELINE_JS}</script>"""
    path = path or os.path.join(am.HERE, "data", "timeline.html")
    open(path, "w").write(out)
    print(path, f"{os.path.getsize(path) / 1e3:.0f}KB")
    return path

if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "timeline":
        timeline()
    else:
        render(sys.argv[1] if len(sys.argv) > 1 else date.today().strftime("%Y-%m"))
