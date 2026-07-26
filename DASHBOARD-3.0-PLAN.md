# Home Network Dashboard 3.0 — "The Brain Grows Up"

> 2.0 built the brain: one dashboard that can see and control every PC in the house.
> 3.0 makes it **dependable, reachable from anywhere, and proactive** — a brain that survives reboots without help, works from your phone at the grocery store, watches the house *for* you, and plugs into PlexClaw so the whole media pipeline is one system.

Author: planning pass, 2026-07-11. Owner: Cory. All machines are the owner's own equipment; everything here is authorized personal/homelab use.

---

## 0. Where we actually are (honest snapshot)

**2.0 delivered (all built & verified 2026-07-10/11):**
- Brain (`brain.py`, port 8788) on PLEXSERVER: job queue (SQLite), device registry, audit log, password login, SSE live push, Wake-on-LAN.
- Agent on each PC (`homedash-agent.ps1`): run/install/pia/play/fetch/transfer/backup/applist jobs, heartbeat with CPU/mem/drives/PIA/LAN-IP/MAC.
- Local launcher (`homedash-launcher.ps1`, 127.0.0.1:8799): 1-click Parsec / Remote Desktop / Files from the browser.
- Full UI (`ui.html`): fleet cards with the old dashboard's button row + all drives, install catalog (57 apps, 8 bundles), Plex browser + "Play on any PC", file upload/transfer, AI chat (6 providers incl. the Fangu slot), backups, Telegram, settings, Ctrl-K palette.
- MCP server (`mcp_server.py`, 10 tools) ready to register with Claude.
- Old 8787 dashboard retired (redirects to 8788; still runs hidden as the auto-start vehicle).
- Fleet: PLEXSERVER (.174) + Gaming PC (.189, DESKTOP-QPGMBCI) enrolled. Media PC (.237) self-enrolls via the hourly pull.

**2.0's unpaid tab (the honest part — 3.0 Phase 0 is paying this off):**
1. **Firewall** — brain's Python only has a *Public* inbound allow rule; the home net is *Private*, so other PCs may not reach :8788 until you run (as admin):
   `New-NetFirewallRule -DisplayName "Home Brain 8788" -Direction Inbound -Action Allow -Protocol TCP -LocalPort 8788 -Profile Private`
2. **Password not set yet** — first PC to open the dashboard from LAN should "Create a password."
3. **API keys not pasted** — Settings → AI provider keys (default is claude / claude-haiku-4-5, key pending; the key pasted in chat must be **rotated** first). Plex token + Telegram bot token/chatId also pending.
4. **Persistence is indirect** — brain/agent/launcher only auto-start because the retired 8787 script's Startup shortcut boots them. If that chain breaks, everything breaks. (Fixed properly in Phase 1.)
5. **Tailscale + rclone** — decided yes, never installed (`tailscale up` and `rclone config` are interactive sign-ins only you can do).
6. **Gaming PC runs an older agent** — self-heals on next dashboard restart, but there's no version tracking to *know* that (fixed in Phase 1).
7. Small UI promise: a **"Local only" drives toggle** (gaming PC maps server drives, so the same disk shows twice — correct but noisy).

---

## 1. The three ideas that define 3.0

**2.0's idea was the job queue.** 3.0 has three:

1. **Self-reliance.** Nothing in the system should need Cory to notice it's broken. The brain is a real service with a watchdog; agents report their version and self-update; the brain backs itself up; every piece has a heartbeat and something watching that heartbeat.
2. **Anywhere.** Tailscale turns "works on the couch" into "works at work, at the store, on vacation" — same dashboard, same phone, zero port-forwarding. The UI becomes a proper installable phone app (PWA).
3. **Proactive.** Today the brain answers when asked. 3.0 gives it a **rules engine** (schedules + triggers → actions) and a daily Telegram digest, so it tells *you*: "Media PC's C: hits full in ~9 days," "Gaming PC's VPN dropped an hour ago," "backup failed last night." The AI chat gets the same eyes.

Everything below hangs off these three.

---

## 2. Guiding principles (carried over + new)

