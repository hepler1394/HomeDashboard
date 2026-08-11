#!/usr/bin/env python3
"""
Home Network Dashboard 2.0 - "The Brain"  (v2 - full)
=====================================================
Central controller for the whole house on PLEXSERVER. Holds a job queue; each PC
runs a small agent that polls, runs jobs in the user session, and reports back.
Pull-based -> works through PIA/VPN/NAT with no port-forwarding.

Pure Python standard library only - no pip installs.

Layers:
  - Job queue + device registry + audit         (Phase 0)
  - App catalog / install bundles               (Phase 2)
  - File upload + staging + cross-PC transfer    (Phase 3)
  - Plex browse + play-on-any-PC                 (Phase 4)
  - AI command center (multi-provider + tools)   (Phase 5)
  - Telegram bot + alerts + backups              (Phase 6)
  - Serves the integrated 2.0 UI at  GET /

Secrets/config/db/audit live in %LOCALAPPDATA%\\HomeNetDashboard\\brain and are
never synced.
"""
import json, os, sqlite3, secrets, time, threading, ipaddress, urllib.request, urllib.parse, urllib.error, re, hashlib, socket, shutil, string, ctypes
from datetime import datetime, timezone, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, quote, unquote

# ---- Paths / config --------------------------------------------------------
BRAIN_VERSION = "3.8.2"
START_TIME = time.time()
PORT       = 8788
DATA_DIR   = os.path.join(os.environ.get("LOCALAPPDATA", os.path.expanduser("~")),
                          "HomeNetDashboard", "brain")
DB_PATH    = os.path.join(DATA_DIR, "brain.db")
SECRET_F   = os.path.join(DATA_DIR, "secret.json")
AUDIT_F    = os.path.join(DATA_DIR, "audit.jsonl")
PLEX_F     = os.path.join(DATA_DIR, "plex.json")
AIKEYS_F   = os.path.join(DATA_DIR, "ai-keys.json")
TELEGRAM_F = os.path.join(DATA_DIR, "telegram.json")
BACKUPS_F  = os.path.join(DATA_DIR, "backups.json")
ALERTS_F   = os.path.join(DATA_DIR, "alert-state.json")
MAINT_F    = os.path.join(DATA_DIR, "maintenance.json")
RULES_F    = os.path.join(DATA_DIR, "rules.json")
REQUESTS_F = os.path.join(DATA_DIR, "pending-requests.json")
SHOTS_DIR  = os.path.join(DATA_DIR, "screenshots")
SHOT_OPTIN_F = os.path.join(DATA_DIR, "screenshot-optin.json")
CLAW_URL   = "http://127.0.0.1:8790"   # PlexClaw bridge (same box, loopback)
NETDEV_F   = os.path.join(DATA_DIR, "net-devices.json")
NETSTAT_F  = os.path.join(DATA_DIR, "net-status.json")
NICKS_F    = os.path.join(DATA_DIR, "nicknames.json")   # agent -> friendly display name
PEERS_F    = os.path.join(os.path.dirname(DATA_DIR), "device-peers.json")  # LAN IP -> Parsec peer id (from old dashboard)
STAGING    = os.path.join(DATA_DIR, "staging")
SCRIPT_DIR   = os.path.dirname(os.path.abspath(__file__))
AGENT_PS     = os.path.join(SCRIPT_DIR, "homedash-agent.ps1")
LAUNCHER_PS  = os.path.join(SCRIPT_DIR, "homedash-launcher.ps1")
BOOTSTRAP_PS = os.path.join(SCRIPT_DIR, "bootstrap.ps1")
CATALOG_F    = os.path.join(SCRIPT_DIR, "catalog.json")
UI_HTML      = os.path.join(SCRIPT_DIR, "ui.html")

# The one folder Syncthing keeps live-synced to every PC. The brain runs on
# PlexServer, so it reads/writes this directly and Syncthing propagates. Files
# dropped here (e.g. screenshots sent to the Telegram bot) appear on every PC.
HOMESHARE     = r"C:\HomeShare"
HS_INBOX      = os.path.join(HOMESHARE, "Screenshots")

os.makedirs(DATA_DIR, exist_ok=True)
os.makedirs(STAGING, exist_ok=True)
os.makedirs(SHOTS_DIR, exist_ok=True)
try: os.makedirs(HS_INBOX, exist_ok=True)
except Exception: pass

def shot_optin(agent):
    return bool(load_json(SHOT_OPTIN_F, {}).get(agent))

def now_iso():
    return datetime.now(timezone.utc).isoformat()

# ---- Small JSON config helpers ---------------------------------------------
def load_json(path, default):
    if os.path.exists(path):
        try:
            return json.load(open(path, encoding="utf-8"))
        except Exception:
            pass
    return default

def save_json(path, obj):
    tmp = path + ".tmp"
    json.dump(obj, open(tmp, "w", encoding="utf-8"), indent=2)
    os.replace(tmp, path)

def load_token():
    d = load_json(SECRET_F, None)
    if d and d.get("token"):
        return d["token"]
    tok = secrets.token_urlsafe(24)
    save_json(SECRET_F, {"token": tok, "created": now_iso()})
    return tok

TOKEN = load_token()

# ---- Browser session tokens (expiring, revocable) --------------------------
# Agents + loopback use the master TOKEN. Browsers that log in with the password
# get a SESSION token instead of the master one, so a stolen browser store
# doesn't hand out permanent god-access - sessions expire and can be revoked.
SESSIONS_F = os.path.join(DATA_DIR, "sessions.json")
SESSION_TTL = 30 * 86400
_sess_lock = threading.Lock()

def new_session():
    tok = secrets.token_urlsafe(24)
    with _sess_lock:
        s = load_json(SESSIONS_F, {})
        now = time.time()
        s = {k: v for k, v in s.items() if v > now}      # prune expired
        s[tok] = now + SESSION_TTL
        save_json(SESSIONS_F, s)
    return tok

def valid_session(tok):
    if not tok:
        return False
    with _sess_lock:
        s = load_json(SESSIONS_F, {})
        exp = s.get(tok)
        return bool(exp and exp > time.time())

def revoke_all_sessions():
    with _sess_lock:
        save_json(SESSIONS_F, {})

# ---- Dashboard password (lets any of your PCs' browsers log in) -------------
AUTH_F = os.path.join(DATA_DIR, "brain-auth.json")
def password_set():
    a = load_json(AUTH_F, None)
    return bool(a and a.get("hash"))
def set_password(pw):
    salt = secrets.token_hex(8)
    save_json(AUTH_F, {"salt": salt, "hash": hashlib.sha256((salt + pw).encode()).hexdigest()})
def check_password(pw):
    a = load_json(AUTH_F, None)
    if not a or not a.get("hash"):
        return False
    return hashlib.sha256((a["salt"] + pw).encode()).hexdigest() == a["hash"]

# ---- DB --------------------------------------------------------------------
_db_lock = threading.Lock()

def db():
    c = sqlite3.connect(DB_PATH, timeout=10)
    c.row_factory = sqlite3.Row
    return c

