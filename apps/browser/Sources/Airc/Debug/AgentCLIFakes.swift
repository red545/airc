// Copyright 2026 The Airc Authors; SPDX-License-Identifier: Apache-2.0
#if AIRC_TESTING // test builds only
// The fake `claude` and `codex` executables for `--script agentcli` (AgentCLICheck.swift): Python 3 scripts that speak
// Claude Code's headless stream-json protocol and Codex's app-server JSON-RPC, drive the MCP server Airc configures
// (the airc-mcp helper), and follow the script in fake-state.json next to them. No network, model or credentials.
enum AgentCLIFakes {
    static let claude = #"""
#!/usr/bin/env python3
# Fake `claude` for Airc's agentcli checks: speaks Claude Code's headless stream-json protocol (claude -p
# --input-format stream-json --output-format stream-json) and drives the MCP server from --mcp-config (Airc's airc-mcp
# helper), following the script in fake-state.json next to it. No network, no model, no credentials.
import json, os, queue, subprocess, sys, threading, time, uuid

D = os.path.dirname(os.path.abspath(__file__))

def state():
    try:
        with open(os.path.join(D, "fake-state.json")) as f:
            return json.load(f)
    except Exception:
        return {}

def log(o):
    o["t"] = time.time()
    o["case"] = state().get("case", "?")
    o["cli"] = "claude"
    with open(os.path.join(D, "fake-log.jsonl"), "a") as f:
        f.write(json.dumps(o) + "\n")

args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("2.9.0 (Claude Code)")
    sys.exit(0)
if args[:2] == ["auth", "status"]:
    li = state().get("loggedIn", True)
    o = {"loggedIn": li, "authMethod": "claude.ai" if li else "none", "apiProvider": "firstParty"}
    if li:
        o["subscriptionType"] = "max"
    print(json.dumps(o, indent=2))
    sys.exit(0 if li else 1)
if "-p" not in args:
    sys.stderr.write("fake claude: only -p is scripted\n")
    sys.exit(2)

def flag(n):
    return args[args.index(n) + 1] if n in args else None

log({"event": "start", "argv": args, "pid": os.getpid(), "pgid": os.getpgid(0), "cwd": os.getcwd(),
     "apiKeyEnv": any(k in os.environ for k in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN")),
     "mcpTimeout": os.environ.get("MCP_TOOL_TIMEOUT")})

out_lock = threading.Lock()
def emit(o):
    with out_lock:
        sys.stdout.write(json.dumps(o) + "\n")
        sys.stdout.flush()

class MCP:
    """A minimal MCP stdio client (2025-06-18 handshake)."""
    def __init__(self, cfg):
        env = dict(os.environ)
        env.update(cfg.get("env") or {})
        self.p = subprocess.Popen([cfg["command"]] + list(cfg.get("args") or []), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=env)
        self.next = 0
        self.ok = False
        self.tools = []
        r = self.req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "fake-claude", "version": "2.9.0"}})
        if r and "result" in r:
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tl = self.req("tools/list", {})
            self.tools = [t["name"] for t in ((tl or {}).get("result") or {}).get("tools", [])]
            self.ok = True
        log({"event": "mcp", "ok": self.ok, "helperPid": self.p.pid, "tools": self.tools})

    def send(self, o):
        try:
            self.p.stdin.write((json.dumps(o) + "\n").encode())
            self.p.stdin.flush()
        except Exception:
            pass

    def req(self, method, params):
        self.next += 1
        i = self.next
        self.send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        while True:
            line = self.p.stdout.readline()
            if not line:
                return None
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("id") == i:
                return o

    def call(self, name, arguments):
        r = self.req("tools/call", {"name": name, "arguments": arguments})
        if r is None:
            return ("MCP server closed", True)
        if "error" in r:
            return (r["error"].get("message", "error"), True)
        res = r.get("result") or {}
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        return (text, bool(res.get("isError")))

