"""
YT Grabber - AI-powered YouTube search, download, library & channel watcher.
Local only. For downloading videos you own or are licensed to download.
"""
import hashlib
import json
import os
import re
import subprocess
import threading
import time
import uuid
import webbrowser
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import requests
from flask import (Flask, Response, jsonify, render_template, request,
                   send_file, abort)

import yt_dlp

APP_DIR = Path(__file__).parent
CONFIG_PATH = APP_DIR / "config.json"
COOKIES_TXT = APP_DIR / "cookies.txt"

VIDEO_EXTS = {".mp4", ".mkv", ".webm", ".mov", ".m4v", ".avi", ".flv", ".mp3", ".m4a", ".opus"}

DEFAULT_CONFIG = {
    "download_dir": str(Path.home() / "Videos" / "YT Grabber"),
    "bind_host": "127.0.0.1",        # 0.0.0.0 = reachable over Tailscale/LAN
    "youtube_api_keys": [],
    "search_engine": "ytdlp",        # 'ytdlp' (accurate, no quota) or 'api'
    "active_ai_provider": "",
    "watched_channels": [],          # [{channel_id,title,url,last_video_id,thumbnail,auto_download}]
    "watch_interval_min": 30,
    "auto_download_new": False,      # master switch (per-channel toggles gate it)
    "auto_categorize": True,         # Qwen sorts each new download into a category
    "categories": [
        "Commercials & Ads", "Music", "Gaming", "News", "Politics",
        "True Crime", "Sports", "Movies & TV", "Education & How-To",
        "Comedy & Entertainment", "Documentary & History", "Other",
    ],
    "ai_providers": {
        "openai":     {"api_key": "", "model": "gpt-4o-mini"},
        "anthropic":  {"api_key": "", "model": "claude-3-5-haiku-latest"},
        "gemini":     {"api_key": "", "model": "gemini-2.0-flash"},
        "deepseek":   {"api_key": "", "model": "deepseek-chat"},
        "openrouter": {"api_key": "", "model": "openai/gpt-4o-mini"},
        "groq":       {"api_key": "", "model": "llama-3.3-70b-versatile"},
        "local":      {"api_key": "", "model": "qwen2.5",
                       "base_url": "http://localhost:11434/v1"},
    },
    "ytdlp": {
        "best_quality": True,
        "prefer_mp4": True,
        "embed_thumbnail": True,
        "embed_metadata": True,
        "write_thumbnail": True,
        "write_info_json": True,
        "write_subs": False,
        "auto_subs": False,
        "audio_only": False,
        "restrict_filenames": False,
        "subfolder_per_search": True,
        "skip_downloaded": True,
        "cookies_browser": "",
        "cookie_file": str(COOKIES_TXT) if COOKIES_TXT.exists() else "",
        "concurrent_downloads": 4,
        "filename_template": "%(title)s [%(id)s].%(ext)s",
        "rate_limit_kbps": 0,
    },
}


def load_config():
    cfg = json.loads(json.dumps(DEFAULT_CONFIG))
    if CONFIG_PATH.exists():
        try:
            saved = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
            for k, v in saved.items():
                if isinstance(v, dict) and isinstance(cfg.get(k), dict):
                    for k2, v2 in v.items():
                        if isinstance(v2, dict) and isinstance(cfg[k].get(k2), dict):
                            cfg[k][k2].update(v2)
                        else:
                            cfg[k][k2] = v2
                else:
                    cfg[k] = v
        except Exception:
            pass
    # auto-attach saved cookies.txt if present and none configured
    if COOKIES_TXT.exists() and not cfg["ytdlp"].get("cookie_file") \
            and not cfg["ytdlp"].get("cookies_browser"):
        cfg["ytdlp"]["cookie_file"] = str(COOKIES_TXT)
    return cfg


def save_config(cfg):
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


config = load_config()
app = Flask(__name__)


# --------------------------------------------------------------- shared utils

def archive_path():
    return Path(config["download_dir"]) / "downloaded_archive.txt"


def categories_path():
    return Path(config["download_dir"]) / "categories.json"


cat_lock = threading.Lock()


