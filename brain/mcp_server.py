# -*- coding: utf-8 -*-
# =============================================================================
# home-control MCP server
# -----------------------------------------------------------------------------
# God-mode control over a fleet of home Windows PCs, via an existing local
# "brain" HTTP service. This is the owner's own homelab (authorized personal
# use). Claude issues jobs; the per-device agents sandbox/allow-list execution.
#
# INSTALL
#   pip install mcp httpx        # httpx is OPTIONAL -- see HTTP note below
#   (only `mcp` is strictly required; HTTP uses stdlib urllib.request)
#
# REGISTER WITH CLAUDE CODE
#   claude mcp add --transport stdio home-control -- python C:\HomeDashboard\brain\mcp_server.py
#
# REGISTER WITH CLAUDE DESKTOP  (claude_desktop_config.json)
#   {
#     "mcpServers": {
#       "home-control": {
#         "command": "python",
#         "args": ["C:\\HomeDashboard\\brain\\mcp_server.py"],
#         "env": {
#           "BRAIN_URL": "http://127.0.0.1:8788",
#           "BRAIN_TOKEN": "optional-if-not-loopback"
#         }
#       }
#     }
#   }
#
# HTTP NOTE
#   This file uses Python's stdlib urllib.request for all HTTP, so no pip
#   dependency beyond `mcp` is needed. (httpx is listed in the install line
#   only because the official SDK examples commonly use it; it is not imported
#   here.)
#
# THE BRAIN API
#   Base URL : env BRAIN_URL or http://127.0.0.1:8788
#   Auth     : header  X-Brain-Token: <token>   (not required from loopback)
#   Token    : %LOCALAPPDATA%\HomeNetDashboard\brain\secret.json  {"token": "..."}
#              (fallback: env BRAIN_TOKEN)
#   Endpoints:
#     GET  /devices  -> {"devices":[{agent,host,ip,online,stats:{...}},...]}
#     GET  /jobs     -> {"jobs":[{id,agent,type,args,status,result,created},...]}
#     POST /jobs  {agent,type,args,by} -> {ok,id}
# =============================================================================

import os
import sys
import json
import time
import datetime
import urllib.request
import urllib.error

# --- MCP SDK import guard ----------------------------------------------------
try:
    from mcp.server.fastmcp import FastMCP
except Exception:  # ImportError and anything else
    sys.stderr.write(
        "\n[home-control] The 'mcp' package is not installed.\n"
        "Install it with:  pip install mcp\n"
        "Then re-run this server.\n\n"
    )
    sys.exit(1)


# =============================================================================
# Configuration
# =============================================================================

BRAIN_URL = os.environ.get("BRAIN_URL", "http://127.0.0.1:8788").rstrip("/")

# Destructive-action master switch. When False, power() refuses outright.
# Flip to True (and pass confirm=True per call) to actually sleep/restart/shutdown.
ALLOW_DESTRUCTIVE = False

_LOCALAPPDATA = os.environ.get("LOCALAPPDATA", os.path.expanduser("~"))
_BRAIN_DIR = os.path.join(_LOCALAPPDATA, "HomeNetDashboard", "brain")
_SECRET_PATH = os.path.join(_BRAIN_DIR, "secret.json")
_AUDIT_PATH = os.path.join(_BRAIN_DIR, "mcp-audit.jsonl")

# How long to poll for a job to finish before giving up.
_POLL_TIMEOUT_S = 60
_POLL_INTERVAL_S = 1.0

_ACTOR = "claude-mcp"


def _load_token():
    """Read the brain token from secret.json, falling back to env BRAIN_TOKEN."""
    try:
        with open(_SECRET_PATH, "r", encoding="utf-8") as f:
            data = json.load(f)
        tok = data.get("token")
        if tok:
            return str(tok)
    except Exception:
        pass
    return os.environ.get("BRAIN_TOKEN")


BRAIN_TOKEN = _load_token()


# =============================================================================
# Audit log
# =============================================================================

def _audit(tool, args):
    """Append one JSON line recording a tool invocation. Never raises."""
    try:
        os.makedirs(_BRAIN_DIR, exist_ok=True)
        line = {
            "ts": datetime.datetime.now(datetime.timezone.utc).isoformat(),
            "tool": tool,
            "args": args,
        }
        with open(_AUDIT_PATH, "a", encoding="utf-8") as f:
            f.write(json.dumps(line, default=str) + "\n")
    except Exception:
        # Auditing must never break a tool call.
        pass


# =============================================================================
# HTTP helpers (stdlib only)
# =============================================================================

