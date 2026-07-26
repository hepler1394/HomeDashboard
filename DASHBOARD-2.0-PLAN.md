# Home Network Dashboard 2.0 — "The Brain"

> Goal: one dashboard to **see, know, and control every computer in the house** — install software, move files between PCs, toggle VPNs, play movies, back up to the cloud, and eventually let an AI (via your own MCP) do all of it — without walking over to plug in a USB stick.

Author: planning pass, 2026-07-10. Owner: Cory. All machines are the owner's own equipment; everything here is authorized personal/homelab use.

---

## 0. The one idea that makes 2.0 possible

**Today (v1):** every PC runs its own dashboard, and each dashboard can only *do* things on the PC it's running on. To control PC B you have to be at PC B (or use `shutdown /m` with admin). There is no way for the dashboard on the Plex server to run "install VLC" on the couch PC.

**2.0:** turn the Plex server (`PLEXSERVER`, `192.168.1.174`) into the **central brain**, and put a tiny **agent** on every PC. The brain holds a **job queue**. Each PC's agent polls the brain ("any jobs for me?"), runs the job locally, and reports the result back. That's the whole unlock:

```
   ┌─────────────────────────────────────────────┐
   │  BRAIN  (Plex server, always on)             │
   │  - Dashboard UI (localhost + LAN + Tailscale)│
   │  - Job queue  (jobs.json / SQLite)           │
   │  - AI command center + MCP server            │
   │  - Telegram bot ("homedashboard")            │
   └───────▲───────────────▲───────────────▲──────┘
           │ poll+report    │               │
   ┌───────┴──────┐  ┌──────┴───────┐  ┌────┴─────────┐
   │ Agent: MainPC│  │ Agent: Media │  │ Agent: Couch │
   │ runs jobs in │  │     PC       │  │     PC       │
   │ user session │  │              │  │              │
   └──────────────┘  └──────────────┘  └──────────────┘
```

Why pull-based (agent polls the brain) instead of push (brain runs commands on PCs)?
- It's exactly the model your existing hourly `dashboard-pull.ps1` already uses — proven on your network.
- It sidesteps the two things that make Windows remote-exec painful: **WinRM being off by default** on client Windows, and **winget refusing to work well outside an interactive session** (confirmed: winget is "an interactive desktop package management tool," server support is experimental). An agent running in the logged-in user's session runs winget natively with zero drama.
- It works through PIA/VPN and NAT: the agent makes *outbound* calls to the brain, so nothing needs to be port-forwarded to each PC.
- One security boundary to harden (the brain), not N.

Everything below builds on this brain+agent spine.

---

## 1. Guiding principles

1. **Keep the "no-install, pure-PowerShell" soul where it helps, but grow up where needed.** The v1 server is elegant (raw TCP, no admin). 2.0 keeps that for the UI, but the agent + AI + MCP layers justify a real backend (Python is already on the Plex box for PlexClaw). Use the right tool per layer.
2. **The brain is the only trusted, hardened surface.** Agents only accept jobs from the brain, over a shared secret, ideally only on the Tailscale interface.
3. **Allow-list, don't deny-list.** Especially for AI-driven actions. Whitelist the exact commands/packages that may run; reject everything else.
4. **Every mutating action is logged, append-only, on the brain** — so a compromised PC can't erase its own trail.
5. **Destructive actions require a human confirm** (a click, or a typed "YES"), enforced server-side — never trust the AI's own "are you sure?".
6. **Progressive rollout.** Each phase ships something usable on its own. No big-bang rewrite.

---

## 2. Current state (v1) — what we're building on

- **`HomeDashboard.ps1`** — pure-PowerShell raw-TCP HTTP server on `127.0.0.1:8787` (optional LAN bind + Basic-auth password). Endpoints: `/api/status`, `/api/history`, `/api/search`, `/api/aisearch`, `/api/keys`, `/api/setkey`, `/api/setpeer`, `/api/ls`, `/api/action`, `/api/reindex`, `/api/indexstat`, `/api/quit`. Actions all run locally via `Start-Process`.
- **`index.html`** — the live UI (server serves it if present). Already has: sidebar nav, KPI rings (storage/CPU/mem/uptime), device cards, drives grid, **file browser with drag-and-drop copy (same PC only)**, copy/move picker, Windows/mac themes, light/dark, history sparklines, drive-fill forecast.
- **AI search** — multi-provider (Gemini/Claude/DeepSeek/AIMLAPI), keys in `%LOCALAPPDATA%\HomeNetDashboard\ai-config.json`, NL→filename query translation, backed by Everything (voidtools) HTTP server or the built-in flat index.
- **Sync topology** — Plex server is master: `publish-to-master.ps1` (every 5 min) copies `HomeDashboard.ps1`/`index.html`/`Build-Index.ps1` → `\\PLEXSERVER\HomeShare\Dashboard-Setup`. Each PC runs `dashboard-pull.ps1` (hourly) to pull + restart. Local config (keys/auth) never synced except `device-peers.json`.
- **Devices** hardcoded in `$Devices` (Main PC .189, Plex .174, Media PC .237). Status via ping + port probes (445/3389/32400).