def load_categories_store():
    try:
        return json.loads(categories_path().read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_categories_store(store):
    try:
        categories_path().parent.mkdir(parents=True, exist_ok=True)
        categories_path().write_text(json.dumps(store, indent=2), encoding="utf-8")
    except Exception:
        pass


ID_IN_NAME = re.compile(r"\[([\w-]{11})\]")


def key_for(stem_or_rel):
    """Prefer the YouTube id embedded in the filename, else the path itself."""
    m = ID_IN_NAME.search(stem_or_rel)
    return m.group(1) if m else stem_or_rel


def classify_title(title):
    """Ask the active model to bucket a title into one configured category."""
    cats = config.get("categories", [])
    provider = config.get("active_ai_provider")
    if not provider or not cats:
        return ""
    system = ("You classify a video by its title into exactly ONE category from "
              "this list: " + "; ".join(cats) + ". Reply with only the exact "
              "category name, nothing else.")
    try:
        out = call_ai(provider, f"Title: {title}", system).strip()
    except Exception:
        return ""
    # match to a real category (case-insensitive / substring safe)
    low = out.lower()
    for c in cats:
        if c.lower() == low:
            return c
    for c in cats:
        if c.lower() in low or low in c.lower():
            return c
    return cats[-1] if cats else ""  # fall back to last ("Other")


def categorize_and_store(video_id, title):
    if not config.get("auto_categorize"):
        return
    cat = classify_title(title)
    if not cat:
        return
    with cat_lock:
        store = load_categories_store()
        store[video_id] = cat
        save_categories_store(store)


def load_archive_ids():
    try:
        return {line.split()[-1] for line in
                archive_path().read_text(encoding="utf-8").splitlines() if line.strip()}
    except FileNotFoundError:
        return set()


def cookie_opts():
    y = config["ytdlp"]
    o = {}
    if y.get("cookie_file") and Path(y["cookie_file"]).exists():
        o["cookiefile"] = y["cookie_file"]
    elif y.get("cookies_browser"):
        o["cookiesfrombrowser"] = (y["cookies_browser"],)
    return o


def fmt_secs(s):
    try:
        s = int(s)
    except (TypeError, ValueError):
        return ""
    h, m, sec = s // 3600, (s % 3600) // 60, s % 60
    return f"{h}:{m:02}:{sec:02}" if h else f"{m}:{sec:02}"


def fmt_count(n):
    try:
        n = int(n)
    except (TypeError, ValueError):
        return ""
    for div, suf in ((1_000_000_000, "B"), (1_000_000, "M"), (1_000, "K")):
        if n >= div:
            return f"{n / div:.1f}".rstrip("0").rstrip(".") + suf
    return str(n)


ISO_DUR = re.compile(r"PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?")


def fmt_iso_duration(iso):
    m = ISO_DUR.match(iso or "")
    if not m:
        return ""
    h, mi, s = (int(x) if x else 0 for x in m.groups())
    return f"{h}:{mi:02}:{s:02}" if h else f"{mi}:{s:02}"


def best_thumb(entry):
    if entry.get("thumbnail"):
        return entry["thumbnail"]
    thumbs = entry.get("thumbnails") or []
    if thumbs:
        # pick a medium-large one
        withw = [t for t in thumbs if t.get("width")]
        if withw:
            withw.sort(key=lambda t: t["width"])
            return withw[min(len(withw) - 1, len(withw) * 2 // 3)]["url"]
        return thumbs[-1].get("url", "")
    vid = entry.get("id", "")
    return f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg" if vid else ""


# ----------------------------------------------------------- search: yt-dlp

def ytdlp_search(query, n):
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True,
            "skip_download": True, "default_search": "ytsearch"}
    opts.update(cookie_opts())
    arch = load_archive_ids()
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"ytsearch{n}:{query}", download=False)
    out = []
    for e in info.get("entries", []) or []:
        if not e or not e.get("id"):
            continue
        out.append({
            "id": e["id"],
            "title": e.get("title", ""),
            "channel": e.get("channel") or e.get("uploader", ""),
            "published": "",
            "thumbnail": best_thumb(e),
            "duration": fmt_secs(e.get("duration")),
            "views": fmt_count(e.get("view_count")),
            "description": (e.get("description") or "")[:200],
            "downloaded": e["id"] in arch,
        })
    return out


# --------------------------------------------------------------- search: API

YT_SEARCH = "https://www.googleapis.com/youtube/v3/search"
YT_VIDEOS = "https://www.googleapis.com/youtube/v3/videos"
YT_CHANNELS = "https://www.googleapis.com/youtube/v3/channels"
YT_PLAYLISTS = "https://www.googleapis.com/youtube/v3/playlists"
YT_PLAYLIST_ITEMS = "https://www.googleapis.com/youtube/v3/playlistItems"


class QuotaExhausted(Exception):
    pass


def yt_get(url, params):
    keys = config.get("youtube_api_keys") or []
    if not keys:
        raise RuntimeError("No YouTube API key set (needed for API engine). "
                           "Switch to the yt-dlp engine in Settings, or add a key.")
    last = None
    for key in keys:
        r = requests.get(url, params=dict(params, key=key), timeout=20)
        if r.status_code == 200:
            return r.json()
        try:
            err = r.json().get("error", {})
        except Exception:
            err = {}
        reason = err.get("errors", [{}])[0].get("reason", "")
        last = f"{err.get('code', r.status_code)}: {err.get('message', r.text[:200])}"
        if reason in ("quotaExceeded", "dailyLimitExceeded", "rateLimitExceeded"):
            continue
        raise RuntimeError(last)
    raise QuotaExhausted(f"All API keys exhausted. Last error: {last}")


def api_video_details(ids):
    arch = load_archive_ids()
    details = []
    for i in range(0, len(ids), 50):
        d = yt_get(YT_VIDEOS, {"part": "contentDetails,statistics,snippet",
                               "id": ",".join(ids[i:i + 50])})
        details.extend(d.get("items", []))
    out = []
    for v in details:
        sn = v["snippet"]
        t = sn.get("thumbnails", {})
        thumb = (t.get("high") or t.get("medium") or t.get("default") or {}).get("url", "")
        out.append({
            "id": v["id"], "title": sn.get("title", ""),
            "channel": sn.get("channelTitle", ""),
            "published": (sn.get("publishedAt") or "")[:10], "thumbnail": thumb,
            "duration": fmt_iso_duration(v.get("contentDetails", {}).get("duration")),
            "views": fmt_count(v.get("statistics", {}).get("viewCount")),
            "description": (sn.get("description") or "")[:200],
            "downloaded": v["id"] in arch,
        })
    return out


@app.route("/api/search")
def api_search():
    q = request.args.get("q", "").strip()
    if not q:
        return jsonify({"error": "Empty query"}), 400
    want = min(int(request.args.get("max", 50)), 200)
    engine = request.args.get("engine") or config.get("search_engine", "ytdlp")
    try:
        if engine == "ytdlp":
            return jsonify({"query": q, "results": ytdlp_search(q, want),
                            "engine": "ytdlp"})
        # API engine
        order = request.args.get("order", "relevance")
        duration = request.args.get("duration", "any")
        cc = request.args.get("cc") == "1"
        items, page = [], None
        while len(items) < want:
            p = {"part": "snippet", "q": q, "type": "video",
                 "maxResults": min(50, want - len(items)), "order": order,
                 "safeSearch": "none"}
            if duration != "any":
                p["videoDuration"] = duration
            if cc:
                p["videoLicense"] = "creativeCommon"
            if page:
                p["pageToken"] = page
            data = yt_get(YT_SEARCH, p)
            items.extend(data.get("items", []))
            page = data.get("nextPageToken")
            if not page:
                break
        ids = [i["id"]["videoId"] for i in items if i.get("id", {}).get("videoId")]
        return jsonify({"query": q, "results": api_video_details(ids), "engine": "api"})
    except (RuntimeError, QuotaExhausted) as e:
        return jsonify({"error": str(e)}), 502


@app.route("/api/channel")
def api_channel():
    """List videos from channel / playlist / single-video URL via yt-dlp (no quota)."""
    url = request.args.get("url", "").strip()
    want = min(int(request.args.get("max", 200)), 1000)
    if not re.search(r"(youtube\.com|youtu\.be)", url):
        return jsonify({"error": "Not a YouTube URL."}), 400
    # normalize a channel URL to its videos tab
    if re.search(r"youtube\.com/(@[\w.\-]+|channel/UC[\w-]+|c/[\w.\-]+|user/[\w.\-]+)$", url):
        url = url.rstrip("/") + "/videos"
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True,
            "skip_download": True, "playlistend": want}
    opts.update(cookie_opts())
    arch = load_archive_ids()
    try:
        with yt_dlp.YoutubeDL(opts) as ydl:
            info = ydl.extract_info(url, download=False)
    except Exception as e:
        return jsonify({"error": f"Could not load: {str(e)[:200]}"}), 502
    title = info.get("title") or info.get("channel") or "Results"
    entries = info.get("entries")
    if entries is None:  # single video
        entries = [info]
    out = []
    for e in entries:
        if not e or not e.get("id"):
            continue
        out.append({
            "id": e["id"], "title": e.get("title", ""),
            "channel": e.get("channel") or e.get("uploader") or info.get("channel", ""),
            "published": "", "thumbnail": best_thumb(e),
            "duration": fmt_secs(e.get("duration")),
            "views": fmt_count(e.get("view_count")),
            "description": (e.get("description") or "")[:200],
            "downloaded": e["id"] in arch,
        })
    return jsonify({"query": title, "results": out})


