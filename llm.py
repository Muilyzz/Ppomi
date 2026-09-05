"""llm — one chat completion for the personal tools. OpenAI when OPENAI_API_KEY is set (stdlib HTTP, no dependency),
otherwise Claude through the SDK installed in ./.venv. Returns (text, usage_line)."""
import glob, json, os, sys, urllib.error, urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
if os.path.exists(os.path.join(HERE, ".env")):          # self-sufficient: works when imported alone
    for _line in open(os.path.join(HERE, ".env")):
        _k, _, _v = _line.strip().partition("=")
        _k = _k.strip().removeprefix("export ").strip()
        if _k and not _k.startswith("#") and _k not in os.environ:
            os.environ[_k] = _v.split(" #")[0].strip().strip("\"'")

def _openai(body):
    key = os.environ.get("OPENAI_API_KEY", "")
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions", json.dumps(body).encode(),
                                 {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=180) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"OpenAI {e.code}: {e.read().decode()[:300]}")

def _openai_stream(body, on_delta):
    """Stream one chat completion (SSE). Rebuilds the same `message` dict a non-streaming call returns,
    calling on_delta(text_so_far) as content arrives. Tool-call arguments are concatenated by index."""
    key = os.environ.get("OPENAI_API_KEY", "")
    req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
                                 json.dumps({**body, "stream": True, "stream_options": {"include_usage": True}}).encode(),
                                 {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=180)
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"OpenAI {e.code}: {e.read().decode()[:300]}")
    return parse_sse(iter(r), on_delta)

def parse_sse(lines, on_delta=None):
    """Turn OpenAI SSE lines into {"choices":[{"message":...}], "usage":...}. Separated for testing."""
    text, calls, usage = "", {}, {}
    for raw in lines:
        line = raw.decode() if isinstance(raw, bytes) else raw
        line = line.strip()
        if not line.startswith("data:") or line == "data: [DONE]":
            continue
        d = json.loads(line[5:])
        if d.get("usage"):
            usage = d["usage"]
        for ch in d.get("choices", []):
            delta = ch.get("delta", {})
            if delta.get("content"):
                text += delta["content"]
                if on_delta:
                    on_delta(text)
            for tc in delta.get("tool_calls", []) or []:
                slot = calls.setdefault(tc.get("index", 0), {"id": "", "type": "function", "function": {"name": "", "arguments": ""}})
                slot["id"] = tc.get("id") or slot["id"]
                fn = tc.get("function", {})
                slot["function"]["name"] += fn.get("name", "") or ""
                slot["function"]["arguments"] += fn.get("arguments", "") or ""
    msg = {"role": "assistant", "content": text or None}
    if calls:
        msg["tool_calls"] = [calls[i] for i in sorted(calls)]
    return {"choices": [{"message": msg}], "usage": usage}