**Gaps 2.0 fills:** no cross-PC control, no cross-PC file transfer, no remote install, no VPN control, no Plex→VLC, no cloud/shared drives, no Telegram, no AI that *acts* (only searches), no MCP, and the UI gets crowded with many drives.

---

## 3. Target architecture (2.0)

### 3.1 The brain (on PLEXSERVER)
Add a **Python backend** (FastAPI or the existing PlexClaw stack) alongside the PowerShell UI server, OR extend the PowerShell server. Recommendation: **introduce a small Python service on the brain** for the job queue, AI, MCP, and Telegram (these are painful in raw PowerShell), and keep the PowerShell server for the existing UI/status/file endpoints during transition. Long-term the UI can point at the Python backend.

Brain responsibilities:
- **Device registry** (replace hardcoded `$Devices` with `devices.json`, self-registered by agents on first check-in).
- **Job queue** — `POST /jobs` (enqueue), `GET /jobs?agent=<id>&pending=1` (agent polls), `POST /jobs/<id>/result` (agent reports). Store in SQLite.
- **Auth** — shared secret per agent (bearer token); bind to Tailscale IP.
- **AI command center** — the multi-provider router (below) + tool-calling loop.
- **MCP server** — exposes the same job/tool surface to Claude.
- **Telegram bot** — long-poll loop, owner-only.
- **Audit log** — append-only `audit.log` (JSONL).

