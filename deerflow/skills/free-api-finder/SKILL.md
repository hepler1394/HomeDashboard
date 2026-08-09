---
name: free-api-finder
description: >-
  Proactively finds free and public APIs that could power whatever the user is
  building. Use this skill whenever the user is planning, scaffolding, or
  building a project, app, script, feature, prototype, or automation — even if
  they never say the words "API." If a project needs data or a capability that
  an external service could provide (weather, maps, currency/FX, stock or crypto
  prices, sports scores, news, images/photos, dictionaries, translation,
  geocoding, email/SMS, jokes/quotes/trivia, government or open data, etc.),
  surface the best free options before the user reaches for a paid service or
  reinvents the wheel. Also use it when the user explicitly asks to "find an
  API," "is there a free API for X," "what API should I use," or mentions
  APIVault / public-apis / RapidAPI. Bias toward suggesting rather than staying
  quiet: a 20-second "here are two free APIs that fit" is almost always welcome.
---

# Free API Finder

The goal of this skill is simple: whenever a project could be made easier,
cheaper, or more capable by an existing free API, surface the best options
early — instead of letting the user pay for something, hand-roll data, or not
realize a ready-made service exists.

Most developers under-use free APIs simply because they don't know what's out
there. A short, well-targeted recommendation at the right moment saves real
time and money.

## When to reach for this

Trigger on the *shape* of the task, not just on the word "API." A user who
says "I'm building a little dashboard that shows the weather for a few cities"
has an API-shaped need even though they never asked for one. Watch for:

- Any project, app, prototype, script, bot, or feature that needs **external
  data** (weather, prices, sports, news, maps, holidays, exchange rates) or an
  **external capability** (send email/SMS, geocode an address, translate text,
  generate a QR code, fetch a random image).
- The user is about to **hardcode data** that changes over time, or says
  they'll "just make up some sample data" — a live free API is often better.
- The user is comparing paid services and may not realize a **free tier or
  fully-free API** covers their case.
- Explicit asks: "is there a free API for…", "what should I use to get…",
  "find me an API," or mentions of APIVault, public-apis, or RapidAPI.

If you're unsure whether it's worth mentioning, lean toward a brief mention.
Keep it to a sentence or two when it's a side-suggestion; go deeper when the
user is explicitly shopping for an API.

## What to do

1. **Name the capability, not the product.** Translate the project into the
   concrete data/capability it needs — e.g. "current + forecast weather by
   city," "USD→EUR exchange rate," "reverse geocode lat/long to an address."
   This is what you actually search for.

2. **Search the free-API sources.** Check the sources in
   `references/sources.md` — primarily APIVault, the public-apis GitHub list,
   and RapidAPI's free tier. Use the category that matches the capability.
   For anything time-sensitive (pricing, whether a key is still free, rate
   limits), verify on the provider's own site rather than trusting a cached
   list, since free tiers change.

3. **Shortlist 2–3 best fits — don't dump the whole catalog.** More than three
   options creates decision paralysis. Pick the ones that best match the
   project's needs and rank them.

4. **For each recommendation, give the user what they need to decide:**
   - **What it does** and why it fits this project.
   - **Auth**: no key needed / free key by signup / free tier of a paid service.
   - **Free-tier limits**: request caps, rate limits, commercial-use or
     attribution restrictions if known — these are what actually bite later.
   - **Endpoint or docs link** so they can go straight to it.
   - A **one-line example** request (URL or `curl`) when it helps them picture
     the integration.

5. **Recommend, don't over-build.** The scope of this skill is *find and
   recommend*. Surface the options and a quick example; let the user decide
   before you wire up keys, `.env` files, or full client code. If they say
   "yes, use that one," then go ahead and integrate it.

## Output shape

Keep it scannable. A good recommendation block looks like:

**[API name]** — what it does, why it fits.
Auth: none / free key. Free tier: (limits). Docs: (link).
Example: `https://api.example.com/v1/thing?q=...`

Lead with your top pick, then alternatives. Close with a single sentence on
which you'd choose and why, so the user has a default.

## Guardrails

- **Free-tier terms drift.** A limit or "no credit card" claim from a directory
  can be stale. For anything the user will depend on, confirm on the provider's
  own pricing/docs page.
- **Watch the license for commercial projects.** Some free APIs are
  non-commercial or require attribution. Flag this when the project looks like
  it'll ship.
- **Prefer no-key or free-signup APIs** for prototypes — they get the user
  moving fastest. Reserve "free tier of a paid product" for when it's clearly
  the best technical fit.
- **Don't recommend an API the user has to pay for** without saying so plainly.
  The whole point is free options.