# ------------------------------------------------------------------ downloads

jobs = {}
jobs_lock = threading.Lock()
executor = None


def get_executor():
    global executor
    if executor is None:
        w = int(config["ytdlp"].get("concurrent_downloads", 4)) or 4
        executor = ThreadPoolExecutor(max_workers=w)
    return executor


class CancelledByUser(Exception):
    pass


def build_ydl_opts(job, subfolder=""):
    y = config["ytdlp"]
    outdir = Path(config["download_dir"])
    if y.get("subfolder_per_search") and subfolder:
        safe = re.sub(r'[<>:"/\\|?*]', "_", subfolder)[:80].strip()
        outdir = outdir / safe
    outdir.mkdir(parents=True, exist_ok=True)
    opts = {
        "outtmpl": str(outdir / y.get("filename_template", "%(title)s [%(id)s].%(ext)s")),
        "noplaylist": True, "quiet": True, "no_warnings": True,
        "restrictfilenames": bool(y.get("restrict_filenames")),
        "writethumbnail": bool(y.get("write_thumbnail") or y.get("embed_thumbnail")),
        "writeinfojson": bool(y.get("write_info_json")),
        "postprocessors": [],
        "progress_hooks": [lambda d: progress_hook(job["id"], d)],
    }
    opts.update(cookie_opts())
    if y.get("audio_only"):
        opts["format"] = "bestaudio/best"
        opts["postprocessors"].append({"key": "FFmpegExtractAudio",
                                       "preferredcodec": "mp3", "preferredquality": "0"})
    else:
        opts["format"] = "bestvideo*+bestaudio/best" if y.get("best_quality", True) else "best"
        if y.get("prefer_mp4"):
            opts["merge_output_format"] = "mp4"
            opts["postprocessors"].append({"key": "FFmpegVideoRemuxer",
                                           "preferedformat": "mp4"})
    if y.get("write_subs"):
        opts["writesubtitles"] = True
    if y.get("auto_subs"):
        opts["writeautomaticsub"] = True
    if y.get("embed_metadata"):
        opts["postprocessors"].append({"key": "FFmpegMetadata"})
    if y.get("embed_thumbnail"):
        opts["postprocessors"].append({"key": "FFmpegThumbnailsConvertor", "format": "jpg"})
        opts["postprocessors"].append({"key": "EmbedThumbnail",
                                       "already_have_thumbnail": bool(y.get("write_thumbnail"))})
    rate = int(y.get("rate_limit_kbps") or 0)
    if rate > 0:
        opts["ratelimit"] = rate * 1024
    if y.get("skip_downloaded", True):
        opts["download_archive"] = str(archive_path())
    return opts


