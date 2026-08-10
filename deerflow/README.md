# DeerFlow runtime config (tracked copy)

The live DeerFlow checkout lives at `../deer-flow`, a clone of
[bytedance/deer-flow](https://github.com/bytedance/deer-flow). Everything that
makes that install *ours* — the model list, the custom skills, the MCP and skill
toggles — sits in paths upstream gitignores:

```
config.yaml               deer-flow/.gitignore:33
extensions_config.json    deer-flow/.gitignore:35
skills/custom/*           deer-flow/.gitignore:46
.env                      deer-flow/.gitignore:30
```

Sensible for upstream, bad for us: it meant our entire configuration existed on
one disk with no version control and no backup. This directory is that backup.

## Contents

| Path | What it is |
| --- | --- |
| `config.yaml` | Full DeerFlow config: the model list, tools, sandbox, memory settings |
| `extensions_config.json` | MCP servers and per-skill enable state |
| `skills/` | Our custom skills, mirroring `deer-flow/skills/custom/` |
| `sync.ps1` | Copies between here and the live checkout in either direction |

**`.env` is deliberately absent and must stay that way** — it holds real
credentials. Every `api_key` in `config.yaml` is a `$VAR` reference, never a
literal, which is what makes this directory safe to push.

### What `deer-flow/.env` must contain

It is the only file here with no backup, and several entries are settings you
would not think to recreate. If it is ever lost, rebuild it with these keys:

| Key | Purpose |
| --- | --- |
| `ANTHROPIC_API_KEY` | Claude Sonnet 5, the default model |
| `BRAVE_SEARCH_API_KEY` | legacy; search now uses DDGS and needs no key |
| `OPENROUTER_API_KEY` | OpenRouter, paid and `:free` models |
| `GEMINI_API_KEY` | currently rejected as invalid; Gemini is disabled in config |
| `DEER_FLOW_BRAIN_TOKEN` | lets the delivery tool authenticate to the dashboard brain. Mint a fresh one with `curl http://127.0.0.1:8788/token` **from PlexServer itself** — that route is loopback-only |
| `AUTH_JWT_SECRET` | signs login cookies. Was auto-generated into `backend/.deer-flow/.jwt_secret`; pinned here so losing that file does not log everyone out. **Changing it invalidates every session.** |
| `DEER_FLOW_AUTH_ALLOW_INSECURE_PERSISTENT_COOKIE=1` | the non-obvious one. The dashboard reaches DeerFlow over plain HTTP at a Tailscale hostname, which is neither HTTPS nor localhost, so the cookie policy falls through to `public_http_session` with `max_age=None` — a cookie that dies on browser close, forcing a login every time. This flag restores the 7-day cookie. |

Verify the cookie policy after any change:

```powershell
wsl -d Ubuntu-24.04 -u root -- docker exec deer-flow-gateway sh -lc 'cd backend && PYTHONPATH=. uv run --no-sync python -c "
from starlette.requests import Request
from app.gateway.auth.session_cookie import resolve_session_cookie_policy
scope={\"type\":\"http\",\"headers\":[(b\"host\",b\"plexserver.tail22fc0f.ts.net:2026\")],\"scheme\":\"http\",\"path\":\"/\",\"query_string\":b\"\",\"method\":\"POST\",\"client\":(\"10.0.0.5\",1),\"server\":(\"x\",2026)}
print(resolve_session_cookie_policy(Request(scope), remember_me=True))"'
```

It should report `operator_insecure_persistent` with `max_age=604800`, not
`public_http_session`.

## Keeping it current

Nothing syncs automatically. After changing a model, a skill, or an MCP server,
run this or the two copies drift:

```powershell
cd C:\HomeDashboard\deerflow
.\sync.ps1            # live -> here
git add deerflow && git commit -m "chore: sync deerflow config"
```

`.\sync.ps1 -Check` reports whether they have diverged without changing
anything. `.\sync.ps1 -Restore` pushes this copy back onto the live checkout —
after which you must recreate `deer-flow\.env` by hand and recreate the gateway
container, since the restore deliberately does not touch secrets.

## Skills

`skills/` holds four: `anti-ai-slop`, `autopilot-mode`, `free-api-finder`
(copies of the ones in `~/.claude/skills`) and `home-fleet`, which is
DeerFlow-only and documents the machines, the dashboard brain's API, and the
things the DeerFlow container cannot reach.

Two gotchas when copying a skill from `~/.claude/skills`:

- DeerFlow's YAML parser is stricter than Claude Code's. A `description:` on one
  unquoted line containing a colon parses fine in Claude Code but throws
  "mapping values are not allowed here" here, and the skill is **silently
  skipped**. Use a folded block (`description: >-`).
- `autopilot-mode` is its own git repo, so a plain copy drags a whole `.git/`
  along with it. Delete it after copying.

Verify a skill actually registered rather than assuming:

```powershell
docker exec deer-flow-gateway sh -lc 'cd backend && PYTHONPATH=. uv run --no-sync python -c "from deerflow.skills import get_or_new_skill_storage; print(sorted(s.name for s in get_or_new_skill_storage().load_skills()))"'
```