cfg_path = flag("--mcp-config")
servers = {}
if cfg_path:
    with open(cfg_path) as f:
        servers = json.load(f).get("mcpServers", {})
log({"event": "config", "servers": sorted(servers.keys())})
mcp = MCP(servers["airc"]) if "airc" in servers else None
session = flag("--resume") or str(uuid.uuid4())

inbox = queue.Queue()
interrupted = threading.Event()

def reader():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            o = json.loads(line)
        except Exception:
            continue
        if o.get("type") == "control_request" and (o.get("request") or {}).get("subtype") == "interrupt":
            if state().get("ignoreInterrupt"):
                log({"event": "interrupt-ignored"})
                continue
            log({"event": "interrupt"})
            emit({"type": "control_response", "response": {"subtype": "success", "request_id": o.get("request_id")}})
            interrupted.set()
            continue
        inbox.put(o)
    inbox.put(None)

threading.Thread(target=reader, daemon=True).start()

def wait(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if interrupted.is_set():
            return False
        time.sleep(0.02)
    return not interrupted.is_set()

def turns_done():
    n = 0
    case = state().get("case", "?")
    try:
        with open(os.path.join(D, "fake-log.jsonl")) as f:
            for l in f:
                o = json.loads(l)
                if o.get("case") == case and o.get("event") == "turn":
                    n += 1
    except Exception:
        pass
    return n

initialized = False
tid = 0
while True:
    m = inbox.get()
    if m is None:
        break
    if m.get("type") != "user":
        continue
    interrupted.clear()
    st = state()
    n = turns_done()
    content = (m.get("message") or {}).get("content")
    text = content if isinstance(content, str) else " ".join(c.get("text", "") for c in content or [])
    log({"event": "turn", "n": n, "text": text, "session": session})
    if not initialized:
        initialized = True
        emit({"type": "system", "subtype": "init", "session_id": session, "model": "claude-opus-5-5", "cwd": os.getcwd(),
              "tools": ["mcp__airc__" + t for t in (mcp.tools if mcp else [])],
              "mcp_servers": [{"name": "airc", "status": "connected" if mcp and mcp.ok else "failed"}],
              "permissionMode": flag("--permission-mode") or "default"})
    if not st.get("loggedIn", True):
        emit({"type": "result", "subtype": "success", "is_error": True, "result": "Not logged in · Please run /login",
              "session_id": session})
        continue
    turns = st.get("turns") or [[{"say": "OK."}]]
    steps = turns[min(n, len(turns) - 1)]
    last = ""
    stopped = False
    for s in steps:
        if interrupted.is_set():
            stopped = True
            break
        if "say" in s:
            words = s["say"].split(" ")
            for i, w in enumerate(words):
                emit({"type": "stream_event", "session_id": session,
                      "event": {"type": "content_block_delta", "index": 0,
                                "delta": {"type": "text_delta", "text": w + ("" if i == len(words) - 1 else " ")}}})
                if not wait(s.get("every", 0.03)):
                    break
            emit({"type": "assistant", "session_id": session, "message": {"role": "assistant", "content": [{"type": "text", "text": s["say"]}]}})
            last = s["say"]
        elif "tool" in s:
            tid += 1
            emit({"type": "assistant", "session_id": session, "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_%d" % tid, "name": "mcp__airc__" + s["tool"], "input": s.get("args", {})}]}})
            if mcp and mcp.ok:
                text, err = mcp.call(s["tool"], s.get("args", {}))
            else:
                text, err = ("No MCP server", True)
            log({"event": "tool", "name": s["tool"], "isError": err, "result": text[:4000]})
            emit({"type": "user", "session_id": session, "message": {"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_%d" % tid, "content": text[:4000], "is_error": err}]}})
        elif "foreign" in s:
            tid += 1
            log({"event": "foreign", "name": s["foreign"]})
            emit({"type": "assistant", "session_id": session, "message": {"role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_%d" % tid, "name": s["foreign"], "input": {"command": "ls ~"}}]}})
            if wait(3):
                log({"event": "foreign-not-stopped"})
        elif "hold" in s:
            log({"event": "hold"})
            wait(s["hold"])
        elif "crash" in s:
            log({"event": "crash", "code": s["crash"]})
            sys.stderr.write("fake claude: crashing on purpose\n")
            sys.stderr.flush()
            os._exit(s["crash"])
    if interrupted.is_set() or stopped:
        emit({"type": "result", "subtype": "error_during_execution", "is_error": True, "session_id": session})
        continue
    emit({"type": "result", "subtype": "success", "is_error": False, "result": last, "session_id": session,
          "num_turns": 1, "total_cost_usd": 0.0123,
          "usage": {"input_tokens": 1200, "output_tokens": 80, "cache_read_input_tokens": 300, "cache_creation_input_tokens": 0}})