def progress_hook(job_id, d):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job:
            return
        if job["status"] == "cancelled":
            raise CancelledByUser()
        if d["status"] == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            done = d.get("downloaded_bytes") or 0
            job["progress"] = round(done / total * 100, 1) if total else 0
            job["speed"] = d.get("_speed_str", "").strip()
            job["eta"] = d.get("_eta_str", "").strip()
            job["status"] = "downloading"
        elif d["status"] == "finished":
            job["progress"] = 100
            job["status"] = "processing"
            job["filepath"] = d.get("filename", "")


def run_download(job_id, subfolder):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job or job["status"] == "cancelled":
            return
        job["status"] = "starting"
    url = f"https://www.youtube.com/watch?v={job['video_id']}"
    try:
        with yt_dlp.YoutubeDL(build_ydl_opts(job, subfolder)) as ydl:
            ydl.download([url])
        with jobs_lock:
            job["status"] = "done"
            job["progress"] = 100
        # auto-categorize in the background (non-blocking)
        threading.Thread(target=categorize_and_store,
                         args=(job["video_id"], job.get("title", "")),
                         daemon=True).start()
    except Exception as e:
        with jobs_lock:
            if job["status"] == "cancelled" or isinstance(e, CancelledByUser) \
                    or "CancelledByUser" in str(e):
                job["status"] = "cancelled"
            else:
                job["status"] = "error"
                job["error"] = str(e)[:300]


def queue_video(v, subfolder, arch=None):
    """Create a job for one video dict {id,title,thumbnail} and start it.
    Returns 'queued', 'skipped', or job id string. Assumes caller may hold arch."""
    if arch is None:
        arch = load_archive_ids() if config["ytdlp"].get("skip_downloaded", True) else set()
    jid = uuid.uuid4().hex[:10]
    already = v["id"] in arch
    entry = {
        "id": jid, "video_id": v["id"], "title": v.get("title", v["id"]),
        "thumbnail": v.get("thumbnail", ""), "subfolder": subfolder,
        "status": "skipped" if already else "queued",
        "progress": 100 if already else 0, "speed": "", "eta": "",
        "error": "", "filepath": "",
    }
    with jobs_lock:
        jobs[jid] = entry
    if already:
        return "skipped"
    get_executor().submit(run_download, jid, subfolder)
    return jid