1. **Pay the tab before building the penthouse.** Phase 0 finishes 2.0's user-gated leftovers before any new feature.
2. **The brain stays the only trusted surface.** New reach (Tailscale, phone) widens where you connect *from*, never what's exposed. Nothing ever faces the public internet.
3. **Allow-list, don't deny-list** — unchanged, now with per-agent tokens instead of one shared secret.
4. **Every mutating action logged, append-only, on the brain** — and 3.0 finally gives the audit log a *viewer* so it's actually read.
5. **Destructive = human confirm, enforced server-side** — unchanged.
6. **Progressive rollout, every phase shippable** — unchanged. The publish/pull sync pipeline carries every update to every PC automatically.
7. **Keep it simple for the owner.** One password, one URL (`http://192.168.1.174:8788`, later `http://brain:8788` via Tailscale), one Telegram bot. Complexity lives inside the brain, not in front of Cory.

---

## 3. Feature-by-feature design

### A. Bulletproof foundation (self-reliance layer)
The single most valuable thing 3.0 can ship, because everything else stands on it.

- **True persistence** — replace the "8787 Startup-shortcut happens to boot everything" chain with real per-PC startup entries: `HomeDashBrain` (server only), `HomeDashAgent` + `HomeDashLauncher` (every PC), registered by the agent's own bootstrap (Run key or logon scheduled task — one-time approval per PC, then forever). The retired 8787 server can then be *truly* removed.
- **Watchdog** — a tiny loop (inside the agent) that checks the brain (on server) / agent (elsewhere) every minute and restarts it if dead. The brain reciprocates: an agent that misses 3 heartbeats flips its fleet card to "stale" and (Phase 4) pings Telegram.
- **Versioned self-update** — brain and agent each carry a `VERSION`; the heartbeat reports it; the fleet card shows it; "agent outdated" becomes a visible badge with a one-click "Update agent" job (download `/agent` + restart self). No more guessing whether the gaming PC picked up the new code.
- **Brain self-backup** — nightly copy of `brain.db`, `brain-auth.json`, `secret.json`, `catalog.json` to a second drive (and later the rclone remote). Ransomware/disk-death insurance for the thing that controls the house.
- **Health page** — `/health` + a Settings card: brain uptime, DB size, last backup, per-agent version/last-seen/launcher-alive, job error rate. When something's weird, this page says what.

### B. Anywhere: Tailscale + a real phone experience
- **Tailscale on all 3 PCs** (the one interactive step per PC: `tailscale up`). Brain addressed as `plexserver` MagicDNS name; PIA split-tunnel bypasses `100.64.0.0/10`. Agents and UI keep working with VPN up, DHCP churn, or from outside the house.
- **PWA** — manifest + service worker + icon on `ui.html`: "Add to Home Screen" on your phone and the dashboard becomes an app. Works on the couch via LAN, works anywhere via Tailscale on the phone.
- **Mobile layout pass** — fleet cards stack, drive grids collapse, buttons get thumb-sized, Ctrl-K becomes a search button. Same file, media queries only.
- **Phone-first actions** — the four things you actually want from the store: is everything online, is the VPN on, wake a PC, play something on the media PC. Front and center on small screens.

### C. Proactive brain: rules engine + daily digest
A small scheduler inside `brain.py` (no new dependencies — a thread and a `rules.json`):

