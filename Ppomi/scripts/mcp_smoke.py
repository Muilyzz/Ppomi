#!/usr/bin/env python3
"""Ppomi --mcp 스모크 테스트 (표준 라이브러리만).

사용: python3 scripts/mcp_smoke.py [Ppomi 실행 파일 경로]
      기본 경로: .build/debug/Ppomi   실패가 하나라도 있으면 exit 1.
"""
import json
import queue
from pathlib import Path
import subprocess
import sys
import threading

BIN = sys.argv[1] if len(sys.argv) > 1 else str(Path(__file__).resolve().parents[1] / ".build/debug/Ppomi")
REQUIRED = {"phone_screen", "confirm_payment", "balances", "transactions", "sql", "read_playbook", "note_footprint", "run_combo"}

proc = subprocess.Popen([BIN, "--mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE, text=True, bufsize=1)
lines = queue.Queue()
err = []
threading.Thread(target=lambda: ([lines.put(l) for l in proc.stdout], lines.put(None)), daemon=True).start()
threading.Thread(target=lambda: err.extend(proc.stderr), daemon=True).start()

_id = 0


def send(obj):
    proc.stdin.write(json.dumps(obj, ensure_ascii=False) + "\n")
    proc.stdin.flush()


def request(method, params=None):
    global _id
    _id += 1
    send({"jsonrpc": "2.0", "id": _id, "method": method, "params": params or {}})
    return _id


def recv(timeout):
    """다음 JSON 한 줄. 빈 줄·비JSON 줄은 건너뛴다."""
    while True:
        try:
            line = lines.get(timeout=timeout)
        except queue.Empty:
            raise TimeoutError(f"{timeout}초 내 응답 없음")
        if line is None:
            raise EOFError("서버 stdout 닫힘")
        line = line.strip()
        if not line:
            continue
        try:
            return json.loads(line)
        except ValueError:
            print("  (비JSON 줄 무시)", line[:80])


def wait_result(rid, timeout=15):
    while True:
        msg = recv(timeout)
        if msg.get("id") == rid and "method" not in msg:
            if "error" in msg:
                raise RuntimeError(f"error {msg['error']}")
            return msg["result"]
        print("  (다른 메시지)", json.dumps(msg, ensure_ascii=False)[:100])


def wait_server_request(method, timeout=20):
    while True:
        msg = recv(timeout)
        if msg.get("method") == method and "id" in msg:
            return msg
        print("  (다른 메시지)", json.dumps(msg, ensure_ascii=False)[:100])


def call(name, args=None):
    return wait_result(request("tools/call", {"name": name, "arguments": args or {}}))


def text(result):
    return "".join(c.get("text", "") for c in result.get("content", []) if c.get("type") == "text")


def confirm(answer):
    """confirm_payment 호출 → elicitation/create 대기 → answer 로 응답 → 도구 결과 텍스트."""
    rid = request("tools/call", {"name": "confirm_payment",
                                 "arguments": {"summary": "스모크 테스트", "amount": 1000, "method": "테스트"}})
    el = wait_server_request("elicitation/create", 20)
    p = el.get("params", {})
    print("  message:", p.get("message", "")[:120])
    print("  options:", p.get("requestedSchema", {}).get("properties", {}).get("choice", {}).get("enum"))
    send({"jsonrpc": "2.0", "id": el["id"], "result": answer})
    return text(wait_result(rid))


fails = 0


def step(label, fn):
    global fails
    try:
        out = fn()
        print(f"PASS {label}" + (f" — {out}" if out else ""))
    except Exception as e:
        fails += 1
        print(f"FAIL {label} — {type(e).__name__}: {e}")


def s_init():
    r = wait_result(request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {"elicitation": {}},
                                           "clientInfo": {"name": "mcp_smoke", "version": "0"}}))
    assert r.get("protocolVersion") == "2025-06-18", r.get("protocolVersion")
    return f"{r.get('protocolVersion')} {r.get('serverInfo')} | {r.get('instructions', '')[:80]!r}"


def s_list():
    names = [t["name"] for t in wait_result(request("tools/list"))["tools"]]
    missing = REQUIRED - set(names)
    assert not missing, f"missing {sorted(missing)}"
    return names


def s_transactions():
    d = json.loads(text(call("transactions", {"days": 7})))
    rows = d if isinstance(d, list) else next((v for v in d.values() if isinstance(v, list)), d)
    return f"{len(rows)} rows"


def s_delete():
    r = call("sql", {"query": "delete from transactions"})
    assert r.get("isError") is True, f"isError={r.get('isError')} {text(r)[:80]}"
    return text(r)[:80]


def s_confirm_cancel():
    t = confirm({"action": "accept", "content": {"choice": "취소"}})
    assert "취소" in t, t[:120]
    return t[:80]


def s_confirm_decline():
    t = confirm({"action": "decline"})
    assert "취소" in t or "답이 없었다" in t, t[:120]
    return t[:80]


step("1 initialize", s_init)
step("2 notifications/initialized", lambda: send({"jsonrpc": "2.0", "method": "notifications/initialized"}))
step("3 tools/list", s_list)
step("4 balances", lambda: text(call("balances"))[:120])
step("5 transactions days=7", s_transactions)
step("6 sql count", lambda: text(call("sql", {"query": "select count(*) from transactions"}))[:120])
step("7 sql delete → isError", s_delete)
step("8 read_playbook 여기어때", lambda: text(call("read_playbook", {"app": "여기어때"}))[:100])
step("9 confirm_payment accept 취소", s_confirm_cancel)
step("10 confirm_payment decline", s_confirm_decline)

proc.stdin.close()
try:
    proc.wait(timeout=5)
except subprocess.TimeoutExpired:
    proc.kill()
    proc.wait()
print(f"\n--- server stderr ({len(err)} lines) ---")
sys.stdout.write("".join(err))
print(f"\n{'ALL PASS' if not fails else f'{fails} FAILED'} (exit {proc.returncode})")
sys.exit(1 if fails else 0)