def auto_download_channel(ch, fresh_videos):
    """If master + per-channel auto-download are on, queue the fresh uploads."""
    if not config.get("auto_download_new"):
        return
    if not ch.get("auto_download"):
        return
    sub = ch.get("title", "") if config["ytdlp"].get("subfolder_per_search") else ""
    for v in fresh_videos:
        queue_video({"id": v["id"], "title": v["title"], "thumbnail": v["thumbnail"]}, sub)


@app.route("/api/download", methods=["POST"])
def api_download():
    data = request.get_json(force=True)
    videos = data.get("videos", [])
    subfolder = data.get("subfolder", "")
    arch = load_archive_ids() if config["ytdlp"].get("skip_downloaded", True) else set()
    created, skipped = [], 0
    for v in videos:
        r = queue_video(v, subfolder, arch)
        if r == "skipped":
            skipped += 1
        else:
            created.append(r)
    return jsonify({"queued": created, "skipped": skipped})


@app.route("/api/progress")
def api_progress():
    with jobs_lock:
        return jsonify({"jobs": list(jobs.values())[::-1]})


@app.route("/api/jobs/clear", methods=["POST"])
def api_jobs_clear():
    with jobs_lock:
        for jid in [j for j, job in jobs.items()
                    if job["status"] in ("done", "error", "cancelled", "skipped")]:
            del jobs[jid]
    return jsonify({"ok": True})


