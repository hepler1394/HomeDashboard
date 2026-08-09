# Free & Public API Sources

Priority order for finding free APIs. Match the project's needed capability to
a category, pull a shortlist, then verify current free-tier terms on the
provider's own site (free tiers change).

## 1. APIVault — apivault.dev

An open directory of thousands of free and public APIs across ~50 categories
(animals, anime, blockchain, crypto, finance, health, music, news, weather,
development, and more).

- Browse by category: `https://apivault.dev/categories`
- A specific category, e.g. development: `https://apivault.dev/categories/Development`
- Good first stop for "is there a free API for X" — most listings are no-key
  or free-signup.

## 2. public-apis (GitHub) — github.com/public-apis/public-apis

The largest community-maintained list of free APIs, organized as a big
category table. Each row notes whether **Auth** is required (No / apiKey /
OAuth), whether **HTTPS** is supported, and CORS status — which makes it easy
to filter for zero-friction options.

- Repo: `https://github.com/public-apis/public-apis`
- Fastest way to search: use the on-page browser find within a category, or
  search the repo for the capability keyword (e.g. "weather", "currency").
- A mirror with a searchable JSON API also exists at
  `https://github.com/public-api-lists/public-api-lists` if you want
  programmatic lookup.

## 3. RapidAPI free tier — rapidapi.com

A large API marketplace. Many APIs offer a **free tier** (often "freemium":
free up to N requests/month, then paid). Useful when you need something more
specialized or with an SLA than the fully-free directories carry.

- Hub: `https://rapidapi.com/hub`
- Filter results to **Free** pricing. Note these usually require a RapidAPI
  account and key, and the "free" tier has a monthly cap — always read the
  pricing panel, since the free allowance and overage behavior vary a lot.

## Verifying before recommending

- Open the provider's own docs/pricing page for anything the user will depend
  on. Directory metadata (key required?, rate limit, commercial use) can be
  out of date.
- Prefer no-key or free-signup APIs for prototypes; flag non-commercial or
  attribution-required licenses for anything that will ship.