### 3.2 The agent (on every PC)
A small PowerShell (or Python) script installed once per PC, run as a scheduled task at logon (so it's in the interactive session for winget/VLC). Loop:
1. `GET https://brain:PORT/jobs?agent=<thisPC>` every ~3–5 s (long-poll or short poll), with bearer token.
2. For each job, dispatch by `type` to a **fixed handler** (never eval raw strings):
   - `run` (allow-listed command), `install` (winget/choco id from allow-list), `pia` (on/off/status), `play` (Plex→VLC), `copy`/`move`/`push` (file transfer), `power` (sleep/restart/shutdown), `open`, `status`.
3. `POST /jobs/<id>/result` with stdout/exit code.
4. Heartbeat: include CPU/mem/disk/PIA-state/uptime in the poll so the brain always has fresh status for every PC (not just ping).

The agent is the single component that must be deployed to each PC once — and it can self-update by pulling from the brain (reuse the existing publish/pull pattern).

### 3.3 Reaching every PC even behind PIA — networking layer
Two settings on **every** PC (research-confirmed):
- `piactl set allowlan true` — the CLI equivalent of PIA's "Allow LAN traffic"; keeps SMB/RDP/8787 reachable on the LAN with the VPN up. **This is the crux of "reach it while VPN is on."**
- `piactl background enable` — so PIA works headless/scripted with no GUI open.

Plus **install Tailscale on every PC** as the reliability overlay:
- Each PC gets a stable `100.x` IP + MagicDNS name that never changes (DHCP, VPN churn, moving networks). The brain addresses agents by MagicDNS name.
- Coexists with PIA if you **bypass the Tailscale range `100.64.0.0/10` in PIA split-tunnel** and don't run PIA's kill switch aggressively (or use `auto`). Never use a Tailscale exit node on a PIA machine.
- Because agents poll *outbound* to the brain, Tailscale also means you can control the whole house **from outside the LAN** (phone, work) with no port-forwarding.

Verdict: `allowlan true` is mandatory and zero-risk; Tailscale is strongly recommended and is what makes the whole thing bulletproof and remote-capable.

---

## 4. Feature-by-feature design

### A. Better file transfer + drag-and-drop (incl. **between** PCs)
Current: drag a row onto a folder → copies **on the same PC** only.

2.0:
1. **Upload from your computer into the dashboard** — real drag-and-drop of files from your desktop/Explorer onto the browser window. Add a drop zone + `POST /api/upload` (multipart) that writes into the currently-open folder. This is the "I dropped a file and it went to the server" experience.
2. **Transfer between PCs** — in the file browser, right-click a file → "Send to → Media PC / Couch PC". This enqueues a `push` job: the source PC's agent reads the file and POSTs it to the brain (or directly to the destination agent over Tailscale), which writes it on the target. Under the hood it's just SMB copy if `allowlan` is on (`Copy-Item \\target\share`), with the agent path as fallback when SMB is blocked.
3. **Shared drop folder** — a Syncthing/SMB "HomeShare" folder (see F) that every PC has; dragging into it is the dead-simple "everyone gets it" path.
4. **Progress + big-file handling** — chunked upload, a transfer list in the status bar, resumable via `rclone`/`robocopy` under the hood for large media.

### B. AI command center (multi-provider keys + a chat that *acts*)
Upgrade Settings → keys to a full **provider manager**, and add an **AI Chat** panel that can *do things*, not just search files.

Providers (store `{base_url, api_key, default_model}` each; one OpenAI-shaped client for all but Anthropic):

| Provider | Base URL | Compatible | Fast/cheap model (2026) |
|---|---|---|---|
| OpenAI | `https://api.openai.com/v1` | native | `gpt-5-nano` |
| Anthropic (Claude) | `https://api.anthropic.com` (`/v1/messages`) | own schema | `claude-haiku-4-5` |
| Google Gemini | `https://generativelanguage.googleapis.com/v1beta/openai` | yes | `gemini-3.5-flash` |
| xAI Grok | `https://api.x.ai/v1` | yes | `grok-4.1-fast` |
| DeepSeek | `https://api.deepseek.com` | yes | `deepseek-v4-flash` (migrate off `deepseek-chat` before 2026-07-24) |
| **Fangu** | user-supplied base URL (OpenAI-compatible by default) | yes (assumed) | user-supplied model id |

> **Fangu is a first-class provider slot** the owner will fill in later. The key manager exposes editable `base_url` / `model` fields for it (defaulting to the OpenAI-shaped `/chat/completions` path), so whatever endpoint Fangu actually uses, the owner pastes the key + URL when ready. No key needed to build the slot.

The chat is a **tool-calling loop**: the model is given tools (`list_devices`, `run_on(pc, task)`, `install(pc, app)`, `play(pc, movie)`, `pia(pc, on/off)`, `transfer(file, from, to)`, `disk_report`, …). When it calls a tool, the brain enqueues the matching **job**, waits for the agent's result, and feeds it back. That's how "install this stuff on the couch PC" becomes real: you type it, the model calls `install(couch, VLC)`, the couch agent runs `winget install VideoLAN.VLC`, done — you never touch the USB.

Same key manager powers the existing "Ask AI" file search (keep it).

### C. Remote software install ("install this stuff from the dashboard")
The headline feature. Design:
- **Agent-run winget/choco in the user session** (avoids WinRM + winget's interactive-only problem entirely). Job: `{type:"install", pc:"couch", manager:"winget", id:"VideoLAN.VLC"}` → agent runs `winget install --silent --accept-package-agreements --accept-source-agreements --id VideoLAN.VLC`.
- **App catalog / bundles** — a curated list ("My couch-PC starter pack": VLC, Parsec, PIA, Tailscale, Syncthing, rclone, Everything, Chrome…). One click installs the whole bundle across a PC. This directly kills your "I have to install the USB stuff manually" pain — define the bundle once, click "Set up this PC," the agent installs everything.
- **Bootstrap** — the *only* manual step per new PC is installing the agent itself. Ship a one-liner: a signed `bootstrap.ps1` on the HomeShare that installs Tailscale + the agent + registers with the brain. After that, everything (including all other apps) is remote.
- **winget PowerShell module** (`Microsoft.WinGet.Client`) on the agent for structured install/upgrade/list, so the dashboard can show "updates available" per PC and one-click "update all."
- Fallbacks: Chocolatey for apps not in winget; direct MSI/EXE download+silent-install for the rest (allow-listed URLs only).
- **Alternative if you'd rather not build the agent yourself:** self-host **Tactical RMM** (open-source; runs PowerShell/Bash/Python natively, script library, scheduled tasks, software deploy, uses MeshCentral under the hood for remote desktop). It's heavier (Docker, a real server) but gives you install/patch/script/monitor out of the box, and MeshCentral gives full remote desktop + file transfer. Recommendation: **build the light agent for the dashboard-native experience; optionally run MeshCentral alongside** purely for on-demand remote desktop/screen control, since it's the best free tool for that and Tactical can embed it.

### D. PIA VPN control + staying reachable
- **Per-PC toggle** in each device card: a PIA pill (green=Connected, grey=Disconnected, amber=transitional) driven by the agent's heartbeat (`piactl get connectionstate`).
- **On/off** = `pia` job → agent runs `piactl connect` / `piactl disconnect`. Also expose region, kill-switch, and port-forward status.
- One-time hardening pushed by the "Set up this PC" bundle: `piactl background enable` + `piactl set allowlan true`.
- Show a clear warning in the UI when a PC's VPN is **off** so you never assume a machine is protected when it isn't.
- `piactl.exe` lives at `C:\Program Files\Private Internet Access\piactl.exe`.

### E. Plex → VLC one-click play
- Browsers can't launch `vlc.exe`, so the **brain/agent does it server-side**. Add `/play?ratingKey=<id>&pc=<target>`:
  1. Brain looks up the item's Part key via Plex API: `GET /library/metadata/<id>` → `Media[0].Part[0].key`.
  2. Builds `http://192.168.1.174:32400<partKey>?X-Plex-Token=<token>` (direct play, no transcode).
  3. Enqueues a `play` job → **target PC's agent** runs `vlc.exe "<url>"`. So you can start a movie on *any* PC in the house from the dashboard, not just the one you're sitting at.
- **Plex browser panel** in the UI: list libraries (`/library/sections`), browse a section (`/library/sections/<k>/all`), search, click a poster → "Play on [PC]". Uses Plex API + posters (`/photo/:/transcode`).
- Keep the `X-Plex-Token` **server-side only** — never render it into the page. LAN/HTTPS only.
- Optional upgrade: `plex-mpv-shim` on each PC turns it into a proper Plex cast target (skip-intro, subtitles) if raw VLC isn't enough.

### F. Shared folder + cloud drives in the sidebar
A new sidebar section **"Drives & Shares"** grouping:
- **HomeShare** — one folder every PC has. Pick one:
  - **Syncthing** (recommended for "survives a PC being off" — every PC keeps a real local copy, P2P, no cloud, encrypted). Web UI + REST API on `:8384` so the dashboard can show sync status.
  - or a plain **SMB share** off the always-on Plex server (simplest; gone if server's off).
- **Cloud drives** — Google Drive / OneDrive / Dropbox as real drive letters:
  - **rclone mount** (free, scriptable, 70+ providers; `rclone mount gdrive: G: --vfs-cache-mode full`, needs WinFsp). Config at `%APPDATA%\rclone\rclone.conf` (holds OAuth tokens — protect it).
  - or **RaiDrive** (the GUI you mentioned) if you want least-friction "Drive shows up in Explorer."
- Dashboard surfaces each mount's free space, mounted/unmounted state, and a "remount" button (agent job). Because the agent can install + configure, the dashboard can set up rclone/RaiDrive on a new PC too.

### G. Backup drives / cloud backup
- **Add backup targets** — external drives and cloud remotes shown as cards with free space, last-backup time, and status.
- **Scheduled rclone backups** — `rclone copy` (additive, safe — not `sync`) on a Task Scheduler trigger; write an exit-code `status.json` the dashboard reads. Show last run, bytes moved, errors. Use `--dry-run` first for any `sync`.
- **3-2-1 hygiene reminder** in the UI: keep at least one non-mirror backup so ransomware/accidental delete doesn't propagate.

### H. Telegram bot — "homedashboard"
- Create via **@BotFather** → `/newbot` → username `homedashboard_bot` → save the token (treat as a password; store outside git/web root).
- **Long polling** (no public URL, no port-forward, no TLS needed) on the brain: `getUpdates?timeout=30&offset=<n+1>`.
- **Hard-whitelist your numeric chat ID** — reject everything else silently. Map messages to a **fixed command set**, never raw shell.
- Commands mirror dashboard actions: `/status` (all PCs), `/disk`, `/pia couch on`, `/install couch vlc`, `/play "Andor" mediapc`, `/wake mainpc`, `/backup run`. Destructive ones (`/reboot`) require a typed `YES` confirm.
- **Push alerts** — brain sends you a message on: a drive crossing 90%, a PC going offline, a backup failing, PIA dropping on a PC, internet down. This is the "know everything" half of the brain.

### I. Your own MCP server ("god mode" for Claude)
- Build a **Python FastMCP** server on the brain that exposes the job/tool surface to Claude (Desktop, Code, or the in-dashboard chat):
  - stdio transport if Claude runs on the brain; **streamable-HTTP** if Claude connects from another machine (`FastMCP("home-control", host=…, port=…)`, `mcp.run(transport="streamable-http")`).
  - Register in Claude Code: `claude mcp add --transport http home-control http://plexserver:PORT/mcp`.
- Tools = thin wrappers over the same job queue: `list_devices`, `run_command(pc, cmd)`, `install_app(pc, id)`, `list_drives(pc)`, `transfer(file, from, to)`, `pia(pc, state)`, `play(pc, ratingKey)`, `backup_run()`, `read_logs(pc)`.
- **Don't start from scratch** — fork a hardened base: **win-cli-mcp-server** (Windows CLI + SSH, config-driven blocking) or **mcp-shell-server** (whitelisted commands + structured audit logging). Adapt their allow-list + audit patterns.
- **Security (mandatory before "god-level"):**
  - Allow-list commands/packages; validate `pc`/`cmd`/`id` args; `subprocess.run([...], shell=False)` — never interpolate model output into a shell.
  - Tiered: read-only auto-runs; reversible mutations run+log; **destructive (delete/format/disable-security/reboot) require out-of-band human confirm**, enforced in the server.
  - Run the MCP server as a **low-privilege service account**, not Administrator. Bind to LAN/Tailscale only, bearer token, TLS.
  - Append-only audit log on the brain; kill-switch flag to disable all mutating tools; dry-run mode.

### J. UI/UX 2.0 — "so many drives, hard to focus"
- **Fleet overview first** — top of the home view becomes a compact **grid of all PCs** (online dot, CPU/mem/disk mini-rings, PIA state, quick actions), so "see all computers at a glance" is the landing experience.
- **Per-PC drill-down** — click a PC → its drives, processes, installed apps, backups, VPN, and a terminal/actions panel. Drives are **grouped by PC** and collapsible, and you can **star/pin** the drives you care about so the 20-drive wall collapses to the 3 you use.
- **Command palette (Ctrl-K)** — type "install vlc on couch", "play Andor on media pc", "vpn off mainpc", "open D on plex" — fuzzy-routes to actions and the AI chat. This is the fastest "brain" interface.
- **Global search** spanning files (existing), devices, apps, and Plex.
- **Density controls + focus mode** — hide offline PCs, filter drives by "local/network/cloud/backup", collapse sections. Keep the nice themes/rings.
- **Live everything** — websocket/SSE push from the brain instead of 8 s polling, so status, transfers, and job results stream in real time.
- **Status bar** shows active jobs/transfers across the fleet.

---

## 5. Phased roadmap (build order)

> **STATUS 2026-07-10: Phases 0–7 all BUILT and the 2.0 UI is verified in-browser.** Everything runs on the brain at `http://localhost:8788/`. What remains is *your* input — pasting keys/tokens, enrolling PCs with the one-liner, approving the persistence task, and the interactive sign-ins (`tailscale up`, `rclone config`). See §9.

**Phase 0 — Foundation (brain + agent spine). ✅ BUILT & PROVEN 2026-07-10.**
Files in `C:\HomeDashboard\brain\`: `brain.py` (pure-stdlib job-queue service on `:8788`, SQLite + audit log), `homedash-agent.ps1` (per-PC agent), `bootstrap.ps1` (one-line enroll), `start-brain.vbs` / `start-agent.vbs`. Proven on PlexServer: full job lifecycle (register→enqueue→poll→result), remote `run hostname`→PlexServer, `pia status`→Connected, allow-list refuses `format C:`, heartbeat returns live stats (17 drives). Enroll any PC with `irm http://192.168.1.174:8788/bootstrap | iex`.
*Pending user:* (1) approve/register the `HomeDashBrain` + `HomeDashAgent` logon tasks for auto-start (safety classifier blocked me from creating them autonomously — see below); (2) enroll the couch PC to run the live remote VLC-install + PIA-toggle demo.

**Phase 1 — Networking + reach.** Install Tailscale on all PCs; enforce `piactl set allowlan true` + `background enable`. Confirm the brain reaches every agent by MagicDNS name with PIA on. Add the **PIA on/off/status** feature (D) as the first real cross-PC control.

**Phase 2 — Remote install (C).** Agent winget/choco handlers, the app **catalog + bundles**, and "Set up this PC" one-click. Kills the USB-stick chore.

**Phase 3 — Files (A) + shares (F).** Real upload drag-drop, cross-PC "Send to", HomeShare (Syncthing or SMB), rclone/RaiDrive cloud mounts in the sidebar.

**Phase 4 — Media (E).** Plex browser panel + "Play on any PC" via VLC.

**Phase 5 — AI command center (B).** Multi-provider key manager (incl. Grok/OpenAI/FriendliAI), the tool-calling chat that enqueues jobs. "Install this on the couch PC" by chat.

**Phase 6 — Telegram (H) + backups (G) + alerts.** The "know everything from your phone" layer.

**Phase 7 — MCP god mode (I).** Fork a hardened MCP base, expose the tool surface to Claude, wire the security gates.

**Phase 8 — UI 2.0 (J) + polish.** Fleet overview, command palette, live push, focus mode. (Pull UI improvements earlier where cheap.)

Each phase is shippable and syncs to all PCs through the existing publish/pull pipeline (extended to carry the agent + backend).

---

## 6. Security & safety (consolidated — read before building I/C)

- **Trust boundary = the brain.** Agents accept jobs only from the brain, authenticated by a per-agent bearer secret, bound to the Tailscale interface (not `0.0.0.0`).
- **Allow-list everything AI/remote can run.** Commands, winget IDs, file paths, target PCs. Reject the rest. Never pass model/Telegram text to a shell.
- **Human-confirm destructive ops** server-side (delete, format, disable security, reboot). A click in the dashboard or a typed `YES` in Telegram.
- **Least privilege.** Agent and MCP run as limited service accounts; elevate only for the specific job that needs it.
- **Append-only audit log on the brain** for every mutating action: who/what/args/target/decision/result.
- **Secrets off the page and out of git:** Plex token, AI keys, PIA creds, Telegram token, rclone.conf. Keep the existing "config never synced" rule; extend it.
- **Kill switch** to disable all mutating tools instantly.
- **Never expose any of this to the public internet.** LAN + Tailscale only.

---

## 7. Tech stack decisions

| Layer | Pick | Why |
|---|---|---|
| Brain backend | Python (FastAPI) on PLEXSERVER | AI, MCP, Telegram, job queue are painful in raw PowerShell; Python already on the box |
| Agent | PowerShell scheduled task (logon) | Runs in interactive session → winget/VLC just work; matches existing pull model |
| Job store | SQLite | Simple, durable, queryable for audit |
| Reach/overlay | Tailscale + PIA `allowlan true` | Stable names, remote access, survives VPN churn |
| Remote desktop (optional) | MeshCentral | Best free screen control; Tactical can embed it |
| Cloud drives | rclone (power) / RaiDrive (GUI) | Scriptable vs. least-friction |
| Shared folder | Syncthing (offline-proof) or SMB | Local copies vs. simplest |
| AI router | one OpenAI-shaped client + Anthropic adapter | 5 of 6 providers are OpenAI-compatible |
| MCP | Python FastMCP, fork win-cli/mcp-shell | Don't reinvent the allow-list/audit base |
| Telegram | long-poll, owner-ID whitelist | No public URL, safe |

---

## 8. Open questions for the owner

**DECIDED (2026-07-10):**
- **Fangu** — keep as its own provider slot; owner adds base URL + key later. (Not FriendliAI.)
- **Tailscale** — YES, install on all PCs.
- **Control engine** — build the light dashboard-native agent (optionally add MeshCentral later just for remote desktop).
- **Shared folder** — Syncthing.

**Still open:**
1. **How far do you want the MCP "god mode" to reach on day one** — read/status + install only, or full command execution? (Recommend starting gated and expanding.)

---

## 9. Immediate next steps (Phase 0 starter)

1. Decide Q1–Q5 above (or say "you pick" and I'll take the recommended path).
2. I scaffold the **brain service** (job queue + registry + auth + audit) on PLEXSERVER.
3. I write the **agent** + `bootstrap.ps1`, and we install it on one PC (the couch PC is the perfect first target — it proves "set it up without walking over").
4. First end-to-end demo: from the dashboard, **install VLC on the couch PC** and **toggle its PIA** — the two actions that prove the whole architecture.