log({"event": "exit"})
"""#

    static let codex = #"""
#!/usr/bin/env python3
# Fake `codex` for Airc's agentcli checks: speaks `codex app-server` JSON-RPC (newline-delimited, no "jsonrpc" member)
# and drives the MCP server Airc puts in thread/start's config (the airc-mcp helper), following the script in
# fake-state.json next to it. No network, no model, no credentials.
import json, os, subprocess, sys, threading, time, uuid

D = os.path.dirname(os.path.abspath(__file__))

def state():
    try:
        with open(os.path.join(D, "fake-state.json")) as f:
            return json.load(f)
    except Exception:
        return {}

def log(o):
    o["t"] = time.time()
    o["case"] = state().get("case", "?")
    o["cli"] = "codex"
    with open(os.path.join(D, "fake-log.jsonl"), "a") as f:
        f.write(json.dumps(o) + "\n")

args = sys.argv[1:]
if args[:1] == ["--version"]:
    print("codex-cli 0.200.0")
    sys.exit(0)
if args[:1] != ["app-server"]:
    sys.stderr.write("fake codex: only app-server is scripted\n")
    sys.exit(2)

log({"event": "start", "argv": args, "pid": os.getpid(), "pgid": os.getpgid(0), "cwd": os.getcwd(),
     "apiKeyEnv": any(k in os.environ for k in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "ANTHROPIC_AUTH_TOKEN"))})

out_lock = threading.Lock()
def emit(o):
    with out_lock:
        sys.stdout.write(json.dumps(o) + "\n")
        sys.stdout.flush()

def notify(method, params):
    emit({"method": method, "params": params})

class MCP:
    def __init__(self, cfg):
        env = dict(os.environ)
        env.update(cfg.get("env") or {})
        self.p = subprocess.Popen([cfg["command"]] + list(cfg.get("args") or []), stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, env=env)
        self.next = 0
        self.ok = False
        self.tools = []
        r = self.req("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                    "clientInfo": {"name": "fake-codex", "version": "0.200.0"}})
        if r and "result" in r:
            self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tl = self.req("tools/list", {})
            self.tools = [t["name"] for t in ((tl or {}).get("result") or {}).get("tools", [])]
            self.ok = True
        log({"event": "mcp", "ok": self.ok, "helperPid": self.p.pid, "tools": self.tools})

    def send(self, o):
        try:
            self.p.stdin.write((json.dumps(o) + "\n").encode())
            self.p.stdin.flush()
        except Exception:
            pass

    def req(self, method, params):
        self.next += 1
        i = self.next
        self.send({"jsonrpc": "2.0", "id": i, "method": method, "params": params})
        while True:
            line = self.p.stdout.readline()
            if not line:
                return None
            try:
                o = json.loads(line)
            except Exception:
                continue
            if o.get("id") == i:
                return o

    def call(self, name, arguments):
        r = self.req("tools/call", {"name": name, "arguments": arguments})
        if r is None:
            return ("MCP server closed", True)
        if "error" in r:
            return (r["error"].get("message", "error"), True)
        res = r.get("result") or {}
        text = "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")
        return (text, bool(res.get("isError")))

