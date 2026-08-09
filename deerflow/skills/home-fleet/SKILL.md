---
name: home-fleet
description: >-
  Background knowledge about Cory's home infrastructure: the four PCs on the
  fleet, the HomeDashboard "brain" API and how to query it live, the services
  running on PlexServer (DeerFlow, Plex, YT Grabber, Syncthing), and what this
  agent can and cannot reach from inside its container. Read this before
  answering anything about "my PCs", "the dashboard", "the fleet", "the server",
  "my media", or before trying to reach a machine or service on the home
  network — it saves guessing at hostnames, ports, and reachability.
license: private
---

# Cory's home fleet

Owner: Cory (GitHub `hepler1394`, email `coryh2014@gmail.com`). Never use emojis
in anything produced for him.

## Machines

Verified live from the dashboard on 2026-08-08:

| Host | LAN IP | Notes |
| --- | --- | --- |
| `PLEXSERVER` | `192.168.1.174` | Always-on server. Runs everything below. Tailscale `100.84.102.74`. |
| `MAINPC` | `192.168.1.189` | Cory's main desktop. |
| `MYMEDIACENTER` | `192.168.1.237` | Living-room box. |
| `LAPTOP` | `192.168.1.196` | Frequently offline. |

All four are Windows and joined to Tailscale, so they are reachable off-LAN by
their Tailscale addresses as well. The dashboard agent on PlexServer reports its
own IP as a `172.29.x.x` WSL virtual adapter address — that is not the address to
use; use `192.168.1.174`.

**Windows account names differ per machine — do not assume.** Verified 2026-08-08:

| Host | Account | Desktop |
| --- | --- | --- |
| `MAINPC` | `Cory` | `C:\Users\Cory\Desktop` (not OneDrive-redirected) |
| `PLEXSERVER` | `BigBory` | `C:\Users\BigBory\Desktop` |

`MYMEDIACENTER` and `LAPTOP` accounts are not yet recorded — list `C:\Users` on
them with a `listdir` job before writing a path. Guessing the PlexServer account
name for another machine is the specific mistake to avoid; MainPC is `Cory`, not
`BigBory`. `/devices` does not report the logged-in user, so this table is the
only source.

## The HomeDashboard brain

The dashboard is a Python service ("the brain") on PlexServer port **8788**.
Source lives at `C:\HomeDashboard\brain\brain.py` with the single-page UI in
`brain/ui.html`; the repo is `github.com/hepler1394/HomeDashboard`.

**This agent's container can reach it directly** — verified — at either
`http://host.docker.internal:8788` or `http://192.168.1.174:8788`, and it is
inside the brain's local-trust range, so endpoints work without extra auth.
Useful read-only endpoints:

- `GET /health` — service and agent version
- `GET /devices` — every PC with online state, LAN IP, and live stats
- `GET /jobs`, `GET /history`, `GET /audit` — job queue and activity
- `GET /net`, `GET /forecasts`, `GET /backups` — network, weather, backup status
- `GET /plex/sections`, `GET /plex/search?q=…` — Plex library

Prefer querying `/devices` over repeating the table above; the table is a
snapshot and machines come and go.

Each PC also runs a dashboard agent exposing an HMAC-authenticated command
channel on port **2222** — that is how the dashboard runs commands remotely. It
is not SSH, and this agent does not hold the HMAC key.

## Services on PlexServer

| Service | Port | Notes |
| --- | --- | --- |
| HomeDashboard brain | 8788 | The dashboard UI and API. |
| DeerFlow | 2026 | This system. Docker Desktop, compose project `deer-flow`. |
| YT Grabber | 5117 | Also reverse-proxied by the brain at `/ytgrabber`. |
| Plex | 32400 | Media library, also surfaced in the dashboard. |

`C:\HomeShare` is kept in sync across the fleet by Syncthing. Alerts and some
commands run through a Telegram bot.

## What this agent can and cannot do

Can:

- Reach the brain API and the LAN, as described above.
- Run shell commands, read and write files, and search the web — but all inside
  its own Linux container, not on Windows.

Cannot, without help:

- Touch the Windows filesystem. `C:\HomeDashboard` and `C:\HomeShare` are not
  mounted here; only this repo's `skills/` directory and the DeerFlow data
  directory are.
- Run commands on the other PCs. The port 2222 channel needs an HMAC key this
  agent does not have. Route that work through Cory or the dashboard.
- Control a desktop GUI. There is no computer-use or Parsec access from here.

Say so plainly when a task needs one of those rather than pretending to have
done it.