@app.route("/api/jobs/<job_id>/cancel", methods=["POST"])
def api_job_cancel(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
        if job and job["status"] in ("queued", "starting", "downloading", "processing"):
            job["status"] = "cancelled"
    return jsonify({"ok": True})


@app.route("/api/jobs/<job_id>/retry", methods=["POST"])
def api_job_retry(job_id):
    with jobs_lock:
        job = jobs.get(job_id)
        if not job or job["status"] not in ("error", "cancelled"):
            return jsonify({"ok": False}), 400
        job.update(status="queued", progress=0, error="", speed="", eta="")
        sub = job.get("subfolder", "")
    get_executor().submit(run_download, job_id, sub)
    return jsonify({"ok": True})


@app.route("/api/jobs/cancel_all", methods=["POST"])
def api_jobs_cancel_all():
    with jobs_lock:
        for job in jobs.values():
            if job["status"] in ("queued", "starting", "downloading"):
                job["status"] = "cancelled"
    return jsonify({"ok": True})


# -------------------------------------------------------------------- library

@app.route("/api/library")
def api_library():
    root = Path(config["download_dir"])
    store = load_categories_store()
    items = []
    if root.exists():
        for p in root.rglob("*"):
            if ".thumbs" in p.parts:
                continue
            if p.suffix.lower() in VIDEO_EXTS and p.is_file():
                rel = p.relative_to(root)
                stat = p.stat()
                is_audio = p.suffix.lower() in {".mp3", ".m4a", ".opus"}
                relurl = str(rel).replace("\\", "/")
                category = store.get(key_for(p.stem)) or store.get(relurl) or ""
                # sibling thumbnail, else ffmpeg-generated frame (for video)
                thumb = ""
                for ext in (".jpg", ".webp", ".png"):
                    cand = p.with_suffix(ext)
                    if cand.exists():
                        thumb = "/media/" + str(cand.relative_to(root)).replace("\\", "/")
                        break
                if not thumb and not is_audio:
                    thumb = "/thumb/" + relurl
                items.append({
                    "name": p.stem, "file": p.name,
                    "rel": str(rel).replace("\\", "/"),
                    "folder": str(rel.parent).replace("\\", "/") if rel.parent != Path(".") else "",
                    "size_mb": round(stat.st_size / 1048576, 1),
                    "mtime": int(stat.st_mtime),
                    "url": "/media/" + str(rel).replace("\\", "/"),
                    "thumb": thumb,
                    "category": category,
                    "audio": p.suffix.lower() in {".mp3", ".m4a", ".opus"},
                })
    items.sort(key=lambda x: x["mtime"], reverse=True)
    uncat = sum(1 for it in items if not it["category"])
    return jsonify({"root": str(root), "items": items,
                    "categories": config.get("categories", []),
                    "uncategorized": uncat})


@app.route("/api/default_categories")
def api_default_categories():
    return jsonify({"categories": DEFAULT_CONFIG["categories"]})


@app.route("/api/categorize_library", methods=["POST"])
def api_categorize_library():
    """Classify any library files that don't yet have a category (background)."""
    root = Path(config["download_dir"])
    store = load_categories_store()
    todo = []
    if root.exists():
        for p in root.rglob("*"):
            if ".thumbs" in p.parts or p.suffix.lower() not in VIDEO_EXTS or not p.is_file():
                continue
            k = key_for(p.stem)
            if not store.get(k) and not store.get(str(p.relative_to(root)).replace("\\", "/")):
                todo.append((k, p.stem))

    def worker():
        for k, name in todo:
            cat = classify_title(name)
            if cat:
                with cat_lock:
                    s = load_categories_store()
                    s[k] = cat
                    save_categories_store(s)

    if todo:
        threading.Thread(target=worker, daemon=True).start()
    return jsonify({"ok": True, "queued": len(todo)})


@app.route("/media/<path:relpath>")
def media(relpath):
    root = Path(config["download_dir"]).resolve()
    target = (root / relpath).resolve()
    if not str(target).startswith(str(root)) or not target.exists():
        abort(404)
    return send_file(target, conditional=True)  # supports range/seeking


@app.route("/thumb/<path:relpath>")
def thumb(relpath):
    """Generate & cache a poster frame from a video with ffmpeg."""
    root = Path(config["download_dir"]).resolve()
    target = (root / relpath).resolve()
    if not str(target).startswith(str(root)) or not target.exists():
        abort(404)
    cache_dir = root / ".thumbs"
    cache_dir.mkdir(parents=True, exist_ok=True)
    cache = cache_dir / (hashlib.md5(relpath.encode()).hexdigest() + ".jpg")
    if not cache.exists() or cache.stat().st_size == 0:
        for seek in ("10", "1", "0"):
            subprocess.run(["ffmpeg", "-y", "-ss", seek, "-i", str(target),
                            "-frames:v", "1", "-vf", "scale=480:-1", str(cache)],
                           capture_output=True)
            if cache.exists() and cache.stat().st_size > 0:
                break
    if cache.exists() and cache.stat().st_size > 0:
        return send_file(cache)
    abort(404)


@app.route("/api/reveal", methods=["POST"])
def api_reveal():
    """Open the folder containing a file in the OS file manager."""
    rel = request.get_json(force=True).get("rel", "")
    root = Path(config["download_dir"]).resolve()
    target = (root / rel).resolve()
    if not str(target).startswith(str(root)) or not target.exists():
        return jsonify({"ok": False}), 404
    try:
        if os.name == "nt":
            os.system(f'explorer /select,"{target}"')
        else:
            os.system(f'xdg-open "{target.parent}"')
    except Exception:
        pass
    return jsonify({"ok": True})


# ------------------------------------------------------ channel watch / notify

def resolve_channel(url):
    """Return {channel_id,title,url,thumbnail} from any channel/video URL."""
    opts = {"quiet": True, "no_warnings": True, "extract_flat": True,
            "skip_download": True, "playlistend": 1}
    opts.update(cookie_opts())
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(url, download=False)
    cid = info.get("channel_id") or info.get("uploader_id")
    if not cid and info.get("entries"):
        cid = (info["entries"][0] or {}).get("channel_id")
    title = info.get("channel") or info.get("uploader") or info.get("title", "")
    return {"channel_id": cid, "title": title,
            "url": info.get("channel_url") or url, "thumbnail": ""}


def fetch_feed(channel_id):
    """Return list of {id,title,published,thumbnail} from a channel's RSS feed."""
    r = requests.get("https://www.youtube.com/feeds/videos.xml",
                     params={"channel_id": channel_id}, timeout=15)
    r.raise_for_status()
    ns = {"a": "http://www.w3.org/2005/Atom", "yt": "http://www.youtube.com/xml/schemas/2015",
          "media": "http://search.yahoo.com/mrss/"}
    root = ET.fromstring(r.content)
    out = []
    for e in root.findall("a:entry", ns):
        vid = e.findtext("yt:videoId", "", ns)
        out.append({
            "id": vid, "title": e.findtext("a:title", "", ns),
            "published": e.findtext("a:published", "", ns)[:10],
            "thumbnail": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
        })
    return out


notifications = []  # newest first: {channel_id,channel,video_id,title,published,thumbnail,seen}
notif_lock = threading.Lock()


def poll_channels():
    while True:
        try:
            watched = config.get("watched_channels", [])
            for ch in watched:
                cid = ch.get("channel_id")
                if not cid:
                    continue
                try:
                    feed = fetch_feed(cid)
                except Exception:
                    continue
                if not feed:
                    continue
                last = ch.get("last_video_id")
                if last is None:
                    ch["last_video_id"] = feed[0]["id"]
                    continue
                fresh = []
                for v in feed:
                    if v["id"] == last:
                        break
                    fresh.append(v)
                if fresh:
                    ch["last_video_id"] = feed[0]["id"]
                    with notif_lock:
                        for v in reversed(fresh):
                            notifications.insert(0, {
                                "channel_id": cid, "channel": ch.get("title", ""),
                                "video_id": v["id"], "title": v["title"],
                                "published": v["published"], "thumbnail": v["thumbnail"],
                                "seen": False})
                    auto_download_channel(ch, fresh)
                    save_config(config)
        except Exception:
            pass
        time.sleep(max(5, int(config.get("watch_interval_min", 30))) * 60)


@app.route("/api/watch", methods=["POST"])
def api_watch():
    url = request.get_json(force=True).get("url", "").strip()
    try:
        ch = resolve_channel(url)
    except Exception as e:
        return jsonify({"error": str(e)[:200]}), 502
    if not ch.get("channel_id"):
        return jsonify({"error": "Couldn't find a channel at that URL."}), 400
    watched = config.setdefault("watched_channels", [])
    if any(w["channel_id"] == ch["channel_id"] for w in watched):
        return jsonify({"ok": True, "already": True, "channel": ch})
    try:
        feed = fetch_feed(ch["channel_id"])
        ch["last_video_id"] = feed[0]["id"] if feed else None
        ch["thumbnail"] = feed[0]["thumbnail"] if feed else ""
    except Exception:
        ch["last_video_id"] = None
    watched.append(ch)
    save_config(config)
    return jsonify({"ok": True, "channel": ch})


@app.route("/api/watch/<channel_id>/auto", methods=["POST"])
def api_watch_auto(channel_id):
    on = bool(request.get_json(force=True).get("on"))
    for w in config.get("watched_channels", []):
        if w["channel_id"] == channel_id:
            w["auto_download"] = on
    save_config(config)
    return jsonify({"ok": True})


@app.route("/api/watch/<channel_id>", methods=["DELETE"])
def api_unwatch(channel_id):
    config["watched_channels"] = [w for w in config.get("watched_channels", [])
                                  if w["channel_id"] != channel_id]
    save_config(config)
    return jsonify({"ok": True})


@app.route("/api/watched")
def api_watched():
    return jsonify({"channels": config.get("watched_channels", [])})


@app.route("/api/notifications")
def api_notifications():
    with notif_lock:
        return jsonify({"items": notifications[:100],
                        "unseen": sum(1 for n in notifications if not n["seen"])})


@app.route("/api/notifications/seen", methods=["POST"])
def api_notif_seen():
    with notif_lock:
        for n in notifications:
            n["seen"] = True
    return jsonify({"ok": True})


@app.route("/api/check_now", methods=["POST"])
def api_check_now():
    """Force an immediate poll of all watched channels."""
    watched = config.get("watched_channels", [])
    found = 0
    for ch in watched:
        cid = ch.get("channel_id")
        if not cid:
            continue
        try:
            feed = fetch_feed(cid)
        except Exception:
            continue
        last = ch.get("last_video_id")
        fresh = []
        for v in feed:
            if v["id"] == last:
                break
            fresh.append(v)
        if last is None and feed:
            ch["last_video_id"] = feed[0]["id"]
        elif fresh:
            ch["last_video_id"] = feed[0]["id"]
            with notif_lock:
                for v in reversed(fresh):
                    notifications.insert(0, {
                        "channel_id": cid, "channel": ch.get("title", ""),
                        "video_id": v["id"], "title": v["title"],
                        "published": v["published"], "thumbnail": v["thumbnail"],
                        "seen": False})
            auto_download_channel(ch, fresh)
            found += len(fresh)
    save_config(config)
    return jsonify({"ok": True, "new": found})


# -------------------------------------------------------------------- settings

@app.route("/api/settings", methods=["GET", "POST"])
def api_settings():
    global config, executor
    if request.method == "GET":
        return jsonify(config)
    inc = request.get_json(force=True)
    for k in ("download_dir", "bind_host", "youtube_api_keys",
              "active_ai_provider", "search_engine", "watch_interval_min",
              "auto_download_new", "auto_categorize", "categories"):
        if k in inc:
            config[k] = inc[k]
    if "ai_providers" in inc:
        for name, val in inc["ai_providers"].items():
            config["ai_providers"].setdefault(name, {}).update(val)
    if "ytdlp" in inc:
        config["ytdlp"].update(inc["ytdlp"])
    Path(config["download_dir"]).mkdir(parents=True, exist_ok=True)
    save_config(config)
    executor = None
    return jsonify({"ok": True, "config": config})


@app.route("/api/test_key", methods=["POST"])
def api_test_key():
    key = request.get_json(force=True).get("key", "").strip()
    r = requests.get(YT_SEARCH, params={"part": "snippet", "q": "test",
                     "maxResults": 1, "type": "video", "key": key}, timeout=15)
    if r.status_code == 200:
        return jsonify({"ok": True})
    try:
        msg = r.json()["error"]["message"]
    except Exception:
        msg = r.text[:200]
    return jsonify({"ok": False, "error": msg})


# -------------------------------------------------------------------------- AI

AI_EXPAND_SYSTEM = (
    "You are a YouTube search assistant. The user describes what they want to "
    "find. Reply ONLY with a JSON array of 3-6 diverse YouTube search query "
    "strings that would surface that content. No commentary, no markdown.")

AI_SELECT_SYSTEM = (
    "You are a video curator. You get a user's intent and a numbered list of "
    "YouTube videos (id | title | channel | duration). Reply ONLY with a JSON "
    "array of the video ids that genuinely match the intent. Be selective. "
    "No commentary, no markdown.")


def call_ai(provider, prompt, system):
    p = config["ai_providers"].get(provider, {})
    key, model = p.get("api_key", ""), p.get("model", "")
    if not key and provider != "local":
        raise RuntimeError(f"No API key set for {provider}. Add it in Settings.")
    if provider == "anthropic":
        r = requests.post("https://api.anthropic.com/v1/messages",
            headers={"x-api-key": key, "anthropic-version": "2023-06-01",
                     "content-type": "application/json"},
            json={"model": model, "max_tokens": 1500, "system": system,
                  "messages": [{"role": "user", "content": prompt}]}, timeout=30)
        r.raise_for_status()
        return r.json()["content"][0]["text"]
    if provider == "gemini":
        r = requests.post(
            f"https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent",
            params={"key": key},
            json={"system_instruction": {"parts": [{"text": system}]},
                  "contents": [{"parts": [{"text": prompt}]}]}, timeout=30)
        r.raise_for_status()
        return r.json()["candidates"][0]["content"]["parts"][0]["text"]
    base = {"openai": "https://api.openai.com/v1",
            "deepseek": "https://api.deepseek.com/v1",
            "openrouter": "https://openrouter.ai/api/v1",
            "groq": "https://api.groq.com/openai/v1",
            "local": p.get("base_url") or "http://localhost:11434/v1"}.get(provider)
    if not base:
        raise RuntimeError(f"Unknown provider: {provider}")
    timeout = 120 if provider == "local" else 30  # local models can be slower
    r = requests.post(f"{base}/chat/completions",
        headers={"Authorization": f"Bearer {key or 'local'}"},
        json={"model": model, "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": prompt}]}, timeout=timeout)
    r.raise_for_status()
    return r.json()["choices"][0]["message"]["content"]