def _headers():
    h = {"Content-Type": "application/json", "Accept": "application/json"}
    if BRAIN_TOKEN:
        h["X-Brain-Token"] = BRAIN_TOKEN
    return h


def _http(method, path, body=None, timeout=20):
    url = BRAIN_URL + path
    data = None
    if body is not None:
        data = json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data, headers=_headers(), method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode("utf-8", "replace")
        except Exception:
            pass
        raise RuntimeError("brain %s %s -> HTTP %s: %s" % (method, path, e.code, detail[:400]))
    except urllib.error.URLError as e:
        raise RuntimeError("brain %s %s unreachable: %s" % (method, path, e.reason))
    if not raw:
        return {}
    try:
        return json.loads(raw)
    except Exception:
        return {"raw": raw}


def _get(path):
    return _http("GET", path)


def _post(path, body):
    return _http("POST", path, body=body)


# =============================================================================
# Validation
# =============================================================================

def _validate_agent(agent):
    if not isinstance(agent, str):
        raise ValueError("agent must be a string")
    a = agent.strip()
    if not a:
        raise ValueError("agent must be a non-empty string")
    # Simple identifier: letters, digits, dot, dash, underscore.
    for ch in a:
        if not (ch.isalnum() or ch in "-_."):
            raise ValueError("agent contains invalid characters: %r" % agent)
    return a


def _validate_enum(name, value, allowed):
    if not isinstance(value, str):
        raise ValueError("%s must be a string" % name)
    v = value.strip().lower()
    if v not in allowed:
        raise ValueError("%s must be one of %s (got %r)" % (name, sorted(allowed), value))
    return v


# =============================================================================
# Job enqueue + poll
# =============================================================================

def _enqueue_and_wait(agent, jtype, args):
    """Enqueue a job for `agent`, poll /jobs until it's done/error or times out.

    Returns a dict summarizing the outcome.
    """
    resp = _post("/jobs", {"agent": agent, "type": jtype, "args": args or {}, "by": _ACTOR})
    if not isinstance(resp, dict) or not resp.get("ok"):
        return {"ok": False, "error": "enqueue failed", "response": resp}
    job_id = resp.get("id")
    if job_id is None:
        return {"ok": False, "error": "no job id returned", "response": resp}

    deadline = time.time() + _POLL_TIMEOUT_S
    last = None
    while time.time() < deadline:
        time.sleep(_POLL_INTERVAL_S)
        jobs = _get("/jobs").get("jobs", [])
        job = next((j for j in jobs if str(j.get("id")) == str(job_id)), None)
        if job is None:
            continue
        last = job
        status = str(job.get("status", "")).lower()
        if status in ("done", "ok", "complete", "completed", "success"):
            return {"ok": True, "id": job_id, "status": status, "result": job.get("result")}
        if status in ("error", "failed", "fail"):
            return {"ok": False, "id": job_id, "status": status, "result": job.get("result")}
    return {
        "ok": False,
        "id": job_id,
        "status": "timeout",
        "error": "job did not finish within %ds" % _POLL_TIMEOUT_S,
        "last": last,
    }


# =============================================================================
# MCP server + tools
# =============================================================================

mcp = FastMCP("home-control")


@mcp.tool()
def list_devices() -> dict:
    """List all devices known to the brain, with their latest stats.

    Read-only. Returns the full devices array:
    [{agent, host, ip, online, stats:{cpu, mem, uptime, pia, drives:[...]}}, ...]
    """
    _audit("list_devices", {})
    return {"devices": _get("/devices").get("devices", [])}


@mcp.tool()
def device_status(agent: str) -> dict:
    """Get one device's latest stats (cpu, mem, uptime, pia, drives).

    Read-only. `agent` is the device's agent id.
    """
    agent = _validate_agent(agent)
    _audit("device_status", {"agent": agent})
    devices = _get("/devices").get("devices", [])
    dev = next((d for d in devices if str(d.get("agent")) == agent), None)
    if dev is None:
        return {"ok": False, "error": "no such agent: %s" % agent}
    return {
        "ok": True,
        "agent": agent,
        "host": dev.get("host"),
        "ip": dev.get("ip"),
        "online": dev.get("online"),
        "stats": dev.get("stats", {}),
    }


@mcp.tool()
def list_drives(agent: str) -> dict:
    """List a device's drives (letter, freeGB, totalGB, usedPct) from its stats.

    Read-only.
    """
    agent = _validate_agent(agent)
    _audit("list_drives", {"agent": agent})
    devices = _get("/devices").get("devices", [])
    dev = next((d for d in devices if str(d.get("agent")) == agent), None)
    if dev is None:
        return {"ok": False, "error": "no such agent: %s" % agent}
    drives = (dev.get("stats") or {}).get("drives", [])
    return {"ok": True, "agent": agent, "drives": drives}