- **Triggers:** time-of-day / interval, drive ≥ N%, PC offline > N min, PIA state change, backup result, job failure, new device on network (see G), agent version mismatch.
- **Actions:** Telegram message, enqueue any existing job type (backup, install, pia, run allow-listed), flag in UI.
- **Starter rules shipped by default:** nightly backup at 2am → digest result; drive ≥90% → alert with the *forecast* ("full in ~N days," ported from v1's history math); PC offline 10 min → alert; PIA drops on a PC that had it on → alert.
- **Morning digest (Telegram, ~7am):** one message — fleet up/down, disks at a glance with forecasts, last backup, anything the rules flagged overnight. The "know everything" promise, delivered without opening anything.
- **Rules UI** — a simple Settings card: toggle each rule, edit thresholds/times. Not a visual programming language — a checklist.
- **History returns** — the brain records per-PC CPU/mem/drive samples into SQLite (the agents already send them every poll; today they're discarded). Sparklines come back to the fleet cards, now fleet-wide, and power the forecasts.

### D. AI 3.0: a chat with eyes, memory, and a cheap local option
- **Context injection** — every AI chat turn gets a compact live fleet snapshot (same data as the digest) so "why is the server slow?" or "which PC has room for 200GB?" get real answers without tool round-trips.
- **AI reads history** — new tools: `history(pc, metric)`, `audit(last N)`, `job_status(id)`. "What happened last night?" becomes answerable.
- **Proactive AI (opt-in)** — the morning digest optionally runs *through* the AI first: raw stats → 3-sentence human summary + anything it thinks deserves attention. Costs pennies on haiku.
- **Local model slot (Ollama)** — the gaming PC has the GPU; the agent can install Ollama from the catalog. Add `ollama` as a 7th provider (base URL `http://<gamingpc>:11434/v1`, OpenAI-shaped). Free, private, no key to rotate — good default for digests/summaries; cloud providers stay for the smart stuff.
- **Voice via Telegram** — Telegram voice notes → (provider transcription) → same command pipeline. "Hey, wake the media PC" from the car. (Stretch; only if the rest lands.)

### E. Media 3.0: PlexClaw ⇄ Brain bridge
Two systems on the same box that don't know about each other yet. Bridge them:

- **Request pipeline** — dashboard/Telegram "request a movie/show" → hands off to PlexClaw's existing download pipeline → progress surfaces as a brain job → "Added to Plex" Telegram ping when the library updates. `/request Andor S2` from your phone, notification when it's watchable.
- **Download status card** — a Media-tab card showing PlexClaw's active downloads/enrichment (PlexClaw exposes a small read-only status endpoint; the brain proxies it).
- **Watch stats** — PlexClaw's new watch-insights work surfaces in the dashboard's Media tab (most-watched, recently added, who's watching now via Plex sessions).
- **"Continue watching, but over there"** — pick a Plex session and re-launch it on another PC's VLC at the same offset (Plex API gives `viewOffset`; VLC takes `--start-time`).
- **Boundaries:** the bridge is read-mostly; PlexClaw keeps owning downloads. One new allow-listed brain endpoint per direction, token-gated like everything else.

### F. Fleet-wide file search
v1 had per-PC search (Everything/flat index). 3.0 federates it:
- Search box queries **all online agents in parallel** (new `search` job type → agent hits its local Everything HTTP port or falls back to the flat index) and merges results tagged by PC.
- Result actions: open folder (launcher), send-to-PC (existing transfer), play (if media).
- "Where did I put that ISO?" works across the whole house from one box. Everything (voidtools) goes in the standard install bundle so every PC gets the fast path.

### G. Whole-home awareness (beyond the 3 PCs)
The dashboard only knows PCs with agents. The house has more:
- **Network scan** — brain ARP-scans the LAN on a schedule; known devices get names (router, phones, TV, printer); new/unknown MACs raise a "new device joined Wi-Fi" alert (a genuinely useful security signal).
- **Presence** — phones on/off Wi-Fi ≈ who's home. Purely informational, feeds rules ("everyone's phone gone + gaming PC idle 2h → offer sleep" — *offer*, never auto-power).
- **Internet health** — brain pings out every minute + hourly speed sample; uptime/speed history on the dashboard; "internet down at 3:12am for 6 min" in the digest. Ammunition for ISP arguments.
- Router/IoT *control* is explicitly **out of scope** — awareness only.

### H. Remote eyes (see the screen, not just the stats)
- **Screenshot job** — new agent job type: capture the desktop, POST to brain, show in the PC detail view. "Is something stuck on the media PC's screen?" answered in one click. (Screenshots are of your own PCs, stored transiently, served only to the authed UI.)
- **MeshCentral (optional, self-hosted)** — the 2.0 plan's answer for full remote desktop in the browser. Revisit only if Parsec/RDP via the launcher isn't enough — it's a real server to run and Parsec already covers the couch-gaming case.

### I. Security 3.0 (the audit finally gets teeth)
- **Per-agent tokens** — replace the single shared secret: each agent gets its own token at enroll; brain can revoke one PC without re-keying the house.
- **Audit viewer** — a Settings tab rendering the append-only log (filter by PC/action/date). Logs nobody reads are decoration.
- **Kill switch in the UI** — one red toggle that flips the brain to read-only (heartbeats/status keep flowing; all mutating jobs 403). Already a principle, becomes a button.
- **Login hardening** — rate-limit `/login` (5 tries → 5-min lockout), session tokens instead of storing the master token in localStorage, sessions expire monthly.
- **Tailscale-only mode (later)** — once Tailscale is on everything, optionally bind the brain to loopback + the Tailscale interface and drop the LAN firewall rule entirely. Strictly smaller attack surface; do it when convenient, not before.

### J. UI polish backlog (cheap wins, sprinkle throughout)
- "Local only" drives toggle (the promised de-dup for mapped drives).
- Job/transfer history panel (what ran, when, exit codes) — the audit viewer's friendlier sibling.
- Per-PC notes field ("this is the couch PC, HDMI 2").
- Density/focus modes and hide-offline, ported from the 2.0 wish list.
- Update-all button per PC once `applist/updates` (already in the agent) is surfaced.

---

## 4. Phased roadmap

> Same contract as 2.0: each phase ships something usable, syncs house-wide via the existing publish/pull pipeline, and nothing depends on a later phase.

**Phase 0 — Pay the tab (user + assistant, ~1 sitting).**
Firewall rule (user, admin, one command — §0.1) → set the dashboard password → rotate + paste API keys, Plex token, Telegram token → `tailscale up` on the 3 PCs (user; assistant preps configs + PIA split-tunnel) → verify Media PC enrolled. *Exit test: phone on Tailscale loads the dashboard from off-LAN and wakes a PC.*

**Phase 1 — Bulletproof (A). ✅ BUILT 2026-07-11 (v3.1.0).** Run-key startup entries (agent self-registers `HomeDashAgent` + `HomeDashBrain`, no admin); mutual watchdog (agent revives launcher + brain every 60s, launcher revives agent); versioned agents with automatic self-update (brain advertises the expected version in every poll response); daily brain self-backup to a second fixed drive (7 kept, sqlite-consistent, verified on G:); `/health` endpoint + System-health card in Settings. 8787 kept intentionally as a redirect/second bootstrap — it is no longer load-bearing, which was the real goal. Old agents (gaming/media PC) migrate automatically via the HomeDashboard.ps1 hash-compare bridge within the hour.

**Phase 2 — Anywhere (B). ✅ BUILT 2026-07-11 (brain v3.2.0).** PWA shell (manifest + network-first service worker + brain-glyph icons, served by the brain); mobile layout ≤820px (sidebar → bottom tab bar, stacked cards, thumb-sized buttons, 🔍 palette button); Fleet quick strip on phones (per-PC online pill, tap-to-toggle VPN, Wake when offline, ▶ Play shortcut). Verified: desktop unchanged, phone viewport renders with no horizontal scroll, tabs navigate, SW controlling on localhost. *Honest note: the full "installs like an app" standalone experience on Android needs HTTPS — that arrives free with Tailscale (`tailscale serve`) in Phase 0/later; until then Android opens it as a browser shortcut, iPhone "Add to Home Screen" works standalone over HTTP.* Remaining user step: open the dashboard on the phone and Add to Home Screen.

**Phase 3 — Proactive (C). ✅ BUILT 2026-07-11 (brain v3.3.0).** History recording (per-PC CPU/mem/local-drive samples every 2 min into SQLite, 14-day retention); rules engine replacing the old alert loop — six configurable rules (drive ≥N% with fill-forecast, offline >N min with back-online notice, VPN drop, job failure, morning digest hour, nightly backup hour), state tracked even while Telegram is off so nothing false fires later; morning digest (PCs, VPN, hot disks with "full in ~Nd", self-backup, jobs 24h); Settings card with toggles/thresholds + "Send test digest" preview; 24h CPU sparklines on fleet cards; drive cards show fill forecasts. Verified: samples accumulate, rules save/load, digest composes correctly (preview shown in UI; Telegram send activates the moment the bot token is added in Phase 0). *The 7am digest and live alerts start reaching the phone as soon as the Telegram bot is configured.*

**Phase 4 — AI 3.0 (D). ✅ COMPLETE 2026-07-11 (brain v3.6.1, agent v3.4.1).** Fleet-context injection (live snapshot in every chat), history/audit/job_status AI tools, AI-written digest, Ollama on the gaming PC's GPU. Owner chose **small-local + cloud**: the free local model (llama3.2:3b, ~1s warm on the GPU) writes the daily digest; the Claude key drives the acting chat. *Exit test PASSED: chat answered "PLEXSERVER K: 93%, DESKTOP-QPGMBCI not on VPN" from the live snapshot via Claude (3.3s); the AI digest arrived on Telegram written in warm sentences via the free local model (3.7s).* Minor follow-ups logged (stream the agent's Ollama-pull progress instead of blocking; dedupe duplicate agents; expire stale jobs).

**Phase 5 — Media bridge (E). ✅ BUILT 2026-07-11 (brain v3.5.0, agent v3.3.0, PlexClaw bridge v1.0).** New `backend/brain_bridge.py` in PlexClaw: loopback-only sidecar on :8790 inside the always-running headless cron — /status (qBit downloads, Plex now-playing, recently added, watch-report totals), /request (same smart_download pipeline as the bot), /playurl (continue-watching URLs). Brain proxies it (/claw/*), remembers pending requests, and the rules loop pings Telegram when a request lands in Plex. Telegram gained `/request <title> [year]`. Media tab rebuilt: request box, now-playing with "Continue on <PC>" (VLC resumes at the right spot via agent 3.3.0 `--start-time`), live download progress, recently-added, watch-stats chips (fun fact surfaced: 2,178 items, 5.3% ever watched, 6.5TB never-watched). Verified end-to-end with a can't-exist title (search ran, honest not_found, nothing downloaded). Bonus fix: restarting the cron surfaced a latent syntax error in media_cron.py (torn duplicate lines from an old edit) — repaired, engine healthy.

**Phase 6 — Search + awareness (F, G). ✅ BUILT 2026-07-11 (brain v3.6.0, agent v3.4.1).** Fleet-wide file search (new agent `search` job → Everything :8011 or the v1 flat index; brain `/search` fans out to every online PC in parallel and merges results tagged by PC — verified 40 merged hits). Passive network awareness: ARP ping-sweep every 30 min → device table with new-device Telegram alerts (baselines silently on first scan), internet up/down probe every 60s, hourly speed sample; new "Network" sidebar view (internet card + nameable 22-device table) and digest lines. Two new alert toggles (new device, internet down). Verified: search UI, network scan (22 devices, auto-labeled our own PCs), internet UP. *Presence tracking deliberately omitted per §7. Caught + fixed a real reliability gap mid-build (see note).* 

> **Reliability lesson banked (2026-07-11):** self-update keys only on the version *string*, so a same-version *content* change can silently ship a broken agent that the launcher then restart-loops. It bit us once (a corrupt intermediate 3.4.0 got self-pulled before the fix). Rule going forward, now habit: **any agent code change gets a version bump**, never an in-place edit at the same version. Recovered by bumping to 3.4.1 + re-pushing.

**Phase 7 — Eyes + security teeth (H, I). ✅ BUILT 2026-07-11 (brain v3.8.0, agent v3.5.1).** Kill switch (read-only mode freezes all fleet actions while status keeps flowing — verified 403 on a job then restored), audit-log viewer (Settings → Security, filterable, newest-first), login rate-limit (5 bad tries → 5-min lockout, verified), opt-in screenshots (per-PC, off by default; agent GDI capture → brain → PC-detail view; verified a real 259KB desktop capture on the server), and browser session tokens (login now issues a 30-day expiring token instead of the permanent master key, + "sign out all browsers"). *Per-agent tokens deliberately deferred (see note) — the one planned item with real lockout risk and, on a 3-PC trusted LAN, modest benefit; better done as a careful dedicated pass. MeshCentral skipped per §7 (Parsec/RDP suffices).*

> **Per-agent tokens — reasoned deferral:** the plan called for replacing the shared master secret with a per-agent revocable token. Building it safely requires the brain to tell agents apart from browsers, but both connect from the LAN over the same origin, so without per-agent identity the master token can't be forbidden to browsers either — i.e. session tokens are a *partial* win until per-agent tokens land. However, doing it wrong locks the whole fleet out (agents can't auth → no control at all). On a firewalled home network with 3 trusted PCs, the marginal security gain doesn't justify that risk in a long build session. Recommendation: implement it later in a focused pass with the master token retained as an always-valid recovery key.

**Phase 8 — Polish (J).** The UI backlog, as energy allows.

---

## STATUS 2026-07-11: Phases 1–7 all BUILT & VERIFIED. Brain v3.8.0, agents v3.5.1.
The 3.0 vision is delivered: the fleet self-heals (watchdogs, versioned self-update, self-backup), reaches anywhere (PWA + mobile, Tailscale-ready), runs proactively (rules engine + morning Telegram digest + AI written by a free local model on the gaming PC's GPU), bridges PlexClaw (request-from-phone + watch stats), searches every PC + watches the network, and has a real security layer (kill switch, audit viewer, rate-limit, opt-in screenshots, expiring sessions). Open follow-ups, all logged: per-agent tokens (deferred, reasoned), agent duplicate-dedupe, stream Ollama-pull progress, Phase 8 UI polish. Phase 0 owner tasks (Tailscale sign-ins on all PCs, firewall rule if not done) remain the user's to finish for full off-LAN/HTTPS.

---

## 5. Security & safety (delta from 2.0)

Everything in the 2.0 §6 stands. New in 3.0:
- Per-agent tokens with UI revocation (replaces the single shared secret).
- Kill switch becomes a physical button in Settings, not just a flag.
- `/login` rate-limiting + expiring sessions.
- Screenshots: transient storage, authed-UI-only, never synced or logged.
- Network scan is **passive awareness only** — the brain never gets tools to touch the router, IoT, or anyone else's devices.
- Rules engine can only trigger **already-allow-listed job types**; a rule is config, never code.
- Tailscale-only bind mode as the eventual end-state (drop the LAN firewall hole once the overlay is everywhere).

---

## 6. Tech stack (delta)

| Layer | Pick | Why |
|---|---|---|
| Everything from 2.0 | unchanged | it works |
| Scheduler/rules | thread + `rules.json` inside brain.py | no new deps, pure stdlib |
| History store | same SQLite (`brain.db`), rolling window | data already arrives in heartbeats |
| Phone app | PWA (manifest + service worker) | no app store, no build step |
| Local AI | Ollama on the gaming PC, OpenAI-shaped `/v1` | free, private, GPU is right there |
| Net scan | ARP table + ping sweep from brain | stdlib, passive |
| Screenshots | agent `Add-Type` GDI capture → POST | no installs |
| PlexClaw bridge | small HTTP endpoints both ways, token-gated | keeps ownership boundaries clean |

---

## 7. Open questions — DECIDED 2026-07-11 (owner said "take the recommended path")

1. **Ollama on the gaming PC** — **YES.** Install via the catalog when Phase 4 lands (~4GB model on its disk, GPU used only when asked). Makes the AI digest free.
2. **Presence tracking** — **SKIP for now.** Phase 6 ships the network scan + new-device alerts (the security-useful part) without the "who's home" inference. Easy to add later if wanted.
3. **Screenshots** — **OPT-IN per PC.** Off by default; a per-PC toggle in its detail view enables the screenshot job for that machine only.
4. **MeshCentral** — **SKIP.** Parsec + RDP via the local launcher already cover remote desktop; no new server to babysit.
5. **Phase order** — **KEEP as written**: reliability → anywhere → proactive → AI → media bridge. Nothing jumps the queue.

---

## 8. Immediate next steps

1. Run the Phase 0 checklist together (one sitting: firewall command, password, keys, `tailscale up` ×3).
2. Assistant builds Phase 1 (it's all code on the brain/agent — no user gates except the one-time startup-entry approval per PC).
3. First 3.0 demo: **pull the server's power plug, plug it back in, and watch the whole system come back by itself** — then check your phone for the digest that says it did.