mcp = None
thread = None
turn = None
interrupted = threading.Event()
server_req = 0
worker = None

def turns_done():
    n = 0
    case = state().get("case", "?")
    try:
        with open(os.path.join(D, "fake-log.jsonl")) as f:
            for l in f:
                o = json.loads(l)
                if o.get("case") == case and o.get("event") == "turn":
                    n += 1
    except Exception:
        pass
    return n

def wait(seconds):
    end = time.time() + seconds
    while time.time() < end:
        if interrupted.is_set():
            return False
        time.sleep(0.02)
    return not interrupted.is_set()

def run_turn(tid, text):
    global server_req
    st = state()
    n = turns_done()
    log({"event": "turn", "n": n, "text": text, "thread": thread})
    notify("turn/started", {"threadId": thread, "turn": {"id": tid, "status": "inProgress", "items": []}})
    if not st.get("loggedIn", True):
        notify("error", {"threadId": thread, "turnId": tid, "willRetry": False,
                         "error": {"message": "unexpected status 401 Unauthorized: Missing bearer or basic authentication in header"}})
        notify("turn/completed", {"threadId": thread, "turn": {"id": tid, "status": "failed", "items": []}})
        return
    turns = st.get("turns") or [[{"say": "OK."}]]
    steps = turns[min(n, len(turns) - 1)]
    item = 0
    for s in steps:
        if interrupted.is_set():
            break
        item += 1
        iid = "item_%s_%d" % (tid[-4:], item)
        if "say" in s:
            words = s["say"].split(" ")
            notify("item/started", {"threadId": thread, "turnId": tid, "startedAtMs": int(time.time() * 1000),
                                    "item": {"type": "agentMessage", "id": iid, "text": ""}})
            for i, w in enumerate(words):
                notify("item/agentMessage/delta", {"threadId": thread, "turnId": tid, "itemId": iid,
                                                   "delta": w + ("" if i == len(words) - 1 else " ")})
                if not wait(s.get("every", 0.03)):
                    break
            notify("item/completed", {"threadId": thread, "turnId": tid, "item": {"type": "agentMessage", "id": iid, "text": s["say"]}})
        elif "tool" in s:
            notify("item/started", {"threadId": thread, "turnId": tid, "startedAtMs": int(time.time() * 1000),
                                    "item": {"type": "mcpToolCall", "id": iid, "server": "airc", "tool": s["tool"],
                                             "arguments": s.get("args", {}), "status": "inProgress"}})
            if mcp and mcp.ok:
                text, err = mcp.call(s["tool"], s.get("args", {}))
            else:
                text, err = ("No MCP server", True)
            log({"event": "tool", "name": s["tool"], "isError": err, "result": text[:4000]})
            notify("item/completed", {"threadId": thread, "turnId": tid, "item": {"type": "mcpToolCall", "id": iid, "server": "airc",
                   "tool": s["tool"], "arguments": s.get("args", {}), "status": "failed" if err else "completed",
                   "result": {"content": [{"type": "text", "text": text[:4000]}]}}})
        elif "foreign" in s:
            log({"event": "foreign", "name": s["foreign"]})
            notify("item/started", {"threadId": thread, "turnId": tid, "startedAtMs": int(time.time() * 1000),
                                    "item": {"type": "commandExecution", "id": iid, "command": "ls ~", "commandActions": [],
                                             "cwd": os.getcwd(), "status": "inProgress"}})
            server_req += 1
            emit({"id": "srv-%d" % server_req, "method": "item/commandExecution/requestApproval",
                  "params": {"threadId": thread, "turnId": tid, "itemId": iid, "command": "ls ~"}})
            if wait(3):
                log({"event": "foreign-not-stopped"})
        elif "elicit" in s:
            for name in ("airc", "personal-fs"):
                server_req += 1
                emit({"id": "srv-%d" % server_req, "method": "mcpServer/elicitation/request",
                      "params": {"serverName": name, "threadId": thread, "turnId": tid, "mode": "form",
                                 "message": "Allow the tool?", "requestedSchema": {"type": "object", "properties": {}}}})
            wait(0.5)
        elif "hold" in s:
            log({"event": "hold"})
            wait(s["hold"])
        elif "crash" in s:
            log({"event": "crash", "code": s["crash"]})
            sys.stderr.write("fake codex: crashing on purpose\n")
            sys.stderr.flush()
            os._exit(s["crash"])
    notify("thread/tokenUsage/updated", {"threadId": thread, "turnId": tid, "tokenUsage": {
        "total": {"inputTokens": 1500 * (n + 1), "cachedInputTokens": 200, "outputTokens": 90 * (n + 1), "reasoningOutputTokens": 0,
                  "totalTokens": 1590 * (n + 1)},
        "last": {"inputTokens": 1500, "cachedInputTokens": 200, "outputTokens": 90, "reasoningOutputTokens": 0, "totalTokens": 1590}}})
    status = "interrupted" if interrupted.is_set() else "completed"
    notify("turn/completed", {"threadId": thread, "turn": {"id": tid, "status": status, "items": []}})

