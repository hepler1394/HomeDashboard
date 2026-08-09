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

**`.env` is deliberately absent and must stay that way** — it holds the real
Anthropic, Brave, and Gemini keys. Every `api_key` in `config.yaml` is a `$VAR`
reference, never a literal, which is what makes this directory safe to push.

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