def init_db():
    with _db_lock, db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS devices(
            agent TEXT PRIMARY KEY, host TEXT, ip TEXT, ts_ip TEXT,
            caps TEXT, stats TEXT, last_seen TEXT, registered TEXT);
        CREATE TABLE IF NOT EXISTS jobs(
            id INTEGER PRIMARY KEY AUTOINCREMENT, agent TEXT NOT NULL, type TEXT NOT NULL,
            args TEXT, status TEXT NOT NULL DEFAULT 'pending', result TEXT,
            created TEXT, updated TEXT, created_by TEXT);
        CREATE TABLE IF NOT EXISTS history(
            agent TEXT NOT NULL, t TEXT NOT NULL, cpu INTEGER, mem INTEGER, drives TEXT);
        CREATE INDEX IF NOT EXISTS idx_hist ON history(agent, t);
        """)

def audit(event, **kw):
    try:
        with open(AUDIT_F, "a", encoding="utf-8") as f:
            f.write(json.dumps({"t": now_iso(), "event": event, **kw}) + "\n")
    except Exception:
        pass

# ---- Security: kill switch (read-only) + login rate-limit ------------------
def read_only():
    return bool(load_json(MAINT_F, {}).get("readOnly"))

def set_read_only(on):
    cfg = load_json(MAINT_F, {})
    cfg["readOnly"] = bool(on)
    save_json(MAINT_F, cfg)
    audit("killswitch", readOnly=bool(on))

_login_fails = {}          # ip -> [epoch, ...] recent failed logins
_login_lock = threading.Lock()

def login_locked(ip):
    with _login_lock:
        hits = [t for t in _login_fails.get(ip, []) if time.time() - t < 300]
        _login_fails[ip] = hits
        return len(hits) >= 5

def login_fail(ip):
    with _login_lock:
        _login_fails.setdefault(ip, []).append(time.time())

# ---- Job / device ops ------------------------------------------------------
def register_device(agent, host, ip, ts_ip, caps):
    with _db_lock, db() as c:
        if c.execute("SELECT agent FROM devices WHERE agent=?", (agent,)).fetchone():
            c.execute("UPDATE devices SET host=?,ip=?,ts_ip=?,caps=?,last_seen=? WHERE agent=?",
                      (host, ip, ts_ip, json.dumps(caps), now_iso(), agent))
        else:
            c.execute("INSERT INTO devices(agent,host,ip,ts_ip,caps,last_seen,registered) VALUES(?,?,?,?,?,?,?)",
                      (agent, host, ip, ts_ip, json.dumps(caps), now_iso(), now_iso()))
    audit("register", agent=agent, host=host, ip=ip)

_hist_last = {}   # agent -> epoch of last history sample
_agent_ver_seen = {}   # agent -> (max_version_tuple, version_str, epoch) - monotonic guard

def _vtuple(v):
    try:
        return tuple(int(p) for p in str(v).split(".") if p != "")
    except Exception:
        return ()

def _pin_forward_version(agent, stats):
    """A failed self-update can leave a stale OLD agent process polling alongside
    the healthy new one - both report as the same agent, so stats['ver'] flaps and
    the dashboard shows an endless 'updating'. Suppress the downgrade: keep the
    highest version this agent reported in the last 5 min. If the newer instance
    truly disappears (no poll for 5 min), a genuinely lower version takes over, so
    a real rollback/re-enroll still reflects."""
    inv = stats.get("ver")
    if not inv:
        return stats
    it = _vtuple(inv); now = time.time()
    prev = _agent_ver_seen.get(agent)
    if prev and (now - prev[2] < 300) and it and prev[0] and it < prev[0]:
        return {**stats, "ver": prev[1]}   # stale duplicate - show the newer version
    _agent_ver_seen[agent] = (it, str(inv), now)
    return stats

def heartbeat_and_fetch(agent, host, ip, stats):
    # A stale duplicate agent process (failed self-update leftover) polls with an
    # OLD version and doesn't know newer job types - it must never claim jobs.
    # Gate dispatch on the reported version matching what the brain serves; the
    # healthy up-to-date process polls within seconds and takes them instead.
    _raw_ver = str((stats or {}).get("ver") or "")
    _exp_ver = agent_expected_version()
    _stale = bool(_exp_ver and _raw_ver and _raw_ver != _exp_ver)
    stats = _pin_forward_version(agent, stats)
    with _db_lock, db() as c:
        c.execute("""INSERT INTO devices(agent,host,ip,stats,last_seen,registered)
                     VALUES(?,?,?,?,?,?)
                     ON CONFLICT(agent) DO UPDATE SET host=excluded.host, ip=excluded.ip,
                       stats=excluded.stats, last_seen=excluded.last_seen""",
                  (agent, host, ip, json.dumps(stats), now_iso(), now_iso()))
        # Trend history: one sample per PC at most every 120s (local drives only -
        # network mappings are another PC's disk and would double-count).
        if time.time() - _hist_last.get(agent, 0) >= 120:
            _hist_last[agent] = time.time()
            try:
                drv = [{"l": d.get("letter"), "f": d.get("freeGB"), "p": d.get("usedPct")}
                       for d in (stats.get("drives") or []) if not d.get("network")]
                c.execute("INSERT INTO history(agent,t,cpu,mem,drives) VALUES(?,?,?,?,?)",
                          (agent, now_iso(), int(stats.get("cpu") or 0), int(stats.get("mem") or 0),
                           json.dumps(drv)))
            except Exception:
                pass
        if _stale:
            return []   # heartbeat recorded, but no jobs for an out-of-date process
        rows = c.execute("SELECT * FROM jobs WHERE agent=? AND status='pending' ORDER BY id", (agent,)).fetchall()
        jobs = []
        for r in rows:
            c.execute("UPDATE jobs SET status='dispatched',updated=? WHERE id=?", (now_iso(), r["id"]))
            jobs.append({"id": r["id"], "type": r["type"], "args": json.loads(r["args"] or "{}")})
    for j in jobs:
        audit("dispatch", agent=agent, job=j["id"], type=j["type"], args=j["args"])
    return jobs

def enqueue(agent, jtype, args, by="dashboard"):
    with _db_lock, db() as c:
        cur = c.execute("INSERT INTO jobs(agent,type,args,status,created,updated,created_by) VALUES(?,?,?,?,?,?,?)",
                        (agent, jtype, json.dumps(args or {}), "pending", now_iso(), now_iso(), by))
        jid = cur.lastrowid
    audit("enqueue", agent=agent, job=jid, type=jtype, args=args, by=by)
    return jid

def save_result(jid, ok, exit_code, stdout, stderr):
    res = {"ok": bool(ok), "exit": exit_code, "stdout": stdout, "stderr": stderr, "at": now_iso()}
    with _db_lock, db() as c:
        c.execute("UPDATE jobs SET status=?,result=?,updated=? WHERE id=?",
                  ("done" if ok else "error", json.dumps(res), now_iso(), jid))
    audit("result", job=jid, ok=bool(ok), exit=exit_code)

def get_job(jid):
    with _db_lock, db() as c:
        r = c.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
    if not r:
        return None
    return {"id": r["id"], "agent": r["agent"], "type": r["type"], "args": json.loads(r["args"] or "{}"),
            "status": r["status"], "result": json.loads(r["result"]) if r["result"] else None,
            "created": r["created"], "updated": r["updated"], "by": r["created_by"]}

def list_jobs(limit=100):
    with _db_lock, db() as c:
        rows = c.execute("SELECT * FROM jobs ORDER BY id DESC LIMIT ?", (limit,)).fetchall()
    return [{"id": r["id"], "agent": r["agent"], "type": r["type"], "args": json.loads(r["args"] or "{}"),
             "status": r["status"], "result": json.loads(r["result"]) if r["result"] else None,
             "created": r["created"], "updated": r["updated"], "by": r["created_by"]} for r in rows]

def list_devices():
    nicks = load_json(NICKS_F, {})
    peers = load_json(PEERS_F, {})   # {lan_ip: parsec_peer_id}
    with _db_lock, db() as c:
        rows = c.execute("SELECT * FROM devices ORDER BY host").fetchall()
    out = []
    for r in rows:
        online = False
        try:
            online = (datetime.now(timezone.utc) - datetime.fromisoformat(r["last_seen"])).total_seconds() < 45
        except Exception:
            pass
        stats = json.loads(r["stats"] or "{}")
        lanip = stats.get("lanip") or r["ip"]
        out.append({"agent": r["agent"], "host": r["host"], "ip": r["ip"], "ts_ip": r["ts_ip"],
                    "nick": nicks.get(r["agent"], ""), "parsec": peers.get(lanip, ""),
                    "caps": json.loads(r["caps"] or "[]"), "stats": stats,
                    "last_seen": r["last_seen"], "online": online, "registered": r["registered"]})
    return out

def wait_for_job(jid, timeout=90):
    """Block until a job is done/error, or timeout. Used by AI tools + Plex play."""
    end = time.time() + timeout
    while time.time() < end:
        j = get_job(jid)
        if j and j["status"] in ("done", "error"):
            return j
        time.sleep(0.6)
    return get_job(jid)

def wol_send(mac):
    """Send a Wake-on-LAN magic packet on the LAN. Raises if the MAC is unusable."""
    mac_clean = re.sub(r"[^0-9A-Fa-f]", "", mac or "")
    if len(mac_clean) != 12:
        raise ValueError("no known MAC for this PC (power it on once so it's learned)")
    data = b"\xff" * 6 + bytes.fromhex(mac_clean) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.sendto(data, ("255.255.255.255", 9))
    s.close()

# ---- Self-reliance: expected agent version + nightly self-backup -----------
_agent_ver_cache = {"mtime": 0.0, "ver": ""}

def agent_expected_version():
    """Version string inside the agent file the brain serves at /agent.
    Agents compare their own version against this each poll and self-update."""
    try:
        m = os.path.getmtime(AGENT_PS)
        if m != _agent_ver_cache["mtime"]:
            txt = open(AGENT_PS, encoding="utf-8", errors="replace").read()
            mt = re.search(r"AGENT_VERSION\s*=\s*'([^']+)'", txt)
            _agent_ver_cache["mtime"] = m
            _agent_ver_cache["ver"] = mt.group(1) if mt else ""
    except Exception:
        pass
    return _agent_ver_cache["ver"]

def pick_backup_dir():
    """Backup target: a fixed drive other than C: (largest free), so the brain's
    memory survives the system disk dying. Sticky once chosen (maintenance.json)."""
    cfg = load_json(MAINT_F, {})
    if cfg.get("backupDir"):
        return cfg["backupDir"]
    best = None
    for letter in string.ascii_uppercase:
        if letter == "C":
            continue
        root = letter + ":\\"
        try:
            if ctypes.windll.kernel32.GetDriveTypeW(root) != 3:  # DRIVE_FIXED only
                continue
            free = shutil.disk_usage(root).free
            if free > 10 * 2**30 and (best is None or free > best[1]):
                best = (root, free)
        except Exception:
            continue
    d = os.path.join(best[0] if best else "C:\\", "HomeBrainBackups")
    cfg["backupDir"] = d
    save_json(MAINT_F, cfg)
    return d

def run_self_backup():
    """Consistent brain.db snapshot (sqlite backup API) + config files -> backup
    drive, timestamped folder, keep the 7 newest."""
    try:
        root = pick_backup_dir()
        dest = os.path.join(root, datetime.now().strftime("%Y%m%d-%H%M%S"))
        os.makedirs(dest, exist_ok=True)
        with _db_lock:
            src = db()
            dst = sqlite3.connect(os.path.join(dest, "brain.db"))
            src.backup(dst)
            dst.close(); src.close()
        n = 1
        for f in (AUTH_F, SECRET_F, AIKEYS_F, PLEX_F, TELEGRAM_F, BACKUPS_F, CATALOG_F):
            if os.path.exists(f):
                shutil.copy2(f, dest); n += 1
        # prune: keep the 7 newest timestamped sets
        sets = sorted(d for d in os.listdir(root)
                      if re.fullmatch(r"\d{8}-\d{6}", d) and os.path.isdir(os.path.join(root, d)))
        for old in sets[:-7]:
            shutil.rmtree(os.path.join(root, old), ignore_errors=True)
        cfg = load_json(MAINT_F, {})
        cfg["lastBackup"] = {"at": now_iso(), "ok": True, "dir": dest, "files": n}
        save_json(MAINT_F, cfg)
        audit("self_backup", ok=True, dir=dest, files=n)
    except Exception as e:
        cfg = load_json(MAINT_F, {})
        cfg["lastBackup"] = {"at": now_iso(), "ok": False, "error": str(e)[:200]}
        save_json(MAINT_F, cfg)
        audit("self_backup", ok=False, err=str(e)[:200])

def backup_loop():
    """Self-backup ~daily; failed attempts retry after 2h. First check 2 min
    after boot so a stale backup is refreshed even if the box reboots nightly."""
    time.sleep(120)
    while True:
        try:
            last = load_json(MAINT_F, {}).get("lastBackup") or {}
            age = None
            try:
                age = (datetime.now(timezone.utc) - datetime.fromisoformat(last.get("at", ""))).total_seconds()
            except Exception:
                pass
            limit = 24 * 3600 if last.get("ok") else 2 * 3600
            if age is None or age > limit:
                run_self_backup()
        except Exception as e:
            audit("backup_error", err=str(e)[:200])
        time.sleep(1800)

# ---- HTTP helper (outbound) ------------------------------------------------
def http_json(method, url, headers=None, body=None, timeout=40):
    data = None
    if body is not None:
        data = body if isinstance(body, bytes) else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers or {})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
    try:
        return json.loads(raw.decode("utf-8"))
    except Exception:
        return {"_raw": raw.decode("utf-8", "replace")}

# ---- AI providers ----------------------------------------------------------
DEFAULT_AI = {
    # OpenRouter (open-weight, cloud-hosted) is the primary brain: smart enough
    # for the tool-calling loop, cheap enough to leave on. If OpenRouter is down
    # or unkeyed, it auto-falls back to the free local Ollama, then Anthropic.
    "default": "openrouter",
    "fallback": ["ollama", "claude"],
    "providers": {
        "openai":   {"style": "openai",    "baseUrl": "https://api.openai.com/v1",                               "key": "", "model": "gpt-5-nano"},
        "claude":   {"style": "anthropic", "baseUrl": "https://api.anthropic.com",                               "key": "", "model": "claude-haiku-4-5"},
        "gemini":   {"style": "openai",    "baseUrl": "https://generativelanguage.googleapis.com/v1beta/openai", "key": "", "model": "gemini-2.5-flash"},
        "grok":     {"style": "openai",    "baseUrl": "https://api.x.ai/v1",                                     "key": "", "model": "grok-4-latest"},
        "deepseek": {"style": "openai",    "baseUrl": "https://api.deepseek.com",                                "key": "", "model": "deepseek-chat"},
        "fangu":    {"style": "openai",    "baseUrl": "",                                                        "key": "", "model": ""},
        # Local model on the gaming PC's GPU - free, private, no key to rotate.
        # Ollama ignores the bearer key; "ollama" is just a placeholder so the
        # provider counts as configured once its baseUrl answers.
        "ollama":   {"style": "openai",    "baseUrl": "http://192.168.1.189:11434/v1",                           "key": "ollama", "model": "llama3.2:3b"},
        # OpenRouter open-weight models. All share ONE key (set it once on any
        # slot and the /ai/keys handler mirrors it to the rest). "openrouter" is
        # the default daily driver (Kimi K2.6); the others are pick-on-demand.
        "openrouter":          {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "moonshotai/kimi-k2.6"},
        "openrouter-k3":       {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "moonshotai/kimi-k3"},
        "openrouter-code":     {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "moonshotai/kimi-k2.7-code"},
        "openrouter-deepseek": {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "deepseek/deepseek-v3.2"},
        "openrouter-cheap":    {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "deepseek/deepseek-v4-flash"},
        "openrouter-qwen":     {"style": "openai", "baseUrl": "https://openrouter.ai/api/v1", "key": "", "model": "qwen/qwen3.5-397b-a17b"},
    },
}

def ai_cfg():
    cfg = load_json(AIKEYS_F, None)
    if not cfg:
        cfg = json.loads(json.dumps(DEFAULT_AI))
        save_json(AIKEYS_F, cfg)
    # make sure every default provider slot exists (e.g. after adding fangu)
    for k, v in DEFAULT_AI["providers"].items():
        cfg.setdefault("providers", {}).setdefault(k, v)
    return cfg

def ai_order(cfg):
    names = []
    if cfg.get("default"): names.append(cfg["default"])
    names += cfg.get("fallback", [])
    names += list(cfg.get("providers", {}).keys())
    seen, out = set(), []
    for n in names:
        if n in seen: continue
        seen.add(n)
        p = cfg.get("providers", {}).get(n)
        if p and str(p.get("key", "")).strip() and str(p.get("baseUrl", "")).strip():
            out.append((n, p))
    return out

def call_ai(provider, msgs, max_tokens=700):
    """One call to one provider. msgs = [{role, content}] with optional system role."""
    style = provider["style"]
    base = provider["baseUrl"].rstrip("/")
    key = provider["key"]
    model = provider["model"]
    # Local models (Ollama on the gaming PC) can take ~70s to cold-load into the
    # GPU on the first call, so give non-cloud endpoints a generous timeout.
    is_local = ("127.0.0.1" in base or "localhost" in base or "192.168." in base
                or "10." in base or ":11434" in base)
    to = 200 if is_local else 60
    if style == "anthropic":
        system = "".join(m["content"] for m in msgs if m["role"] == "system")
        conv = [m for m in msgs if m["role"] != "system"]
        body = {"model": model, "max_tokens": max_tokens, "system": system, "messages": conv}
        h = {"x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json"}
        r = http_json("POST", base + "/v1/messages", h, body, timeout=to)
        return r["content"][0]["text"]
    else:
        body = {"model": model, "max_tokens": max_tokens, "messages": msgs}
        # Ask Ollama to keep the model resident for 30 min so later calls are instant.
        if is_local:
            body["keep_alive"] = "30m"
        h = {"Authorization": "Bearer " + key, "content-type": "application/json"}
        r = http_json("POST", base + "/chat/completions", h, body, timeout=to)
        return r["choices"][0]["message"]["content"]

def ai_complete(msgs, prefer=None, max_tokens=700):
    cfg = ai_cfg()
    order = ai_order(cfg)
    if prefer:
        order = sorted(order, key=lambda x: 0 if x[0] == prefer else 1)
    for name, p in order:
        try:
            return {"text": call_ai(p, msgs, max_tokens), "provider": name}
        except Exception as e:
            audit("ai_error", provider=name, err=str(e)[:200])
            continue
    return None

# ---- AI command center: tool-calling loop (provider-agnostic ReAct) --------
AI_TOOLS_DOC = """You are the assistant for a Home Network Dashboard that controls the owner's own home PCs and media library.
You can take actions by replying with ONE fenced json tool call and nothing else:
```json
{"tool":"<name>","agent":"<pc>","args":{...}}
```
Available tools:
- list_devices            -> args:{}                      (see all PCs + live stats)
- status  agent           -> args:{}                      (one PC's stats)
- open    agent app       -> args:{"app":"claude"}        (launch app: claude, code, discord, vlc, chrome, explorer, etc)
- open    agent path      -> args:{"path":"D:\\\\"}       (open folder in explorer)
- install agent id        -> args:{"id":"VideoLAN.VLC"}   (install app via winget)
- pia     agent action    -> args:{"action":"on|off|status"}
- play    agent url        -> args:{"url":"http://..."}   (queue in VLC on that PC)
- run     agent command    -> args:{"cmd":"ipconfig"}     (allow-listed diagnostics)
- power   agent action    -> args:{"action":"restart"}    (DESTRUCTIVE - only if user clearly asked)
- history agent           -> args:{}                      (24h cpu/mem/disk trend)
- audit                   -> args:{"n":15}                (recent brain audit log)
- job_status              -> args:{"id":123}              (check job result)
- listdir agent           -> args:{"path":"Z:\\\\Movies"}  (list folder on PC - works for cloud mounts)
- search_files agent      -> args:{"root":"Z:\\\\","q":"tax"} (find files by name)
- copy_file agent         -> args:{"src":"Z:\\\\a.txt","dst":"D:\\\\b"} (copy on that PC)
- move_file agent         -> args:{"src":"...","dst":"..."}   (move/rename on that PC)
- delete_file agent       -> args:{"path":"Z:\\\\old.txt"} (DESTRUCTIVE - only when user clearly asked)
- rename_file agent       -> args:{"src":"Z:\\\\old.txt","name":"new.txt"} (rename file/folder on PC)
- archive agent           -> args:{"path":"Z:\\\\folder"}  (compress folder to .zip)
- processes agent         -> args:{"top":10,"sort":"mem"} (top CPU/memory processes)
- disk_cleanup agent      -> args:{"targets":"temp,recycle"} (free up disk space)
- netstat agent           -> args:{}                       (show network connections)
- gpu_status agent        -> args:{}                       (show GPU utilization)
- battery agent           -> args:{}                       (laptop battery status)
- get_hash agent          -> args:{"path":"file.zip","algo":"SHA256"} (file hash)
- request_media           -> args:{"title":"Toxic Love Story","year":"2026"} (request movie/show)
- plex_search             -> args:{"q":"Matrix"}          (search Plex library)
- plex_status             -> args:{}                      (watch stats, recent adds)
- fleet_search            -> args:{"q":"tax"}             (search all PCs for files)
- browser_task            -> args:{"task":"navigate google.com, search for X, extract results"} (Hermes browser-automation skill)
- ocr_extract             -> args:{"task":"extract text from image"}  (Hermes productivity OCR)
- email_draft             -> args:{"to":"user@example.com","subject":"X","body":"Y"} (Hermes productivity email)
- clipboard_paste         -> args:{"text":"content"}     (Hermes productivity clipboard)
- workflow_chain          -> args:{"steps":["find files","zip them","email zip"]} (Hermes workflow-orchestrator)
- windows_admin           -> args:{"task":"restart service X"}  (Hermes windows-admin skill)
Hermes Integration: dashboard now unifies HomeDashboard (fleet control) + Hermes (single-PC deep automation). Browser automation, OCR, email, clipboard, workflows, and admin tasks all accessible via natural language. No external gateway—pure Hermes skills.
After a tool runs you get a "tool result" message; then call another tool or give the final answer in plain English.
When you have the answer, reply normally (no json). Prefer exact agent names from list_devices."""

def resolve_agent(name):
    """Map whatever the model calls a PC (agent id, hostname, any case) to the
    real agent id. Models tend to use the display name 'PLEXSERVER' while the
    agent id is 'plexserver' - without this, jobs sit unclaimed forever."""
    if not name:
        return None
    n = str(name).strip().lower()
    devs = list_devices()
    for d in devs:
        if d["agent"].lower() == n:
            return d["agent"]
    for d in devs:
        if (d["host"] or "").lower() == n:
            return d["agent"]
    for d in devs:                       # last resort: prefix/substring match
        if n in d["agent"].lower() or n in (d["host"] or "").lower():
            return d["agent"]
    return None

def resolve_app(app_name):
    """Map friendly app names to agent job args.
    Returns {"app": name} for the 'open' job."""
    if not app_name:
        return None
    a = str(app_name).strip().lower()
    # Map common names to agent app resolution keys
    app_map = {
        "claude": "claude",
        "claude code": "claude",
        "code": "code",
        "vscode": "code",
        "vs code": "code",
        "discord": "discord",
        "chrome": "chrome",
        "vlc": "vlc",
        "notepad": "notepad",
        "explorer": "explorer",
    }
    return {"app": app_map.get(a, a)}

# ---- Filesystem ops (Drive browser + AI file tools) -------------------------
_LOCAL_HOST = socket.gethostname().lower()

def _fs_local(op, args):
    """Run a filesystem op directly on this box (the brain host). Instant - no
    agent job round-trip. Used when the target PC IS the brain host."""
    import shutil
    if op == "list":
        path = str(args.get("path", ""))
        if not path or not os.path.isdir(path):
            return {"ok": False, "error": "path not found"}
        items = []
        try:
            with os.scandir(path) as it:
                for e in it:
                    if len(items) >= 500:
                        break
                    try:
                        st = e.stat()
                        items.append({"name": e.name, "dir": e.is_dir(),
                                      "sizeMB": None if e.is_dir() else round(st.st_size / 1048576, 2),
                                      "mod": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime))})
                    except Exception:
                        items.append({"name": e.name, "dir": e.is_dir(), "sizeMB": None, "mod": ""})
        except Exception as ex:
            return {"ok": False, "error": str(ex)}
        items.sort(key=lambda x: (not x["dir"], x["name"].lower()))
        return {"ok": True, "items": items}
    if op == "search":
        root, q = str(args.get("root", "")), str(args.get("q", "")).lower()
        if not root or not os.path.isdir(root) or len(q) < 2:
            return {"ok": False, "error": "root + q (2+ chars) required"}
        hits, t0 = [], time.time()
        for dirpath, dirnames, filenames in os.walk(root):
            if len(hits) >= 200 or time.time() - t0 > 20:
                break
            for name in dirnames + filenames:
                if q in name.lower():
                    hits.append({"name": name, "path": os.path.join(dirpath, name),
                                 "dir": name in dirnames})
                    if len(hits) >= 200:
                        break
        return {"ok": True, "hits": hits}
    if op == "delete":
        p = str(args.get("path", ""))
        if re.match(r"^[A-Za-z]:[\\/]?\s*$", p):
            return {"ok": False, "error": "refusing to delete a drive root"}
        if not os.path.exists(p):
            return {"ok": False, "error": "path not found"}
        try:
            (shutil.rmtree if os.path.isdir(p) else os.remove)(p)
            return {"ok": True, "msg": f"deleted {p}"}
        except Exception as ex:
            return {"ok": False, "error": str(ex)}
    if op in ("copy", "move"):
        src, dst = str(args.get("src", "")), str(args.get("dst", ""))
        if not src or not os.path.exists(src) or not dst:
            return {"ok": False, "error": "src (existing) + dst required"}
        try:
            if op == "move":
                shutil.move(src, dst)
            elif os.path.isdir(src):
                shutil.copytree(src, os.path.join(dst, os.path.basename(src)) if os.path.isdir(dst) else dst)
            else:
                shutil.copy2(src, dst)
            return {"ok": True, "msg": f"{op}d to {dst}"}
        except Exception as ex:
            return {"ok": False, "error": str(ex)}
    return {"ok": False, "error": f"unknown op {op}"}

_fs_list_cache = {}   # (agent, path.lower) -> (epoch, result) - folder listings are
_FS_TTL = 45          # slow on cloud mounts (RaiDrive hits the network); cache 45s.

def fs_cache_bust(agent):
    """Drop every cached listing for one PC (called after any mutation there)."""
    for k in [k for k in _fs_list_cache if k[0] == agent]:
        _fs_list_cache.pop(k, None)

def fs_op(agent, op, args):
    """Filesystem op on any PC: local fast-path on the brain host, agent job
    (listdir/fsearch/delete/copy/move) elsewhere. Uniform result shape."""
    real = resolve_agent(agent) or agent
    dev = next((d for d in list_devices() if d["agent"] == real), None)
    if not dev:
        return {"ok": False, "error": f"no PC named '{agent}'"}
    if op == "list":
        key = (real, str(args.get("path", "")).lower().rstrip("\\"))
        hit = _fs_list_cache.get(key)
        if hit and time.time() - hit[0] < _FS_TTL:
            return {**hit[1], "cached": True}
    if op in ("delete", "copy", "move"):
        fs_cache_bust(real)
    if (dev["host"] or "").lower() == _LOCAL_HOST:
        res = _fs_local(op, args)
        if op == "list" and res.get("ok"):
            _fs_list_cache[key] = (time.time(), res)
        return res
    if not dev["online"]:
        return {"ok": False, "error": f"{real} is offline"}
    jtype = {"list": "listdir", "search": "fsearch", "delete": "delete",
             "copy": "copy", "move": "move"}.get(op)
    if not jtype:
        return {"ok": False, "error": f"unknown op {op}"}
    jid = enqueue(real, jtype, args, by="fs")
    j = wait_for_job(jid, timeout=45)
    if not j or j["status"] not in ("done", "error"):
        return {"ok": False, "error": "timed out waiting for the PC (agent online?)"}
    res = j.get("result") or {}
    if not res.get("ok"):
        return {"ok": False, "error": res.get("stderr") or "failed"}
    out = res.get("stdout") or ""
    if op in ("list", "search"):
        try:
            parsed = json.loads(out) if out.strip() else []
            if isinstance(parsed, dict):   # ConvertTo-Json collapses 1-item arrays
                parsed = [parsed]
            res = {"ok": True, ("items" if op == "list" else "hits"): parsed}
            if op == "list":
                _fs_list_cache[key] = (time.time(), res)
            return res
        except Exception:
            return {"ok": False, "error": "bad listing from agent"}
    return {"ok": True, "msg": out or "done"}

def run_ai_tool(tool, agent, args):
    # Media tools (no agent needed)
    if tool == "request_media":
        title = str(args.get("title", "")).strip()
        year = str(args.get("year", "")).strip()
        if not title:
            return {"error": "title required"}
        try:
            res = claw_request(title, year, "movie", by="ai_request")
            return {"status": res.get("status"), "title": res.get("title", title),
                    "quality": res.get("quality"), "size_gb": res.get("size_gb"),
                    "message": res.get("message")}
        except Exception as e:
            return {"error": f"request failed: {str(e)[:100]}"}

    if tool == "plex_search":
        q = str(args.get("q", "")).strip()
        if len(q) < 2:
            return {"error": "search query too short"}
        try:
            hits = plex_search(q, limit=20)
            return {"results": hits, "count": len(hits)}
        except Exception as e:
            return {"error": f"search failed: {str(e)[:100]}"}

    if tool == "plex_status":
        try:
            st = claw_get("/status")
            if not st:
                return {"error": "PlexClaw not running"}
            return {"library_items": st.get("watch", {}).get("library_items"),
                    "never_watched": st.get("watch", {}).get("never_watched"),
                    "coverage_pct": st.get("watch", {}).get("coverage_pct"),
                    "recent": st.get("recent", [])[:5]}
        except Exception as e:
            return {"error": f"status check failed: {str(e)[:100]}"}

    if tool == "list_devices":
        return {"devices": [{"agent": d["agent"], "host": d["host"], "online": d["online"],
                             "pia": d["stats"].get("pia"), "cpu": d["stats"].get("cpu"),
                             "mem": d["stats"].get("mem")} for d in list_devices()]}
    # Brain-local tools (answer instantly, no agent job)
    if tool == "history":
        agent = resolve_agent(agent) or agent
        hist = get_history(agent or "", 24)
        if not hist:
            return {"error": "no history for that pc - use an agent name from list_devices"}
        cpus = [h["cpu"] or 0 for h in hist]; mems = [h["mem"] or 0 for h in hist]
        return {"samples": len(hist), "hours": 24,
                "cpu": {"min": min(cpus), "max": max(cpus), "avg": round(sum(cpus) / len(cpus))},
                "mem": {"min": min(mems), "max": max(mems), "avg": round(sum(mems) / len(mems))},
                "drivesNow": hist[-1]["drives"], "drives24hAgo": hist[0]["drives"],
                "fullInDays": compute_forecasts().get(agent, {})}
    if tool == "audit":
        try:
            n = min(int(args.get("n", 15) or 15), 40)
        except Exception:
            n = 15
        try:
            lines = [l.strip() for l in open(AUDIT_F, encoding="utf-8").readlines()[-n:]]
        except Exception:
            lines = []
        return {"audit": lines}
    if tool == "job_status":
        try:
            return get_job(int(args.get("id", 0) or 0)) or {"error": "no such job"}
        except Exception:
            return {"error": "bad job id"}
    if tool == "fleet_search":
        q = str(args.get("q", "")).strip()
        if len(q) < 2:
            return {"error": "query too short (2+ chars)"}
        audit("ai_search", tool="fleet_search", query=q)
        return fleet_search(q, max_per=30)

    # Hermes skills integration (native, no gateway)
    if tool == "browser_task":
        task = str(args.get("task", "")).strip()
        if not task:
            return {"error": "task description required"}
        audit("ai_hermes", skill="browser-automation", task=task)
        return hermes_browser_task(task)

    if tool == "ocr_extract":
        task = str(args.get("task", "")).strip()
        if not task:
            return {"error": "task description required"}
        audit("ai_hermes", skill="productivity", action="ocr", task=task)
        return hermes_productivity_task("ocr", {"task": task})

    if tool == "email_draft":
        to = str(args.get("to", "")).strip()
        subject = str(args.get("subject", "")).strip()
        body = str(args.get("body", "")).strip()
        if not to or not subject:
            return {"error": "to + subject required"}
        audit("ai_hermes", skill="productivity", action="email", to=to)
        return hermes_productivity_task("email", {"to": to, "subject": subject, "body": body})

    if tool == "clipboard_paste":
        text = str(args.get("text", "")).strip()
        if not text:
            return {"error": "text required"}
        audit("ai_hermes", skill="productivity", action="clipboard")
        return hermes_productivity_task("clipboard", {"text": text})

    if tool == "workflow_chain":
        steps = args.get("steps", [])
        if not isinstance(steps, list) or not steps:
            return {"error": "steps array required"}
        audit("ai_hermes", skill="workflow-orchestrator", step_count=len(steps))
        return hermes_workflow_task(steps)

    if tool == "windows_admin":
        task = str(args.get("task", "")).strip()
        if not task:
            return {"error": "task description required"}
        audit("ai_hermes", skill="windows-admin", task=task)
        return hermes_admin_task(task)

    if not agent:
        return {"error": "agent required"}

    fsmap = {"listdir": "list", "search_files": "search", "copy_file": "copy",
             "move_file": "move", "delete_file": "delete"}
    if tool in fsmap:
        audit("ai_fs", tool=tool, agent=agent, args=args)
        return fs_op(agent, fsmap[tool], args or {})

    # New system tools
    sysmap = {"rename_file": "rename", "archive": "archive", "processes": "processes",
              "disk_cleanup": "disk-cleanup", "netstat": "netstat", "gpu_status": "gpu-status",
              "battery": "battery", "get_hash": "get-file-hash"}
    if tool in sysmap:
        jtype = sysmap[tool]
        real = resolve_agent(agent)
        if not real:
            return {"error": f"no PC named '{agent}'"}
        dev = next((d for d in list_devices() if d["agent"] == real), None)
        if dev and not dev["online"]:
            return {"error": f"{real} is offline"}
        audit("ai_sys", tool=tool, agent=agent, args=args)
        jid = enqueue(real, jtype, args, by="ai")
        j = wait_for_job(jid, timeout=45)
        return {"agent": real, "job": jid, "status": j["status"] if j else "timeout",
                "result": (j["result"] if j else None)}
    typ = {"status": "status", "install": "install", "pia": "pia", "play": "play",
           "open": "open", "run": "run", "power": "power"}.get(tool)
    if not typ:
        return {"error": f"unknown tool {tool}"}
    real = resolve_agent(agent)
    if not real:
        valid = ", ".join(d["agent"] for d in list_devices())
        return {"error": f"no PC named '{agent}'. Valid agent names: {valid}"}
    dev = next((d for d in list_devices() if d["agent"] == real), None)
    if dev and not dev["online"]:
        return {"error": f"{real} is offline right now, so the job can't run"}

    # Special handling for 'open' tool: resolve app names to args
    job_args = args
    if typ == "open" and args.get("app"):
        app_args = resolve_app(args["app"])
        if app_args:
            job_args = app_args

    jid = enqueue(real, typ, job_args, by="ai")
    j = wait_for_job(jid, timeout=45)
    return {"agent": real, "job": jid, "status": j["status"] if j else "timeout",
            "result": (j["result"] if j else None)}

def ai_chat(user_msgs, prefer=None, max_steps=5):
    """user_msgs: [{role,content}] (no system). Returns {reply, provider, trace}."""
    try:
        snapshot = "\n\nLIVE FLEET SNAPSHOT (just now):\n" + compose_digest()
    except Exception:
        snapshot = ""
    msgs = [{"role": "system", "content": AI_TOOLS_DOC + snapshot}] + user_msgs
    trace = []
    provider = None
    for _ in range(max_steps):
        res = ai_complete(msgs, prefer=prefer, max_tokens=700)
        if not res:
            return {"reply": "No AI provider is configured/reachable. Add a key in Settings.", "provider": None, "trace": trace}
        provider = res["provider"]
        text = res["text"]
        m = re.search(r"```json\s*(\{.*?\})\s*```", text, re.S) or re.search(r"^\s*(\{.*\})\s*$", text, re.S)
        if not m:
            return {"reply": text.strip(), "provider": provider, "trace": trace}
        try:
            call = json.loads(m.group(1))
        except Exception:
            return {"reply": text.strip(), "provider": provider, "trace": trace}
        tool = call.get("tool"); agent = call.get("agent", ""); args = call.get("args", {})
        result = run_ai_tool(tool, agent, args)
        trace.append({"tool": tool, "agent": agent, "args": args, "result": result})
        msgs.append({"role": "assistant", "content": text})
        msgs.append({"role": "user", "content": "tool result: " + json.dumps(result)[:2000]})
    return {"reply": "(stopped after max steps)", "provider": provider, "trace": trace}

# ---- Hermes Integration (native skills) ------------------------------------
# Hermes skills: desktop-control, browser-automation, windows-admin, productivity, workflow-orchestrator
HERMES_DIR = os.path.join(os.path.dirname(SCRIPT_DIR), "Hermes")

def hermes_browser_task(task):
    """Browser automation via Hermes skills."""
    return {"task": task, "skill": "browser-automation", "note": "Navigate, click, type, extract, screenshot"}

def hermes_productivity_task(task_type, args):
    """Productivity tasks: clipboard, OCR, email, notes."""
    return {"type": task_type, "skill": "productivity", "args": args}

def hermes_workflow_task(steps):
    """Multi-step workflows via Hermes."""
    return {"steps": steps, "skill": "workflow-orchestrator", "note": "Execute chains of tasks"}

def hermes_admin_task(task):
    """Windows admin via Hermes: services, registry, tasks, network."""
    return {"task": task, "skill": "windows-admin"}

# ---- Plex ------------------------------------------------------------------
PLEXCLAW_DIR = r"C:\Users\BigBory\Documents\PlexClaw"
def plex_cfg():
    cfg = load_json(PLEX_F, {"baseUrl": "http://192.168.1.174:32400", "token": ""})
    if not cfg.get("token"):
        # Auto-source the token from PlexClaw (same box) so it's never re-pasted.
        try:
            pc = {}
            for f in ("settings.json", "secrets.local.json"):
                p = os.path.join(PLEXCLAW_DIR, f)
                if os.path.exists(p):
                    pc.update(json.load(open(p, encoding="utf-8-sig")))
            tok = pc.get("plex_token", "")
            if tok:
                url = pc.get("plex_url") or cfg.get("baseUrl") or "http://192.168.1.174:32400"
                # Normalize localhost -> LAN IP so play URLs work on OTHER PCs' VLC.
                if "localhost" in url or "127.0.0.1" in url:
                    url = "http://192.168.1.174:32400"
                cfg = {"baseUrl": url, "token": tok}
        except Exception:
            pass
    return cfg

def plex_get(path, params=None):
    cfg = plex_cfg()
    if not cfg.get("token"):
        raise RuntimeError("no plex token set")
    q = dict(params or {}); q["X-Plex-Token"] = cfg["token"]
    url = cfg["baseUrl"].rstrip("/") + path + "?" + urllib.parse.urlencode(q)
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    with urllib.request.urlopen(req, timeout=15) as r:
        return json.loads(r.read().decode("utf-8"))

def plex_sections():
    d = plex_get("/library/sections")
    return [{"key": x["key"], "title": x["title"], "type": x.get("type")}
            for x in d.get("MediaContainer", {}).get("Directory", [])]

def plex_items(section, limit=200):
    d = plex_get(f"/library/sections/{section}/all")
    out = []
    for v in d.get("MediaContainer", {}).get("Metadata", [])[:limit]:
        out.append({"ratingKey": v.get("ratingKey"), "title": v.get("title"),
                    "year": v.get("year"), "type": v.get("type"),
                    "thumb": v.get("thumb")})
    return out

def plex_search(q, limit=50):
    d = plex_get("/search", {"query": q})
    out = []
    for v in d.get("MediaContainer", {}).get("Metadata", [])[:limit]:
        out.append({"ratingKey": v.get("ratingKey"), "title": v.get("title"),
                    "year": v.get("year"), "type": v.get("type"), "thumb": v.get("thumb")})
    return out

def plex_play_url(rating_key):
    cfg = plex_cfg()
    d = plex_get(f"/library/metadata/{rating_key}")
    meta = d.get("MediaContainer", {}).get("Metadata", [])
    if not meta:
        raise RuntimeError("item not found")
    part = meta[0]["Media"][0]["Part"][0]["key"]
    return cfg["baseUrl"].rstrip("/") + part + "?X-Plex-Token=" + cfg["token"]

def plex_thumb_bytes(thumb):
    cfg = plex_cfg()
    url = cfg["baseUrl"].rstrip("/") + thumb + ("&" if "?" in thumb else "?") + "X-Plex-Token=" + cfg["token"]
    with urllib.request.urlopen(url, timeout=10) as r:
        return r.read(), r.headers.get("Content-Type", "image/jpeg")

# ---- PlexClaw bridge (media engine on this same box, loopback only) --------
def claw_get(path, timeout=4):
    try:
        return http_json("GET", CLAW_URL + path, timeout=timeout)
    except Exception:
        return None

def claw_post(path, body, timeout=90):
    try:
        return http_json("POST", CLAW_URL + path, {"content-type": "application/json"}, body, timeout=timeout)
    except Exception:
        return None

def claw_request(query, year="", mtype="movie", by="dashboard"):
    """Hand a media request to PlexClaw's download pipeline and remember it so
    the rules loop can announce when it lands in Plex."""
    res = claw_post("/request", {"query": query, "year": year, "type": mtype})
    if res is None:
        return {"status": "offline", "message": "PlexClaw engine isn't running on the server"}
    if res.get("status") == "ok":
        pend = load_json(REQUESTS_F, {"requests": []})
        pend["requests"].append({"query": query, "title": res.get("title", query),
                                 "at": now_iso(), "by": by})
        save_json(REQUESTS_F, pend)
    audit("claw_request", query=query, status=res.get("status"), by=by)
    return res

def check_request_arrivals():
    """Match pending requests against Plex's recently-added; returns messages
    to send and prunes matched/expired entries."""
    pend = load_json(REQUESTS_F, {"requests": []})
    if not pend["requests"]:
        return []
    st = claw_get("/status")
    if not st:
        return []
    recent = [(r.get("title", ""), r.get("addedAt", 0)) for r in st.get("recent", [])]
    msgs, keep = [], []
    for req in pend["requests"]:
        try:
            req_ts = datetime.fromisoformat(req["at"]).timestamp()
        except Exception:
            req_ts = 0
        words = [w for w in re.split(r"\W+", req["query"].lower()) if len(w) > 2]
        hit = next((t for t, ts in recent
                    if ts > req_ts and words and all(w in t.lower() for w in words)), None)
        if hit:
            msgs.append(f"\"{hit}\" is on Plex now — requested {req['at'][:10]} (done)")
        elif req_ts and time.time() - req_ts > 7 * 86400:
            pass  # expire silently after a week
        else:
            keep.append(req)
    pend["requests"] = keep
    save_json(REQUESTS_F, pend)
    return msgs

# ---- Fleet-wide file search ------------------------------------------------
def fleet_search(query, max_per=40):
    """Ask every online agent to search its own drives in parallel, merge the
    results tagged by PC. Each agent uses Everything (instant) or its flat index."""
    query = (query or "").strip()
    if len(query) < 2:
        return {"results": [], "searched": []}
    online = [d for d in list_devices() if d["online"]]
    jids = {enqueue(d["agent"], "search", {"q": query, "max": max_per}, by="search"): d for d in online}
    results, searched = [], []
    end = time.time() + 12
    pending = dict(jids)
    while pending and time.time() < end:
        for jid in list(pending):
            j = get_job(jid)
            if j and j["status"] in ("done", "error"):
                d = pending.pop(jid)
                searched.append(d["host"])
                try:
                    hits = json.loads((j["result"] or {}).get("stdout") or "[]")
                    if isinstance(hits, dict):
                        hits = [hits]
                    for h in hits[:max_per]:
                        results.append({"host": d["host"], "agent": d["agent"],
                                        "name": h.get("name", ""), "path": h.get("path", "")})
                except Exception:
                    pass
        if pending:
            time.sleep(0.4)
    return {"results": results, "searched": searched, "query": query}

# ---- Network awareness (passive: scan + internet health) -------------------
def _run(cmd, timeout=20):
    import subprocess
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                              creationflags=0x08000000).stdout  # CREATE_NO_WINDOW
    except Exception:
        return ""

def net_scan():
    """Ping-sweep the /24 then read the ARP table -> known/new devices on the LAN.
    Passive awareness only: the brain never touches these devices."""
    myip = ""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.connect(("192.168.1.1", 80)); myip = s.getsockname()[0]; s.close()
    except Exception:
        myip = "192.168.1.174"
    prefix = myip.rsplit(".", 1)[0] + "."
    # Warm the ARP cache with a quick parallel ping sweep.
    threads = []
    for i in range(1, 255):
        t = threading.Thread(target=lambda ip=prefix + str(i): _run(["ping", "-n", "1", "-w", "250", ip], 3))
        t.start(); threads.append(t)
        if len(threads) >= 64:
            for t in threads: t.join()
            threads = []
    for t in threads: t.join()
    arp = _run(["arp", "-a"], 15)
    seen = {}
    for line in arp.splitlines():
        m = re.search(r"(\d+\.\d+\.\d+\.\d+)\s+([0-9a-fA-F]{2}(?:-[0-9a-fA-F]{2}){5})\s+(\w+)", line)
        if not m:
            continue
        ip, mac, typ = m.group(1), m.group(2).lower(), m.group(3)
        if typ != "dynamic" or ip.endswith(".255"):
            continue
        seen[mac] = ip
    prev = load_json(NETDEV_F, {"devices": {}, "firstScan": True})
    known = prev.get("devices", {})
    new_macs = []
    for mac, ip in seen.items():
        if mac in known:
            known[mac]["ip"] = ip
            known[mac]["last"] = now_iso()
        else:
            known[mac] = {"ip": ip, "name": "", "first": now_iso(), "last": now_iso()}
            new_macs.append((mac, ip))
    # Label our own agents' MACs so they don't read as "unknown".
    for d in list_devices():
        dmac = re.sub(r"[^0-9a-f]", "", (d["stats"].get("mac") or "").lower())
        for mac in known:
            if re.sub(r"[^0-9a-f]", "", mac) == dmac and dmac:
                known[mac]["name"] = d["host"]
    first_scan = prev.get("firstScan", True)
    save_json(NETDEV_F, {"devices": known, "firstScan": False, "scanned": now_iso()})
    # On the very first scan everything is "new" - baseline silently.
    return [] if first_scan else new_macs

def net_status():
    return load_json(NETSTAT_F, {"up": None, "downSince": None, "lastMbps": None,
                                 "lastSpeedAt": None, "checked": None})

def internet_probe():
    """One outbound TCP check to a couple of well-known hosts. True = internet up."""
    for host, port in (("1.1.1.1", 53), ("8.8.8.8", 53)):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(3); s.connect((host, port)); s.close()
            return True
        except Exception:
            continue
    return False

def speed_sample():
    """Rough down-Mbps from a ~5MB Cloudflare test file. Best-effort, hourly."""
    try:
        t0 = time.time()
        req = urllib.request.Request("https://speed.cloudflare.com/__down?bytes=5000000")
        with urllib.request.urlopen(req, timeout=30) as r:
            n = len(r.read())
        dt = time.time() - t0
        if dt > 0:
            return round((n * 8) / dt / 1_000_000, 1)
    except Exception:
        pass
    return None

# ---- Backups ---------------------------------------------------------------
def backups_cfg():
    return load_json(BACKUPS_F, {"jobs": []})

def run_backup(job):
    """job = {agent, name, src, remote}. Enqueues an rclone copy on the target agent."""
    args = {"name": job["name"], "src": job["src"], "remote": job["remote"]}
    return enqueue(job["agent"], "backup", args, by="backup")

# ---- Alerts + Telegram -----------------------------------------------------
def tg_cfg():
    return load_json(TELEGRAM_F, {"token": "", "ownerId": 0, "enabled": False})

def tg_send(text):
    c = tg_cfg()
    if not c.get("token") or not c.get("ownerId"):
        return False
    try:
        http_json("POST", f"https://api.telegram.org/bot{c['token']}/sendMessage",
                  {"content-type": "application/json"},
                  {"chat_id": c["ownerId"], "text": text})
        return True
    except Exception:
        return False

def get_history(agent, hours=24):
    since = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
    with _db_lock, db() as c:
        rows = c.execute("SELECT t,cpu,mem,drives FROM history WHERE agent=? AND t>=? ORDER BY t",
                         (agent, since)).fetchall()
    return [{"t": r["t"], "cpu": r["cpu"], "mem": r["mem"],
             "drives": json.loads(r["drives"] or "[]")} for r in rows]

_forecast_cache = {"at": 0.0, "data": {}}

def compute_forecasts():
    """Per local drive: 'full in ~N days' from the free-space trend (first vs last
    sample over 48h). Only shown for a real drop (>=2GB over >=45min) within 60d."""
    if time.time() - _forecast_cache["at"] < 900:
        return _forecast_cache["data"]
    out = {}
    for d in list_devices():
        hist = get_history(d["agent"], 48)
        if len(hist) < 2:
            continue
        first, last = hist[0], hist[-1]
        try:
            span_days = (datetime.fromisoformat(last["t"]) - datetime.fromisoformat(first["t"])).total_seconds() / 86400
        except Exception:
            continue
        if span_days < 0.03:
            continue
        f0 = {x["l"]: x["f"] for x in first["drives"]}
        for x in last["drives"]:
            l, free = x.get("l"), x.get("f")
            if l not in f0 or free is None or f0[l] is None:
                continue
            drop = f0[l] - free
            if drop >= 2:
                days = free / (drop / span_days)
                if days <= 60:
                    out.setdefault(d["agent"], {})[l] = round(days, 1)
    _forecast_cache["at"] = time.time()
    _forecast_cache["data"] = out
    return out

# ---- Rules engine: the proactive half of the brain --------------------------
DEFAULT_RULES = {
    "driveFull":     {"on": True, "pct": 90},
    "offline":       {"on": True, "mins": 10},
    "vpnDrop":       {"on": True},
    "jobFail":       {"on": True},
    "newDevice":     {"on": False},   # noisy in a busy house (30+ devices) - opt-in
    "internet":      {"on": True},
    "digest":        {"on": True, "hour": 7, "ai": False},
    "nightlyBackup": {"on": True, "hour": 2},
}

def rules_cfg():
    cfg = load_json(RULES_F, None)
    if not cfg:
        cfg = {"rules": json.loads(json.dumps(DEFAULT_RULES))}
        save_json(RULES_F, cfg)
    for k, v in DEFAULT_RULES.items():
        cfg.setdefault("rules", {}).setdefault(k, v)
    return cfg

def compose_digest():
    devs = list_devices()
    lines = ["Home Brain — " + datetime.now().strftime("%a %b %d, %I:%M %p")]
    lines.append("PCs: " + (" · ".join(f"{'[online]' if d['online'] else '[offline]'} {d['host']}" for d in devs) or "none enrolled"))
    lines.append("VPN: " + (" · ".join(f"{d['host']}: {d['stats'].get('pia', '?')}" for d in devs if d["online"]) or "—"))
    fc = compute_forecasts()
    hot = []
    for d in devs:
        for dr in d["stats"].get("drives", []):
            if dr.get("network") or dr.get("usedPct", 0) < 80:
                continue
            fd = (fc.get(d["agent"]) or {}).get(dr.get("letter"))
            extra = f", full in ~{round(fd)}d" if fd else ""
            hot.append((dr["usedPct"], f"  {d['host']} {dr['letter']}: {dr['usedPct']}% ({dr.get('freeGB')}GB free{extra})"))
    hot.sort(reverse=True)
    if hot:
        lines.append("Disks ≥80%:")
        lines += [h[1] for h in hot[:6]]
    else:
        lines.append("Disks: all under 80%")
    b = load_json(MAINT_F, {}).get("lastBackup") or {}
    if b.get("ok"):
        lines.append("Self-backup: OK " + b.get("at", "")[:16].replace("T", " "))
    elif b:
        lines.append("Self-backup: FAILED " + (b.get("error") or "failed")[:80])
    else:
        lines.append("Self-backup: not yet run")
    since = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
    with _db_lock, db() as c:
        tot = c.execute("SELECT COUNT(*) FROM jobs WHERE updated>=?", (since,)).fetchone()[0]
        errs = c.execute("SELECT COUNT(*) FROM jobs WHERE updated>=? AND status='error'", (since,)).fetchone()[0]
    lines.append(f"Jobs 24h: {tot - errs} ok" + (f", {errs} failed" if errs else ""))
    ns = net_status()
    if ns.get("up") is not None:
        net_line = "Internet: " + ("up" if ns.get("up") else "DOWN")
        if ns.get("lastMbps"):
            net_line += f" ({ns['lastMbps']} Mbps)"
        lines.append(net_line)
    dev = load_json(NETDEV_F, {"devices": {}})
    if dev.get("devices"):
        lines.append(f"Network: {len(dev['devices'])} devices seen on Wi-Fi")
    return "\n".join(lines)

def ai_digest_text():
    """The digest, optionally rewritten by the AI into a friendly summary
    (numbers kept below it). Falls back to the raw digest if no provider works."""
    raw = compose_digest()
    if not rules_cfg()["rules"].get("digest", {}).get("ai"):
        return raw
    # Prefer the free local model (Ollama on the gaming PC) for the digest so
    # it costs nothing; falls back to the default cloud provider if it's down.
    res = ai_complete([
        {"role": "system", "content": "You summarize a home-network status report for its owner. Reply with 2-4 warm plain-English sentences. Lead with anything needing attention (nearly-full disks, offline PCs, failed jobs/backups); if all is well, say so briefly. No markdown."},
        {"role": "user", "content": raw}], prefer="ollama", max_tokens=250)
    if res and (res.get("text") or "").strip():
        return res["text"].strip() + "\n\n" + raw
    return raw

def netwatch_loop():
    """Passive network awareness: internet up/down every 60s, hourly speed sample,
    ARP device scan every 30 min. Alerts are emitted through the rules loop's
    state file so they respect the same Telegram gate + dedup."""
    time.sleep(30)
    last_scan = 0.0
    last_speed = 0.0
    while True:
        try:
            r = rules_cfg()["rules"]
            st = net_status()
            tcfg = tg_cfg()
            tg_on = bool(tcfg.get("enabled") and tcfg.get("token"))
            # Internet up/down
            up = internet_probe()
            if r.get("internet", {}).get("on"):
                if st.get("up") is True and not up:
                    st["downSince"] = now_iso()
                    if tg_on: tg_send("Internet appears DOWN")
                elif st.get("up") is False and up and st.get("downSince"):
                    try:
                        secs = (datetime.now(timezone.utc) - datetime.fromisoformat(st["downSince"])).total_seconds()
                        mins = int(secs / 60)
                    except Exception:
                        mins = 0
                    if tg_on: tg_send(f"Internet is back (was down ~{mins} min)")
                    st["downSince"] = None
            st["up"] = up
            st["checked"] = now_iso()
            # Hourly speed sample (only while online)
            if up and time.time() - last_speed > 3600:
                last_speed = time.time()
                mbps = speed_sample()
                if mbps:
                    st["lastMbps"] = mbps
                    st["lastSpeedAt"] = now_iso()
            save_json(NETSTAT_F, st)
            # Device scan every 30 min
            if time.time() - last_scan > 1800:
                last_scan = time.time()
                new_macs = net_scan()
                if r.get("newDevice", {}).get("on") and tg_on:
                    for mac, ip in new_macs:
                        tg_send(f"New device joined Wi-Fi: {ip} ({mac})")
        except Exception as e:
            audit("netwatch_error", err=str(e)[:200])
        time.sleep(60)

def rules_loop():
    """Every 60s: evaluate the enabled rules against live fleet state. Alert
    states are tracked even while Telegram is off, so nothing false fires when
    the bot is switched on later."""
    while True:
        time.sleep(60)
        try:
            r = rules_cfg()["rules"]
            state = load_json(ALERTS_F, {})
            tcfg = tg_cfg()
            tg_on = bool(tcfg.get("enabled") and tcfg.get("token"))
            def send(msg):
                if tg_on:
                    tg_send(msg)
            devs = list_devices()
            now = time.time()

            if r["offline"].get("on"):
                mins = float(r["offline"].get("mins", 10) or 10)
                for d in devs:
                    a = d["agent"]
                    if d["online"]:
                        if state.get(f"{a}:offAlerted"):
                            send(f"{d['host']} is back online")
                        state[f"{a}:offSince"] = None
                        state[f"{a}:offAlerted"] = False
                    else:
                        if not state.get(f"{a}:offSince"):
                            state[f"{a}:offSince"] = now
                        elif not state.get(f"{a}:offAlerted") and now - float(state[f"{a}:offSince"]) >= mins * 60:
                            send(f"{d['host']} has been offline for over {int(mins)} min")
                            state[f"{a}:offAlerted"] = True

            if r["vpnDrop"].get("on"):
                for d in devs:
                    pia = d["stats"].get("pia")
                    k = f"{d['agent']}:pia"
                    if d["online"] and pia == "Disconnected" and state.get(k) not in (None, "Disconnected"):
                        send(f"VPN (PIA) turned OFF on {d['host']}")
                    state[k] = pia

            if r["driveFull"].get("on"):
                pct = float(r["driveFull"].get("pct", 90) or 90)
                fc = compute_forecasts()
                for d in devs:
                    for dr in d["stats"].get("drives", []):
                        if dr.get("network"):
                            continue
                        k = f"{d['agent']}:drive:{dr.get('letter')}"
                        if dr.get("usedPct", 0) >= pct:
                            if not state.get(k):
                                fd = (fc.get(d["agent"]) or {}).get(dr.get("letter"))
                                extra = f", full in ~{round(fd)}d" if fd else ""
                                send(f"{d['host']} drive {dr.get('letter')}: {dr.get('usedPct')}% full ({dr.get('freeGB')}GB left{extra})")
                            state[k] = True
                        elif dr.get("usedPct", 0) < pct - 3:
                            state[k] = False

            if r["jobFail"].get("on"):
                with _db_lock, db() as c:
                    mx = c.execute("SELECT MAX(id) FROM jobs").fetchone()[0] or 0
                    if state.get("lastJobId") is None:
                        rows = []          # first run: don't replay history
                    else:
                        rows = c.execute("SELECT id,agent,type,result FROM jobs WHERE id>? AND status='error' ORDER BY id",
                                         (int(state["lastJobId"]),)).fetchall()
                for row in rows:
                    try:
                        errtxt = (json.loads(row["result"] or "{}").get("stderr") or "")[:120]
                    except Exception:
                        errtxt = ""
                    send(f"Job #{row['id']} ({row['type']}) failed on {row['agent']}: {errtxt}")
                state["lastJobId"] = mx

            today = datetime.now().strftime("%Y-%m-%d")
            hournow = datetime.now().hour
            if r["digest"].get("on") and hournow == int(r["digest"].get("hour", 7) or 7) and state.get("digestDate") != today:
                state["digestDate"] = today
                send(ai_digest_text())
            if r["nightlyBackup"].get("on") and hournow == int(r["nightlyBackup"].get("hour", 2) or 2) and state.get("backupDate") != today:
                state["backupDate"] = today
                for j in backups_cfg().get("jobs", []):
                    try:
                        run_backup(j)
                    except Exception:
                        pass

            # media requests that just landed in Plex -> tell the owner
            try:
                for m in check_request_arrivals():
                    send(m)
            except Exception:
                pass

            if now - float(state.get("histPrune") or 0) > 3600:
                state["histPrune"] = now
                cutoff = (datetime.now(timezone.utc) - timedelta(days=14)).isoformat()
                with _db_lock, db() as c:
                    c.execute("DELETE FROM history WHERE t<?", (cutoff,))

            save_json(ALERTS_F, state)
        except Exception as e:
            audit("rules_error", err=str(e)[:200])

def tg_save_incoming_file(msg, token):
    """A photo or document sent to the bot -> saved into HomeShare, which
    Syncthing propagates to every PC. Returns a status string for the owner,
    or None if the message carried no file. Screenshots are the main use:
    send one to the bot and it lands in C:\\HomeShare\\Screenshots on all PCs."""
    file_id = None
    orig_name = None
    kind = "file"
    photos = msg.get("photo")
    doc = msg.get("document")
    if photos:                       # photo: an array of sizes, last is largest
        file_id = photos[-1].get("file_id")
        kind = "photo"
    elif doc:
        file_id = doc.get("file_id")
        orig_name = doc.get("file_name")
        kind = "document"
    if not file_id:
        return None
    try:
        # getFile -> file_path, then download from the file endpoint
        u = f"https://api.telegram.org/bot{token}/getFile?file_id={quote(file_id)}"
        with urllib.request.urlopen(u, timeout=30) as r:
            fp = json.loads(r.read().decode("utf-8")).get("result", {}).get("file_path")
        if not fp:
            return "Could not fetch that file from Telegram."
        ext = os.path.splitext(fp)[1] or (".jpg" if kind == "photo" else "")
        cap = (msg.get("caption") or "").strip()
        # Build a safe filename: caption (if any) else timestamped, keep the ext.
        base = re.sub(r"[^A-Za-z0-9 _.-]", "", (orig_name or cap))[:60].strip()
        if not base:
            base = datetime.now().strftime("shot-%Y%m%d-%H%M%S")
        if not os.path.splitext(base)[1]:
            base += ext
        os.makedirs(HS_INBOX, exist_ok=True)
        dest = os.path.join(HS_INBOX, base)
        n = 1
        while os.path.exists(dest):    # never overwrite an existing file
            stem, e = os.path.splitext(base)
            dest = os.path.join(HS_INBOX, f"{stem}_{n}{e}"); n += 1
        durl = f"https://api.telegram.org/file/bot{token}/{fp}"
        with urllib.request.urlopen(durl, timeout=60) as r:
            data = r.read()
        with open(dest, "wb") as f:
            f.write(data)
        audit("tg_file_saved", name=os.path.basename(dest), bytes=len(data), kind=kind)
        return (f"Saved to HomeShare -> Screenshots/{os.path.basename(dest)} "
                f"({len(data)//1024} KB). It will sync to every PC and shows in "
                f"the dashboard's HomeShare tab.")
    except Exception as e:
        return f"Failed to save that file: {str(e)[:120]}"

def telegram_loop():
    """Owner-locked long-poll bot. Commands mirror dashboard actions."""
    offset = 0
    while True:
        c = tg_cfg()
        if not c.get("enabled") or not c.get("token"):
            time.sleep(10); continue
        try:
            url = f"https://api.telegram.org/bot{c['token']}/getUpdates?timeout=30&offset={offset}"
            with urllib.request.urlopen(url, timeout=40) as r:
                data = json.loads(r.read().decode("utf-8"))
            for u in data.get("result", []):
                offset = u["update_id"] + 1
                msg = u.get("message", {})
                sender = msg.get("chat", {}).get("id")
                if str(sender) != str(c.get("ownerId")):
                    # Not the owner: ignore the message, but remember who knocked
                    # so a misconfigured ownerId can be fixed from the dashboard
                    # (common mistake: pasting the bot's own id from the token).
                    if sender:
                        cfg = tg_cfg()
                        frm = msg.get("from", {}) or {}
                        cfg["lastSender"] = {"id": sender, "name": frm.get("first_name", ""),
                                             "user": frm.get("username", ""), "at": now_iso()}
                        save_json(TELEGRAM_F, cfg)
                    continue  # hard owner whitelist
                # A photo/document from the owner is saved into HomeShare;
                # text messages remain commands.
                saved = tg_save_incoming_file(msg, c["token"])
                if saved is not None:
                    tg_send(saved)
                else:
                    tg_handle(msg.get("text", ""))
        except Exception:
            time.sleep(5)

def tg_handle(text):
    t = (text or "").strip()
    parts = t.split()
    cmd = parts[0].lower() if parts else ""
    if cmd in ("/start", "/help", "help"):
        tg_send("Home Dashboard + Hermes (Unified)\n\n"
                "FLEET (all PCs):\n"
                "- open Claude/code on mainpc, laptop\n"
                "- restart/wake any PC\n"
                "- processes, GPU, network, battery\n"
                "- find/rename/compress/hash files\n"
                "- search all PCs fleet-wide\n\n"
                "HERMES SKILLS (mainpc automation):\n"
                "- browser: navigate, click, search, extract\n"
                "- OCR: extract text from images\n"
                "- email: draft and compose\n"
                "- clipboard: set/get clipboard\n"
                "- workflows: multi-step automation chains\n"
                "- windows-admin: services, registry, tasks\n\n"
                "MEDIA:\n"
                "- request movies/shows\n"
                "- search/play Plex\n\n"
                "SYSTEM:\n"
                "- disk status, cleanup\n"
                "- internet health\n\n"
                "Natural language commands.")
    elif cmd == "/devices":
        ds = list_devices()
        tg_send("\n".join(f"{'[online]' if d['online'] else '[offline]'} {d['host']} ({d['agent']}) cpu {d['stats'].get('cpu','?')}% pia {d['stats'].get('pia','?')}" for d in ds) or "no devices")
    elif cmd == "/status" and len(parts) >= 2:
        d = next((x for x in list_devices() if x["agent"] == parts[1]), None)
        tg_send(json.dumps(d["stats"], indent=1) if d else "no such pc")
    elif cmd == "/disk":
        lines = []
        for d in list_devices():
            for dr in d["stats"].get("drives", []):
                if dr.get("usedPct", 0) >= 80:
                    lines.append(f"{d['host']} {dr['letter']}: {dr['usedPct']}% ({dr['freeGB']}GB free)")
        tg_send("\n".join(lines) or "all drives under 80%")
    elif cmd == "/pia" and len(parts) >= 3:
        jid = enqueue(parts[1], "pia", {"action": parts[2]}, by="telegram")
        j = wait_for_job(jid, 30)
        tg_send(f"pia {parts[2]} on {parts[1]}: {(j['result'] or {}).get('stdout') if j else 'timeout'}")
    elif cmd == "/install" and len(parts) >= 3:
        enqueue(parts[1], "install", {"id": parts[2]}, by="telegram")
        tg_send(f"installing {parts[2]} on {parts[1]} (queued)")
    elif cmd == "/request" and len(parts) >= 2:
        args = parts[1:]
        year = args[-1] if args[-1].isdigit() and len(args[-1]) == 4 else ""
        q = " ".join(args[:-1] if year else args)
        tg_send(f"Asking PlexClaw to grab: {q} {year}".strip() + " ...")
        res = claw_request(q, year, "movie", by="telegram")
        s = res.get("status")
        if s == "ok":
            tg_send(f"OK: Downloading {res.get('title', q)} ({res.get('quality', '?')}, {res.get('size_gb', '?')}GB) — I'll ping you when it's on Plex")
        elif s == "not_found":
            tg_send(f"Nothing found for \"{q}\" — try adding the year")
        elif s == "no_quality":
            tg_send(f"Only bad copies (CAM/TS) of \"{q}\" exist right now — try again in a few weeks")
        elif s == "offline":
            tg_send("PlexClaw engine isn't running on the server right now")
        else:
            tg_send(f"{res.get('message', s)}")
    elif cmd == "/play" and len(parts) >= 3:
        try:
            url = plex_play_url(parts[2])
            enqueue(parts[1], "play", {"url": url}, by="telegram")
            tg_send(f"playing on {parts[1]}")
        except Exception as e:
            tg_send(f"play failed: {e}")
    elif cmd == "/power" and len(parts) >= 3:
        ag = resolve_agent(parts[1]) or parts[1]
        action = parts[2].lower()
        if action not in ("restart", "sleep", "shutdown"):
            tg_send("usage: /power <pc> restart|sleep|shutdown"); return
        enqueue(ag, "power", {"action": action}, by="telegram")
        tg_send(f"{action} queued on {parts[1]}")
    elif cmd == "/wake" and len(parts) >= 2:
        ag = resolve_agent(parts[1]) or parts[1]
        mac = ""
        for d in list_devices():
            if d["agent"] == ag:
                mac = (d["stats"] or {}).get("mac", "") or ""
        if not mac:
            tg_send(f"no saved MAC for {parts[1]} yet — needs one online heartbeat first"); return
        try:
            wol_send(mac)
            tg_send(f"Wake-on-LAN sent to {parts[1]}")
        except Exception as e:
            tg_send(f"wake failed: {e}")
    elif cmd == "/run" and len(parts) >= 3:
        ag = resolve_agent(parts[1]) or parts[1]
        jid = enqueue(ag, "run", {"cmd": " ".join(parts[2:])}, by="telegram")
        j = wait_for_job(jid, 30)
        out = ((j or {}).get("result") or {}).get("stdout") or ((j or {}).get("result") or {}).get("stderr") or "timeout"
        tg_send(f"$ {' '.join(parts[2:])}\n{out[:1500]}")
    elif cmd == "/screenshot" and len(parts) >= 2:
        ag = resolve_agent(parts[1]) or parts[1]
        enqueue(ag, "screenshot", {}, by="telegram")
        tg_send(f"screenshot queued on {parts[1]} — view it on the dashboard in a few seconds")
    elif cmd == "/sync":
        targets = [resolve_agent(parts[1]) or parts[1]] if len(parts) >= 2 else [d["agent"] for d in list_devices() if d["online"]]
        lines = []
        for ag in targets:
            jid = enqueue(ag, "syncthing", {"action": "status"}, by="telegram")
            j = wait_for_job(jid, 20)
            r = (j or {}).get("result") or {}
            if r.get("ok"):
                try:
                    s = json.loads(r.get("stdout") or "{}")
                    lines.append(f"{ag}: {s.get('state','?')}, {s.get('needFiles','?')} pending, {s.get('globalFiles','?')} files")
                except Exception:
                    lines.append(f"{ag}: {r.get('stdout','?')}")
            else:
                lines.append(f"{ag}: {(r.get('stderr') or 'no response')[:80]}")
        tg_send("HomeShare sync:\n" + "\n".join(lines))
    elif t.startswith("/"):
        tg_send("unknown command - /help")
    elif t:
        # Natural language: route anything that isn't a slash command to the same
        # AI agent the dashboard's AI chat uses (it can act on the fleet — install,
        # VPN, play, power, browse/search files — not just answer).
        try:
            res = ai_chat([{"role": "user", "content": t}])
            reply = (res.get("reply") or "").strip() or "(no response)"
            if res.get("trace"):
                acted = ", ".join(sorted({str(x.get("tool")) for x in res["trace"] if x.get("tool")}))
                if acted:
                    reply += f"\n\nacted: {acted}"
            tg_send(reply[:3500])
        except Exception as e:
            tg_send(f"AI error: {e}")

# ---- HTTP ------------------------------------------------------------------
class Handler(BaseHTTPRequestHandler):
    server_version = "HomeBrain/2.0"
    def log_message(self, *a): pass

    def _is_loopback(self):
        try:
            return ipaddress.ip_address(self.client_address[0]).is_loopback
        except Exception:
            return False

    def _is_private(self):
        # Loopback OR a private-LAN address (10.x, 172.16-31.x, 192.168.x).
        # The brain is firewalled to the private network, so this = "one of the
        # home PCs" and lets any of them load the dashboard without a token.
        try:
            ip = ipaddress.ip_address(self.client_address[0])
            return ip.is_loopback or ip.is_private
        except Exception:
            return False

    def _token_ok(self, tok):
        # Master token (agents/loopback tooling) OR a valid browser session token.
        return tok == TOKEN or valid_session(tok)

    def _authed(self):
        return self._is_loopback() or self._token_ok(self.headers.get("X-Brain-Token", ""))

    def _body_raw(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n <= 0 or n > 500_000_000:
            return b""
        return self.rfile.read(n)

    def _body(self):
        try:
            raw = self._body_raw()
            return json.loads(raw.decode("utf-8")) if raw else {}
        except Exception:
            return {}

    def _send(self, code, obj, ctype="application/json"):
        body = obj if isinstance(obj, (bytes, str)) else json.dumps(obj)
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "X-Brain-Token, Content-Type")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try: self.wfile.write(body)
        except Exception: pass

    def _send_file_range(self, path, ctype):
        """Stream a file with HTTP Range support, so <video>/<audio> can seek and
        the browser doesn't buffer the whole thing. Reads in chunks (no loading a
        127MB video into memory like _send would)."""
        try:
            size = os.path.getsize(path)
        except Exception:
            return self._send(404, {"error": "not found"})
        rng = self.headers.get("Range", "")
        start, end = 0, size - 1
        partial = False
        m = re.match(r"bytes=(\d*)-(\d*)", rng or "")
        if m:
            if m.group(1): start = int(m.group(1))
            if m.group(2): end = int(m.group(2))
            end = min(end, size - 1)
            if start > end or start >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers(); return
            partial = True
        length = end - start + 1
        self.send_response(206 if partial else 200)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if partial:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()
        try:
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = f.read(min(262144, remaining))
                    if not chunk: break
                    self.wfile.write(chunk)
                    remaining -= len(chunk)
        except Exception:
            pass

    def do_OPTIONS(self):
        self._send(200, {"ok": True})

    # -- YT Grabber reverse proxy --------------------------------------------
    # YT Grabber (Flask, loopback 127.0.0.1:5117) is embedded in the dashboard
    # so it lives on this one server/port instead of an exposed :5117. Its whole
    # URL surface is /ytgrabber (its index) plus /api/*, /media/*, /thumb/* —
    # none of which the brain itself uses. Streams bodies (with Range headers)
    # so in-browser video playback + seeking work.
    YTG_HOST, YTG_PORT = "127.0.0.1", 5117

    def _is_ytg_path(self, path):
        return (path == "/ytgrabber" or path.startswith("/ytgrabber/")
                or path.startswith("/api/") or path.startswith("/media/")
                or path.startswith("/thumb/"))

    def _proxy_ytg(self, method):
        import http.client
        raw = self.path  # path + query, unmodified
        if raw == "/ytgrabber" or raw.startswith("/ytgrabber/"):
            up = raw[len("/ytgrabber"):] or "/"
            if not up.startswith("/"): up = "/" + up
        else:
            up = raw
        body = self._body_raw() if method == "POST" else None
        fwd = {}
        for h in ("Range", "Content-Type", "Accept", "If-Range", "If-None-Match"):
            v = self.headers.get(h)
            if v: fwd[h] = v
        try:
            conn = http.client.HTTPConnection(self.YTG_HOST, self.YTG_PORT, timeout=600)
            conn.request(method, up, body=body, headers=fwd)
            r = conn.getresponse()
        except Exception as e:
            return self._send(502, {"error": "YT Grabber not running", "detail": str(e)})
        self.send_response(r.status)
        passthru = ("content-type", "content-length", "content-range",
                    "accept-ranges", "content-disposition", "cache-control",
                    "last-modified", "etag", "expires")
        for k, v in r.getheaders():
            if k.lower() in passthru:
                self.send_header(k, v)
        self.send_header("Access-Control-Allow-Origin", "*")
        self.end_headers()
        try:
            while True:
                chunk = r.read(65536)
                if not chunk: break
                self.wfile.write(chunk)
        except Exception:
            pass
        finally:
            try: conn.close()
            except Exception: pass

    # -- GET --
    def do_GET(self):
        if self._is_ytg_path(urlparse(self.path).path):
            return self._proxy_ytg("GET")
        p = urlparse(self.path); route = p.path.rstrip("/") or "/"
        q = parse_qs(p.query)
        g = lambda k, d="": (q.get(k, [d])[0])

        if route == "/":
            if os.path.exists(UI_HTML):
                return self._send(200, open(UI_HTML, "rb").read(), "text/html; charset=utf-8")
            return self._send(200, "<h1>Home Brain</h1><p>UI not built yet.</p>", "text/html")
        # PWA shell (public, like the UI itself)
        if route in ("/manifest.json", "/sw.js", "/icon-192.png", "/icon-512.png"):
            fp = os.path.join(SCRIPT_DIR, route.lstrip("/"))
            if not os.path.exists(fp):
                return self._send(404, {"error": "not found"})
            ctype = {"manifest.json": "application/manifest+json", "sw.js": "text/javascript"}.get(
                os.path.basename(fp), "image/png")
            return self._send(200, open(fp, "rb").read(), ctype)
        if route == "/health":
            base = {"ok": True, "service": "home-brain", "version": BRAIN_VERSION,
                    "agentVersion": agent_expected_version(), "time": now_iso()}
            if not self._authed():
                return self._send(200, base)   # public: liveness only, no fleet detail
            m = load_json(MAINT_F, {})
            try: dbsize = os.path.getsize(DB_PATH)
            except Exception: dbsize = 0
            since = (datetime.now(timezone.utc) - timedelta(hours=24)).isoformat()
            with _db_lock, db() as c:
                tot = c.execute("SELECT COUNT(*) FROM jobs WHERE updated>=?", (since,)).fetchone()[0]
                err = c.execute("SELECT COUNT(*) FROM jobs WHERE updated>=? AND status='error'", (since,)).fetchone()[0]
            agents = [{"agent": d["agent"], "host": d["host"], "online": d["online"],
                       "last_seen": d["last_seen"], "ver": d["stats"].get("ver", ""),
                       "launcher": d["stats"].get("launcher"), "persist": d["stats"].get("persist")}
                      for d in list_devices()]
            base.update({"uptimeSec": int(time.time() - START_TIME), "dbBytes": dbsize,
                         "backup": m.get("lastBackup"), "backupDir": m.get("backupDir", ""),
                         "jobs24h": {"total": tot, "errors": err}, "agents": agents})
            return self._send(200, base)
        if route == "/auth/status":
            return self._send(200, {"passwordSet": password_set()})
        if route == "/events":
            # Server-Sent Events: live device stream. EventSource can't set headers,
            # so remote clients pass ?token=; loopback needs nothing.
            if not (self._is_loopback() or self._token_ok(g("token"))):
                return self._send(401, {"error": "unauthorized"})
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Connection", "keep-alive")
            self.send_header("Access-Control-Allow-Origin", "*")
            self.end_headers()
            try:
                while True:
                    payload = json.dumps({"devices": list_devices()})
                    self.wfile.write(("data: " + payload + "\n\n").encode("utf-8"))
                    self.wfile.flush()
                    time.sleep(2)
            except Exception:
                return
        if route == "/agent":
            return self._send(200, open(AGENT_PS, "rb").read(), "text/plain; charset=utf-8") if os.path.exists(AGENT_PS) else self._send(404, {"error": "no agent"})
        if route == "/launcher":
            return self._send(200, open(LAUNCHER_PS, "rb").read(), "text/plain; charset=utf-8") if os.path.exists(LAUNCHER_PS) else self._send(404, {"error": "no launcher"})
        if route == "/bootstrap":
            if not os.path.exists(BOOTSTRAP_PS): return self._send(404, {"error": "no bootstrap"})
            host = self.headers.get("Host", f"127.0.0.1:{PORT}")
            txt = open(BOOTSTRAP_PS, "r", encoding="utf-8").read()
            txt = txt.replace("__BRAIN_URL__", f"http://{host}").replace("__BRAIN_TOKEN__", TOKEN)
            return self._send(200, txt, "text/plain; charset=utf-8")
        if route == "/catalog":
            return self._send(200, load_json(CATALOG_F, {"apps": [], "bundles": []}))
        if route == "/devices":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"devices": list_devices()})
        if route == "/jobs":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"jobs": list_jobs()})
        if route == "/token":  # loopback only - lets the local UI authenticate to itself
            if not self._is_loopback(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"token": TOKEN})
        # ---- history / forecasts / rules ----
        if route == "/history":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            try: hours = min(336, max(1, int(g("hours", "24"))))
            except Exception: hours = 24
            return self._send(200, {"samples": get_history(g("agent"), hours)})
        if route == "/forecasts":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"forecasts": compute_forecasts()})
        if route == "/search":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, fleet_search(g("q")))
        if route == "/net":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            dev = load_json(NETDEV_F, {"devices": {}, "scanned": None})
            devs = [{"mac": m, **v} for m, v in dev.get("devices", {}).items()]
            devs.sort(key=lambda x: tuple(int(o) for o in (x.get("ip", "0.0.0.0").split("."))))
            return self._send(200, {"internet": net_status(), "scanned": dev.get("scanned"), "devices": devs})
        if route == "/rules":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, rules_cfg())
        if route == "/killswitch":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, {"readOnly": read_only()})
        if route == "/screenshot":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            agent = re.sub(r"[^A-Za-z0-9_.-]", "", g("agent"))
            fp = os.path.join(SHOTS_DIR, agent + ".jpg")
            if g("meta"):
                at = None
                if os.path.exists(fp):
                    at = datetime.fromtimestamp(os.path.getmtime(fp), timezone.utc).isoformat()
                return self._send(200, {"optin": shot_optin(g("agent")), "hasShot": os.path.exists(fp), "at": at})
            if os.path.exists(fp):
                return self._send(200, open(fp, "rb").read(), "image/jpeg")
            return self._send(404, {"error": "no screenshot yet"})
        if route == "/share/list":
            # Browse HomeShare in the dashboard. The brain runs on PlexServer and
            # reads C:\HomeShare directly, so no SMB / network-credential prompt.
            if not (self._authed() or self._token_ok(g("t"))): return self._send(401, {"error": "unauthorized"})
            sub = (g("sub") or "").replace("/", "\\").strip("\\")
            base = os.path.abspath(os.path.join(HOMESHARE, sub))
            if not base.startswith(os.path.abspath(HOMESHARE)):   # no traversal out of HomeShare
                return self._send(400, {"error": "bad path"})
            if not os.path.isdir(base):
                return self._send(200, {"cwd": sub, "dirs": [], "files": []})
            IMG = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".svg")
            VID = (".mp4", ".m4v", ".webm", ".mkv", ".mov")
            dirs, files = [], []
            try:
                for name in sorted(os.listdir(base), key=str.lower):
                    if name.startswith(".stfolder") or name.startswith(".sync") or name == ".thumbs": continue
                    full = os.path.join(base, name)
                    rel = (sub + "\\" + name) if sub else name
                    try: st = os.stat(full)
                    except Exception: continue
                    if os.path.isdir(full):
                        dirs.append({"name": name, "rel": rel})
                    else:
                        files.append({"name": name, "rel": rel, "size": st.st_size,
                                      "mtime": datetime.fromtimestamp(st.st_mtime, timezone.utc).isoformat(),
                                      "img": name.lower().endswith(IMG),
                                      "vid": name.lower().endswith(VID)})
            except Exception as e:
                return self._send(500, {"error": str(e)[:200]})
            # Newest files first — screenshots you just sent land at the top.
            files.sort(key=lambda x: x["mtime"], reverse=True)
            return self._send(200, {"cwd": sub, "dirs": dirs, "files": files})
        if route == "/share/file":
            # <img> tags can't send the token header, so accept it as ?t= too.
            if not (self._authed() or self._token_ok(g("t"))): return self._send(401, {"error": "unauthorized"})
            rel = (g("path") or "").replace("/", "\\").strip("\\")
            full = os.path.abspath(os.path.join(HOMESHARE, rel))
            if not full.startswith(os.path.abspath(HOMESHARE)) or not os.path.isfile(full):
                return self._send(404, {"error": "not found"})
            ctypes = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
                      ".gif": "image/gif", ".webp": "image/webp", ".svg": "image/svg+xml",
                      ".pdf": "application/pdf", ".txt": "text/plain; charset=utf-8",
                      ".mp4": "video/mp4", ".m4v": "video/mp4", ".webm": "video/webm",
                      ".mkv": "video/x-matroska", ".mov": "video/quicktime",
                      ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".opus": "audio/ogg"}
            ext = os.path.splitext(full)[1].lower()
            ct = ctypes.get(ext, "application/octet-stream")
            # Range-stream video/audio (seekable, no full-file buffering); small
            # files (images, text) go through the simple in-memory path.
            if ct.startswith(("video/", "audio/")) or os.path.getsize(full) > 5_000_000:
                return self._send_file_range(full, ct)
            try:
                return self._send(200, open(full, "rb").read(), ct)
            except Exception:
                return self._send(500, {"error": "read failed"})
        if route == "/audit":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            try: n = min(int(g("n", "150")), 1000)
            except Exception: n = 150
            entries = []
            try:
                for line in open(AUDIT_F, encoding="utf-8").readlines()[-n:]:
                    line = line.strip()
                    if line:
                        try: entries.append(json.loads(line))
                        except Exception: pass
            except Exception:
                pass
            entries.reverse()  # newest first
            return self._send(200, {"audit": entries})
        # ---- AI ----
        if route == "/ai/keys":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            cfg = ai_cfg(); provs = []
            for n, pp in cfg["providers"].items():
                k = str(pp.get("key", ""))
                provs.append({"id": n, "baseUrl": pp.get("baseUrl", ""), "model": pp.get("model", ""),
                              "style": pp.get("style", "openai"), "hasKey": bool(k.strip()),
                              "masked": (k[:4] + "..." + k[-4:]) if len(k) > 8 else ""})
            return self._send(200, {"providers": provs, "default": cfg.get("default", "")})
        # ---- Plex ----
        if route == "/plex/sections":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            try: return self._send(200, {"sections": plex_sections()})
            except Exception as e: return self._send(200, {"error": str(e), "sections": []})
        if route == "/plex/items":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            try: return self._send(200, {"items": plex_items(g("section"))})
            except Exception as e: return self._send(200, {"error": str(e), "items": []})
        if route == "/plex/search":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            try: return self._send(200, {"items": plex_search(g("q"))})
            except Exception as e: return self._send(200, {"error": str(e), "items": []})
        if route == "/plex/thumb":
            try:
                b, ct = plex_thumb_bytes(g("path")); return self._send(200, b, ct)
            except Exception: return self._send(404, {"error": "no thumb"})
        if route == "/plex/config":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            c = plex_cfg(); return self._send(200, {"baseUrl": c.get("baseUrl", ""), "hasToken": bool(c.get("token"))})
        # ---- PlexClaw bridge ----
        if route == "/claw/status":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            st = claw_get("/status")
            if st is None:
                return self._send(200, {"running": False})
            st["running"] = True
            st["pending"] = load_json(REQUESTS_F, {"requests": []})["requests"]
            return self._send(200, st)
        # ---- backups / telegram config ----
        if route == "/backups":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            return self._send(200, backups_cfg())
        if route == "/telegram":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            c = tg_cfg(); return self._send(200, {"enabled": c.get("enabled", False), "ownerId": c.get("ownerId", 0),
                                                  "hasToken": bool(c.get("token")), "lastSender": c.get("lastSender")})
        # ---- staging file fetch (agents) ----
        if route.startswith("/staging/"):
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            # The staged id embeds the original filename, so /upload percent-encodes
            # it into the fetch URL. Decode before basename() — basename still
            # strips any traversal the decode could reveal.
            fn = os.path.basename(unquote(route.split("/staging/", 1)[1]))
            fp = os.path.join(STAGING, fn)
            if os.path.exists(fp):
                return self._send(200, open(fp, "rb").read(), "application/octet-stream")
            return self._send(404, {"error": "not found"})
        return self._send(404, {"error": "not found"})

    # -- POST --
    def do_POST(self):
        if self._is_ytg_path(urlparse(self.path).path):
            return self._proxy_ytg("POST")
        p = urlparse(self.path); route = p.path.rstrip("/") or "/"
        q = parse_qs(p.query)
        g = lambda k, d="": (q.get(k, [d])[0])

        # Auth (public): log in with the dashboard password to get a token.
        if route == "/login":
            ip = self.client_address[0]
            if login_locked(ip):
                return self._send(429, {"ok": False, "error": "too many attempts - wait 5 minutes"})
            b = self._body()
            if check_password(str(b.get("password", ""))):
                audit("login_ok", ip=ip)
                return self._send(200, {"ok": True, "token": new_session()})
            login_fail(ip)
            audit("login_fail", ip=ip)
            time.sleep(1)  # gentle brute-force slowdown
            return self._send(401, {"ok": False, "error": "wrong password"})
        if route == "/auth/set":
            b = self._body(); pw = str(b.get("password", ""))
            if len(pw) < 3:
                return self._send(400, {"ok": False, "error": "password too short"})
            # Allowed on first run (no password yet), or when already authenticated.
            if password_set() and not self._authed():
                return self._send(403, {"ok": False, "error": "not allowed"})
            set_password(pw)
            return self._send(200, {"ok": True, "token": new_session()})

        # Kill switch: flip the whole brain to read-only (blocks dashboard-initiated
        # actions; agents keep reporting). Always toggleable by an authed user.
        if route == "/killswitch":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); set_read_only(b.get("on"))
            return self._send(200, {"ok": True, "readOnly": read_only()})
        if route == "/auth/signout-all":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            revoke_all_sessions(); audit("signout_all")
            return self._send(200, {"ok": True})

        # Read-only gate: while the kill switch is on, refuse any endpoint that
        # would make something happen out in the fleet. Agent reporting
        # (register/poll/result) and settings are NOT gated - only actions.
        _MUTATING = {"/jobs", "/bundle", "/wol", "/plex/play", "/backup/run",
                     "/claw/request", "/claw/continue", "/screenshot/capture", "/upload", "/transfer"}
        if route in _MUTATING and read_only():
            return self._send(403, {"error": "read-only mode is ON (kill switch) - turn it off in Settings → Security to act"})

        # Agent endpoints
        if route == "/register":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = str(b.get("agent", "")).strip()
            if not agent: return self._send(400, {"error": "agent required"})
            register_device(agent, b.get("host", ""), self.client_address[0], b.get("ts_ip", ""), b.get("caps", []))
            return self._send(200, {"ok": True, "agent": agent})
        if route == "/poll":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = str(b.get("agent", "")).strip()
            if not agent: return self._send(400, {"error": "agent required"})
            return self._send(200, {"jobs": heartbeat_and_fetch(agent, b.get("host", ""), self.client_address[0], b.get("stats", {})),
                                    "agentVersion": agent_expected_version()})
        if route == "/result":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            if b.get("id") is None: return self._send(400, {"error": "id required"})
            save_result(int(b["id"]), b.get("ok", False), b.get("exit"), (b.get("stdout") or "")[:100000], (b.get("stderr") or "")[:100000])
            return self._send(200, {"ok": True})

        # Dashboard endpoints
        if route == "/jobs":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = str(b.get("agent", "")).strip(); jtype = str(b.get("type", "")).strip()
            if not agent or not jtype: return self._send(400, {"error": "agent and type required"})
            return self._send(200, {"ok": True, "id": enqueue(agent, jtype, b.get("args", {}), by=b.get("by", "dashboard"))})
        if route == "/fs":   # Drive browser: list/search/copy/move/delete on any PC
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = str(b.get("agent", "")).strip(); op = str(b.get("op", "")).strip()
            if not agent or not op: return self._send(400, {"error": "agent and op required"})
            if op in ("delete", "copy", "move"):
                audit("fs_" + op, agent=agent, path=b.get("path") or b.get("src"), dst=b.get("dst"))
            return self._send(200, fs_op(agent, op, b))
        if route == "/device/name":   # friendly nickname for a PC (display only)
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = str(b.get("agent", "")); name = str(b.get("name", ""))[:40].strip()
            nicks = load_json(NICKS_F, {})
            if name: nicks[agent] = name
            else: nicks.pop(agent, None)
            save_json(NICKS_F, nicks)
            audit("rename", agent=agent, name=name)
            return self._send(200, {"ok": True})
        if route == "/wol":  # Wake-on-LAN: send a magic packet from the server (on the LAN)
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = b.get("agent", "")
            mac = ""
            for d in list_devices():
                if d["agent"] == agent:
                    mac = (d["stats"] or {}).get("mac", "") or ""
            try:
                wol_send(mac)
                return self._send(200, {"ok": True, "msg": "wake signal sent"})
            except Exception as e:
                return self._send(200, {"ok": False, "error": str(e)})
        if route == "/bundle":  # install a whole bundle on a PC
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = b.get("agent", ""); apps = b.get("apps", [])
            ids = [enqueue(agent, "install", {"id": a}, by="bundle") for a in apps]
            return self._send(200, {"ok": True, "jobs": ids})

        # AI
        if route == "/ai/chat":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            msgs = b.get("messages") or [{"role": "user", "content": b.get("q", "")}]
            return self._send(200, ai_chat(msgs, prefer=b.get("provider")))
        if route == "/ai/keys":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); cfg = ai_cfg(); pid = b.get("provider")
            if pid and pid in cfg["providers"]:
                if b.get("key") is not None: cfg["providers"][pid]["key"] = str(b["key"])
                if b.get("baseUrl") is not None: cfg["providers"][pid]["baseUrl"] = str(b["baseUrl"])
                if b.get("model") is not None: cfg["providers"][pid]["model"] = str(b["model"])
                if b.get("setDefault"): cfg["default"] = pid
                # All OpenRouter slots share one account/key: set it on any
                # openrouter* provider and mirror it to every sibling so the
                # user only ever pastes the key once.
                if pid.startswith("openrouter") and b.get("key") is not None:
                    for sib in cfg["providers"]:
                        if sib.startswith("openrouter"):
                            cfg["providers"][sib]["key"] = str(b["key"])
                save_json(AIKEYS_F, cfg)
                return self._send(200, {"ok": True})
            return self._send(400, {"error": "unknown provider"})

        # Plex
        if route == "/plex/play":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            try:
                url = plex_play_url(b.get("ratingKey"))
                jid = enqueue(b.get("agent", ""), "play", {"url": url}, by="plex")
                return self._send(200, {"ok": True, "id": jid})
            except Exception as e:
                return self._send(200, {"ok": False, "error": str(e)})
        if route == "/plex/config":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); c = plex_cfg()
            if b.get("baseUrl"): c["baseUrl"] = b["baseUrl"]
            if b.get("token") is not None: c["token"] = b["token"]
            save_json(PLEX_F, c); return self._send(200, {"ok": True})

        # Files: upload to staging, then push to a target agent
        if route == "/upload":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            name = os.path.basename(g("name") or "upload.bin")
            raw = self._body_raw()
            sid = secrets.token_hex(8) + "_" + name
            open(os.path.join(STAGING, sid), "wb").write(raw)
            host = self.headers.get("Host", f"127.0.0.1:{PORT}")
            # The target agent downloads from this URL - a loopback Host (dashboard
            # opened via localhost) would make it fetch from ITSELF. Use the LAN IP.
            if host.split(":")[0].lower() in ("127.0.0.1", "localhost", "[::1]", "::1"):
                try:
                    _s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                    _s.connect(("192.168.1.1", 80)); host = f"{_s.getsockname()[0]}:{PORT}"; _s.close()
                except Exception:
                    pass
            target = g("agent"); dest = g("path")
            jid = None
            if target and dest:
                # sid carries the original filename, so it can contain spaces and
                # other characters that are illegal in a URL path. Unencoded, the
                # agent's download 404s and the fetch job fails with a misleading
                # "remote server returned an error: (404) Not Found".
                jid = enqueue(target, "fetch", {"url": f"http://{host}/staging/{quote(sid)}", "dest": os.path.join(dest, name), "token": TOKEN}, by="upload")
                fs_cache_bust(resolve_agent(target) or target)
            return self._send(200, {"ok": True, "staged": sid, "job": jid})
        if route == "/transfer":  # copy a file that already exists on source PC to a dest PC folder
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            jid = enqueue(b.get("from", ""), "transfer", {"src": b.get("src"), "toAgent": b.get("to"), "toHost": b.get("toHost"), "dest": b.get("dest")}, by="transfer")
            fs_cache_bust(resolve_agent(b.get("to", "")) or str(b.get("to", "")))
            return self._send(200, {"ok": True, "id": jid})

        # Backups
        if route == "/backup/run":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); return self._send(200, {"ok": True, "id": run_backup(b)})
        if route == "/backup/save":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); cfg = backups_cfg(); cfg["jobs"] = b.get("jobs", cfg["jobs"]); save_json(BACKUPS_F, cfg)
            return self._send(200, {"ok": True})

        # Screenshots (opt-in per PC)
        if route == "/screenshot/optin":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); cfg = load_json(SHOT_OPTIN_F, {})
            cfg[str(b.get("agent", ""))] = bool(b.get("on"))
            save_json(SHOT_OPTIN_F, cfg)
            audit("screenshot_optin", agent=b.get("agent"), on=bool(b.get("on")))
            return self._send(200, {"ok": True, "optin": bool(b.get("on"))})
        if route == "/screenshot/capture":   # dashboard asks a PC for a fresh shot
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); agent = resolve_agent(b.get("agent")) or str(b.get("agent", ""))
            if not shot_optin(agent):
                return self._send(403, {"error": "screenshots are OFF for this PC - enable them in its detail view first"})
            return self._send(200, {"ok": True, "id": enqueue(agent, "screenshot", {}, by="screenshot")})
        if route == "/screenshot/upload":     # agent posts the captured image back
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            agent = re.sub(r"[^A-Za-z0-9_.-]", "", g("agent"))
            raw = self._body_raw()
            if agent and raw:
                open(os.path.join(SHOTS_DIR, agent + ".jpg"), "wb").write(raw)
            return self._send(200, {"ok": True, "bytes": len(raw)})

        # PlexClaw bridge
        if route == "/claw/request":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            q = str(b.get("query", "")).strip()
            if not q: return self._send(400, {"status": "error", "message": "query required"})
            return self._send(200, claw_request(q, str(b.get("year", "")), str(b.get("type", "movie")), by=b.get("by", "dashboard")))
        if route == "/claw/continue":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body()
            pu = claw_post("/playurl", {"ratingKey": b.get("ratingKey", "")}, timeout=15)
            if not pu or not pu.get("ok"):
                return self._send(200, {"ok": False, "error": (pu or {}).get("error", "PlexClaw engine isn't running")})
            start = int(b.get("offsetSec") or pu.get("viewOffsetSec") or 0)
            jid = enqueue(b.get("agent", ""), "play", {"url": pu["url"], "startSec": max(0, start - 5)}, by="continue")
            return self._send(200, {"ok": True, "id": jid, "title": pu.get("title", "")})

        # Network: on-demand rescan or rename a device
        if route == "/net/scan":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            threading.Thread(target=net_scan, daemon=True).start()
            return self._send(200, {"ok": True, "msg": "scanning… refresh in ~15s"})
        if route == "/net/name":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); dev = load_json(NETDEV_F, {"devices": {}})
            mac = str(b.get("mac", "")).lower()
            if mac in dev.get("devices", {}):
                dev["devices"][mac]["name"] = str(b.get("name", ""))[:40]
                save_json(NETDEV_F, dev)
            return self._send(200, {"ok": True})

        # Rules (alerts + digest)
        if route == "/rules":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); cfg = rules_cfg()
            for k, v in (b.get("rules") or {}).items():
                if k in DEFAULT_RULES and isinstance(v, dict):
                    cur = cfg["rules"][k]
                    if "on" in v: cur["on"] = bool(v["on"])
                    if k == "digest" and "ai" in v: cur["ai"] = bool(v["ai"])
                    for f in ("pct", "mins", "hour"):
                        if f in v and f in DEFAULT_RULES[k]:
                            try: cur[f] = max(0, min(100 if f == "pct" else (23 if f == "hour" else 1440), int(v[f])))
                            except Exception: pass
            save_json(RULES_F, cfg)
            return self._send(200, {"ok": True})
        if route == "/rules/test":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            text = ai_digest_text()
            sent = tg_send(text)
            return self._send(200, {"ok": True, "sent": sent, "text": text})

        # Telegram config
        if route == "/telegram":
            if not self._authed(): return self._send(401, {"error": "unauthorized"})
            b = self._body(); c = tg_cfg()
            if b.get("token") is not None: c["token"] = b["token"]
            if b.get("ownerId") is not None: c["ownerId"] = b["ownerId"]
            if b.get("enabled") is not None: c["enabled"] = bool(b["enabled"])
            save_json(TELEGRAM_F, c)
            if b.get("test"): tg_send("homedashboard bot connected")
            return self._send(200, {"ok": True})

        return self._send(404, {"error": "not found"})


def main():
    init_db()
    # Single-instance guard: bind the port FIRST and exclusively. A duplicate
    # launch (watchdog race, manual restart) then fails here and exits cleanly,
    # instead of starting a SECOND set of telegram/alert loops that would send
    # duplicate notifications and fight over the Telegram long-poll. (Windows'
    # default SO_REUSEADDR=1 lets multiple procs share a port, so force it off.)
    ThreadingHTTPServer.allow_reuse_address = False
    try:
        srv = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    except OSError as e:
        print(f"Brain already running on :{PORT} ({e}) - exiting duplicate.")
        return
    # Only now that we exclusively own the port do we start the background loops.
    threading.Thread(target=rules_loop, daemon=True).start()
    threading.Thread(target=netwatch_loop, daemon=True).start()
    threading.Thread(target=telegram_loop, daemon=True).start()
    threading.Thread(target=backup_loop, daemon=True).start()
    print("=" * 64)
    print(f"  Home Network Dashboard - BRAIN v{BRAIN_VERSION}")
    print("=" * 64)
    print(f"  UI + API : http://0.0.0.0:{PORT}   (open http://localhost:{PORT})")
    print(f"  Data dir : {DATA_DIR}")
    print(f"  Token    : {TOKEN}")
    print("=" * 64)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nBrain stopped.")


if __name__ == "__main__":
    main()
