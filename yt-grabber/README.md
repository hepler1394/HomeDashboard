# YT Grabber

A local, AI-powered YouTube search, download, and library tool with a YouTube-style UI. Search any subject (or paste a channel/playlist/video URL), preview, and bulk-download at best quality via yt-dlp. Runs entirely on your machine.

**Use only for videos you own or are licensed to download** (your own channels, friends' channels with permission, Creative Commons, etc.).

## Run

Double-click **`Start YT Grabber.bat`**, or:

```
pip install -r requirements.txt
python app.py
```

Opens automatically at http://127.0.0.1:5117 (localhost only). Requires **ffmpeg** on PATH.

## Features

- **Accurate search** powered by yt-dlp — finds exact titles, no API quota. (Optional YouTube Data API engine in Settings.)
- **Channel / playlist / video URLs** — paste one to list every upload (up to 500) and bulk-grab.
- **Select all / multi-select → download best quality**, with a live download queue (progress, speed, ETA, cancel, retry, cancel-all).
- **AI expand** turns a rough idea into several smart search queries.
- **AI select** auto-checks only the results matching a plain-language description.
- **Local model support** — point at Ollama / LM Studio (e.g. Qwen) so AI features run free, private, on your own hardware. Cloud providers (DeepSeek, Gemini, Anthropic, OpenAI, OpenRouter, Groq) also supported.
- **Library** — browse everything in your download folder with in-browser playback, plus text search, category (folder) filter, type/sort filters, and **AI smart search** over your files.
- **Channel watch + notifications** — watch channels via their RSS feed; new uploads appear in a Notifications tab. Optional per-channel **auto-download** (master switch, off by default).
- **Creative Commons filter**, duplicate-skipping download archive, cookie support (browser or cookies.txt) for your own private/unlisted videos.
- Robust **Settings**: download location, concurrency, filename template, speed limit, quality/format checkboxes, and more.

## Configuration

All settings live in `config.json` (created on first run, gitignored). Add API keys, cookies, and preferences in the in-app Settings panel.

## Security

`.gitignore` excludes `cookies.txt`, `config.json`, and `downloaded_archive.txt` so secrets never get committed. Keep this repo private if your local config contains keys or cookies. The app binds to localhost only.
