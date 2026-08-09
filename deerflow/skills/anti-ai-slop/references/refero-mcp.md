# Using Refero as the reference source

[Refero](https://refero.design/search) is a curated library of high-quality real
product screens (web and iOS). It is the preferred first stop for step 1 —
anchoring to real human design before building. The user has a Refero Pro
account.

## If the Refero MCP is connected

Refero exposes an MCP server, so its search tools may be available in-session
(look for `refero` / `mcp__refero__*` tools, e.g. a search tool). When present:

- **Search by the specific surface and product category**, not generic words.
  Good queries: "fintech onboarding flow," "SaaS pricing page," "dashboard empty
  state," "settings page," "multi-step form navigation," "mobile checkout,"
  "analytics dashboard dark." Weak queries: "nice website," "modern UI."
- **Pull 2–4 screens** that fit the brief and study *why* they work: type scale,
  spacing rhythm, color restraint, hierarchy, how they handle edge/empty states.
- **Translate into constraints** for the current build (named type pairing,
  palette, spacing scale, layout pattern) and write them down before coding.
- If the first search is thin, try the same intent phrased by industry, by app
  name, or by flow.

## If the Refero MCP is NOT connected

Tell the user it isn't connected and offer the one-line setup. They configure it
with **their own token** from https://refero.design/mcp (Pro required). Do not
hardcode anyone's token into this skill or into shared config — it's a personal
secret.

Claude Code, for example, connects it with:

```
claude mcp add --transport http refero https://api.refero.design/mcp \
  --header "Authorization: Bearer <YOUR_REFERO_TOKEN>"
```

Cursor, Antigravity, Lovable, Codex, and others have equivalent config on the
same Refero MCP setup page. After adding it, the first Refero call opens a
browser to sign in, then it's automatic.

## If Refero can't be used at all right now

Fall back to reasoning from 2–3 specific, named real products that fit the brief
(e.g. Linear, Stripe, Vercel, Notion, Things, Raycast) — extract concrete
choices from how *they* actually solve the surface, rather than inventing a
generic look. Still write the choices down as constraints before building.