@app.route("/api/ai_expand", methods=["POST"])
def api_ai_expand():
    data = request.get_json(force=True)
    provider = data.get("provider") or config.get("active_ai_provider")
    if not provider:
        return jsonify({"error": "No AI provider selected in Settings."}), 400
    try:
        text = call_ai(provider, data.get("prompt", ""), AI_EXPAND_SYSTEM)
        m = re.search(r"\[.*\]", text, re.DOTALL)
        queries = json.loads(m.group(0)) if m else [text.strip()]
        return jsonify({"queries": [str(q) for q in queries if str(q).strip()][:6]})
    except Exception as e:
        return jsonify({"error": str(e)[:300]}), 502


@app.route("/api/ai_select", methods=["POST"])
def api_ai_select():
    data = request.get_json(force=True)
    provider = data.get("provider") or config.get("active_ai_provider")
    videos = data.get("videos", [])
    if not provider:
        return jsonify({"error": "No AI provider selected in Settings."}), 400
    if not videos:
        return jsonify({"error": "No videos to choose from."}), 400
    listing = "\n".join(f"{v['id']} | {v['title']} | {v.get('channel','')} | {v.get('duration','')}"
                        for v in videos[:200])
    try:
        text = call_ai(provider, f"Intent: {data.get('intent','')}\n\nVideos:\n{listing}",
                       AI_SELECT_SYSTEM)
        m = re.search(r"\[.*\]", text, re.DOTALL)
        ids = json.loads(m.group(0)) if m else []
        valid = {v["id"] for v in videos}
        return jsonify({"ids": [i for i in ids if i in valid]})
    except Exception as e:
        return jsonify({"error": str(e)[:300]}), 502


# ------------------------------------------------------------------------- UI

@app.route("/")
def index():
    return render_template("index.html")


if __name__ == "__main__":
    Path(config["download_dir"]).mkdir(parents=True, exist_ok=True)
    threading.Thread(target=poll_channels, daemon=True).start()
    if os.environ.get("YTG_NO_BROWSER") != "1":
        threading.Timer(1.2, lambda: webbrowser.open("http://127.0.0.1:5117")).start()
    app.run(host=config.get("bind_host", "127.0.0.1"), port=5117,
            debug=False, threaded=True)