def chat(system, messages, tools=None, execute=None, model=None, max_rounds=6, on_delta=None):
    """Conversation turn with optional tool calling (OpenAI). `messages` = [{role, content}], newest last.
    `execute(name, args) -> str` runs a tool. `on_delta(text_so_far)` streams the answer as it is generated.
    Returns (reply_text, usage_line, [tool names called])."""
    if not os.environ.get("OPENAI_API_KEY", "").startswith("sk-"):
        text, usage = complete(system, "\n".join(f"{m['role']}: {m['content']}" for m in messages), model=model)
        return text, usage, []
    model = model or os.environ.get("OPENAI_MODEL", "gpt-5-mini")
    msgs = [{"role": "system", "content": system}] + list(messages)
    called, tokens, done = [], [0, 0], set()
    usage = lambda: f"{model} 입력 {tokens[0]} / 출력 {tokens[1]} 토큰"
    # Chat latency: gpt-5.x reasons before the first token. 'none' is ~30% faster and is also the only value the
    # chat-completions endpoint accepts alongside function tools. The weekly review (complete()) keeps full reasoning.
    effort = os.environ.get("OPENAI_EFFORT", "none")
    def ask(with_tools):
        body = {"model": model, "messages": msgs}
        if model.startswith("gpt-5") and effort:
            body["reasoning_effort"] = effort
        if tools and with_tools:
            body["tools"], body["tool_choice"] = tools, "auto"
        d = _openai_stream(body, on_delta) if on_delta else _openai(body)
        u = d.get("usage", {}); tokens[0] += u.get("prompt_tokens", 0); tokens[1] += u.get("completion_tokens", 0)
        return d["choices"][0]["message"]
    for _ in range(max_rounds):
        msg = ask(with_tools=True)
        if not (msg.get("tool_calls") and execute):
            return (msg.get("content") or "").strip(), usage(), called
        msgs.append(msg)
        for tc in msg["tool_calls"]:
            name = tc["function"]["name"]
            try:
                args = json.loads(tc["function"].get("arguments") or "{}")
            except json.JSONDecodeError:
                args = {}
            key = (name, json.dumps(args, sort_keys=True, ensure_ascii=False))
            if key in done:                           # same call again: answer from what you already have
                result = f"{name} 은(는) 이미 이번 턴에 호출했다. 그 결과로 답을 쓰라."
            else:
                done.add(key); called.append(name)
                try:
                    result = execute(name, args)
                except Exception as e:                # a failing tool must not kill the conversation
                    result = f"오류: {e}"
            msgs.append({"role": "tool", "tool_call_id": tc["id"], "content": str(result)[:4000]})
    # rounds exhausted: ask once more with no tools so the turn always ends in words, never in a canned failure
    msgs.append({"role": "system", "content": "도구는 그만 쓰고, 지금까지의 도구 결과만으로 사용자에게 바로 답하라."})
    final = (ask(with_tools=False).get("content") or "").strip()
    return final or "지금은 답을 못 만들었어요. 다시 물어봐 주세요.", usage(), called

def complete(system, user, model=None, max_tokens=2000):
    key = os.environ.get("OPENAI_API_KEY", "")
    if key.startswith("sk-"):
        model = model or os.environ.get("OPENAI_MODEL", "gpt-5-mini")
        body = json.dumps({"model": model, "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}]}).encode()
        req = urllib.request.Request("https://api.openai.com/v1/chat/completions", body,
                                     {"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=180) as r:
                d = json.load(r)
        except urllib.error.HTTPError as e:
            raise RuntimeError(f"OpenAI {e.code}: {e.read().decode()[:300]}")
        u = d.get("usage", {})
        return d["choices"][0]["message"]["content"].strip(), f"{model} 입력 {u.get('prompt_tokens')} / 출력 {u.get('completion_tokens')} 토큰"
    sys.path += glob.glob(os.path.join(HERE, ".venv", "lib", "python3*", "site-packages"))
    try:
        import anthropic
    except ImportError:
        raise RuntimeError("API 키가 없습니다: .env에 OPENAI_API_KEY 또는 ANTHROPIC_API_KEY (Claude는 .venv에 anthropic 설치)")
    try:
        client = anthropic.Anthropic()
        r = client.messages.create(model=model or "claude-opus-5", max_tokens=max_tokens,
                                   system=[{"type": "text", "text": system, "cache_control": {"type": "ephemeral"}}],
                                   messages=[{"role": "user", "content": user}])
    except anthropic.AuthenticationError:
        raise RuntimeError("ANTHROPIC_API_KEY가 없거나 틀렸습니다")
    except anthropic.APIStatusError as e:
        raise RuntimeError(f"Claude API {e.status_code}: {e.message}")
    except TypeError:                                 # no credentials at all
        raise RuntimeError("API 키가 없습니다: .env에 OPENAI_API_KEY 또는 ANTHROPIC_API_KEY")
    return ("".join(b.text for b in r.content if b.type == "text").strip(),
            f"{r.model} 입력 {r.usage.input_tokens} / 캐시 {r.usage.cache_read_input_tokens or 0} / 출력 {r.usage.output_tokens} 토큰")