def thread_params(p, kind):
    global mcp, thread
    log({"event": kind, "params": p})
    servers = ((p.get("config") or {}).get("mcp_servers") or {})
    airc = servers.get("airc")
    if airc and airc.get("enabled", True) and mcp is None:
        mcp = MCP(airc)
    thread = p.get("threadId") or str(uuid.uuid4())
    return {"thread": {"id": thread, "status": {"type": "idle"}, "turns": []}, "model": "gpt-6.1-sol", "modelProvider": "openai",
            "cwd": p.get("cwd"), "approvalPolicy": p.get("approvalPolicy"), "approvalsReviewer": "user",
            "sandbox": {"type": "readOnly"}}

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        m = json.loads(line)
    except Exception:
        continue
    method = m.get("method")
    i = m.get("id")
    p = m.get("params") or {}
    if method is None:
        # An answer to one of our requests (approvals, elicitations).
        log({"event": "answer", "id": i, "result": m.get("result"), "error": m.get("error")})
        continue
    if method == "initialize":
        emit({"id": i, "result": {"userAgent": "airc/0.200.0", "codexHome": D, "platformFamily": "unix", "platformOs": "macos"}})
    elif method == "initialized":
        pass
    elif method == "account/read":
        li = state().get("loggedIn", True)
        emit({"id": i, "result": {"account": {"type": "chatgpt", "email": "p@example.com", "planType": "plus"} if li else None,
                                  "requiresOpenaiAuth": True}})
    elif method == "config/read":
        emit({"id": i, "result": {"config": {"mcp_servers": {"personal-fs": {"command": "/usr/bin/false"}}}, "origins": {}}})
    elif method == "thread/start":
        emit({"id": i, "result": thread_params(p, "thread/start")})
        notify("thread/started", {"thread": {"id": thread, "model": "gpt-6.1-sol"}})
    elif method == "thread/resume":
        emit({"id": i, "result": thread_params(p, "thread/resume")})
    elif method == "turn/start":
        turn = "turn_" + uuid.uuid4().hex[:12]
        interrupted.clear()
        text = " ".join(x.get("text", "") for x in p.get("input", []))
        emit({"id": i, "result": {"turn": {"id": turn, "status": "inProgress", "items": []}}})
        worker = threading.Thread(target=run_turn, args=(turn, text), daemon=True)
        worker.start()
    elif method == "turn/interrupt":
        if state().get("ignoreInterrupt"):
            log({"event": "interrupt-ignored"})
            continue
        log({"event": "interrupt", "params": p})
        emit({"id": i, "result": {}})
        interrupted.set()
    elif i is not None:
        emit({"id": i, "error": {"code": -32601, "message": "fake codex: " + method}})
log({"event": "exit"})
"""#
}
#endif