@mcp.tool()
def run_command(agent: str, command: str) -> dict:
    """Run a shell command on a device and return its output.

    Enqueues a `run` job. NOTE: execution is allow-list-gated on the agent
    side -- the target device will refuse commands not on its allow list.
    Args are passed through verbatim; no shell string is built here.
    """
    agent = _validate_agent(agent)
    if not isinstance(command, str) or not command.strip():
        raise ValueError("command must be a non-empty string")
    _audit("run_command", {"agent": agent, "command": command})
    return _enqueue_and_wait(agent, "run", {"cmd": command})


@mcp.tool()
def install_app(agent: str, package_id: str, manager: str = "winget") -> dict:
    """Install an application on a device via its package manager.

    Enqueues an `install` job. `package_id` is the manager's package id;
    `manager` defaults to "winget".
    """
    agent = _validate_agent(agent)
    if not isinstance(package_id, str) or not package_id.strip():
        raise ValueError("package_id must be a non-empty string")
    if not isinstance(manager, str) or not manager.strip():
        raise ValueError("manager must be a non-empty string")
    _audit("install_app", {"agent": agent, "package_id": package_id, "manager": manager})
    return _enqueue_and_wait(agent, "install", {"id": package_id, "manager": manager})


@mcp.tool()
def set_pia(agent: str, action: str) -> dict:
    """Control PIA VPN on a device.

    Enqueues a `pia` job. `action` is one of: on, off, status, harden.
    """
    agent = _validate_agent(agent)
    action = _validate_enum("action", action, {"on", "off", "status", "harden"})
    _audit("set_pia", {"agent": agent, "action": action})
    return _enqueue_and_wait(agent, "pia", {"action": action})


@mcp.tool()
def play_url(agent: str, url: str) -> dict:
    """Play a URL in VLC on a device.

    Enqueues a `play` job. `url` is passed through as a job arg.
    """
    agent = _validate_agent(agent)
    if not isinstance(url, str) or not url.strip():
        raise ValueError("url must be a non-empty string")
    _audit("play_url", {"agent": agent, "url": url})
    return _enqueue_and_wait(agent, "play", {"url": url})


@mcp.tool()
def open_path(agent: str, path: str) -> dict:
    """Open a file or path on a device with its default handler.

    Enqueues an `open` job. `path` is passed through as a job arg.
    """
    agent = _validate_agent(agent)
    if not isinstance(path, str) or not path.strip():
        raise ValueError("path must be a non-empty string")
    _audit("open_path", {"agent": agent, "path": path})
    return _enqueue_and_wait(agent, "open", {"path": path})


@mcp.tool()
def power(agent: str, action: str, confirm: bool = False) -> dict:
    """DESTRUCTIVE: sleep, restart, or shut down a device.

    Enqueues a `power` job. `action` is one of: sleep, restart, shutdown.

    Guarded twice:
      1. Module-level ALLOW_DESTRUCTIVE must be True (edit this file to enable).
      2. The call must pass confirm=True.
    If either guard is not satisfied, the tool refuses without doing anything.
    """
    agent = _validate_agent(agent)
    action = _validate_enum("action", action, {"sleep", "restart", "shutdown"})
    _audit("power", {"agent": agent, "action": action, "confirm": bool(confirm)})

    if not ALLOW_DESTRUCTIVE:
        return {
            "ok": False,
            "refused": True,
            "error": (
                "Destructive actions are disabled. To allow power control, set "
                "ALLOW_DESTRUCTIVE = True at the top of mcp_server.py and restart "
                "the MCP server."
            ),
        }
    if not confirm:
        return {
            "ok": False,
            "refused": True,
            "error": (
                "power(%s, %r) is destructive; re-call with confirm=True to proceed."
                % (agent, action)
            ),
        }
    return _enqueue_and_wait(agent, "power", {"action": action})


@mcp.tool()
def recent_jobs(limit: int = 20) -> dict:
    """List recent jobs across all devices.

    Read-only. `limit` caps how many of the most recent jobs to return.
    """
    try:
        limit = int(limit)
    except Exception:
        limit = 20
    if limit < 1:
        limit = 1
    _audit("recent_jobs", {"limit": limit})
    jobs = _get("/jobs").get("jobs", [])
    # Most recent last in the brain's list; return the tail.
    return {"jobs": jobs[-limit:]}


# =============================================================================
# Entrypoint
# =============================================================================

if __name__ == "__main__":
    mcp.run(transport="stdio")
